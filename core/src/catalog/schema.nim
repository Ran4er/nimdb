## schema.nim — Column types, table schema, and tuple serialisation
##
## Tuple wire format (variable-length):
##   For each column: [tag: uint8] [payload]
##   tag 0x00 = NULL
##   tag 0x01 = INT4   payload: 4 bytes LE int32
##   tag 0x02 = INT8   payload: 8 bytes LE int64
##   tag 0x03 = FLOAT8 payload: 8 bytes (IEEE 754 little-endian)
##   tag 0x04 = TEXT   payload: uint16 length + UTF-8 bytes
##   tag 0x05 = BOOL   payload: 1 byte (0/1)
##   tag 0x06 = BYTES  payload: uint16 length + raw bytes

import std/[strutils, math]
import ../storage/types

type
  ColKind* = enum
    ckNull    = 0x00'u8
    ckInt4    = 0x01'u8
    ckInt8    = 0x02'u8
    ckFloat8  = 0x03'u8
    ckText    = 0x04'u8
    ckBool    = 0x05'u8
    ckBytes   = 0x06'u8

  ColDef* = object
    name*:       string
    kind*:       ColKind
    notNull*:    bool
    primaryKey*: bool

  TableSchema* = object
    name*:    string
    tableId*: ObjId
    cols*:    seq[ColDef]

  # Runtime value
  Value* = object
    case kind*: ColKind
    of ckNull:   discard
    of ckInt4:   i4*:  int32
    of ckInt8:   i8*:  int64
    of ckFloat8: f8*:  float64
    of ckText:   text*: string
    of ckBool:   b*:   bool
    of ckBytes:  raw*: seq[byte]

  Row* = seq[Value]

# ─── Value helpers ────────────────────────────────────────────────────────

proc `$`*(v: Value): string =
  case v.kind
  of ckNull:   "NULL"
  of ckInt4:   $v.i4
  of ckInt8:   $v.i8
  of ckFloat8: $v.f8
  of ckText:   v.text
  of ckBool:   if v.b: "true" else: "false"
  of ckBytes:  "<bytes:" & $v.raw.len & ">"

proc `==`*(a, b: Value): bool =
  if a.kind != b.kind: return false
  case a.kind
  of ckNull:   true
  of ckInt4:   a.i4 == b.i4
  of ckInt8:   a.i8 == b.i8
  of ckFloat8: a.f8 == b.f8
  of ckText:   a.text == b.text
  of ckBool:   a.b == b.b
  of ckBytes:  a.raw == b.raw

proc `<`*(a, b: Value): bool =
  if a.kind != b.kind: return false
  case a.kind
  of ckNull:   false
  of ckInt4:   a.i4 < b.i4
  of ckInt8:   a.i8 < b.i8
  of ckFloat8: a.f8 < b.f8
  of ckText:   a.text < b.text
  of ckBool:   (not a.b) and b.b
  of ckBytes:  false

proc `<=`*(a, b: Value): bool = a == b or a < b

proc nullVal*(): Value = Value(kind: ckNull)
proc intVal*(x: int32): Value = Value(kind: ckInt4, i4: x)
proc int8Val*(x: int64): Value = Value(kind: ckInt8, i8: x)
proc floatVal*(x: float64): Value = Value(kind: ckFloat8, f8: x)
proc textVal*(x: string): Value = Value(kind: ckText, text: x)
proc boolVal*(x: bool): Value = Value(kind: ckBool, b: x)

proc toFloat*(v: Value): float64 =
  case v.kind
  of ckInt4:   float64(v.i4)
  of ckInt8:   float64(v.i8)
  of ckFloat8: v.f8
  else: raise newException(ValueError, "Not numeric: " & $v.kind)

proc toInt64*(v: Value): int64 =
  case v.kind
  of ckInt4:   int64(v.i4)
  of ckInt8:   v.i8
  of ckFloat8: int64(v.f8)
  else: raise newException(ValueError, "Not integer: " & $v.kind)

proc isNumeric*(v: Value): bool =
  v.kind in {ckInt4, ckInt8, ckFloat8}

# ─── Tuple encode / decode ────────────────────────────────────────────────

proc encodeTuple*(row: Row): seq[byte] =
  result = newSeqOfCap[byte](row.len * 8)
  for v in row:
    result.add(uint8(v.kind))
    case v.kind
    of ckNull: discard
    of ckInt4:
      var buf: array[4, byte]
      lePut32(buf, 0, cast[uint32](v.i4))
      result.add(buf)
    of ckInt8:
      var buf: array[8, byte]
      lePut64(buf, 0, cast[uint64](v.i8))
      result.add(buf)
    of ckFloat8:
      var buf: array[8, byte]
      let bits = cast[uint64](v.f8)
      lePut64(buf, 0, bits)
      result.add(buf)
    of ckText:
      let bytes = cast[seq[byte]](v.text)
      var lenBuf: array[2, byte]
      lePut16(lenBuf, 0, uint16(bytes.len))
      result.add(lenBuf)
      result.add(bytes)
    of ckBool:
      result.add(if v.b: 1'u8 else: 0'u8)
    of ckBytes:
      var lenBuf: array[2, byte]
      lePut16(lenBuf, 0, uint16(v.raw.len))
      result.add(lenBuf)
      result.add(v.raw)

proc decodeTuple*(data: seq[byte]; ncols: int): Row =
  result = newSeq[Value](ncols)
  var pos = 0
  for i in 0 ..< ncols:
    if pos >= data.len: break
    let tag = ColKind(data[pos]); inc pos
    case tag
    of ckNull:
      result[i] = nullVal()
    of ckInt4:
      let v = cast[int32](leGet32(data, pos)); pos += 4
      result[i] = intVal(v)
    of ckInt8:
      let v = cast[int64](leGet64(data, pos)); pos += 8
      result[i] = int8Val(v)
    of ckFloat8:
      let bits = leGet64(data, pos); pos += 8
      result[i] = floatVal(cast[float64](bits))
    of ckText:
      let len = int(leGet16(data, pos)); pos += 2
      result[i] = textVal(cast[string](data[pos ..< pos + len]))
      pos += len
    of ckBool:
      result[i] = boolVal(data[pos] != 0); inc pos
    of ckBytes:
      let len = int(leGet16(data, pos)); pos += 2
      result[i] = Value(kind: ckBytes, raw: data[pos ..< pos + len])
      pos += len

proc parseColKind*(s: string): ColKind =
  case s.toUpperAscii()
  of "INT", "INT4", "INTEGER":   ckInt4
  of "BIGINT", "INT8":           ckInt8
  of "FLOAT", "FLOAT8", "REAL":  ckFloat8
  of "TEXT", "VARCHAR", "STRING": ckText
  of "BOOL", "BOOLEAN":          ckBool
  of "BYTES", "BYTEA":           ckBytes
  else: raise newException(CatalogError, "Unknown type: " & s)

proc colKindName*(k: ColKind): string =
  case k
  of ckNull:   "NULL"
  of ckInt4:   "INT4"
  of ckInt8:   "INT8"
  of ckFloat8: "FLOAT8"
  of ckText:   "TEXT"
  of ckBool:   "BOOL"
  of ckBytes:  "BYTES"
