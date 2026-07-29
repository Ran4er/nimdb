## vector_index.nim — HNSW Approximate Nearest Neighbour index
##
## Hierarchical Navigable Small World (HNSW) graph.
## Ref: Malkov & Yashunin (2018) arXiv:1603.09320
##
## Parameters:
##   M     — max connections per node per layer (default 16)
##   efC   — ef during construction (default 200)
##   efS   — ef during search (default 50)
##
## Distance metrics supported:
##   Cosine, L2, Dot product (inner product, for normalised vecs)

import std/[math, tables, sets, heapqueue, algorithm, random, hashes]
import tensor
import ../storage/types

type
  DistMetric* = enum
    dmCosine, dmL2, dmDot

  HNSWNode* = object
    id*:       int64          ## external row id (TupleId encoded)
    vec*:      Tensor
    layers*:   seq[seq[int]]  ## layers[l] = neighbour ids at layer l

  HNSWIndex* = ref object
    nodes*:    seq[HNSWNode]
    idMap*:    Table[int64, int]   ## external id → node index
    metric*:   DistMetric
    M*:        int
    Mmax0*:    int             ## max connections at layer 0
    efC*:      int             ## ef construction
    efS*:      int             ## ef search
    mL*:       float           ## normalisation factor for level gen
    entryPt*:  int             ## index of entry point node
    maxLayer*: int
    dim*:      int             ## vector dimension (0 = not yet set)
    rng*:      Rand

# ─── Distance ─────────────────────────────────────────────────────────────

proc dist*(idx: HNSWIndex; a, b: Tensor): float32 =
  case idx.metric
  of dmCosine: 1.0'f32 - cosineSimF32(a, b)
  of dmL2:     l2distF32(a, b)
  of dmDot:    1.0'f32 - dot(a, b)  ## higher dot = smaller distance

proc newHNSWIndex*(metric = dmCosine; M = 16; efC = 200; efS = 50): HNSWIndex =
  let mmax0 = M * 2
  HNSWIndex(
    metric:  metric,
    M:       M,
    Mmax0:   mmax0,
    efC:     efC,
    efS:     efS,
    mL:      1.0 / ln(float(M)),
    entryPt: -1,
    maxLayer: -1,
    rng:     initRand(42)
  )

proc randomLevel(idx: HNSWIndex): int =
  result = 0
  while idx.rng.rand(1.0) < exp(-1.0 / idx.mL) and result < 16:
    inc result

# ─── Search helpers ───────────────────────────────────────────────────────

type
  Candidate = object
    d:  float32
    ni: int   ## node index

proc `<`(a, b: Candidate): bool = a.d < b.d

proc searchLayer(idx: HNSWIndex; q: Tensor; ep: int;
                 ef: int; layer: int): seq[Candidate] =
  ## Greedy search within one layer. Returns ef nearest candidates.
  var visited  = initHashSet[int]()
  var cands    = initHeapQueue[Candidate]()   ## min-heap (closest first)
  var dynList  = initHeapQueue[Candidate]()   ## working set

  let d0 = idx.dist(q, idx.nodes[ep].vec)
  visited.incl(ep)
  cands.push(Candidate(d: d0, ni: ep))
  dynList.push(Candidate(d: d0, ni: ep))

  # We use a max-heap trick: negate distances for "worst" tracking
  var worst = d0

  while cands.len > 0:
    let curr = cands.pop()
    if curr.d > worst and dynList.len >= ef: break

    let neighbours = if layer < idx.nodes[curr.ni].layers.len:
                       idx.nodes[curr.ni].layers[layer]
                     else: @[]
    for nb in neighbours:
      if nb in visited: continue
      visited.incl(nb)
      let nd = idx.dist(q, idx.nodes[nb].vec)
      if nd < worst or dynList.len < ef:
        cands.push(Candidate(d: nd, ni: nb))
        dynList.push(Candidate(d: nd, ni: nb))
        if dynList.len > ef:
          # pop worst — heapqueue is min, so we need max tracking
          # We rebuild: just keep ef best
          var tmp: seq[Candidate]
          while dynList.len > 0: tmp.add(dynList.pop())
          tmp.sort(proc(a, b: Candidate): int =
            if a.d < b.d: -1 elif a.d > b.d: 1 else: 0)
          for c in tmp[0 ..< min(ef, tmp.len)]: dynList.push(c)
        worst = 0.0'f32
        var peeked: seq[Candidate]
        while dynList.len > 0: peeked.add(dynList.pop())
        for c in peeked: dynList.push(c)
        for c in peeked:
          if c.d > worst: worst = c.d

  var res: seq[Candidate]
  while dynList.len > 0: res.add(dynList.pop())
  res.sortedByIt(it.d)

