## node.nim — Distributed layer: PA/EL (PACELC model)
##
## NimDB's distribution strategy:
##   PA  = Partition-tolerant + Available
##         On network partition we stay available; may serve stale reads.
##   EL  = Eventually consistent + Low latency
##         Under normal operation we optimise for low latency,
##         accepting eventual (not strong) consistency.
##
## Design:
##   • Consistent hashing ring for shard assignment
##   • Gossip protocol (SWIM-inspired) for failure detection
##   • Async replication: primary writes locally, fans-out async
##   • Tunable read quorum (1 = low-latency, N/2+1 = stronger consistency)
##   • Anti-entropy repair via Merkle hash exchange

import std/[tables, hashes, math, locks, times, net, strformat,
            sequtils, algorithm, random]
import ../storage/types

# ─── Consistent hashing ring ──────────────────────────────────────────────

const VirtualNodes* = 150   ## vnodes per physical node

type
  NodeId* = string   ## "host:port"

  RingEntry* = object
    hash*:   uint64
    nodeId*: NodeId

  HashRing* = ref object
    mu*:      Lock
    entries*: seq[RingEntry]   ## sorted by hash

proc xxHash64(key: string): uint64 =
  ## Fast non-crypto hash (simplified xxHash64 variant).
  const P1 = 11400714785074694791'u64
  const P2 = 14029467366897019727'u64
  const P5 = 2870177450012600261'u64
  var h = P5 + uint64(key.len)
  for c in key: h = (h xor uint64(c)) * P1
  h = h xor (h shr 33)
  h = h * P2
  h = h xor (h shr 29)
  h

proc newHashRing*(): HashRing =
  result = HashRing()
  initLock(result.mu)

proc addNode*(ring: HashRing; nid: NodeId) =
  acquire(ring.mu)
  defer: release(ring.mu)
  for i in 0 ..< VirtualNodes:
    let h = xxHash64(nid & "#" & $i)
    ring.entries.add(RingEntry(hash: h, nodeId: nid))
  ring.entries.sort(proc(a, b: RingEntry): int =
    if a.hash < b.hash: -1 elif a.hash > b.hash: 1 else: 0)

proc removeNode*(ring: HashRing; nid: NodeId) =
  acquire(ring.mu)
  defer: release(ring.mu)
  ring.entries.keepIf(proc(e: RingEntry): bool = e.nodeId != nid)

proc getNode*(ring: HashRing; key: string): NodeId =
  ## Return the node responsible for key.
  acquire(ring.mu)
  defer: release(ring.mu)
  if ring.entries.len == 0: return ""
  let h = xxHash64(key)
  var lo = 0; var hi = ring.entries.len - 1
  while lo < hi:
    let mid = (lo + hi) shr 1
    if ring.entries[mid].hash < h: lo = mid + 1 else: hi = mid
  ring.entries[lo mod ring.entries.len].nodeId

proc getNodes*(ring: HashRing; key: string; n: int): seq[NodeId] =
  ## Return n replica nodes for key (for replication factor N).
  acquire(ring.mu)
  defer: release(ring.mu)
  if ring.entries.len == 0: return
  let h = xxHash64(key)
  var idx = 0
  var lo = 0; var hi = ring.entries.len - 1
  while lo < hi:
    let mid = (lo + hi) shr 1
    if ring.entries[mid].hash < h: lo = mid + 1 else: hi = mid
  idx = lo
  var seen: Table[NodeId, bool]
  while seen.len < n and seen.len < ring.entries.len:
    let nid = ring.entries[idx mod ring.entries.len].nodeId
    if nid notin seen:
      seen[nid] = true; result.add(nid)
    inc idx

# ─── Gossip / failure detection ───────────────────────────────────────────

type
  NodeState* = enum
    nsAlive, nsSuspect, nsDead

  GossipEntry* = object
    nodeId*:    NodeId
    state*:     NodeState
    heartbeat*: int64     ## unix epoch seconds
    version*:   int64

  GossipTable* = ref object
    mu*:      Lock
    self*:    NodeId
    entries*: Table[NodeId, GossipEntry]
    ring*:    HashRing

const
  SuspectTimeout* = 5    ## seconds before marking Suspect
  DeadTimeout*    = 30   ## seconds before marking Dead

