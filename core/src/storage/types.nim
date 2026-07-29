## types.nim — Core types, constants, and errors for NimDB

const
  PageSize*       = 8192        ## 8 KB page (same as PostgreSQL default)
  MaxNameLen*     = 64          ## Max identifier length
  BufferPoolSize* = 2048        ## Number of buffer frames (~16 MB)
  MaxColumns*     = 128         ## Max columns per table
  WalBufSize*     = 64 * 1024   ## WAL write buffer (64 KB)

type
  PageId*  = uint32   ## Logical page number within a heap file
  LSN*     = uint64   ## Log Sequence Number (monotone, 1-based)
  TxnId*   = uint64   ## Transaction identifier
  ObjId*   = uint32   ## Table / index object identifier
  FrameId* = int      ## Buffer pool frame index

  NimDBError*   = object of CatchableError
  StorageError* = object of NimDBError
  TxnError*     = object of NimDBError
  SQLError*     = object of NimDBError
  CatalogError* = object of NimDBError

const
  InvalidPage*  = PageId(0xFFFF_FFFF'u32)
  InvalidLSN*   = LSN(0)
  InvalidTxnId* = TxnId(0)
  InvalidFrame* = FrameId(-1)

# ─── Little-endian helpers ────────────────────────────────────────────────────

proc leGet16*(buf: openArray[byte], off: int): uint16 {.inline.} =
  uint16(buf[off]) or (uint16(buf[off+1]) shl 8)

proc leGet32*(buf: openArray[byte], off: int): uint32 {.inline.} =
  uint32(buf[off]) or (uint32(buf[off+1]) shl 8) or
  (uint32(buf[off+2]) shl 16) or (uint32(buf[off+3]) shl 24)

proc leGet64*(buf: openArray[byte], off: int): uint64 {.inline.} =
  uint64(leGet32(buf, off)) or (uint64(leGet32(buf, off+4)) shl 32)

proc lePut16*(buf: var openArray[byte], off: int, v: uint16) {.inline.} =
  buf[off]   = byte(v and 0xFF)
  buf[off+1] = byte(v shr 8)

proc lePut32*(buf: var openArray[byte], off: int, v: uint32) {.inline.} =
  buf[off]   = byte(v and 0xFF)
  buf[off+1] = byte((v shr 8) and 0xFF)
  buf[off+2] = byte((v shr 16) and 0xFF)
  buf[off+3] = byte(v shr 24)

proc lePut64*(buf: var openArray[byte], off: int, v: uint64) {.inline.} =
  lePut32(buf, off,   uint32(v and 0xFFFF_FFFF'u64))
  lePut32(buf, off+4, uint32(v shr 32))
