## mvcc.nim — Multi-Version Concurrency Control
##
## Replaces the original 2PL-only approach with proper MVCC.
##
## Each tuple version carries:
##   xmin: TxnId  — transaction that created this version
##   xmax: TxnId  — transaction that deleted/updated (0 = live)
##
## Visibility rule for transaction T with snapshot S:
##   VISIBLE iff:
##     xmin is committed AND xmin ≤ S.maxCommittedTxn
##     AND (xmax = 0 OR xmax > S.maxCommittedTxn OR xmax not committed)
##
## On UPDATE:
##   1. Mark old tuple xmax = T.id
##   2. Insert new tuple with xmin = T.id, xmax = 0
##
## On COMMIT:
##   - Mark T as committed in CommitLog
##   - Garbage collect versions where xmax is committed and all live
##     transactions' snapshots are newer (no reader needs them).
##
## Integration: heap scan checks visibility before returning tuples.

import std/[tables, locks, sets]
import ../storage/types
import ../storage/wal

# ─── Tuple version header (prepended to every heap tuple) ─────────────────

const TupleHdrSize* = 16    ## 8 + 8 bytes

type
  TupleHdr* = object
    xmin*: TxnId   ## creator txn
    xmax*: TxnId   ## deleter txn (0 = alive)

proc encodeTupleHdr*(hdr: TupleHdr; buf: var seq[byte]; off: int) =
  lePut64(buf, off,     uint64(hdr.xmin))
  lePut64(buf, off + 8, uint64(hdr.xmax))

proc decodeTupleHdr*(buf: seq[byte]; off: int): TupleHdr =
  TupleHdr(xmin: TxnId(leGet64(buf, off)),
            xmax: TxnId(leGet64(buf, off + 8)))

proc wrapTuple*(hdr: TupleHdr; data: openArray[byte]): seq[byte] =
  ## Prepend version header to tuple data.
  result = newSeq[byte](TupleHdrSize + data.len)
  encodeTupleHdr(hdr, result, 0)
  if data.len > 0:
    copyMem(addr result[TupleHdrSize], unsafeAddr data[0], data.len)

proc unwrapTuple*(raw: seq[byte]): (TupleHdr, seq[byte]) =
  ## Split header and payload.
  if raw.len < TupleHdrSize:
    return (TupleHdr(), @[])
  let hdr  = decodeTupleHdr(raw, 0)
  let data = raw[TupleHdrSize .. ^1]
  (hdr, data)

# ─── Snapshot ─────────────────────────────────────────────────────────────

type
  TxnStatus* = enum tsActive, tsCommitted, tsAborted

  Snapshot* = object
    txnId*:           TxnId
    ## At snapshot creation, all txns with id <= minActive were committed.
    ## Active txns at snapshot time are invisible (even if committed later).
    minActive*:       TxnId
    activeTxns*:      HashSet[TxnId]

  CommitLog* = ref object
    mu*:     Lock
    status*: Table[TxnId, TxnStatus]
    maxCommitted*: TxnId

proc newCommitLog*(): CommitLog =
  result = CommitLog()
  initLock(result.mu)

proc markCommitted*(cl: CommitLog; id: TxnId) =
  acquire(cl.mu); defer: release(cl.mu)
  cl.status[id] = tsCommitted
  if id > cl.maxCommitted: cl.maxCommitted = id

proc markAborted*(cl: CommitLog; id: TxnId) =
  acquire(cl.mu); defer: release(cl.mu)
  cl.status[id] = tsAborted

proc isCommitted*(cl: CommitLog; id: TxnId): bool =
  acquire(cl.mu); defer: release(cl.mu)
  cl.status.getOrDefault(id, tsActive) == tsCommitted

proc isAborted*(cl: CommitLog; id: TxnId): bool =
  acquire(cl.mu); defer: release(cl.mu)
  cl.status.getOrDefault(id, tsActive) == tsAborted

# ─── MVCC visibility check ────────────────────────────────────────────────

