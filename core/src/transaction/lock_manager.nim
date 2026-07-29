## lock_manager.nim — Two-Phase Locking (2PL)
##
## Lock granularity:
##   Table lock : (tableId)
##   Row lock   : (tableId, pageId, slotId)
##
## Lock modes:
##   Shared (S)    — multiple readers can hold simultaneously
##   Exclusive (X) — only one writer; incompatible with S and X
##
## Compatibility matrix:
##          S      X
##   S    grant  wait
##   X    wait   wait

import std/[tables, locks, sets]
import ../storage/types

type
  LockMode* = enum
    lmShared = "S", lmExclusive = "X"

  LockKey* = object
    tableId*: ObjId
    pageId*:  PageId   ## InvalidPage → table-level lock
    slotId*:  uint16

  LockEntry* = object
    holders*:  HashSet[TxnId]
    mode*:     LockMode
    waiting*:  seq[(TxnId, LockMode)]  ## txnId, requested mode

  LockManager* = ref object
    mu*:   Lock
    locks*: Table[LockKey, LockEntry]

proc newLockManager*(): LockManager =
  result = LockManager()
  initLock(result.mu)

proc tableLock*(tableId: ObjId): LockKey =
  LockKey(tableId: tableId, pageId: InvalidPage, slotId: 0)

proc rowLock*(tableId: ObjId; pageId: PageId; slotId: uint16): LockKey =
  LockKey(tableId: tableId, pageId: pageId, slotId: slotId)

proc compatible(held: LockMode; req: LockMode): bool =
  held == lmShared and req == lmShared

proc tryAcquire*(lm: LockManager; txnId: TxnId; key: LockKey;
                 mode: LockMode): bool =
  ## Non-blocking lock attempt. Returns true if lock was granted immediately.
  acquire(lm.mu)
  defer: release(lm.mu)

  if not lm.locks.hasKey(key):
    # No contention — grant immediately
    lm.locks[key] = LockEntry(
      holders: [txnId].toHashSet(),
      mode: mode,
      waiting: @[])
    return true

  var entry = lm.locks[key]

  # Already holding it — upgrade or re-grant
  if txnId in entry.holders:
    if entry.mode == lmExclusive or mode == lmShared:
      return true   # already have what we need
    # Upgrade S → X: only allowed if sole holder
    if entry.holders.len == 1:
      entry.mode = lmExclusive
      lm.locks[key] = entry
      return true
    return false   # other holders, cannot upgrade yet

  if compatible(entry.mode, mode):
    entry.holders.incl(txnId)
    lm.locks[key] = entry
    return true

  return false

proc acquire*(lm: LockManager; txnId: TxnId; key: LockKey;
              mode: LockMode; timeoutMs = 5000) =
  ## Blocking acquire. Raises TxnError on timeout.
  import std/times
  let deadline = getTime() + initDuration(milliseconds = timeoutMs)
  while true:
    if lm.tryAcquire(txnId, key, mode): return
    if getTime() > deadline:
      raise newException(TxnError,
        "Lock timeout for txn " & $txnId & " on " & $key.tableId)
    sleep(1)

proc release*(lm: LockManager; txnId: TxnId; key: LockKey) =
  acquire(lm.mu)
  defer: release(lm.mu)
  if not lm.locks.hasKey(key): return
  var entry = lm.locks[key]
  entry.holders.excl(txnId)
  if entry.holders.len == 0:
    lm.locks.del(key)
  else:
    lm.locks[key] = entry

proc releaseAll*(lm: LockManager; txnId: TxnId) =
  ## Release every lock held by this transaction (called on commit/abort).
  acquire(lm.mu)
  defer: release(lm.mu)
  var toRemove: seq[LockKey]
  for key, entry in lm.locks.mpairs:
    entry.holders.excl(txnId)
    if entry.holders.len == 0: toRemove.add(key)
  for k in toRemove: lm.locks.del(k)

proc heldBy*(lm: LockManager; txnId: TxnId): seq[LockKey] =
  acquire(lm.mu)
  defer: release(lm.mu)
  for key, entry in lm.locks:
    if txnId in entry.holders: result.add(key)
