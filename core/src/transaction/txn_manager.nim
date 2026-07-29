## txn_manager.nim — Transaction lifecycle manager
##
## Tracks active transactions, their WAL LSN chains, and coordinates
## with the lock manager on commit / abort.

import std/[tables, locks, atomics]
import ../storage/[types, wal]
import lock_manager

type
  TxnStatus* = enum
    txActive, txCommitted, txAborted

  TxnRecord* = object
    txnId*:    TxnId
    status*:   TxnStatus
    lastLsn*:  LSN
    beginLsn*: LSN

  TxnManager* = ref object
    wal*:      WAL
    lockMgr*:  LockManager
    mu*:       Lock
    txns*:     Table[TxnId, TxnRecord]
    nextId*:   uint64
    ## Thread-local "current session transaction"
    ## (for single-connection REPL use; set per-connection in server)
    curTxn*:   TxnId

proc newTxnManager*(wal: WAL): TxnManager =
  result = TxnManager(
    wal:     wal,
    lockMgr: newLockManager(),
    nextId:  1,
    curTxn:  InvalidTxnId
  )
  initLock(result.mu)

# ─── Begin ────────────────────────────────────────────────────────────────

proc begin*(tm: TxnManager): TxnId =
  acquire(tm.mu)
  let id = TxnId(tm.nextId); inc tm.nextId
  release(tm.mu)
  let lsn = tm.wal.logBegin(id)
  acquire(tm.mu)
  tm.txns[id] = TxnRecord(txnId: id, status: txActive,
                           lastLsn: lsn, beginLsn: lsn)
  release(tm.mu)
  id

# ─── Commit ───────────────────────────────────────────────────────────────

proc commit*(tm: TxnManager; txnId: TxnId) =
  acquire(tm.mu)
  if not tm.txns.hasKey(txnId):
    release(tm.mu)
    raise newException(TxnError, "Unknown txn: " & $txnId)
  let prev = tm.txns[txnId].lastLsn
  release(tm.mu)

  let lsn = tm.wal.logCommit(txnId, prev)
  tm.lockMgr.releaseAll(txnId)

  acquire(tm.mu)
  tm.txns[txnId] = TxnRecord(txnId: txnId, status: txCommitted, lastLsn: lsn)
  if tm.curTxn == txnId: tm.curTxn = InvalidTxnId
  release(tm.mu)

# ─── Abort ────────────────────────────────────────────────────────────────

proc abort*(tm: TxnManager; txnId: TxnId) =
  acquire(tm.mu)
  if not tm.txns.hasKey(txnId):
    release(tm.mu)
    return
  let prev = tm.txns[txnId].lastLsn
  release(tm.mu)

  discard tm.wal.logAbort(txnId, prev)
  tm.lockMgr.releaseAll(txnId)

  acquire(tm.mu)
  tm.txns[txnId] = TxnRecord(txnId: txnId, status: txAborted, lastLsn: InvalidLSN)
  if tm.curTxn == txnId: tm.curTxn = InvalidTxnId
  release(tm.mu)

# ─── Helpers ──────────────────────────────────────────────────────────────

proc currentTxn*(tm: TxnManager): TxnId =
  acquire(tm.mu); defer: release(tm.mu)
  tm.curTxn

proc setCurrentTxn*(tm: TxnManager; id: TxnId) =
  acquire(tm.mu); defer: release(tm.mu)
  tm.curTxn = id

proc lastLsn*(tm: TxnManager; txnId: TxnId): LSN =
  acquire(tm.mu); defer: release(tm.mu)
  if tm.txns.hasKey(txnId): tm.txns[txnId].lastLsn
  else: InvalidLSN

proc setLastLsn*(tm: TxnManager; txnId: TxnId; lsn: LSN) =
  acquire(tm.mu); defer: release(tm.mu)
  if tm.txns.hasKey(txnId):
    tm.txns[txnId].lastLsn = lsn

proc isActive*(tm: TxnManager; txnId: TxnId): bool =
  acquire(tm.mu); defer: release(tm.mu)
  tm.txns.hasKey(txnId) and tm.txns[txnId].status == txActive

proc abortAll*(tm: TxnManager) =
  ## Abort every active txn (called on shutdown).
  acquire(tm.mu)
  var actives: seq[TxnId]
  for id, rec in tm.txns:
    if rec.status == txActive: actives.add(id)
  release(tm.mu)
  for id in actives: tm.abort(id)
