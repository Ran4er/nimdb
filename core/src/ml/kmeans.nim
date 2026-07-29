## kmeans.nim — K-Means and Mini-Batch K-Means clustering
##
## Value over sklearn: runs IN-DB during a columnar scan — no export.
## Mini-batch variant converges in O(k · b) per batch, fits huge datasets.
##
## Extra: elbow method for automatic k selection,
##        silhouette score, and cluster assignment as a SQL-callable function.

import std/[math, random, sequtils, algorithm, strformat]
import simd_ops

type
  KMeansModel* = ref object
    k*:           int
    dim*:         int
    centroids*:   seq[seq[float32]]   ## k × dim
    inertia*:     float32             ## sum of squared distances to nearest centroid
    nIter*:       int
    converged*:   bool
    counts*:      seq[int]            ## samples per cluster

  MiniBatchKMeans* = ref object
    km*:          KMeansModel
    batchSize*:   int
    bufX*:        seq[seq[float32]]   ## mini-batch buffer
    counts*:      seq[float32]        ## EMA centroid update counts

# ─── Init helpers ─────────────────────────────────────────────────────────

proc initCentroids(X: seq[seq[float32]]; k: int; seed: int): seq[seq[float32]] =
  ## K-Means++ initialisation: first centroid random, rest proportional to D².
  var rng = initRand(seed)
  result  = @[X[rng.rand(X.len - 1)]]
  while result.len < k:
    var dists = newSeq[float32](X.len)
    var total = 0.0'f32
    for i, x in X:
      var best = Inf.float32
      for c in result:
        let d = l2distF32Seq(x, c)
        if d < best: best = d
      dists[i] = best * best
      total   += dists[i]
    ## Sample proportional to D²
    var r = float32(rng.rand(1.0)) * total
    var chosen = X.len - 1
    for i in 0 ..< X.len:
      r -= dists[i]
      if r <= 0.0'f32: chosen = i; break
    result.add(X[chosen])

proc newKMeans*(k: int): KMeansModel =
  KMeansModel(k: k, centroids: @[], counts: newSeq[int](k))

proc newMiniBatchKMeans*(k: int; batchSize = 1024): MiniBatchKMeans =
  MiniBatchKMeans(km: newKMeans(k), batchSize: batchSize,
                  counts: newSeq[float32](k))

# ─── Assignment ───────────────────────────────────────────────────────────

proc assign*(m: KMeansModel; x: seq[float32]): int =
  ## Return cluster index for a single vector.
  var best = 0; var bestD = l2distF32Seq(x, m.centroids[0])
  for j in 1 ..< m.k:
    let d = l2distF32Seq(x, m.centroids[j])
    if d < bestD: best = j; bestD = d
  best

proc assignAll*(m: KMeansModel; X: seq[seq[float32]]): seq[int] =
  result = newSeq[int](X.len)
  for i, x in X: result[i] = m.assign(x)

# ─── Full K-Means ─────────────────────────────────────────────────────────

