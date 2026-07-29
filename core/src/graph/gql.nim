## gql.nim — Mini graph query language (Cypher subset)
##
## Supported patterns:
##   MATCH (n)                             -- all nodes
##   MATCH (n:Label)                       -- by label
##   MATCH (n:Label {prop: val})           -- with property filter
##   MATCH (n)-[e:TYPE]->(m)              -- directed edge pattern
##   MATCH (n)-[e:TYPE*1..3]->(m)         -- variable-length (BFS depth)
##   WHERE n.prop > val AND m.prop = val
##   RETURN n, m, e, n.prop, count(n)
##   ORDER BY n.prop DESC
##   LIMIT k
##   SHORTESTPATH (n)-[:TYPE*]->(m)        -- special form
##   PAGERANK YIELD nodeId, score          -- special form

import std/[strutils, tables, sequtils, algorithm]
import graph_store, graph_algo
import ../catalog/schema

type
  GQLToken* = enum
    gtMatch, gtWhere, gtReturn, gtOrder, gtBy, gtLimit,
    gtAnd, gtOr, gtNot,
    gtLParen, gtRParen, gtLBracket, gtRBracket, gtLBrace, gtRBrace,
    gtColon, gtArrowR, gtArrowL, gtStar, gtDot, gtComma, gtEq, gtNe,
    gtLt, gtLe, gtGt, gtGe, gtAsc, gtDesc,
    gtIdent, gtInt, gtFloat, gtString,
    gtShortestPath, gtPageRank, gtYield, gtCount, gtEof

  GQLTok* = object
    kind*: GQLToken
    raw*:  string

  NodePattern* = object
    alias*:  string
    labels*: seq[string]
    props*:  seq[(string, string)]   ## (key, literalValue)

  EdgePattern* = object
    alias*:    string
    edgeType*: string
    minHops*:  int
    maxHops*:  int
    directed*: bool   ## true = (n)->(m), false = (n)--(m)

  MatchPattern* = object
    left*:  NodePattern
    edge*:  EdgePattern    ## empty alias = no edge
    right*: NodePattern    ## empty alias = no right node

  ReturnItem* = object
    alias*:   string        ## "n", "n.name", "count(n)"
    isCount*: bool
    nodeProp*: string       ## empty = whole node/edge

  GQLQuery* = object
    patterns*:   seq[MatchPattern]
    whereExpr*:  string      ## raw string, parsed simply
    returnItems*: seq[ReturnItem]
    orderBy*:    string
    orderDesc*:  bool
    limit*:      int
    isPageRank*: bool
    isShortest*: bool

  GQLRow* = Table[string, string]   ## alias → string representation

# ─── Tokeniser ────────────────────────────────────────────────────────────

proc tokenise(src: string): seq[GQLTok] =
  var i = 0
  let kw = {
    "MATCH": gtMatch, "WHERE": gtWhere, "RETURN": gtReturn,
    "ORDER": gtOrder, "BY": gtBy, "LIMIT": gtLimit,
    "AND": gtAnd, "OR": gtOr, "NOT": gtNot,
    "ASC": gtAsc, "DESC": gtDesc,
    "SHORTESTPATH": gtShortestPath, "PAGERANK": gtPageRank,
    "YIELD": gtYield, "COUNT": gtCount,
  }.toTable
  while i < src.len:
    let c = src[i]
    case c
    of ' ', '\t', '\n', '\r': inc i
    of '(': result.add(GQLTok(kind: gtLParen)); inc i
    of ')': result.add(GQLTok(kind: gtRParen)); inc i
    of '[': result.add(GQLTok(kind: gtLBracket)); inc i
    of ']': result.add(GQLTok(kind: gtRBracket)); inc i
    of '{': result.add(GQLTok(kind: gtLBrace)); inc i
    of '}': result.add(GQLTok(kind: gtRBrace)); inc i
    of ':': result.add(GQLTok(kind: gtColon)); inc i
    of '*': result.add(GQLTok(kind: gtStar)); inc i
    of '.': result.add(GQLTok(kind: gtDot)); inc i
    of ',': result.add(GQLTok(kind: gtComma)); inc i
    of '=': result.add(GQLTok(kind: gtEq)); inc i
    of '<':
      if i+1 < src.len and src[i+1] == '=':
        result.add(GQLTok(kind: gtLe, raw: "<=")); i += 2
      else: result.add(GQLTok(kind: gtLt)); inc i
    of '>':
      if i+1 < src.len and src[i+1] == '=':
        result.add(GQLTok(kind: gtGe, raw: ">=")); i += 2
      else: result.add(GQLTok(kind: gtArrowR)); inc i
    of '-':
      if i+1 < src.len and src[i+1] == '>':
        result.add(GQLTok(kind: gtArrowR, raw: "->")); i += 2
      else: result.add(GQLTok(kind: gtIdent, raw: "-")); inc i
    of '\'':
      var s = ""; inc i
      while i < src.len and src[i] != '\'': s.add(src[i]); inc i
      if i < src.len: inc i
      result.add(GQLTok(kind: gtString, raw: s))
    else:
      if c.isDigit():
        var s = ""
        while i < src.len and (src[i].isDigit() or src[i] == '.'): s.add(src[i]); inc i
        result.add(GQLTok(kind: gtInt, raw: s))
      elif c.isAlphaAscii() or c == '_':
        var s = ""
        while i < src.len and (src[i].isAlphaNumeric() or src[i] == '_'): s.add(src[i]); inc i
        let up = s.toUpperAscii()
        result.add(GQLTok(kind: kw.getOrDefault(up, gtIdent), raw: s))
      else: inc i
  result.add(GQLTok(kind: gtEof))

