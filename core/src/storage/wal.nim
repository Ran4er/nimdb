## wal.nim — Write-Ahead Log
##
## Each log record:
##   lsn     : uint64   (8 bytes)
##   prevLsn : uint64   (8 bytes) — previous LSN of same txn
##   txnId   : uint64   (8 bytes)
##   recType : uint8    (1 byte)
##   bodyLen : uint32   (4 bytes)
##   body    : bytes    (bodyLen bytes)
##   crc32   : uint32   (4 bytes)
##
## Recovery: on startup we replay all records with recType != walAbort
## forward from the last checkpoint LSN.

import std/[os, locks]
import types

const RecHdrSize* = 8 + 8 + 8 + 1 + 4   ## 29 bytes, before body

type
  WalRecType* = enum
    walBegin      = 0'u8
    walCommit     = 1'u8
    walAbort      = 2'u8
    walInsert     = 3'u8
    walUpdate     = 4'u8
    walDelete     = 5'u8
    walCheckpoint = 6'u8

  WalRecord* = object
    lsn*:     LSN
    prevLsn*: LSN
    txnId*:   TxnId
    recType*: WalRecType
    body*:    seq[byte]

  WAL* = ref object
    path:      string
    fd:        File
    mu:        Lock
    nextLsn:   LSN
    lastFlush: LSN
    wbuf:      seq[byte]   ## write buffer
    wpos:      int

# ─── CRC32 ────────────────────────────────────────────────────────────────