proc selectNeighbours(idx: HNSWIndex; q: Tensor;
                      candidates: seq[Candidate]; m: int): seq[int] =
  ## Heuristic neighbour selection (simple version: take M closest).
  let take = min(m, candidates.len)
  for i in 0 ..< take: result.add(candidates[i].ni)

# ─── Insert ───────────────────────────────────────────────────────────────

proc insert*(idx: HNSWIndex; vec: Tensor; extId: int64) =
  if idx.dim == 0:
    idx.dim = vec.len
  elif vec.len != idx.dim:
    raise newException(StorageError,
      "Vector dim mismatch: expected " & $idx.dim & " got " & $vec.len)

  let ni    = idx.nodes.len
  let level = idx.randomLevel()
  var node  = HNSWNode(id: extId, vec: vec,
                        layers: newSeq[seq[int]](level + 1))
  idx.nodes.add(node)
  idx.idMap[extId] = ni

  if idx.entryPt < 0:
    idx.entryPt  = ni
    idx.maxLayer = level
    return

  var ep = idx.entryPt
  var curMaxLayer = idx.maxLayer

  # Greedy descent from top to level+1
  for lc in countdown(curMaxLayer, level + 1):
    let res = idx.searchLayer(vec, ep, 1, lc)
    if res.len > 0: ep = res[0].ni

  # Insert into layers 0..level
  for lc in countdown(min(level, curMaxLayer), 0):
    let res  = idx.searchLayer(vec, ep, idx.efC, lc)
    let mmax = if lc == 0: idx.Mmax0 else: idx.M
    let nbrs = idx.selectNeighbours(vec, res, mmax)

    idx.nodes[ni].layers[lc] = nbrs

    # Add back-connections
    for nb in nbrs:
      while idx.nodes[nb].layers.len <= lc:
        idx.nodes[nb].layers.add(@[])
      if ni notin idx.nodes[nb].layers[lc]:
        idx.nodes[nb].layers[lc].add(ni)
      # Prune if over limit
      if idx.nodes[nb].layers[lc].len > mmax:
        var cands = idx.nodes[nb].layers[lc].mapIt(
          Candidate(d: idx.dist(idx.nodes[nb].vec, idx.nodes[it].vec), ni: it))
        cands.sort(proc(a, b: Candidate): int =
          if a.d < b.d: -1 elif a.d > b.d: 1 else: 0)
        idx.nodes[nb].layers[lc] = cands[0 ..< mmax].mapIt(it.ni)

    if res.len > 0: ep = res[0].ni

  if level > idx.maxLayer:
    idx.maxLayer = level
    idx.entryPt  = ni

# ─── KNN Search ───────────────────────────────────────────────────────────

type KNNResult* = object
  extId*:    int64
  distance*: float32

proc knnSearch*(idx: HNSWIndex; query: Tensor; k: int;
                ef = -1): seq[KNNResult] =
  ## Return top-k approximate nearest neighbours.
  if idx.entryPt < 0: return
  let efUse = if ef < 0: max(idx.efS, k) else: ef

  var ep = idx.entryPt
  for lc in countdown(idx.maxLayer, 1):
    let res = idx.searchLayer(query, ep, 1, lc)
    if res.len > 0: ep = res[0].ni

  let res = idx.searchLayer(query, ep, efUse, 0)
  for i in 0 ..< min(k, res.len):
    result.add(KNNResult(
      extId:    idx.nodes[res[i].ni].id,
      distance: res[i].d))

# ─── Statistics ───────────────────────────────────────────────────────────

proc stats*(idx: HNSWIndex): string =
  var avgConn = 0.0
  for n in idx.nodes:
    if n.layers.len > 0: avgConn += float(n.layers[0].len)
  if idx.nodes.len > 0: avgConn /= float(idx.nodes.len)
  "HNSWIndex: nodes=" & $idx.nodes.len &
  " maxLayer=" & $idx.maxLayer &
  " dim=" & $idx.dim &
  " metric=" & $idx.metric &
  " avgDegree=" & $int(avgConn)
