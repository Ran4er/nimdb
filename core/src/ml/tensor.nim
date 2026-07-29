## tensor.nim — Dense tensor / vector types optimised for ML storage
##
## Supported shapes:
##   Rank-1 : Vector[N]       → float32 array (embeddings, features)
##   Rank-2 : Matrix[R,C]     → row-major float32 matrix
##   Rank-N : Tensor[shape]   → N-dimensional float32 blob
##
## Wire encoding (for heap storage):
##   [ndim: uint8][shape: ndim × uint32 LE][data: prod(shape) × float32 LE]

import std/[math, sequtils, strformat, algorithm]
import ../storage/types

type
  DType* = enum
    dtF32, dtF64, dtI32, dtI64, dtBool

  Shape* = seq[int]

  Tensor* = ref object
    dtype*: DType
    shape*: Shape
    data*:  seq[byte]   ## raw little-endian bytes

  ## Convenience alias most ML code will use
  Vec* = Tensor

# ─── Constructors ─────────────────────────────────────────────────────────

proc elemBytes*(dt: DType): int =
  case dt
  of dtF32, dtI32: 4
  of dtF64, dtI64: 8
  of dtBool: 1

proc numel*(shape: Shape): int =
  if shape.len == 0: return 0
  result = 1
  for s in shape: result *= s

proc newTensor*(dtype: DType; shape: Shape): Tensor =
  Tensor(dtype: dtype, shape: shape,
         data: newSeq[byte](numel(shape) * elemBytes(dtype)))

proc vectorF32*(vals: openArray[float32]): Tensor =
  result = newTensor(dtF32, @[vals.len])
  for i, v in vals:
    let bits = cast[uint32](v)
    lePut32(result.data, i * 4, bits)

proc vectorF64*(vals: openArray[float64]): Tensor =
  result = newTensor(dtF64, @[vals.len])
  for i, v in vals:
    let bits = cast[uint64](v)
    lePut64(result.data, i * 8, bits)

proc zeroTensor*(dtype: DType; shape: Shape): Tensor =
  newTensor(dtype, shape)  ## zeroed by default (seq init)

proc randTensor*(dtype: DType; shape: Shape; seed = 42): Tensor =
  result = newTensor(dtype, shape)
  var rng = uint64(seed)
  proc next(): uint64 =
    rng = rng xor (rng shl 13)
    rng = rng xor (rng shr 7)
    rng = rng xor (rng shl 17)
    rng
  let n = numel(shape)
  case dtype
  of dtF32:
    for i in 0 ..< n:
      let v = float32(int64(next() mod 10000) - 5000) / 5000.0'f32
      lePut32(result.data, i * 4, cast[uint32](v))
  of dtF64:
    for i in 0 ..< n:
      let v = float64(int64(next() mod 1000000) - 500000) / 500000.0
      lePut64(result.data, i * 8, cast[uint64](v))
  else: discard

# ─── Element access ───────────────────────────────────────────────────────

proc getF32*(t: Tensor; idx: int): float32 =
  cast[float32](leGet32(t.data, idx * 4))

proc setF32*(t: Tensor; idx: int; v: float32) =
  lePut32(t.data, idx * 4, cast[uint32](v))

proc getF64*(t: Tensor; idx: int): float64 =
  cast[float64](leGet64(t.data, idx * 8))

proc setF64*(t: Tensor; idx: int; v: float64) =
  lePut64(t.data, idx * 8, cast[uint64](v))

proc len*(t: Tensor): int = numel(t.shape)

proc `[]`*(t: Tensor; i: int): float32 = t.getF32(i)
proc `[]=`*(t: Tensor; i: int; v: float32) = t.setF32(i, v)

# ─── Serialisation ────────────────────────────────────────────────────────

proc encodeTensor*(t: Tensor): seq[byte] =
  ## Wire format: [dtype:u8][ndim:u8][shape:ndim×u32][data:...]
  let nd = t.shape.len
  result = newSeqOfCap[byte](2 + nd * 4 + t.data.len)
  result.add(uint8(t.dtype))
  result.add(uint8(nd))
  for s in t.shape:
    var buf: array[4, byte]
    lePut32(buf, 0, uint32(s))
    result.add(buf)
  result.add(t.data)

proc decodeTensor*(raw: seq[byte]): Tensor =
  if raw.len < 2: raise newException(StorageError, "Corrupt tensor")
  let dtype = DType(raw[0])
  let nd    = int(raw[1])
  var shape = newSeq[int](nd)
  var off   = 2
  for i in 0 ..< nd:
    shape[i] = int(leGet32(raw, off)); off += 4
  let dataLen = numel(shape) * elemBytes(dtype)
  Tensor(dtype: dtype, shape: shape, data: raw[off ..< off + dataLen])

# ─── Vector operations ────────────────────────────────────────────────────

proc dot*(a, b: Tensor): float32 =
  ## Dot product (requires same shape, dtF32).
  assert a.len == b.len
  result = 0.0'f32
  for i in 0 ..< a.len:
    result += a.getF32(i) * b.getF32(i)

proc l2norm*(a: Tensor): float32 =
  result = 0.0'f32
  for i in 0 ..< a.len: result += a.getF32(i) ^ 2
  result = sqrt(result)

proc cosineSimF32*(a, b: Tensor): float32 =
  let na = a.l2norm(); let nb = b.l2norm()
  if na == 0.0'f32 or nb == 0.0'f32: return 0.0'f32
  dot(a, b) / (na * nb)

proc l2distF32*(a, b: Tensor): float32 =
  assert a.len == b.len
  result = 0.0'f32
  for i in 0 ..< a.len:
    let d = a.getF32(i) - b.getF32(i)
    result += d * d
  result = sqrt(result)

proc add*(a, b: Tensor): Tensor =
  assert a.shape == b.shape
  result = newTensor(a.dtype, a.shape)
  for i in 0 ..< a.len:
    result.setF32(i, a.getF32(i) + b.getF32(i))

proc scale*(a: Tensor; s: float32): Tensor =
  result = newTensor(a.dtype, a.shape)
  for i in 0 ..< a.len:
    result.setF32(i, a.getF32(i) * s)

proc normalize*(a: Tensor): Tensor =
  let n = a.l2norm()
  if n == 0.0'f32: return a
  a.scale(1.0'f32 / n)

proc softmax*(a: Tensor): Tensor =
  result = newTensor(a.dtype, a.shape)
  var maxv = a.getF32(0)
  for i in 1 ..< a.len:
    if a.getF32(i) > maxv: maxv = a.getF32(i)
  var sum = 0.0'f32
  for i in 0 ..< a.len:
    let e = exp(a.getF32(i) - maxv)
    result.setF32(i, e)
    sum += e
  for i in 0 ..< a.len:
    result.setF32(i, result.getF32(i) / sum)

proc `$`*(t: Tensor): string =
  let n = min(t.len, 8)
  result = "Tensor" & $t.shape & "["
  for i in 0 ..< n:
    if i > 0: result.add(", ")
    result.add(&"{t.getF32(i):.4f}")
  if t.len > n: result.add(", ...")
  result.add("]")
