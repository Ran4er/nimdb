## parser.nim — Recursive descent SQL parser

import std/[strutils, parseutils]
import ../storage/types
import ../catalog/schema
import ast, lexer

type
  Parser* = object
    tokens*: seq[Token]
    pos*:    int

proc newParser*(src: string): Parser =
  Parser(tokens: tokenize(src), pos: 0)

proc peek(p: Parser): Token {.inline.} =
  if p.pos < p.tokens.len: p.tokens[p.pos]
  else: Token(kind: tkEof)

proc peekKind(p: Parser): TokKind {.inline.} = p.peek().kind

proc advance(p: var Parser): Token =
  result = p.peek()
  if p.pos < p.tokens.len: inc p.pos

proc check(p: Parser; k: TokKind): bool {.inline.} = p.peekKind() == k

proc match(p: var Parser; k: TokKind): bool =
  if p.check(k): discard p.advance(); true else: false

proc expect(p: var Parser; k: TokKind): Token =
  if not p.check(k):
    raise newException(SQLError,
      "Expected " & $k & " but got " & $p.peekKind() &
      " ('" & p.peek().raw & "') at line " & $p.peek().line)
  p.advance()

proc expectIdent(p: var Parser): string = p.expect(tkIdent).raw

# ─── Expression parsing ───────────────────────────────────────────────────

proc parseExpr(p: var Parser): Expr
proc parsePrimary(p: var Parser): Expr
proc parseOr(p: var Parser): Expr
proc parseAnd(p: var Parser): Expr
proc parseNot(p: var Parser): Expr
proc parseComparison(p: var Parser): Expr
proc parseAddSub(p: var Parser): Expr
proc parseMulDiv(p: var Parser): Expr
proc parseUnary(p: var Parser): Expr

proc parsePrimary(p: var Parser): Expr =
  let t = p.peek()
  case t.kind
  of tkInt:
    discard p.advance()
    let v = parseInt(t.raw)
    return Expr(kind: ekLit, lit: intVal(int32(v)))
  of tkFloat:
    discard p.advance()
    let v = parseFloat(t.raw)
    return Expr(kind: ekLit, lit: floatVal(v))
  of tkString:
    discard p.advance()
    return Expr(kind: ekLit, lit: textVal(t.raw))
  of tkTRUE:
    discard p.advance()
    return Expr(kind: ekLit, lit: boolVal(true))
  of tkFALSE:
    discard p.advance()
    return Expr(kind: ekLit, lit: boolVal(false))
  of tkNULL:
    discard p.advance()
    return Expr(kind: ekLit, lit: nullVal())
  of tkStar:
    discard p.advance()
    return Expr(kind: ekStar)
  of tkMinus:
    discard p.advance()
    let inner = p.parsePrimary()
    return Expr(kind: ekUnOp, uop: uoNeg, operand: inner)
  of tkNOT:
    discard p.advance()
    let inner = p.parsePrimary()
    return Expr(kind: ekUnOp, uop: uoNot, operand: inner)
  of tkCAST:
    discard p.advance()
    discard p.expect(tkLParen)
    let inner = p.parseExpr()
    discard p.expect(tkIdent)  # AS
    let typeKw = p.advance()
    let ck = parseColKind(typeKw.raw)
    discard p.expect(tkRParen)
    return Expr(kind: ekCast, castExpr: inner, castTo: ck)
  of tkLParen:
    discard p.advance()
    let inner = p.parseExpr()
    discard p.expect(tkRParen)
    return inner
  of tkIdent:
    let name = p.advance().raw
    # Function call?
    if p.check(tkLParen):
      discard p.advance()
      var args: seq[Expr]
      if not p.check(tkRParen):
        args.add(p.parseExpr())
        while p.match(tkComma): args.add(p.parseExpr())
      discard p.expect(tkRParen)
      return Expr(kind: ekFunc, fname: name.toLowerAscii(), fargs: args)
    # Qualified column: table.col
    if p.check(tkDot):
      discard p.advance()
      let col = p.expectIdent()
      return Expr(kind: ekCol, table: name, col: col)
    return Expr(kind: ekCol, table: "", col: name)
  else:
    raise newException(SQLError, "Unexpected token in expression: " & $t.kind & " '" & t.raw & "'")

