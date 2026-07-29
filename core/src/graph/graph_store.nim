## graph_store.nim — Property Graph storage
##
## Model: nodes and edges are typed and carry JSON-like properties.
##
## Node: (nodeId: int64, labels: seq[string], props: seq[(string,Value)])
## Edge: (edgeId: int64, fromId: int64, toId: int64,
##        edgeType: string, props: seq[(string,Value)])
##
## Storage layout:
##   nodes heap file  : serialised NodeRecord tuples
##   edges heap file  : serialised EdgeRecord tuples
##   out-adjacency    : Table[int64, seq[int64]]  (in-memory)
##   in-adjacency     : Table[int64, seq[int64]]  (in-memory)
##
## For datasets up to ~100M edges the in-memory adjacency is fine.
## Larger datasets would use a B+ tree on (fromId, edgeId).

import std/[tables, locks, hashes, strutils, sequtils, os]
import ../storage/types
import ../catalog/schema

type
  PropMap* = seq[(string, Value)]

  NodeRecord* = object
    nodeId*: int64
    labels*: seq[string]
    props*:  PropMap

  EdgeRecord* = object
    edgeId*:   int64
    fromId*:   int64
    toId*:     int64
    edgeType*: string
    props*:    PropMap

  GraphStore* = ref object
    mu*:       Lock
    dataDir*:  string
    nodes*:    Table[int64, NodeRecord]
    edges*:    Table[int64, EdgeRecord]
    outAdj*:   Table[int64, seq[int64]]   ## nodeId → seq[edgeId]
    inAdj*:    Table[int64, seq[int64]]
    nextNode*: int64
    nextEdge*: int64
    ## Label index: label → seq[nodeId]
    labelIdx*: Table[string, seq[int64]]

# ─── Graph lifecycle ──────────────────────────────────────────────────────

proc newGraphStore*(dataDir: string): GraphStore =
  result = GraphStore(dataDir: dataDir, nextNode: 1, nextEdge: 1)
  initLock(result.mu)
  ## TODO: persist to / restore from disk on open/close

proc closeGraphStore*(gs: GraphStore) =
  ## Persist to disk (simple JSON dump — swap for binary in prod).
  discard  ## placeholder

# ─── Property helpers ─────────────────────────────────────────────────────

proc getProp*(pm: PropMap; key: string): Value =
  for (k, v) in pm:
    if k == key: return v
  nullVal()

proc setProp*(pm: var PropMap; key: string; val: Value) =
  for i in 0 ..< pm.len:
    if pm[i][0] == key: pm[i] = (key, val); return
  pm.add((key, val))

# ─── Node operations ──────────────────────────────────────────────────────

proc addNode*(gs: GraphStore; labels: seq[string];
              props: PropMap = @[]): int64 =
  acquire(gs.mu); defer: release(gs.mu)
  let id = gs.nextNode; inc gs.nextNode
  gs.nodes[id] = NodeRecord(nodeId: id, labels: labels, props: props)
  if id notin gs.outAdj: gs.outAdj[id] = @[]
  if id notin gs.inAdj:  gs.inAdj[id]  = @[]
  for lbl in labels:
    if lbl notin gs.labelIdx: gs.labelIdx[lbl] = @[]
    gs.labelIdx[lbl].add(id)
  id

proc getNode*(gs: GraphStore; id: int64): NodeRecord =
  acquire(gs.mu); defer: release(gs.mu)
  gs.nodes.getOrDefault(id)

proc setNodeProp*(gs: GraphStore; id: int64; key: string; val: Value) =
  acquire(gs.mu); defer: release(gs.mu)
  if id in gs.nodes: gs.nodes[id].props.setProp(key, val)

proc deleteNode*(gs: GraphStore; id: int64) =
  acquire(gs.mu); defer: release(gs.mu)
  if id notin gs.nodes: return
  ## Remove incident edges
  for eid in gs.outAdj.getOrDefault(id, @[]):
    if eid in gs.edges:
      let e = gs.edges[eid]
      if e.toId in gs.inAdj:
        gs.inAdj[e.toId].keepIf(proc(x: int64): bool = x != eid)
      gs.edges.del(eid)
  for eid in gs.inAdj.getOrDefault(id, @[]):
    if eid in gs.edges:
      let e = gs.edges[eid]
      if e.fromId in gs.outAdj:
        gs.outAdj[e.fromId].keepIf(proc(x: int64): bool = x != eid)
      gs.edges.del(eid)
  for lbl in gs.nodes[id].labels:
    if lbl in gs.labelIdx:
      gs.labelIdx[lbl].keepIf(proc(x: int64): bool = x != id)
  gs.outAdj.del(id); gs.inAdj.del(id)
  gs.nodes.del(id)

proc nodesByLabel*(gs: GraphStore; label: string): seq[int64] =
  acquire(gs.mu); defer: release(gs.mu)
  gs.labelIdx.getOrDefault(label, @[])

proc nodeCount*(gs: GraphStore): int =
  acquire(gs.mu); defer: release(gs.mu)
  gs.nodes.len

# ─── Edge operations ──────────────────────────────────────────────────────

proc addEdge*(gs: GraphStore; fromId, toId: int64; edgeType: string;
              props: PropMap = @[]): int64 =
  acquire(gs.mu); defer: release(gs.mu)
  let id = gs.nextEdge; inc gs.nextEdge
  gs.edges[id] = EdgeRecord(edgeId: id, fromId: fromId, toId: toId,
                              edgeType: edgeType, props: props)
  if fromId notin gs.outAdj: gs.outAdj[fromId] = @[]
  if toId   notin gs.inAdj:  gs.inAdj[toId]    = @[]
  gs.outAdj[fromId].add(id)
  gs.inAdj[toId].add(id)
  id

proc getEdge*(gs: GraphStore; id: int64): EdgeRecord =
  acquire(gs.mu); defer: release(gs.mu)
  gs.edges.getOrDefault(id)

proc outEdges*(gs: GraphStore; nodeId: int64): seq[EdgeRecord] =
  acquire(gs.mu); defer: release(gs.mu)
  for eid in gs.outAdj.getOrDefault(nodeId, @[]):
    if eid in gs.edges: result.add(gs.edges[eid])

proc inEdges*(gs: GraphStore; nodeId: int64): seq[EdgeRecord] =
  acquire(gs.mu); defer: release(gs.mu)
  for eid in gs.inAdj.getOrDefault(nodeId, @[]):
    if eid in gs.edges: result.add(gs.edges[eid])

proc neighbours*(gs: GraphStore; nodeId: int64;
                 edgeType = ""): seq[int64] =
  for e in gs.outEdges(nodeId):
    if edgeType.len == 0 or e.edgeType == edgeType:
      result.add(e.toId)

proc edgeCount*(gs: GraphStore): int =
  acquire(gs.mu); defer: release(gs.mu)
  gs.edges.len

# ─── Serialisation for transport ──────────────────────────────────────────

proc `$`*(n: NodeRecord): string =
  "(" & $n.nodeId & ":" & n.labels.join(":") & " " &
  n.props.mapIt(it[0] & "=" & $it[1]).join(", ") & ")"

proc `$`*(e: EdgeRecord): string =
  "-[" & $e.edgeId & ":" & e.edgeType & " " &
  e.props.mapIt(it[0] & "=" & $it[1]).join(", ") & "]->"

proc stats*(gs: GraphStore): string =
  "GraphStore: nodes=" & $gs.nodeCount() &
  " edges=" & $gs.edgeCount() &
  " labels=" & $gs.labelIdx.len
