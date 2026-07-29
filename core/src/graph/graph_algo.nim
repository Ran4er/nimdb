## graph_algo.nim — Graph algorithms
##
## All algorithms work directly on GraphStore (no copy-out).
##
## Algorithms:
##   BFS            — breadth-first traversal from source(s)
##   DFS            — depth-first traversal
##   ShortestPath   — Dijkstra with optional edge weights
##   PageRank       — iterative PageRank (damping=0.85)
##   WCC            — weakly connected components (Union-Find)
##   TriangleCount  — exact triangle count (O(m^1.5))
##   Betweenness    — betweenness centrality (Brandes, sampled for large graphs)

import std/[tables, sets, heapqueue, deques, sequtils, math, algorithm]
import graph_store

# ─── BFS ──────────────────────────────────────────────────────────────────

type BFSResult* = object
  dist*:    Table[int64, int]   ## node → hop distance
  parent*:  Table[int64, int64] ## node → parent in BFS tree
  order*:   seq[int64]          ## visit order

proc bfs*(gs: GraphStore; source: int64; maxHops = high(int);
          edgeType = ""): BFSResult =
  result.dist[source]   = 0
  result.parent[source] = -1
  result.order.add(source)
  var q = initDeque[int64]()
  q.addLast(source)
  while q.len > 0:
    let u = q.popFirst()
    if result.dist[u] >= maxHops: continue
    for nb in gs.neighbours(u, edgeType):
      if nb notin result.dist:
        result.dist[nb]   = result.dist[u] + 1
        result.parent[nb] = u
        result.order.add(nb)
        q.addLast(nb)

proc shortestHops*(gs: GraphStore; src, dst: int64; edgeType = ""): int =
  let r = gs.bfs(src, edgeType = edgeType)
  r.dist.getOrDefault(dst, -1)

proc reconstructPath*(r: BFSResult; dst: int64): seq[int64] =
  if dst notin r.dist: return
  var cur = dst
  while cur != -1:
    result.add(cur)
    cur = r.parent.getOrDefault(cur, -1)
  result.reverse()

# ─── DFS ──────────────────────────────────────────────────────────────────

type DFSResult* = object
  visited*:  HashSet[int64]
  order*:    seq[int64]    ## pre-order
  finishOrd*: seq[int64]   ## post-order (for topo sort)

proc dfsRec(gs: GraphStore; u: int64; res: var DFSResult; edgeType: string) =
  res.visited.incl(u)
  res.order.add(u)
  for nb in gs.neighbours(u, edgeType):
    if nb notin res.visited:
      dfsRec(gs, nb, res, edgeType)
  res.finishOrd.add(u)

proc dfs*(gs: GraphStore; source: int64; edgeType = ""): DFSResult =
  dfsRec(gs, source, result, edgeType)

# ─── Dijkstra shortest path ───────────────────────────────────────────────

type
  DijkResult* = object
    dist*:   Table[int64, float64]
    parent*: Table[int64, int64]

  DijkEntry = object
    d:  float64
    id: int64

proc `<`(a, b: DijkEntry): bool = a.d < b.d

proc dijkstra*(gs: GraphStore; source: int64;
               weightProp = "weight"; edgeType = ""): DijkResult =
  result.dist[source]   = 0.0
  result.parent[source] = -1
  var pq = initHeapQueue[DijkEntry]()
  pq.push(DijkEntry(d: 0.0, id: source))

  while pq.len > 0:
    let (du, u) = (pq[0].d, pq[0].id); discard pq.pop()
    if du > result.dist.getOrDefault(u, Inf): continue
    for e in gs.outEdges(u):
      if edgeType.len > 0 and e.edgeType != edgeType: continue
      let w   = e.props.getProp(weightProp)
      let wf  = if w.isNumeric: w.toFloat() else: 1.0
      let alt = du + wf
      if alt < result.dist.getOrDefault(e.toId, Inf):
        result.dist[e.toId]   = alt
        result.parent[e.toId] = u
        pq.push(DijkEntry(d: alt, id: e.toId))

proc shortestPath*(gs: GraphStore; src, dst: int64;
                   weightProp = "weight"; edgeType = ""): (float64, seq[int64]) =
  let r = gs.dijkstra(src, weightProp, edgeType)
  let d = r.dist.getOrDefault(dst, Inf)
  var path: seq[int64]
  if d < Inf:
    var cur = dst
    while cur != -1:
      path.add(cur)
      cur = r.parent.getOrDefault(cur, -1)
    path.reverse()
  (d, path)

# ─── PageRank ─────────────────────────────────────────────────────────────