proc parseUnary(p: var Parser): Expr = p.parsePrimary()

proc parseMulDiv(p: var Parser): Expr =
  result = p.parseUnary()
  while p.peekKind() in {tkStar, tkSlash, tkPercent}:
    let op = case p.advance().kind
             of tkStar:    boMul
             of tkSlash:   boDiv
             of tkPercent: boMod
             else: boMul
    let rhs = p.parseUnary()
    result = Expr(kind: ekBinOp, op: op, left: result, right: rhs)

proc parseAddSub(p: var Parser): Expr =
  result = p.parseMulDiv()
  while p.peekKind() in {tkPlus, tkMinus}:
    let op = if p.advance().kind == tkPlus: boAdd else: boSub
    let rhs = p.parseMulDiv()
    result = Expr(kind: ekBinOp, op: op, left: result, right: rhs)

proc parseComparison(p: var Parser): Expr =
  result = p.parseAddSub()
  while true:
    let k = p.peekKind()
    if k == tkIS:
      discard p.advance()
      let neg = p.match(tkNOT)
      discard p.expect(tkNULL)
      result = Expr(kind: ekUnOp,
                    uop: if neg: uoIsNotNull else: uoIsNull,
                    operand: result)
      continue
    if k == tkIN:
      discard p.advance()
      discard p.expect(tkLParen)
      var vals: seq[Expr]
      if not p.check(tkRParen):
        vals.add(p.parseExpr())
        while p.match(tkComma): vals.add(p.parseExpr())
      discard p.expect(tkRParen)
      # Desugar: col IN (a,b,c) → col=a OR col=b OR col=c
      if vals.len == 0:
        result = Expr(kind: ekLit, lit: boolVal(false))
      else:
        var chain = Expr(kind: ekBinOp, op: boEq, left: result, right: vals[0])
        for i in 1 ..< vals.len:
          chain = Expr(kind: ekBinOp, op: boOr, left: chain,
                       right: Expr(kind: ekBinOp, op: boEq,
                                   left: result, right: vals[i]))
        result = chain
      continue
    if k == tkLIKE:
      discard p.advance()
      let rhs = p.parseAddSub()
      result = Expr(kind: ekBinOp, op: boLike, left: result, right: rhs)
      continue
    let op = case k
      of tkEq: boEq
      of tkNe: boNe
      of tkLt: boLt
      of tkLe: boLe
      of tkGt: boGt
      of tkGe: boGe
      else: break
    discard p.advance()
    let rhs = p.parseAddSub()
    result = Expr(kind: ekBinOp, op: op, left: result, right: rhs)

proc parseNot(p: var Parser): Expr =
  if p.match(tkNOT):
    let inner = p.parseComparison()
    return Expr(kind: ekUnOp, uop: uoNot, operand: inner)
  p.parseComparison()

proc parseAnd(p: var Parser): Expr =
  result = p.parseNot()
  while p.match(tkAND):
    let rhs = p.parseNot()
    result = Expr(kind: ekBinOp, op: boAnd, left: result, right: rhs)

proc parseOr(p: var Parser): Expr =
  result = p.parseAnd()
  while p.match(tkOR):
    let rhs = p.parseAnd()
    result = Expr(kind: ekBinOp, op: boOr, left: result, right: rhs)

proc parseExpr(p: var Parser): Expr = p.parseOr()

# ─── SELECT ───────────────────────────────────────────────────────────────

proc parseSelectItems(p: var Parser): seq[SelectItem] =
  proc parseOne(p: var Parser): SelectItem =
    let e = p.parseExpr()
    var alias = ""
    if p.match(tkAS): alias = p.expectIdent()
    elif p.check(tkIdent): alias = p.expectIdent()
    SelectItem(expr: e, alias: alias)
  result.add(p.parseOne())
  while p.match(tkComma): result.add(p.parseOne())