proc newGossipTable*(selfId: NodeId; ring: HashRing): GossipTable =
  result = GossipTable(self: selfId, ring: ring,
                       entries: initTable[NodeId, GossipEntry]())
  initLock(result.mu)
  result.entries[selfId] = GossipEntry(
    nodeId: selfId, state: nsAlive,
    heartbeat: getTime().toUnix(), version: 0)

proc heartbeat*(gt: GossipTable) =
  ## Called periodically to update own heartbeat.
  acquire(gt.mu)
  defer: release(gt.mu)
  if gt.self in gt.entries:
    var e = gt.entries[gt.self]
    e.heartbeat = getTime().toUnix()
    inc e.version
    gt.entries[gt.self] = e

proc merge*(gt: GossipTable; remote: seq[GossipEntry]) =
  ## Merge remote gossip state into local table (SWIM-style).
  acquire(gt.mu)
  defer: release(gt.mu)
  let now = getTime().toUnix()
  for re in remote:
    if re.nodeId == gt.self: continue
    if re.nodeId notin gt.entries or
       gt.entries[re.nodeId].version < re.version:
      gt.entries[re.nodeId] = re
    # Update state based on heartbeat age
    var e = gt.entries[re.nodeId]
    let age = now - e.heartbeat
    if age > DeadTimeout:    e.state = nsDead
    elif age > SuspectTimeout: e.state = nsSuspect
    else:                      e.state = nsAlive
    gt.entries[re.nodeId] = e

proc aliveNodes*(gt: GossipTable): seq[NodeId] =
  acquire(gt.mu)
  defer: release(gt.mu)
  for id, e in gt.entries:
    if e.state == nsAlive: result.add(id)

proc gossipFanout*(gt: GossipTable; k = 3): seq[(NodeId, seq[GossipEntry])] =
  ## Pick k random alive peers and return our state snapshot to send them.
  let alive = gt.aliveNodes().filterIt(it != gt.self)
  var rng   = initRand(getTime().toUnix())
  let peers = rng.sample(alive, min(k, alive.len))
  var snap: seq[GossipEntry]
  acquire(gt.mu)
  for _, e in gt.entries: snap.add(e)
  release(gt.mu)
  for p in peers: result.add((p, snap))

# ─── Replication config ───────────────────────────────────────────────────

type
  ReplicationConfig* = object
    factor*:      int    ## how many replicas (e.g. 3)
    readQuorum*:  int    ## how many must respond on read (1 = eventual)
    writeQuorum*: int    ## how many must ack on write (1 = async)
    asyncWrite*:  bool   ## true = PA/EL (fire-and-forget after local write)

proc paelConfig*(factor = 3): ReplicationConfig =
  ## PA/EL: write locally + async fan-out; reads from 1 replica.
  ReplicationConfig(factor: factor, readQuorum: 1, writeQuorum: 1, asyncWrite: true)

proc strongConfig*(factor = 3): ReplicationConfig =
  ## Strong consistency: quorum writes and reads.
  let q = factor div 2 + 1
  ReplicationConfig(factor: factor, readQuorum: q, writeQuorum: q, asyncWrite: false)

# ─── Shard router ─────────────────────────────────────────────────────────

type
  ShardRouter* = ref object
    ring*:       HashRing
    gossip*:     GossipTable
    replConf*:   ReplicationConfig

proc newShardRouter*(selfId: NodeId; replConf: ReplicationConfig): ShardRouter =
  let ring = newHashRing()
  ring.addNode(selfId)
  ShardRouter(
    ring:      ring,
    gossip:    newGossipTable(selfId, ring),
    replConf:  replConf
  )

proc primaryNode*(sr: ShardRouter; key: string): NodeId =
  sr.ring.getNode(key)

proc replicaNodes*(sr: ShardRouter; key: string): seq[NodeId] =
  sr.ring.getNodes(key, sr.replConf.factor)

proc isLocal*(sr: ShardRouter; key: string): bool =
  sr.ring.getNode(key) == sr.gossip.self

proc routeInfo*(sr: ShardRouter; key: string): string =
  let nodes = sr.replicaNodes(key)
  let alive = sr.gossip.aliveNodes()
  let reachable = nodes.filterIt(it in alive)
  &"key={key} primary={nodes[0]} replicas={nodes.len} " &
  &"reachable={reachable.len} readQ={sr.replConf.readQuorum}"