proc fit*(m: KMeansModel; X: seq[seq[float32]];
          maxIter = 300; tol = 1e-4'f32; seed = 42) =
  let n   = X.len
  let dim = X[0].len
  m.dim   = dim
  m.centroids = initCentroids(X, m.k, seed)

  var assign  = newSeq[int](n)
  var prevInertia = Inf.float32

  for iter in 0 ..< maxIter:
    ## E-step: assign
    m.inertia = 0.0'f32
    for i in 0 ..< n: assign[i] = m.assign(X[i])
    for i in 0 ..< n:
      m.inertia += l2distF32Seq(X[i], m.centroids[assign[i]]) ^ 2

    ## M-step: update centroids
    var sums   = newSeq[seq[float32]](m.k)
    for j in 0 ..< m.k:
      sums[j] = newSeq[float32](dim)
      m.counts[j] = 0
    for i in 0 ..< n:
      let c = assign[i]
      inc m.counts[c]
      for d in 0 ..< dim: sums[c][d] += X[i][d]
    for j in 0 ..< m.k:
      if m.counts[j] > 0:
        for d in 0 ..< dim:
          m.centroids[j][d] = sums[j][d] / float32(m.counts[j])

    m.nIter = iter + 1
    if abs(m.inertia - prevInertia) < tol * prevInertia:
      m.converged = true; break
    prevInertia = m.inertia

# ─── Mini-Batch K-Means (streaming / online) ──────────────────────────────

proc initMiniBatch*(mb: MiniBatchKMeans; sample: seq[seq[float32]]; seed = 42) =
  ## Must be called with a representative sample before partialFit.
  mb.km.dim = sample[0].len
  mb.km.centroids = initCentroids(sample, mb.km.k, seed)
  mb.counts = newSeq[float32](mb.km.k)

proc partialFit*(mb: MiniBatchKMeans; x: seq[float32]) =
  ## Update model with one new vector (call from heap scan).
  mb.bufX.add(x)
  if mb.bufX.len < mb.batchSize: return

  ## Process batch
  let dim = mb.km.dim
  var sums = newSeq[seq[float32]](mb.km.k)
  var hits = newSeq[int](mb.km.k)
  for j in 0 ..< mb.km.k: sums[j] = newSeq[float32](dim)

  for xi in mb.bufX:
    let c = mb.km.assign(xi)
    inc hits[c]
    for d in 0 ..< dim: sums[c][d] += xi[d]

  ## EMA centroid update (learning rate = 1 / count)
  for j in 0 ..< mb.km.k:
    if hits[j] == 0: continue
    mb.counts[j] += float32(hits[j])
    let alpha = float32(hits[j]) / mb.counts[j]
    for d in 0 ..< dim:
      let centd = sums[j][d] / float32(hits[j])
      mb.km.centroids[j][d] = (1.0'f32 - alpha) * mb.km.centroids[j][d] +
                               alpha * centd
  mb.bufX.setLen(0)

proc flush*(mb: MiniBatchKMeans) =
  ## Force-process remaining buffer.
  if mb.bufX.len == 0: return
  let orig = mb.batchSize
  mb.batchSize = 1   ## process one-by-one
  while mb.bufX.len > 0: mb.partialFit(mb.bufX[^1]); mb.bufX.setLen(mb.bufX.len - 1)
  mb.batchSize = orig

# ─── Elbow method ─────────────────────────────────────────────────────────

proc elbowScores*(X: seq[seq[float32]]; kMin = 2; kMax = 10;
                  seed = 42): seq[(int, float32)] =
  ## Fit K-Means for each k and return (k, inertia) pairs.
  ## The "elbow" is where inertia stops dropping sharply.
  for k in kMin .. kMax:
    var m = newKMeans(k)
    m.fit(X, seed = seed)
    result.add((k, m.inertia))

proc suggestK*(scores: seq[(int, float32)]): int =
  ## Return k at the elbow point (max second derivative of inertia).
  if scores.len < 3: return scores[0][0]
  var maxCurv = -Inf.float64
  var best    = scores[1][0]
  for i in 1 ..< scores.len - 1:
    let prev = float64(scores[i-1][1])
    let curr = float64(scores[i][1])
    let next = float64(scores[i+1][1])
    let curv = prev - 2.0 * curr + next
    if curv > maxCurv: maxCurv = curv; best = scores[i][0]
  best

# ─── Silhouette score ─────────────────────────────────────────────────────

proc silhouette*(m: KMeansModel; X: seq[seq[float32]]): float32 =
  ## Average silhouette coefficient ∈ [-1, 1]. Higher = better.
  ## O(n² · k) — only feasible for n < 10k.
  let labels = m.assignAll(X)
  var total = 0.0'f32
  for i in 0 ..< X.len:
    let ci = labels[i]
    var a = 0.0'f32; var aCount = 0
    var b = Inf.float32
    for j in 0 ..< X.len:
      if i == j: continue
      let d = l2distF32Seq(X[i], X[j])
      if labels[j] == ci: a += d; inc aCount
      else:
        let cj = labels[j]
        discard cj   ## just use b below
    if aCount > 0: a /= float32(aCount)
    ## nearest-cluster distance
    for j in 0 ..< m.k:
      if j == ci: continue
      let d = l2distF32Seq(X[i], m.centroids[j])
      if d < b: b = d
    let s = if max(a, b) < 1e-10'f32: 0.0'f32 else: (b - a) / max(a, b)
    total += s
  total / float32(X.len)

proc describe*(m: KMeansModel): string =
  &"KMeans k={m.k} dim={m.dim} nIter={m.nIter} " &
  &"converged={m.converged} inertia={m.inertia:.4f}\n" &
  &"  cluster sizes: {m.counts}"
