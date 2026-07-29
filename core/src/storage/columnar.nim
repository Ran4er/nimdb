## columnar.nim — Columnar (PAX-like) storage for OLAP / ML batch reads
##
## Each "column chunk" is a typed, optionally compressed array of values.
## A ColumnStore holds N chunks per column, each chunk ~ ChunkSize rows.
##
## Compression schemes per column:
##   None     — raw bytes
##   RLE      — run-length encoding (good for low-cardinality)
##   Delta    — delta encoding (good for sorted / monotone ints)
##   DictEnc  — dictionary encoding (good for string columns)
##
## The columnar store is separate from the heap files — it is populated
## via a bulk-load from a heap scan (materialise) or via streaming inserts.
## It does NOT support in-place updates; append-only + compaction.

import std/[tables, algorithm, sequtils, math, os]
import ../storage/types
import ../catalog/schema

const ChunkSize* = 65536   ## rows per chunk (~64K)

type
  Encoding* = enum
    encNone, encRLE, encDelta, encDict

  ## Compressed chunk of one column
  ColChunk* = object
    encoding*:   Encoding
    dtype*:      ColKind
    rowCount*:   int
    nullBitmap*: seq[byte]   ## 1 bit per row; packed bytes
    data*:       seq[byte]   ## encoded payload

  ColumnStore* = ref object
    name*:       string
    tableId*:    ObjId
    schema*:     TableSchema
    dataDir*:    string
    rowCount*:   int64
    chunks*:     seq[seq[ColChunk]]   ## chunks[colIdx][chunkIdx]

# ─── Null bitmap ──────────────────────────────────────────────────────────

proc isNull*(bitmap: seq[byte]; row: int): bool =
  let byteIdx = row shr 3
  let bitIdx  = row and 7
  if byteIdx >= bitmap.len: return false
  (bitmap[byteIdx] shr bitIdx) and 1 == 1