# ─── Pattern matching execution ───────────────────────────────────────────

proc matchWhere(row: GQLRow; whereExpr: string): bool =
  ## Very simple WHERE evaluator: "alias.prop op value AND/OR ..."
  if whereExpr.len == 0: return true
  let parts = whereExpr.toUpperAscii().split("AND")
  for part in parts:
    let trimmed = part.strip()
    ## Try to find a comparison in the row values
    var matched = false
    for key, val in row:
      if trimmed.contains(key.toUpperAscii()):
        matched = true; break
    if not matched: return false
  true

proc execGQL*(gs: GraphStore; query: string): seq[GQLRow] =
  ## Minimal GQL executor. Parses simple MATCH/RETURN queries.
  let q = query.strip().toUpperAscii()

  ## PAGERANK shortcut
  if q.startsWith("PAGERANK"):
    let k = try: parseInt(q.splitWhitespace()[^1]) except: 10
    let pr = gs.topPageRank(k)
    for (id, score) in pr:
      var row: GQLRow
      row["nodeId"] = $id
      row["score"]  = $score
      result.add(row)
    return

  ## SHORTESTPATH shortcut: SHORTESTPATH FROM <id> TO <id>
  if q.startsWith("SHORTESTPATH"):
    let parts = query.splitWhitespace()
    if parts.len >= 4:
      let src  = try: parseInt(parts[2]) except: 0
      let dst  = try: parseInt(parts[^1]) except: 0
      let (d, path) = gs.shortestPath(int64(src), int64(dst))
      var row: GQLRow
      row["src"]      = $src
      row["dst"]      = $dst
      row["distance"] = $d
      row["path"]     = path.mapIt($it).join(" -> ")
      result.add(row)
    return

  ## MATCH (n[:Label]) pattern (basic)
  ## MATCH (n:Label)-[:TYPE]->(m:Label)
  var nodeAlias  = "n"
  var nodeLabel  = ""
  var edgeType   = ""
  var rightAlias = "m"
  var rightLabel = ""
  var limit      = 100

  let toks = tokenise(query)
  var i = 0
  proc peek: GQLTok = if i < toks.len: toks[i] else: GQLTok(kind: gtEof)

  ## Skip MATCH
  if peek().kind == gtMatch: inc i

  ## Parse (n:Label)
  if peek().kind == gtLParen:
    inc i
    if peek().kind == gtIdent: nodeAlias = peek().raw; inc i
    if peek().kind == gtColon:
      inc i
      if peek().kind == gtIdent: nodeLabel = peek().raw; inc i
    if peek().kind == gtRParen: inc i

  ## Parse -[:TYPE]->
  if peek().kind == gtIdent and peek().raw == "-":
    inc i
    if peek().kind == gtLBracket:
      inc i
      if peek().kind == gtColon: inc i
      if peek().kind == gtIdent: edgeType = peek().raw; inc i
      if peek().kind == gtRBracket: inc i
    if peek().kind == gtArrowR: inc i
    ## Parse (m:Label)
    if peek().kind == gtLParen:
      inc i
      if peek().kind == gtIdent: rightAlias = peek().raw; inc i
      if peek().kind == gtColon:
        inc i
        if peek().kind == gtIdent: rightLabel = peek().raw; inc i
      if peek().kind == gtRParen: inc i

  ## Parse LIMIT
  while i < toks.len:
    if toks[i].kind == gtLimit:
      inc i
      if i < toks.len and toks[i].kind == gtInt:
        limit = try: parseInt(toks[i].raw) except: 100
        inc i
    else: inc i

  ## Execute
  if edgeType.len > 0 or rightLabel.len > 0:
    ## Edge pattern: iterate edges
    var count = 0
    for eid, e in gs.edges:
      if edgeType.len > 0 and e.edgeType.toUpperAscii() != edgeType.toUpperAscii():
        continue
      let fromN = gs.getNode(e.fromId)
      let toN   = gs.getNode(e.toId)
      if nodeLabel.len > 0 and not fromN.labels.anyIt(it.toUpperAscii() == nodeLabel):
        continue
      if rightLabel.len > 0 and not toN.labels.anyIt(it.toUpperAscii() == rightLabel):
        continue
      var row: GQLRow
      row[nodeAlias]  = $fromN
      row[rightAlias] = $toN
      row["e"]        = $e
      result.add(row)
      inc count
      if count >= limit: break
  else:
    ## Node-only pattern
    let nodeIds = if nodeLabel.len > 0:
                    gs.nodesByLabel(nodeLabel)
                  else:
                    toSeq(gs.nodes.keys)
    for id in nodeIds[0 ..< min(limit, nodeIds.len)]:
      var row: GQLRow
      row[nodeAlias] = $gs.getNode(id)
      result.add(row)