proc pageRank*(gs: GraphStore; damping = 0.85'f64; iters = 50;
               edgeType = ""): Table[int64, float64] =
  var nodeIds: seq[int64]
  for id in gs.nodes.keys: nodeIds.add(id)
  let n = nodeIds.len
  if n == 0: return

  let init = 1.0 / float64(n)
  for id in nodeIds: result[id] = init

  for _ in 0 ..< iters:
    var next = initTable[int64, float64]()
    for id in nodeIds: next[id] = (1.0 - damping) / float64(n)
    for id in nodeIds:
      let outs = gs.outEdges(id)
      if outs.len == 0: continue
      let share = result[id] / float64(outs.len)
      for e in outs:
        if edgeType.len > 0 and e.edgeType != edgeType: continue
        if e.toId in next:
          next[e.toId] += damping * share
    result = next

proc topPageRank*(gs: GraphStore; k = 10; damping = 0.85'f64;
                  edgeType = ""): seq[(int64, float64)] =
  let pr = gs.pageRank(damping = damping, edgeType = edgeType)
  var pairs = toSeq(pr.pairs)
  pairs.sort(proc(a, b: (int64, float64)): int =
    if a[1] > b[1]: -1 elif a[1] < b[1]: 1 else: 0)
  pairs[0 ..< min(k, pairs.len)]

# ─── Weakly Connected Components (Union-Find) ────────────────────────────

type WCCResult* = object
  comp*:    Table[int64, int64]  ## node → component root
  sizes*:   Table[int64, int]    ## root → size
  nComps*:  int

proc wcc*(gs: GraphStore): WCCResult =
  var parent = initTable[int64, int64]()
  var rank   = initTable[int64, int]()
  for id in gs.nodes.keys: parent[id] = id; rank[id] = 0

  proc find(x: int64): int64 =
    if parent[x] == x: return x
    parent[x] = find(parent[x])   ## path compression
    parent[x]

  proc union(a, b: int64) =
    let ra = find(a); let rb = find(b)
    if ra == rb: return
    if rank[ra] < rank[rb]: parent[ra] = rb
    elif rank[ra] > rank[rb]: parent[rb] = ra
    else: parent[rb] = ra; inc rank[ra]

  for e in gs.edges.values:
    union(e.fromId, e.toId)

  for id in gs.nodes.keys:
    let root = find(id)
    result.comp[id] = root
    result.sizes[root] = result.sizes.getOrDefault(root, 0) + 1

  result.nComps = result.sizes.len

# ─── Triangle count ───────────────────────────────────────────────────────

proc triangleCount*(gs: GraphStore): int64 =
  ## Exact triangle count via intersection of adjacency sets.
  ## O(m · d_avg) — feasible for m < 10M.
  var adj = initTable[int64, HashSet[int64]]()
  for id in gs.nodes.keys: adj[id] = initHashSet[int64]()
  for e in gs.edges.values:
    adj[e.fromId].incl(e.toId)
    adj[e.toId].incl(e.fromId)
  for u in gs.nodes.keys:
    for v in adj[u]:
      if v <= u: continue
      for w in adj[u]:
        if w <= v: continue
        if w in adj[v]: inc result

# ─── Betweenness centrality (Brandes) ────────────────────────────────────

proc betweenness*(gs: GraphStore; normalise = true;
                  sampleSize = -1): Table[int64, float64] =
  ## Brandes algorithm. For large graphs set sampleSize to limit sources.
  var nodeIds: seq[int64]
  for id in gs.nodes.keys: nodeIds.add(id)
  for id in nodeIds: result[id] = 0.0

  var sources = nodeIds
  if sampleSize > 0 and sampleSize < nodeIds.len:
    sources = nodeIds[0 ..< sampleSize]   ## take first N as sample

  for s in sources:
    var stack:  seq[int64]
    var pred  = initTable[int64, seq[int64]]()
    var sigma = initTable[int64, float64]()
    var dist  = initTable[int64, int]()
    for id in nodeIds: sigma[id] = 0.0; dist[id] = -1
    sigma[s] = 1.0; dist[s] = 0
    var q = initDeque[int64](); q.addLast(s)
    while q.len > 0:
      let v = q.popFirst(); stack.add(v)
      for nb in gs.neighbours(v):
        if dist[nb] < 0:
          q.addLast(nb); dist[nb] = dist[v] + 1
        if dist[nb] == dist[v] + 1:
          sigma[nb] += sigma[v]
          pred[nb].add(v)
    var delta = initTable[int64, float64]()
    for id in nodeIds: delta[id] = 0.0
    while stack.len > 0:
      let w = stack.pop()
      for v in pred.getOrDefault(w, @[]):
        delta[v] += (sigma[v] / sigma[w]) * (1.0 + delta[w])
      if w != s: result[w] += delta[w]

  if normalise and nodeIds.len > 2:
    let scale = 1.0 / (float64(nodeIds.len - 1) * float64(nodeIds.len - 2))
    for id in nodeIds: result[id] *= scale
