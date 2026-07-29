## quantize.nim — Vector quantisation for fast ANN search
##
## Two schemes:
##
##  1. Scalar INT8 quantisation
##     Each float32 → int8 via per-vector affine mapping.
##     32× smaller memory, ~10% recall loss, 4–8× faster distance.
##
##  2. Product Quantisation (PQ)  — Jégou et al. 2011
##     Split D-dim vector into M subspaces of Ds = D/M dims.
##     Train K=256 centroids per subspace (k-means).
##     Encode as M bytes → D/8 compression ratio.
##     Distance: lookup table [M × 256] → sum of table values.
##     Typical: D=128, M=8, Ds=16 → 16 bytes instead of 512 bytes.
##     Recall@10 ≈ 95 % with 32× compression.

import std/[math, random, algorithm, sequtils]
import ../storage/types
import simd_ops

# ═══════════════════════════════════════════════════════════════
# Scalar INT8 quantisation
# ═══════════════════════════════════════════════════════════════

type
  INT8Vec* = object
    data*:  seq[int8]    ## quantised values
    scale*: float32      ## dequant: x_f32 = x_i8 * scale + zero
    zero*:  float32

proc quantiseINT8*(v: seq[float32]): INT8Vec =
  ## Asymmetric per-vector INT8 quantisation.
  var mn = v[0]; var mx = v[0]
  for x in v:
    if x < mn: mn = x
    if x > mx: mx = x
  let r = mx - mn
  result.scale = if r < 1e-10'f32: 1.0'f32 else: r / 255.0'f32
  result.zero  = mn
  result.data  = newSeq[int8](v.len)
  for i, x in v:
    let q = clamp(int((x - mn) / result.scale + 0.5), 0, 255)
    result.data[i] = cast[int8](q)

proc dequantise*(q: INT8Vec): seq[float32] =
  result = newSeq[float32](q.data.len)
  for i, x in q.data:
    result[i] = float32(cast[uint8](x)) * q.scale + q.zero

proc dotINT8*(a, b: INT8Vec): float32 =
  ## Approximate dot product via integer arithmetic.
  var acc = 0'i32
  for i in 0 ..< a.data.len:
    acc += int32(a.data[i]) * int32(b.data[i])
  float32(acc) * a.scale * b.scale

proc l2distINT8*(a, b: INT8Vec): float32 =
  var acc = 0'i32
  for i in 0 ..< a.data.len:
    let d = int32(a.data[i]) - int32(b.data[i])
    acc += d * d
  sqrt(float32(acc)) * (a.scale + b.scale) * 0.5'f32

# ═══════════════════════════════════════════════════════════════
# Product Quantisation
# ═══════════════════════════════════════════════════════════════

const PQ_K* = 256    ## centroids per subspace (fits in uint8)

type
  PQCodebook* = ref object
    M*:   int                        ## number of subspaces
    Ds*:  int                        ## subspace dimension  D / M
    D*:   int                        ## full dimension
    ## centroids[m][k] = Ds floats
    centroids*: seq[seq[seq[float32]]]

  PQCode* = object
    codes*: seq[uint8]   ## M bytes, one per subspace

  PQIndex* = ref object
    book*:    PQCodebook
    codes*:   seq[PQCode]   ## one per stored vector
    extIds*:  seq[int64]    ## parallel to codes

# ─── Centroid distance helpers ────────────────────────────────────────────

proc subDist(a, b: seq[float32]): float32 =
  ## Squared L2 distance between two subspace vectors.
  var s = 0.0'f32
  for i in 0 ..< a.len:
    let d = a[i] - b[i]; s += d * d
  s

# ─── K-Means for one subspace ─────────────────────────────────────────────

proc kmeansSubspace(data: seq[seq[float32]]; k: int;
                    iters = 25; seed = 42): seq[seq[float32]] =
  ## Returns k centroids for subspace data (each row = one subspace vector).
  let n  = data.len
  let ds = data[0].len
  var rng = initRand(seed)

  ## Initialise with random sample
  var centres = newSeq[seq[float32]](k)
  var used    = newSeq[bool](n)
  for j in 0 ..< k:
    var idx = rng.rand(n - 1)
    while used[idx]: idx = (idx + 1) mod n
    used[idx] = true
    centres[j] = data[idx]

  var assign = newSeq[int](n)
  var counts = newSeq[int](k)
  var sums   = newSeq[seq[float32]](k)

  for _ in 0 ..< iters:
    for j in 0 ..< k: sums[j] = newSeq[float32](ds)
    for j in 0 ..< k: counts[j] = 0

    ## Assign
    for i in 0 ..< n:
      var best = 0; var bestD = subDist(data[i], centres[0])
      for j in 1 ..< k:
        let d = subDist(data[i], centres[j])
        if d < bestD: best = j; bestD = d
      assign[i] = best
      inc counts[best]
      for d in 0 ..< ds: sums[best][d] += data[i][d]

    ## Update
    for j in 0 ..< k:
      if counts[j] > 0:
        for d in 0 ..< ds: centres[j][d] = sums[j][d] / float32(counts[j])

  centres