proc parseSelect(p: var Parser): Stmt =
  let dist = p.match(tkDISTINCT)
  let items = p.parseSelectItems()
  discard p.expect(tkFROM)
  let tbl = p.expectIdent()
  var alias = ""
  if p.match(tkAS) or p.check(tkIdent): alias = p.expectIdent()

  var joins: seq[JoinClause]
  while p.peekKind() in {tkJOIN, tkINNER, tkLEFT, tkRIGHT, tkFULL, tkCROSS}:
    var jk = jkInner
    if p.match(tkLEFT): jk = jkLeft
    elif p.match(tkRIGHT): jk = jkRight
    elif p.match(tkFULL): jk = jkFull
    elif p.match(tkCROSS): jk = jkCross
    discard p.match(tkINNER); discard p.match(tkJOIN)
    let jt = p.expectIdent()
    var ja = ""; if p.match(tkAS) or p.check(tkIdent): ja = p.expectIdent()
    var onExpr: Expr
    if jk != jkCross: discard p.expect(tkON); onExpr = p.parseExpr()
    joins.add(JoinClause(kind: jk, table: jt, alias: ja, on: onExpr))

  var whereExpr: Expr
  if p.match(tkWHERE): whereExpr = p.parseExpr()

  var groupBy: seq[Expr]
  if p.match(tkGROUP):
    discard p.expect(tkBY)
    groupBy.add(p.parseExpr())
    while p.match(tkComma): groupBy.add(p.parseExpr())

  var having: Expr
  if p.match(tkHAVING): having = p.parseExpr()

  var orderBy: seq[OrderBy]
  if p.match(tkORDER):
    discard p.expect(tkBY)
    proc parseOB(p: var Parser): OrderBy =
      let e = p.parseExpr()
      let d = if p.match(tkDESC): odDesc else: (discard p.match(tkASC); odAsc)
      OrderBy(expr: e, dir: d)
    orderBy.add(p.parseOB())
    while p.match(tkComma): orderBy.add(p.parseOB())

  var lim = -1
  if p.match(tkLIMIT): lim = parseInt(p.expect(tkInt).raw)

  var off = 0
  if p.match(tkOFFSET): off = parseInt(p.expect(tkInt).raw)

  Stmt(kind: skSelect, distinct: dist, selItems: items,
       fromTable: tbl, fromAlias: alias, joins: joins,
       whereExpr: whereExpr, groupBy: groupBy, having: having,
       orderBy: orderBy, limitVal: lim, offsetVal: off)

# ─── INSERT ───────────────────────────────────────────────────────────────

proc parseInsert(p: var Parser): Stmt =
  discard p.expect(tkINTO)
  let tbl = p.expectIdent()
  var cols: seq[string]
  if p.match(tkLParen):
    cols.add(p.expectIdent())
    while p.match(tkComma): cols.add(p.expectIdent())
    discard p.expect(tkRParen)
  discard p.expect(tkVALUES)
  var rows: seq[seq[Expr]]
  proc parseRowVals(p: var Parser): seq[Expr] =
    discard p.expect(tkLParen)
    result.add(p.parseExpr())
    while p.match(tkComma): result.add(p.parseExpr())
    discard p.expect(tkRParen)
  rows.add(p.parseRowVals())
  while p.match(tkComma): rows.add(p.parseRowVals())
  Stmt(kind: skInsert, insTable: tbl, insCols: cols, insVals: rows)

# ─── UPDATE ───────────────────────────────────────────────────────────────

proc parseUpdate(p: var Parser): Stmt =
  let tbl = p.expectIdent()
  discard p.expect(tkSET)
  var sets: seq[(string, Expr)]
  proc parsePair(p: var Parser): (string, Expr) =
    let col = p.expectIdent()
    discard p.expect(tkEq)
    (col, p.parseExpr())
  sets.add(p.parsePair())
  while p.match(tkComma): sets.add(p.parsePair())
  var whereExpr: Expr
  if p.match(tkWHERE): whereExpr = p.parseExpr()
  Stmt(kind: skUpdate, updTable: tbl, updSets: sets, updWhere: whereExpr)

