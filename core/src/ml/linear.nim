## linear.nim — In-database linear and logistic regression
##
## What makes this valuable vs exporting to sklearn/PyTorch:
##   • Training happens in ONE PASS over data during heap scan —
##     no materialising the full dataset into RAM.
##   • Online / incremental: new rows → call partialFit(), model updates.
##   • Model stored as typed blob in the catalog; versioned.
##   • PREDICT() available as a SQL function in the executor.
##   • Regularisation: L1 (Lasso) or L2 (Ridge).
##
## Algorithms:
##   LinearRegression  — OLS via mini-batch SGD
##   LogisticRegression — binary cross-entropy + sigmoid, mini-batch SGD
##   Both support: fit(), partialFit(), predict(), score(), toBytes/fromBytes

import std/[math, random, sequtils, strformat]
import simd_ops

type
  RegKind* = enum rkNone, rkL1, rkL2

  LinearModel* = ref object
    weights*:   seq[float32]   ## including bias at index 0
    nFeatures*: int
    lr*:        float32        ## learning rate
    reg*:       RegKind
    regLambda*: float32
    nSeen*:     int64          ## total training examples seen
    trainLoss*: float32        ## running exponential moving average

  LogisticModel* = ref object
    weights*:   seq[float32]
    nFeatures*: int
    lr*:        float32
    reg*:       RegKind
    regLambda*: float32
    nSeen*:     int64
    trainLoss*: float32
    threshold*: float32        ## decision boundary (default 0.5)

# ─── Init ─────────────────────────────────────────────────────────────────