# ─── PQ codebook training ─────────────────────────────────────────────────

proc trainPQ*(vecs: seq[seq[float32]]; M: int; iters = 25): PQCodebook =
  ## Train a PQ codebook from a set of float32 vectors.
  let D  = vecs[0].len
  assert D mod M == 0, "D must be divisible by M"
  let Ds = D div M
  result = PQCodebook(M: M, Ds: Ds, D: D,
                      centroids: newSeq[seq[seq[float32]]](M))

  for m in 0 ..< M:
    ## Extract subspace m from all vectors
    var sub = newSeq[seq[float32]](vecs.len)
    for i, v in vecs:
      sub[i] = v[m * Ds ..< (m + 1) * Ds]
    let k = min(PQ_K, vecs.len)
    result.centroids[m] = kmeansSubspace(sub, k, iters)

# ─── PQ encode / decode ───────────────────────────────────────────────────

proc encode*(book: PQCodebook; v: seq[float32]): PQCode =
  result.codes = newSeq[uint8](book.M)
  for m in 0 ..< book.M:
    let sub = v[m * book.Ds ..< (m + 1) * book.Ds]
    var best = 0'u8; var bestD = subDist(sub, book.centroids[m][0])
    for k in 1 ..< book.centroids[m].len:
      let d = subDist(sub, book.centroids[m][k])
      if d < bestD: best = uint8(k); bestD = d
    result.codes[m] = best

proc decode*(book: PQCodebook; code: PQCode): seq[float32] =
  result = newSeq[float32](book.D)
  for m in 0 ..< book.M:
    let c = int(code.codes[m])
    let cen = book.centroids[m][c]
    for d in 0 ..< book.Ds:
      result[m * book.Ds + d] = cen[d]

# ─── Asymmetric Distance Computation (ADC) ────────────────────────────────
##
## Key insight: precompute distance from query to every centroid
## in each subspace → lookup table [M × K].
## Then each stored code's distance = sum of M table lookups.
## O(M × K × Ds) for table + O(M) per vector = very fast scan.

type ADCTable* = seq[seq[float32]]   ## [M][K]

proc buildADCTable*(book: PQCodebook; query: seq[float32]): ADCTable =
  result = newSeq[seq[float32]](book.M)
  for m in 0 ..< book.M:
    let qSub = query[m * book.Ds ..< (m + 1) * book.Ds]
    result[m] = newSeq[float32](book.centroids[m].len)
    for k in 0 ..< book.centroids[m].len:
      result[m][k] = subDist(qSub, book.centroids[m][k])

proc adcDist*(table: ADCTable; code: PQCode): float32 {.inline.} =
  ## Approximate distance from query (table) to stored code.
  result = 0.0'f32
  for m in 0 ..< table.len:
    result += table[m][int(code.codes[m])]
  result = sqrt(result)

# ─── PQ Index operations ──────────────────────────────────────────────────

proc newPQIndex*(book: PQCodebook): PQIndex =
  PQIndex(book: book)

proc insert*(idx: PQIndex; v: seq[float32]; extId: int64) =
  idx.codes.add(idx.book.encode(v))
  idx.extIds.add(extId)

proc knnSearch*(idx: PQIndex; query: seq[float32];
                k: int): seq[(int64, float32)] =
  ## Approximate KNN via ADC. Returns (extId, dist) pairs.
  let table = buildADCTable(idx.book, query)
  var dists = newSeq[(float32, int)](idx.codes.len)
  for i, code in idx.codes:
    dists[i] = (adcDist(table, code), i)
  dists.sort(proc(a, b: (float32, int)): int =
    if a[0] < b[0]: -1 elif a[0] > b[0]: 1 else: 0)
  for i in 0 ..< min(k, dists.len):
    result.add((idx.extIds[dists[i][1]], dists[i][0]))

proc stats*(idx: PQIndex): string =
  let bytes = idx.codes.len * idx.book.M
  let full  = idx.codes.len * idx.book.D * 4
  "PQIndex: n=" & $idx.codes.len &
  " M=" & $idx.book.M &
  " D=" & $idx.book.D &
  " compression=" & $int(float(full) / float(bytes).max(1)) & "×" &
  " bytes=" & $bytes
