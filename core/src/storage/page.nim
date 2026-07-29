## page.nim — Fixed-size 8 KB page with slot array and heap tuples
##
## Layout:
##   [0..23]   PageHeader (24 bytes)
##   [24..]    SlotArray  grows →  (4 bytes / slot)
##   [gap]     Free space
##   [..]      TupleData  grows ←  (variable length, at end of page)
##
## SlotEntry (4 bytes):
##   offset : uint16   byte offset from page start to tuple (0 = deleted)
##   length : uint16   byte length of tuple (0 = deleted)

import types

const
  PageHeaderSize* = 24
  SlotEntrySize*  = 4

type
  PageHeader* = object
    lsn*:       LSN      ## Last WAL LSN modifying this page
    pageId*:    PageId
    slotCount*: uint16   ## Total slot entries (includes deleted)
    freeStart*: uint16   ## First free byte (after slot array)
    freeEnd*:   uint16   ## First byte of tuple area
    flags*:     uint16

  SlotEntry* = object
    offset*: uint16
    length*: uint16

  Page* = object
    data*: array[PageSize, byte]

# ─── Header / Slot access ──────────────────────────────────────────────────

proc hdr*(p: ptr Page): ptr PageHeader {.inline.} =
  cast[ptr PageHeader](addr p.data[0])

proc hdr*(p: var Page): ptr PageHeader {.inline.} =
  cast[ptr PageHeader](addr p.data[0])

proc slot*(p: var Page, idx: uint16): ptr SlotEntry {.inline.} =
  cast[ptr SlotEntry](addr p.data[PageHeaderSize + int(idx) * SlotEntrySize])

proc slot*(p: ptr Page, idx: uint16): ptr SlotEntry {.inline.} =
  cast[ptr SlotEntry](addr p.data[PageHeaderSize + int(idx) * SlotEntrySize])

# ─── Page lifecycle ────────────────────────────────────────────────────────

proc initPage*(p: var Page, id: PageId) =
  zeroMem(addr p.data[0], PageSize)
  let h = p.hdr()
  h.lsn       = InvalidLSN
  h.pageId    = id
  h.slotCount = 0
  h.freeStart = uint16(PageHeaderSize)
  h.freeEnd   = uint16(PageSize)
  h.flags     = 0

proc freeSpace*(p: var Page): int {.inline.} =
  let h = p.hdr()
  int(h.freeEnd) - int(h.freeStart)

proc freeSpace*(p: ptr Page): int {.inline.} =
  let h = p.hdr()
  int(h.freeEnd) - int(h.freeStart)

# ─── Tuple operations ──────────────────────────────────────────────────────

proc insertTuple*(p: var Page, data: openArray[byte]): int =
  ## Insert tuple; return slot index or -1 if page is full.
  let needed = data.len + SlotEntrySize
  if p.freeSpace() < needed:
    return -1
  let h = p.hdr()
  # Tuple placed at freeEnd (growing backward)
  let tupleOff = int(h.freeEnd) - data.len
  if data.len > 0:
    copyMem(addr p.data[tupleOff], unsafeAddr data[0], data.len)
  # Write slot entry
  let si = int(h.slotCount)
  let s  = p.slot(uint16(si))
  s.offset = uint16(tupleOff)
  s.length = uint16(data.len)
  # Update header
  h.freeEnd   = uint16(tupleOff)
  h.freeStart = uint16(PageHeaderSize + (si + 1) * SlotEntrySize)
  inc h.slotCount
  return si

proc getTuple*(p: var Page, si: uint16, buf: var seq[byte]): bool =
  ## Copy tuple bytes into buf. Returns false if slot missing or deleted.
  let h = p.hdr()
  if si >= h.slotCount: return false
  let s = p.slot(si)
  if s.length == 0: return false
  buf.setLen(int(s.length))
  copyMem(addr buf[0], addr p.data[int(s.offset)], int(s.length))
  true

proc getTuple*(p: ptr Page, si: uint16, buf: var seq[byte]): bool =
  let h = p.hdr()
  if si >= h.slotCount: return false
  let s = p.slot(si)
  if s.length == 0: return false
  buf.setLen(int(s.length))
  copyMem(addr buf[0], addr p.data[int(s.offset)], int(s.length))
  true

proc deleteTuple*(p: var Page, si: uint16): bool =
  ## Mark slot as deleted (length = 0).
  let h = p.hdr()
  if si >= h.slotCount: return false
  let s = p.slot(si)
  if s.length == 0: return false   # already deleted
  s.offset = 0
  s.length = 0
  true

proc updateTuple*(p: var Page, si: uint16, data: openArray[byte]): bool =
  ## Update tuple in-place if it fits; otherwise delete + reinsert into new slot,
  ## then redirect old slot to new location.
  let h = p.hdr()
  if si >= h.slotCount: return false
  let s = p.slot(si)
  if s.length == 0: return false   # deleted

  if data.len <= int(s.length):
    # Fits in current space
    if data.len > 0:
      copyMem(addr p.data[int(s.offset)], unsafeAddr data[0], data.len)
    s.length = uint16(data.len)
    return true

  # Doesn't fit — free old slot, insert new, redirect
  s.offset = 0
  s.length = 0
  let newSi = p.insertTuple(data)
  if newSi < 0: return false
  let ns = p.slot(uint16(newSi))
  s.offset = ns.offset
  s.length = ns.length
  ns.offset = 0
  ns.length = 0
  true

proc iterSlots*(p: var Page): seq[(uint16, seq[byte])] =
  ## Return all alive (slot, data) pairs.
  let h = p.hdr()
  for i in 0'u16 ..< h.slotCount:
    let s = p.slot(i)
    if s.length > 0:
      var buf = newSeq[byte](int(s.length))
      copyMem(addr buf[0], addr p.data[int(s.offset)], int(s.length))
      result.add((i, buf))
