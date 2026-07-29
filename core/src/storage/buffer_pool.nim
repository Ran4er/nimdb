## buffer_pool.nim — LRU Buffer Pool
##
## The buffer pool keeps frequently-used pages in RAM.
## Each "frame" holds one 8 KB page. Frames are evicted with
## a Clock (Second-Chance) algorithm — O(1) amortized.
##
## Usage:
##   let bp = newBufferPool(wal)
##   let pg = bp.pin(tableId, pageId, loader)   -- load & pin
##   # ... read / modify pg.data ...
##   bp.markDirty(tableId, pageId)
##   bp.unpin(tableId, pageId)

import std/[tables, locks, hashes]
import types, page, wal

type
  FrameState* = enum
    fsFree, fsClean, fsDirty

  Frame* = object
    tableId*:  ObjId
    pageId*:   PageId
    pinCount*: int
    refBit*:   bool   ## Clock reference bit
    state*:    FrameState
    page*:     Page

  ## Loader: reads a page from storage; nil means init blank page
  PageLoader* = proc(tableId: ObjId, pageId: PageId, pg: var Page) {.closure.}
  ## Flusher: writes a dirty page back to storage
  PageFlusher* = proc(tableId: ObjId, pageId: PageId, pg: var Page) {.closure.}

  BufferPool* = ref object
    frames*:   seq[Frame]
    index*:    Table[(ObjId, PageId), int]   ## key → frame idx
    mu*:       Lock
    clock*:    int      ## Clock hand for eviction
    wal*:      WAL
    flusher*:  PageFlusher

proc newBufferPool*(wal: WAL; flusher: PageFlusher = nil;
                    size = BufferPoolSize): BufferPool =
  result = BufferPool(
    frames: newSeq[Frame](size),
    wal: wal,
    flusher: flusher
  )
  initLock(result.mu)

# ─── Clock eviction ───────────────────────────────────────────────────────

proc evict(bp: BufferPool): int =
  ## Find a frame to evict using Clock algorithm. Returns frame index or -1.
  let n = bp.frames.len
  var attempts = 0
  while attempts < 2 * n:
    let i = bp.clock
    bp.clock = (bp.clock + 1) mod n
    var f = addr bp.frames[i]
    if f.state == fsFree:
      return i
    if f.pinCount > 0:
      inc attempts
      continue
    if f.refBit:
      f.refBit = false   ## second chance
      inc attempts
      continue
    # Evict this frame
    if f.state == fsDirty and not bp.flusher.isNil:
      bp.flusher(f.tableId, f.pageId, f.page)
    bp.index.del((f.tableId, f.pageId))
    f.state    = fsFree
    f.pinCount = 0
    f.refBit   = false
    return i
    inc attempts
  return -1

# ─── Public API ───────────────────────────────────────────────────────────

proc pin*(bp: BufferPool; tableId: ObjId; pageId: PageId;
          loader: PageLoader = nil): ptr Page =
  ## Pin a page into the buffer pool. Loads it if not cached.
  ## Returns a raw pointer valid until unpin() is called.
  acquire(bp.mu)
  defer: release(bp.mu)

  let key = (tableId, pageId)
  if key in bp.index:
    let fi = bp.index[key]
    bp.frames[fi].pinCount += 1
    bp.frames[fi].refBit = true
    return addr bp.frames[fi].page

  # Not cached — evict + load
  let fi = bp.evict()
  if fi < 0:
    raise newException(StorageError, "Buffer pool exhausted")

  var f = addr bp.frames[fi]
  f.tableId  = tableId
  f.pageId   = pageId
  f.pinCount = 1
  f.refBit   = true
  f.state    = fsClean

  if loader != nil:
    loader(tableId, pageId, f.page)
  else:
    f.page.initPage(pageId)

  bp.index[key] = fi
  addr f.page

proc unpin*(bp: BufferPool; tableId: ObjId; pageId: PageId) =
  acquire(bp.mu)
  defer: release(bp.mu)
  let key = (tableId, pageId)
  if key in bp.index:
    let fi = bp.index[key]
    if bp.frames[fi].pinCount > 0:
      dec bp.frames[fi].pinCount

proc markDirty*(bp: BufferPool; tableId: ObjId; pageId: PageId) =
  acquire(bp.mu)
  defer: release(bp.mu)
  let key = (tableId, pageId)
  if key in bp.index:
    bp.frames[bp.index[key]].state = fsDirty

proc flushAll*(bp: BufferPool) =
  ## Flush all dirty pages to disk (used on shutdown / checkpoint).
  acquire(bp.mu)
  defer: release(bp.mu)
  for i in 0 ..< bp.frames.len:
    var f = addr bp.frames[i]
    if f.state == fsDirty and not bp.flusher.isNil:
      bp.flusher(f.tableId, f.pageId, f.page)
      f.state = fsClean

proc flushTable*(bp: BufferPool; tableId: ObjId) =
  acquire(bp.mu)
  defer: release(bp.mu)
  for i in 0 ..< bp.frames.len:
    var f = addr bp.frames[i]
    if f.tableId == tableId and f.state == fsDirty and not bp.flusher.isNil:
      bp.flusher(f.tableId, f.pageId, f.page)
      f.state = fsClean

proc invalidate*(bp: BufferPool; tableId: ObjId) =
  ## Remove all frames for a table (used on DROP TABLE).
  acquire(bp.mu)
  defer: release(bp.mu)
  var toRemove: seq[(ObjId, PageId)]
  for key, fi in bp.index:
    if key[0] == tableId:
      bp.frames[fi].state    = fsFree
      bp.frames[fi].pinCount = 0
      toRemove.add(key)
  for k in toRemove:
    bp.index.del(k)