proc isVisible*(hdr: TupleHdr; snap: Snapshot; cl: CommitLog): bool =
  ## Return true if this tuple version is visible to snapshot.

  ## xmin must be committed and not in active set at snapshot time
  let xminOk = hdr.xmin == snap.txnId or        ## own insert
               (cl.isCommitted(hdr.xmin) and
                hdr.xmin notin snap.activeTxns)
  if not xminOk: return false

  ## xmax: 0 means live; otherwise must be after snapshot
  if hdr.xmax == TxnId(0): return true         ## not deleted

  ## Deleted by self → not visible (deleted in same txn)
  if hdr.xmax == snap.txnId: return false

  ## Deleted by txn that was active at snapshot time → still visible
  if hdr.xmax in snap.activeTxns: return true

  ## Deleted by a txn that committed after snapshot → still visible
  not cl.isCommitted(hdr.xmax)

# ─── MVCC Manager ─────────────────────────────────────────────────────────

type
  MVCCManager* = ref object
    mu*:        Lock
    cl*:        CommitLog
    wal*:       WAL
    nextId*:    TxnId
    active*:    Table[TxnId, Snapshot]

proc newMVCCManager*(wal: WAL): MVCCManager =
  result = MVCCManager(cl: newCommitLog(), wal: wal, nextId: TxnId(1))
  initLock(result.mu)

proc beginTxn*(mm: MVCCManager): (TxnId, Snapshot) =
  acquire(mm.mu)
  let id  = mm.nextId; inc mm.nextId
  let actSet = toHashSet(toSeq(mm.active.keys))
  let minAct = if actSet.len > 0: actSet.min() else: id
  let snap = Snapshot(txnId: id, minActive: minAct, activeTxns: actSet)
  mm.active[id] = snap
  release(mm.mu)
  discard mm.wal.logBegin(id)
  (id, snap)

proc commitTxn*(mm: MVCCManager; id: TxnId; prevLsn: LSN) =
  discard mm.wal.logCommit(id, prevLsn)
  mm.cl.markCommitted(id)
  acquire(mm.mu); mm.active.del(id); release(mm.mu)

proc abortTxn*(mm: MVCCManager; id: TxnId; prevLsn: LSN) =
  discard mm.wal.logAbort(id, prevLsn)
  mm.cl.markAborted(id)
  acquire(mm.mu); mm.active.del(id); release(mm.mu)

proc snapshot*(mm: MVCCManager; id: TxnId): Snapshot =
  acquire(mm.mu); defer: release(mm.mu)
  mm.active.getOrDefault(id)

# ─── MVCC-aware heap scan wrapper ────────────────────────────────────────

type
  VisibleCallback* = proc(data: seq[byte]): bool {.closure.}

proc scanVisible*(rawRows: seq[seq[byte]]; snap: Snapshot;
                  cl: CommitLog; cb: VisibleCallback) =
  ## Filter raw heap tuples through MVCC visibility, then call cb.
  for raw in rawRows:
    let (hdr, data) = unwrapTuple(raw)
    if isVisible(hdr, snap, cl):
      if not cb(data): return

# ─── Garbage collection ───────────────────────────────────────────────────

proc canVacuum*(hdr: TupleHdr; cl: CommitLog;
                oldestActive: TxnId): bool =
  ## A dead version can be removed when:
  ##   xmax is committed AND xmax < oldestActive (no live reader needs it).
  if hdr.xmax == TxnId(0): return false   ## still alive
  cl.isCommitted(hdr.xmax) and hdr.xmax < oldestActive

proc vacuum*(mm: MVCCManager; rows: var seq[seq[byte]]) =
  acquire(mm.mu)
  let oldest = if mm.active.len > 0:
                 toSeq(mm.active.keys).min()
               else: mm.nextId
  release(mm.mu)
  rows.keepIf(proc(raw: seq[byte]): bool =
    let (hdr, _) = unwrapTuple(raw)
    not canVacuum(hdr, mm.cl, oldest))