proc newLinearModel*(nFeatures: int; lr = 0.01'f32;
                     reg = rkL2; lam = 0.0001'f32): LinearModel =
  var rng = initRand(42)
  let w = (nFeatures + 1).newSeq[float32]()
  result = LinearModel(weights: w, nFeatures: nFeatures,
                       lr: lr, reg: reg, regLambda: lam, threshold: 0.0'f32)
  ## He init: std = sqrt(2 / nFeatures)
  let std = sqrt(2.0'f32 / float32(nFeatures))
  for i in 1 .. nFeatures:
    result.weights[i] = float32(rng.gauss(0.0, float64(std)))

proc newLogisticModel*(nFeatures: int; lr = 0.01'f32;
                       reg = rkL2; lam = 0.0001'f32): LogisticModel =
  var rng = initRand(42)
  let w = (nFeatures + 1).newSeq[float32]()
  result = LogisticModel(weights: w, nFeatures: nFeatures,
                         lr: lr, reg: reg, regLambda: lam, threshold: 0.5'f32)
  let std = sqrt(2.0'f32 / float32(nFeatures))
  for i in 1 .. nFeatures:
    result.weights[i] = float32(rng.gauss(0.0, float64(std)))

# ─── Forward pass ─────────────────────────────────────────────────────────

proc linearForward*(m: LinearModel; x: seq[float32]): float32 {.inline.} =
  ## y_hat = w0 + w1*x1 + ... + wn*xn
  result = m.weights[0]   ## bias
  if x.len > 0:
    result += dotF32Seq(m.weights.toOpenArray(1, m.nFeatures),
                        x.toOpenArray(0, x.len - 1))

proc logisticForward*(m: LogisticModel; x: seq[float32]): float32 {.inline.} =
  var z = m.weights[0]
  if x.len > 0:
    z += dotF32Seq(m.weights.toOpenArray(1, m.nFeatures),
                   x.toOpenArray(0, x.len - 1))
  1.0'f32 / (1.0'f32 + exp(-z))

# ─── Regularisation gradient ──────────────────────────────────────────────

proc regGrad(w: float32; reg: RegKind; lam: float32): float32 {.inline.} =
  case reg
  of rkNone: 0.0'f32
  of rkL2:   lam * w
  of rkL1:   lam * (if w > 0.0'f32: 1.0'f32 elif w < 0.0'f32: -1.0'f32 else: 0.0'f32)

# ─── SGD update helpers ───────────────────────────────────────────────────

proc linearUpdate(m: LinearModel; x: seq[float32]; y: float32) =
  let yhat  = linearForward(m, x)
  let err   = yhat - y     ## MSE gradient
  ## bias
  m.weights[0] -= m.lr * err
  ## features
  for i in 0 ..< x.len:
    m.weights[i + 1] -= m.lr * (err * x[i] + regGrad(m.weights[i + 1], m.reg, m.regLambda))
  let loss = err * err
  m.trainLoss = 0.99'f32 * m.trainLoss + 0.01'f32 * loss
  inc m.nSeen

proc logisticUpdate(m: LogisticModel; x: seq[float32]; y: float32) =
  let p    = logisticForward(m, x)
  let err  = p - y          ## BCE gradient = (p - y)
  m.weights[0] -= m.lr * err
  for i in 0 ..< x.len:
    m.weights[i + 1] -= m.lr * (err * x[i] + regGrad(m.weights[i + 1], m.reg, m.regLambda))
  let loss = -(y * ln(p + 1e-10'f32) + (1.0'f32 - y) * ln(1.0'f32 - p + 1e-10'f32))
  m.trainLoss = 0.99'f32 * m.trainLoss + 0.01'f32 * loss
  inc m.nSeen

# ─── Public API ───────────────────────────────────────────────────────────

proc partialFit*(m: LinearModel; x: seq[float32]; y: float32) =
  ## Online update with one example. Call from heap scan callback.
  m.linearUpdate(x, y)

proc partialFit*(m: LogisticModel; x: seq[float32]; y: float32) =
  m.logisticUpdate(x, y)

proc fit*(m: LinearModel; X: seq[seq[float32]]; y: seq[float32];
          epochs = 3; batchSize = 64; shuffle = true) =
  ## Mini-batch SGD over a materialised dataset.
  var indices = toSeq(0 ..< X.len)
  var rng = initRand(42)
  for _ in 0 ..< epochs:
    if shuffle: rng.shuffle(indices)
    var b = 0
    while b < X.len:
      let end_ = min(b + batchSize, X.len)
      for i in b ..< end_:
        m.linearUpdate(X[indices[i]], y[indices[i]])
      b = end_

proc fit*(m: LogisticModel; X: seq[seq[float32]]; y: seq[float32];
          epochs = 5; batchSize = 64; shuffle = true) =
  var indices = toSeq(0 ..< X.len)
  var rng = initRand(42)
  for _ in 0 ..< epochs:
    if shuffle: rng.shuffle(indices)
    var b = 0
    while b < X.len:
      let end_ = min(b + batchSize, X.len)
      for i in b ..< end_:
        m.logisticUpdate(X[indices[i]], y[indices[i]])
      b = end_

proc predict*(m: LinearModel; x: seq[float32]): float32 =
  linearForward(m, x)

proc predict*(m: LogisticModel; x: seq[float32]): float32 =
  ## Returns probability P(y=1 | x).
  logisticForward(m, x)

proc predictClass*(m: LogisticModel; x: seq[float32]): int =
  if logisticForward(m, x) >= m.threshold: 1 else: 0

proc score*(m: LinearModel; X: seq[seq[float32]]; y: seq[float32]): float32 =
  ## R² score.
  var ssRes = 0.0'f32; var ssTot = 0.0'f32
  let mean = y.foldl(a + b, 0.0'f32) / float32(y.len)
  for i, xi in X:
    let r = predict(m, xi) - y[i]
    ssRes += r * r
    let t = y[i] - mean; ssTot += t * t
  if ssTot < 1e-10'f32: return 1.0'f32
  1.0'f32 - ssRes / ssTot

proc score*(m: LogisticModel; X: seq[seq[float32]]; y: seq[float32]): float32 =
  ## Accuracy score.
  var correct = 0
  for i, xi in X:
    if predictClass(m, xi) == int(y[i]): inc correct
  float32(correct) / float32(X.len)

proc describe*(m: LinearModel): string =
  &"LinearModel nFeatures={m.nFeatures} nSeen={m.nSeen} " &
  &"lr={m.lr} reg={m.reg} trainLoss={m.trainLoss:.6f}\n" &
  &"  bias={m.weights[0]:.6f} " &
  &"w[1..5]={m.weights[1..min(5,m.weights.len-1)]}"

proc describe*(m: LogisticModel): string =
  &"LogisticModel nFeatures={m.nFeatures} nSeen={m.nSeen} " &
  &"lr={m.lr} reg={m.reg} trainLoss={m.trainLoss:.6f} thresh={m.threshold}"

# ─── Serialisation (to/from byte blob for model registry) ─────────────────

proc toBytes*(m: LinearModel): seq[byte] =
  ## [tag:u8=0x01][nF:i32][lr:f32][reg:u8][lam:f32][nSeen:i64][weights...]
  result = newSeq[byte](1 + 4 + 4 + 1 + 4 + 8 + m.weights.len * 4)
  var off = 0
  result[off] = 0x01; inc off
  lePut32(result, off, uint32(m.nFeatures)); off += 4
  lePut32(result, off, cast[uint32](m.lr));  off += 4
  result[off] = uint8(m.reg); inc off
  lePut32(result, off, cast[uint32](m.regLambda)); off += 4
  lePut64(result, off, cast[uint64](m.nSeen)); off += 8
  for w in m.weights:
    lePut32(result, off, cast[uint32](w)); off += 4

proc linearFromBytes*(data: seq[byte]): LinearModel =
  if data.len < 22: raise newException(StorageError, "Corrupt model blob")
  var off = 1  ## skip tag
  let nF  = int(leGet32(data, off)); off += 4
  let lr  = cast[float32](leGet32(data, off)); off += 4
  let reg = RegKind(data[off]); inc off
  let lam = cast[float32](leGet32(data, off)); off += 4
  let ns  = cast[int64](leGet64(data, off)); off += 8
  var w   = newSeq[float32](nF + 1)
  for i in 0 .. nF:
    w[i] = cast[float32](leGet32(data, off)); off += 4
  LinearModel(weights: w, nFeatures: nF, lr: lr,
              reg: reg, regLambda: lam, nSeen: ns)