proc crc32*(data: openArray[byte]): uint32 =
  result = 0xFFFF_FFFF'u32
  for b in data:
    result = result xor uint32(b)
    for _ in 0..7:
      let mask = -(result and 1)
      result = (result shr 1) xor (0xEDB8_8320'u32 and mask)
  result = result xor 0xFFFF_FFFF'u32

# ─── WAL open / close ─────────────────────────────────────────────────────

proc openWAL*(path: string): WAL =
  result = WAL(
    path: path,
    nextLsn: LSN(1),
    lastFlush: InvalidLSN,
    wbuf: newSeq[byte](WalBufSize * 2),
    wpos: 0
  )
  initLock(result.mu)

  let exists = fileExists(path)
  let mode   = if exists: fmReadWriteExisting else: fmReadWrite
  if not open(result.fd, path, mode):
    raise newException(StorageError, "Cannot open WAL file: " & path)

  if exists:
    # Fast-scan to compute nextLsn from last valid record
    result.fd.setFilePos(0)
    var rawHdr = newSeq[byte](RecHdrSize)
    while true:
      let n = result.fd.readBuffer(addr rawHdr[0], RecHdrSize)
      if n < RecHdrSize: break
      let lsn     = leGet64(rawHdr, 0)
      let bodyLen = int(leGet32(rawHdr, 25))
      # skip body + crc
      result.fd.setFilePos(result.fd.getFilePos() + bodyLen + 4)
      if LSN(lsn) >= result.nextLsn:
        result.nextLsn = LSN(lsn + 1)
    # Position at end for appending
    result.fd.setFilePos(result.fd.getFileSize())

proc closeWAL*(w: WAL) =
  if not w.fd.isNil:
    acquire(w.mu)
    if w.wpos > 0:
      discard w.fd.writeBuffer(addr w.wbuf[0], w.wpos)
      w.wpos = 0
      flushFile(w.fd)
    release(w.mu)
    close(w.fd)
  deinitLock(w.mu)

# ─── Internal write helpers ───────────────────────────────────────────────

proc bufAppend(w: WAL, data: openArray[byte]) {.inline.} =
  if w.wpos + data.len > w.wbuf.len:
    w.wbuf.setLen(w.wpos + data.len + WalBufSize)
  copyMem(addr w.wbuf[w.wpos], unsafeAddr data[0], data.len)
  w.wpos += data.len

proc flushBuf(w: WAL) =
  ## Must be called while holding w.mu
  if w.wpos > 0:
    let written = w.fd.writeBuffer(addr w.wbuf[0], w.wpos)
    if written != w.wpos:
      raise newException(StorageError, "WAL write error")
    flushFile(w.fd)
    w.wpos = 0
    w.lastFlush = LSN(w.nextLsn - 1)

# ─── Public append API ────────────────────────────────────────────────────

proc append*(w: WAL; txnId: TxnId; rt: WalRecType;
             body: openArray[byte]; prevLsn = InvalidLSN): LSN =
  acquire(w.mu)
  defer: release(w.mu)

  let lsn = w.nextLsn
  inc w.nextLsn

  # Build 29-byte header
  var hdr = newSeq[byte](RecHdrSize)
  lePut64(hdr,  0, uint64(lsn))
  lePut64(hdr,  8, uint64(prevLsn))
  lePut64(hdr, 16, uint64(txnId))
  hdr[24] = uint8(rt)
  lePut32(hdr, 25, uint32(body.len))

  let crc = crc32(body)
  var crcBuf = [byte(crc), byte(crc shr 8), byte(crc shr 16), byte(crc shr 24)]

  w.bufAppend(hdr)
  if body.len > 0: w.bufAppend(body)
  w.bufAppend(crcBuf)

  # Flush on commit/abort or when buffer is large
  if rt in {walCommit, walAbort} or w.wpos >= WalBufSize:
    w.flushBuf()

  lsn

proc flush*(w: WAL) =
  acquire(w.mu)
  w.flushBuf()
  release(w.mu)

# ─── Typed log helpers ────────────────────────────────────────────────────

proc logBegin*(w: WAL; txnId: TxnId): LSN =
  w.append(txnId, walBegin, [])

proc logCommit*(w: WAL; txnId: TxnId; prev: LSN): LSN =
  w.append(txnId, walCommit, [], prev)

proc logAbort*(w: WAL; txnId: TxnId; prev: LSN): LSN =
  w.append(txnId, walAbort, [], prev)

proc logInsert*(w: WAL; txnId: TxnId; prev: LSN;
                tableId: ObjId; pageId: PageId; slotId: uint16;
                data: openArray[byte]): LSN =
  var body = newSeq[byte](4 + 4 + 2 + 2 + data.len)
  lePut32(body,  0, tableId)
  lePut32(body,  4, pageId)
  lePut16(body,  8, slotId)
  lePut16(body, 10, uint16(data.len))
  if data.len > 0:
    copyMem(addr body[12], unsafeAddr data[0], data.len)
  w.append(txnId, walInsert, body, prev)

proc logUpdate*(w: WAL; txnId: TxnId; prev: LSN;
                tableId: ObjId; pageId: PageId; slotId: uint16;
                newData: openArray[byte]): LSN =
  var body = newSeq[byte](4 + 4 + 2 + 2 + newData.len)
  lePut32(body,  0, tableId)
  lePut32(body,  4, pageId)
  lePut16(body,  8, slotId)
  lePut16(body, 10, uint16(newData.len))
  if newData.len > 0:
    copyMem(addr body[12], unsafeAddr newData[0], newData.len)
  w.append(txnId, walUpdate, body, prev)

proc logDelete*(w: WAL; txnId: TxnId; prev: LSN;
                tableId: ObjId; pageId: PageId; slotId: uint16): LSN =
  var body = newSeq[byte](10)
  lePut32(body, 0, tableId)
  lePut32(body, 4, pageId)
  lePut16(body, 8, slotId)
  w.append(txnId, walDelete, body, prev)

# ─── Recovery: replay WAL from beginning ──────────────────────────────────

type ReplayHandler* = proc(rec: WalRecord) {.closure.}

proc replay*(w: WAL; handler: ReplayHandler) =
  ## Read all valid records from WAL and call handler for each.
  ## Used during crash recovery.
  let saved = w.fd.getFilePos()
  w.fd.setFilePos(0)
  defer: w.fd.setFilePos(saved)

  var rawHdr = newSeq[byte](RecHdrSize)
  while true:
    let n = w.fd.readBuffer(addr rawHdr[0], RecHdrSize)
    if n < RecHdrSize: break

    let lsn     = LSN(leGet64(rawHdr, 0))
    let prevLsn = LSN(leGet64(rawHdr, 8))
    let txnId   = TxnId(leGet64(rawHdr, 16))
    let rt      = WalRecType(rawHdr[24])
    let bodyLen = int(leGet32(rawHdr, 25))

    var body = newSeq[byte](bodyLen)
    if bodyLen > 0:
      let bn = w.fd.readBuffer(addr body[0], bodyLen)
      if bn < bodyLen: break

    var crcBuf: array[4, byte]
    if w.fd.readBuffer(addr crcBuf[0], 4) < 4: break
    let storedCrc = leGet32(crcBuf, 0)
    if storedCrc != crc32(body): continue   # skip corrupt record

    handler(WalRecord(lsn: lsn, prevLsn: prevLsn,
                      txnId: txnId, recType: rt, body: body))