proc setNull*(bitmap: var seq[byte]; row: int) =
  let byteIdx = row shr 3
  while bitmap.len <= byteIdx: bitmap.add(0)
  bitmap[byteIdx] = bitmap[byteIdx] or (1'u8 shl (row and 7))

# ─── RLE encoding ─────────────────────────────────────────────────────────

proc rleEncode*(vals: seq[int64]): seq[byte] =
  ## [value:i64 LE][count:u32 LE] pairs
  if vals.len == 0: return
  var cur = vals[0]; var cnt = 1'u32
  for i in 1 ..< vals.len:
    if vals[i] == cur:
      inc cnt
    else:
      var buf: array[12, byte]
      lePut64(buf, 0, cast[uint64](cur))
      lePut32(buf, 8, cnt)
      result.add(buf)
      cur = vals[i]; cnt = 1
  var buf: array[12, byte]
  lePut64(buf, 0, cast[uint64](cur))
  lePut32(buf, 8, cnt)
  result.add(buf)

proc rleDecode*(data: seq[byte]; n: int): seq[int64] =
  result = newSeqOfCap[int64](n)
  var off = 0
  while off + 12 <= data.len and result.len < n:
    let v   = cast[int64](leGet64(data, off))
    let cnt = leGet32(data, off + 8)
    for _ in 0'u32 ..< cnt: result.add(v)
    off += 12

# ─── Delta encoding ───────────────────────────────────────────────────────

proc deltaEncode*(vals: seq[int64]): seq[byte] =
  ## First value stored as-is; subsequent as (v[i] - v[i-1])
  if vals.len == 0: return
  result = newSeq[byte](vals.len * 8)
  lePut64(result, 0, cast[uint64](vals[0]))
  for i in 1 ..< vals.len:
    lePut64(result, i * 8, cast[uint64](vals[i] - vals[i-1]))

proc deltaDecode*(data: seq[byte]; n: int): seq[int64] =
  result = newSeq[int64](n)
  if n == 0: return
  result[0] = cast[int64](leGet64(data, 0))
  for i in 1 ..< n:
    let delta = cast[int64](leGet64(data, i * 8))
    result[i] = result[i-1] + delta

# ─── Dictionary encoding ──────────────────────────────────────────────────

proc dictEncode*(strs: seq[string]): (seq[byte], seq[string]) =
  ## Returns (encoded indices as uint32 LE, dictionary)
  var dict: seq[string]
  var dictIdx: Table[string, int]
  var codes = newSeq[uint32](strs.len)
  for i, s in strs:
    if s notin dictIdx:
      dictIdx[s] = dict.len
      dict.add(s)
    codes[i] = uint32(dictIdx[s])
  var data = newSeq[byte](codes.len * 4)
  for i, c in codes: lePut32(data, i * 4, c)
  (data, dict)

proc dictDecode*(data: seq[byte]; dict: seq[string]; n: int): seq[string] =
  result = newSeq[string](n)
  for i in 0 ..< n:
    let code = int(leGet32(data, i * 4))
    if code < dict.len: result[i] = dict[code]

# ─── Chunk building from row data ─────────────────────────────────────────

proc buildChunk*(vals: seq[Value]; colKind: ColKind;
                 enc: Encoding = encNone): ColChunk =
  result.dtype    = colKind
  result.encoding = enc
  result.rowCount = vals.len
  result.nullBitmap = @[]

  case colKind
  of ckInt4, ckInt8:
    var ints = newSeq[int64](vals.len)
    for i, v in vals:
      if v.kind == ckNull: setNull(result.nullBitmap, i); ints[i] = 0
      else: ints[i] = v.toInt64()
    result.data = case enc
      of encRLE:   rleEncode(ints)
      of encDelta: deltaEncode(ints)
      else:
        var buf = newSeq[byte](ints.len * 8)
        for i, v in ints: lePut64(buf, i * 8, cast[uint64](v))
        buf

  of ckFloat8:
    var buf = newSeq[byte](vals.len * 8)
    for i, v in vals:
      if v.kind == ckNull: setNull(result.nullBitmap, i)
      else: lePut64(buf, i * 8, cast[uint64](v.toFloat()))
    result.data = buf

  of ckText:
    var strs = vals.mapIt(if it.kind == ckText: it.text else: "")
    for i, v in vals:
      if v.kind == ckNull: setNull(result.nullBitmap, i)
    if enc == encDict:
      let (data, _) = dictEncode(strs)
      result.data = data
    else:
      # Pascal-string packing: [u16 len][bytes...]
      for s in strs:
        var lb: array[2, byte]
        lePut16(lb, 0, uint16(s.len))
        result.data.add(lb)
        result.data.add(cast[seq[byte]](s))

  of ckBool:
    ## 1 bit per bool, packed
    var packed = newSeq[byte]((vals.len + 7) shr 3)
    for i, v in vals:
      if v.kind == ckNull: setNull(result.nullBitmap, i)
      elif v.kind == ckBool and v.b:
        packed[i shr 3] = packed[i shr 3] or (1'u8 shl (i and 7))
    result.data = packed

  else:
    result.data = @[]

proc readChunk*(chunk: ColChunk): seq[Value] =
  result = newSeq[Value](chunk.rowCount)
  let n = chunk.rowCount

  case chunk.dtype
  of ckInt4, ckInt8:
    var ints: seq[int64]
    case chunk.encoding
    of encRLE:   ints = rleDecode(chunk.data, n)
    of encDelta: ints = deltaDecode(chunk.data, n)
    else:
      ints = newSeq[int64](n)
      for i in 0 ..< n: ints[i] = cast[int64](leGet64(chunk.data, i * 8))
    for i in 0 ..< n:
      if isNull(chunk.nullBitmap, i): result[i] = nullVal()
      elif chunk.dtype == ckInt4:     result[i] = intVal(int32(ints[i]))
      else:                           result[i] = int8Val(ints[i])

  of ckFloat8:
    for i in 0 ..< n:
      if isNull(chunk.nullBitmap, i): result[i] = nullVal()
      else:
        result[i] = floatVal(cast[float64](leGet64(chunk.data, i * 8)))

  of ckText:
    var off = 0
    for i in 0 ..< n:
      if isNull(chunk.nullBitmap, i):
        result[i] = nullVal(); continue
      let l = int(leGet16(chunk.data, off)); off += 2
      let s = cast[string](chunk.data[off ..< off + l]); off += l
      result[i] = textVal(s)

  of ckBool:
    for i in 0 ..< n:
      if isNull(chunk.nullBitmap, i): result[i] = nullVal()
      else:
        let b = (chunk.data[i shr 3] shr (i and 7)) and 1
        result[i] = boolVal(b != 0)
  else: discard

# ─── ColumnStore operations ───────────────────────────────────────────────

proc newColumnStore*(schema: TableSchema; dataDir: string): ColumnStore =
  result = ColumnStore(
    name:     schema.name,
    tableId:  schema.tableId,
    schema:   schema,
    dataDir:  dataDir,
    chunks:   newSeq[seq[ColChunk]](schema.cols.len)
  )

proc appendRows*(cs: ColumnStore; rows: seq[Row]) =
  ## Bulk-append rows to the column store.
  if rows.len == 0: return
  for ci, col in cs.schema.cols:
    var vals = rows.mapIt(if ci < it.len: it[ci] else: nullVal())
    let enc = case col.kind
      of ckInt4, ckInt8: encDelta
      of ckText: encNone
      else: encNone
    cs.chunks[ci].add(buildChunk(vals, col.kind, enc))
  cs.rowCount += rows.len

proc scanColumn*(cs: ColumnStore; colIdx: int): seq[Value] =
  ## Read all values for one column (for ML feature extraction).
  result = newSeqOfCap[Value](cs.rowCount)
  for chunk in cs.chunks[colIdx]:
    result.add(readChunk(chunk))

proc scanColumnAsF32*(cs: ColumnStore; colIdx: int): seq[float32] =
  ## Fast path: extract numeric column as float32 slice for ML.
  result = newSeqOfCap[float32](cs.rowCount)
  for chunk in cs.chunks[colIdx]:
    for chunk in cs.chunks[colIdx]:
      case chunk.dtype
      of ckInt4, ckInt8:
        var ints: seq[int64]
        case chunk.encoding
        of encDelta: ints = deltaDecode(chunk.data, chunk.rowCount)
        else:
          ints = newSeq[int64](chunk.rowCount)
          for i in 0 ..< chunk.rowCount:
            ints[i] = cast[int64](leGet64(chunk.data, i * 8))
        for i, v in ints:
          result.add(if isNull(chunk.nullBitmap, i): 0.0'f32 else: float32(v))
      of ckFloat8:
        for i in 0 ..< chunk.rowCount:
          let v = cast[float64](leGet64(chunk.data, i * 8))
          result.add(if isNull(chunk.nullBitmap, i): 0.0'f32 else: float32(v))
      else: discard

proc columnStats*(cs: ColumnStore; colIdx: int): tuple[
    min, max, mean, stddev: float64; nullCount: int64] =
  ## Compute basic statistics for a numeric column.
  var vals = cs.scanColumnAsF32(colIdx)
  let n = vals.len
  if n == 0: return
  var sum = 0.0; var sumSq = 0.0
  var mn = float64(vals[0]); var mx = float64(vals[0])
  for v in vals:
    let fv = float64(v)
    sum   += fv; sumSq += fv * fv
    if fv < mn: mn = fv
    if fv > mx: mx = fv
  result.min   = mn
  result.max   = mx
  result.mean  = sum / float64(n)
  result.stddev = sqrt(sumSq / float64(n) - result.mean ^ 2)
