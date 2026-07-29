## heap_file.nim — Heap file: manages pages for one table
##
## Each table is stored as a file of 8 KB pages.
## Page 0 is a "header page" with free-space info for the rest.
## Tuples are inserted into the first page with enough free space.

import std/[tables, os, locks]
import types, page, buffer_pool, wal

type
  TupleId* = object
    pageId*: PageId
    slotId*: uint16

  ScanCallback* = proc(tid: TupleId; data: seq[byte]): bool {.closure.}
    ## Return false to stop scan

  HeapFile* = ref object
    tableId*:  ObjId
    path*:     string
    fd*:       File
    mu*:       Lock
    pageCount*: uint32
    bp*:       BufferPool
    wal*:      WAL

# ─── Page I/O (used as loader/flusher callbacks) ──────────────────────────

proc readPageFromDisk*(fd: File; pageId: PageId; pg: var Page) =
  let off = int64(pageId) * PageSize
  fd.setFilePos(off)
  let n = fd.readBuffer(addr pg.data[0], PageSize)
  if n == 0:
    pg.initPage(pageId)   # new page not yet on disk

proc writePageToDisk*(fd: File; pageId: PageId; pg: var Page) =
  let off = int64(pageId) * PageSize
  fd.setFilePos(off)
  discard fd.writeBuffer(addr pg.data[0], PageSize)
  flushFile(fd)

# ─── HeapFile lifecycle ───────────────────────────────────────────────────

proc openHeapFile*(tableId: ObjId; path: string;
                   bp: BufferPool; wal: WAL): HeapFile =
  result = HeapFile(tableId: tableId, path: path, bp: bp, wal: wal)
  initLock(result.mu)

  let exists = fileExists(path)
  let mode   = if exists: fmReadWriteExisting else: fmReadWrite
  if not open(result.fd, path, mode):
    raise newException(StorageError, "Cannot open heap file: " & path)

  result.pageCount = if exists:
    uint32(getFileSize(path) div PageSize)
  else:
    0'u32

  # Wire buffer pool's flusher to write via this file
  let fd = result.fd
  bp.flusher = proc(tid: ObjId; pid: PageId; pg: var Page) =
    writePageToDisk(fd, pid, pg)

proc closeHeapFile*(hf: HeapFile) =
  hf.bp.flushTable(hf.tableId)
  close(hf.fd)
  deinitLock(hf.mu)

# ─── Loader helper ────────────────────────────────────────────────────────

proc makeLoader(hf: HeapFile): PageLoader =
  let fd = hf.fd
  result = proc(tid: ObjId; pid: PageId; pg: var Page) =
    readPageFromDisk(fd, pid, pg)

# ─── Allocate a new page ──────────────────────────────────────────────────

proc allocPage(hf: HeapFile): ptr Page =
  let pid = PageId(hf.pageCount)
  inc hf.pageCount
  let pg = hf.bp.pin(hf.tableId, pid, nil)   # init blank page
  pg.initPage(pid)
  hf.bp.markDirty(hf.tableId, pid)
  pg

# ─── Insert tuple ─────────────────────────────────────────────────────────

proc insert*(hf: HeapFile; data: openArray[byte];
             txnId: TxnId; prevLsn: var LSN): TupleId =
  acquire(hf.mu)
  defer: release(hf.mu)

  # Try existing pages (from last to first for better space locality)
  var pi = if hf.pageCount == 0: 0'u32 else: hf.pageCount - 1
  while true:
    let pg = hf.bp.pin(hf.tableId, PageId(pi), hf.makeLoader())
    let si = pg.insertTuple(data)
    if si >= 0:
      hf.bp.markDirty(hf.tableId, PageId(pi))
      prevLsn = hf.wal.logInsert(txnId, prevLsn,
                  hf.tableId, PageId(pi), uint16(si), data)
      hf.bp.unpin(hf.tableId, PageId(pi))
      return TupleId(pageId: PageId(pi), slotId: uint16(si))
    hf.bp.unpin(hf.tableId, PageId(pi))
    if pi == 0: break
    dec pi

  # All pages full — allocate new
  let pg = hf.allocPage()
  let pid = pg.hdr().pageId
  let si  = pg.insertTuple(data)
  hf.bp.markDirty(hf.tableId, pid)
  prevLsn = hf.wal.logInsert(txnId, prevLsn, hf.tableId, pid, uint16(si), data)
  hf.bp.unpin(hf.tableId, pid)
  TupleId(pageId: pid, slotId: uint16(si))

# ─── Get single tuple ─────────────────────────────────────────────────────

proc get*(hf: HeapFile; tid: TupleId; buf: var seq[byte]): bool =
  let pg = hf.bp.pin(hf.tableId, tid.pageId, hf.makeLoader())
  result = pg.getTuple(tid.slotId, buf)
  hf.bp.unpin(hf.tableId, tid.pageId)

# ─── Delete tuple ─────────────────────────────────────────────────────────

proc delete*(hf: HeapFile; tid: TupleId; txnId: TxnId; prevLsn: var LSN): bool =
  acquire(hf.mu)
  defer: release(hf.mu)
  let pg = hf.bp.pin(hf.tableId, tid.pageId, hf.makeLoader())
  result = pg.deleteTuple(tid.slotId)
  if result:
    hf.bp.markDirty(hf.tableId, tid.pageId)
    prevLsn = hf.wal.logDelete(txnId, prevLsn,
                hf.tableId, tid.pageId, tid.slotId)
  hf.bp.unpin(hf.tableId, tid.pageId)

# ─── Update tuple ─────────────────────────────────────────────────────────

proc update*(hf: HeapFile; tid: TupleId; data: openArray[byte];
             txnId: TxnId; prevLsn: var LSN): bool =
  acquire(hf.mu)
  defer: release(hf.mu)
  let pg = hf.bp.pin(hf.tableId, tid.pageId, hf.makeLoader())
  result = pg.updateTuple(tid.slotId, data)
  if result:
    hf.bp.markDirty(hf.tableId, tid.pageId)
    prevLsn = hf.wal.logUpdate(txnId, prevLsn,
                hf.tableId, tid.pageId, tid.slotId, data)
  hf.bp.unpin(hf.tableId, tid.pageId)

# ─── Full sequential scan ─────────────────────────────────────────────────

proc scan*(hf: HeapFile; cb: ScanCallback) =
  for pid in 0'u32 ..< hf.pageCount:
    let pg = hf.bp.pin(hf.tableId, PageId(pid), hf.makeLoader())
    let h  = pg.hdr()
    for si in 0'u16 ..< h.slotCount:
      var buf: seq[byte]
      if pg.getTuple(si, buf):
        let tid = TupleId(pageId: PageId(pid), slotId: si)
        if not cb(tid, buf):
          hf.bp.unpin(hf.tableId, PageId(pid))
          return
    hf.bp.unpin(hf.tableId, PageId(pid))