# ─── DELETE ───────────────────────────────────────────────────────────────

proc parseDelete(p: var Parser): Stmt =
  discard p.expect(tkFROM)
  let tbl = p.expectIdent()
  var whereExpr: Expr
  if p.match(tkWHERE): whereExpr = p.parseExpr()
  Stmt(kind: skDelete, delTable: tbl, delWhere: whereExpr)

# ─── CREATE TABLE ─────────────────────────────────────────────────────────

proc parseCreateTable(p: var Parser): Stmt =
  let ine = p.match(tkIF)
  if ine: discard p.expect(tkNOT); discard p.expect(tkEXISTS)
  let name = p.expectIdent()
  discard p.expect(tkLParen)
  var cols: seq[ColDef]
  while not p.check(tkRParen):
    let cname = p.expectIdent()
    let typeKw = p.advance()
    let ck = parseColKind(typeKw.raw)
    # optional length for VARCHAR(n) — ignore the n
    if p.match(tkLParen):
      discard p.advance()
      discard p.expect(tkRParen)
    var nn = false; var pk = false
    while p.peekKind() in {tkNOT, tkPRIMARY}:
      if p.match(tkNOT): discard p.expect(tkNULL); nn = true
      if p.match(tkPRIMARY): discard p.expect(tkKEY); pk = true; nn = true
    cols.add(ColDef(name: cname, kind: ck, notNull: nn, primaryKey: pk))
    if not p.match(tkComma): break
  discard p.expect(tkRParen)
  Stmt(kind: skCreateTable, ctName: name, ctCols: cols, ctIfNotExists: ine)

# ─── Top-level dispatch ───────────────────────────────────────────────────

proc parseStmt*(p: var Parser): Stmt =
  let t = p.advance()
  case t.kind
  of tkSELECT:   result = p.parseSelect()
  of tkINSERT:   result = p.parseInsert()
  of tkUPDATE:   result = p.parseUpdate()
  of tkDELETE:   result = p.parseDelete()
  of tkCREATE:
    if p.match(tkINDEX) or (p.check(tkUNIQUE) and (discard p.advance(); p.match(tkINDEX))):
      let uniq = t.kind == tkUNIQUE
      let iname = p.expectIdent()
      discard p.expect(tkON)
      let tname = p.expectIdent()
      discard p.expect(tkLParen)
      let col = p.expectIdent()
      discard p.expect(tkRParen)
      result = Stmt(kind: skCreateIndex, ciName: iname, ciTable: tname,
                    ciCol: col, ciUnique: uniq)
    else:
      discard p.expect(tkTABLE)
      result = p.parseCreateTable()
  of tkDROP:
    discard p.expect(tkTABLE)
    let ine = p.match(tkIF); if ine: discard p.expect(tkEXISTS)
    let name = p.expectIdent()
    result = Stmt(kind: skDropTable, dtName: name, dtIfExists: ine)
  of tkBEGIN:
    discard p.match(tkTRANSACTION)
    result = Stmt(kind: skBegin)
  of tkCOMMIT:
    discard p.match(tkTRANSACTION)
    result = Stmt(kind: skCommit)
  of tkROLLBACK:
    discard p.match(tkTRANSACTION)
    result = Stmt(kind: skRollback)
  of tkEXPLAIN:
    let inner = p.parseStmt()
    result = Stmt(kind: skExplain, explainStmt: inner)
  else:
    raise newException(SQLError, "Unknown statement starting with: " & t.raw)
  discard p.match(tkSemicolon)
  result

proc parse*(sql: string): Stmt =
  var p = newParser(sql)
  p.parseStmt()

proc parseAll*(sql: string): seq[Stmt] =
  var p = newParser(sql)
  while not p.check(tkEof):
    result.add(p.parseStmt())
