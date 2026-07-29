## feature_store.nim — ML Feature Store
##
## Materialises features from raw tables into ready-to-train tensors.
## Supports:
##   - Feature definitions (column transformations)
##   - Materialised feature groups (cached in columnar store)
##   - Online serving (low-latency single-row feature lookup)
##   - Batch export (full tensor matrix for training)
##   - Feature statistics (mean/std for normalisation)
##   - Label extraction

import std/[tables, math, sequtils, algorithm, times, strformat]
import ../storage/types
import ../catalog/schema
import ../storage/columnar
import tensor

type
  TransformKind* = enum
    tkIdentity     ## raw value as-is
    tkStandardize  ## (x - mean) / std
    tkMinMaxScale  ## (x - min) / (max - min)
    tkLog1p        ## log(1 + x)
    tkBoolToFloat  ## bool → 0.0 / 1.0
    tkOneHot       ## categorical → one-hot vector
    tkEmbedding    ## text → pre-stored embedding lookup
    tkBucket       ## numeric → bucket index

  FeatureDef* = object
    name*:       string
    sourceCol*:  int           ## column index in source table
    transform*:  TransformKind
    ## normalisation stats (computed during materialise)
    mean*, std*: float32
    min*, max*:  float32
    ## one-hot / bucket config
    categories*: seq[string]
    buckets*:    seq[float32]
    outputDim*:  int           ## 1 for scalar, N for one-hot/vector

  FeatureGroup* = ref object
    name*:        string
    tableId*:     ObjId
    features*:    seq[FeatureDef]
    labelCol*:    int          ## -1 = no label
    totalDim*:    int          ## sum of outputDim
    matData*:     seq[float32] ## flattened [nrows × totalDim]
    labels*:      seq[float32]
    nRows*:       int
    version*:     int64
    createdAt*:   DateTime

  FeatureStore* = ref object
    groups*:  Table[string, FeatureGroup]
    colStores*: Table[ObjId, ColumnStore]

proc newFeatureStore*(): FeatureStore =
  FeatureStore(groups: initTable[string, FeatureGroup](),
               colStores: initTable[ObjId, ColumnStore]())

# ─── Stats computation ────────────────────────────────────────────────────

proc computeStats*(vals: seq[float32]): tuple[mean, std, min, max: float32] =
  if vals.len == 0: return
  var sum = 0.0'f32; var sumSq = 0.0'f32
  result.min = vals[0]; result.max = vals[0]
  for v in vals:
    sum   += v; sumSq += v * v
    if v < result.min: result.min = v
    if v > result.max: result.max = v
  result.mean = sum / float32(vals.len)
  result.std  = sqrt(sumSq / float32(vals.len) - result.mean ^ 2)
  if result.std < 1e-8'f32: result.std = 1.0'f32  ## avoid div-by-zero

# ─── One-hot helper ───────────────────────────────────────────────────────

proc buildCategories*(vals: seq[Value]): seq[string] =
  var seen: Table[string, bool]
  for v in vals:
    if v.kind == ckText and v.text notin seen:
      seen[v.text] = true; result.add(v.text)
  result.sort()

proc oneHotEncode*(category: string; cats: seq[string]): seq[float32] =
  result = newSeq[float32](cats.len)
  for i, c in cats:
    if c == category: result[i] = 1.0'f32

# ─── Single value transform ───────────────────────────────────────────────

proc applyTransform*(fd: FeatureDef; v: Value): seq[float32] =
  let raw = if v.isNumeric: v.toFloat() else: 0.0
  let fv  = float32(raw)
  case fd.transform
  of tkIdentity:
    result = @[fv]
  of tkStandardize:
    result = @[(fv - fd.mean) / fd.std]
  of tkMinMaxScale:
    let r = fd.max - fd.min
    result = @[if r < 1e-8'f32: 0.0'f32 else: (fv - fd.min) / r]
  of tkLog1p:
    result = @[ln(1.0 + max(0.0, float64(fv))).float32]
  of tkBoolToFloat:
    result = @[if v.kind == ckBool and v.b: 1.0'f32 else: 0.0'f32]
  of tkOneHot:
    let s = if v.kind == ckText: v.text else: $v
    result = oneHotEncode(s, fd.categories)
  of tkBucket:
    var bucket = fd.buckets.len  ## default = last bucket
    for i, b in fd.buckets:
      if fv < b: bucket = i; break
    var oh = newSeq[float32](fd.buckets.len + 1)
    oh[bucket] = 1.0'f32
    result = oh
  of tkEmbedding:
    result = @[fv]  ## placeholder; real impl does lookup

# ─── Materialise ──────────────────────────────────────────────────────────

proc materialise*(fs: FeatureStore; grp: FeatureGroup;
                  cs: ColumnStore): FeatureGroup =
  ## Compute feature stats and fill grp.matData from column store.
  result = grp
  result.nRows      = int(cs.rowCount)
  result.version    = getTime().toUnix()
  result.createdAt  = now()

  # Pass 1: compute stats for normalisation
  for i in 0 ..< result.features.len:
    var fd = result.features[i]
    let vals = cs.scanColumnAsF32(fd.sourceCol)
    let st   = computeStats(vals)
    fd.mean  = st.mean; fd.std  = st.std
    fd.min   = st.min;  fd.max  = st.max
    if fd.transform == tkOneHot:
      let rawVals = cs.scanColumn(fd.sourceCol)
      fd.categories = buildCategories(rawVals)
      fd.outputDim  = fd.categories.len
    elif fd.transform == tkBucket:
      fd.outputDim = fd.buckets.len + 1
    else:
      fd.outputDim = 1
    result.features[i] = fd

  result.totalDim = result.features.mapIt(it.outputDim).foldl(a + b, 0)

  # Pass 2: build feature matrix  [nRows × totalDim]
  result.matData = newSeq[float32](result.nRows * result.totalDim)
  result.labels  = if result.labelCol >= 0: newSeq[float32](result.nRows)
                   else: @[]

  for row in 0 ..< result.nRows:
    var col = 0
    for fd in result.features:
      # Read value from column store
      let rawVals = cs.scanColumn(fd.sourceCol)
      let v = if row < rawVals.len: rawVals[row] else: nullVal()
      let encoded = fd.applyTransform(v)
      let off = row * result.totalDim + col
      for k, fv in encoded: result.matData[off + k] = fv
      col += fd.outputDim

    if result.labelCol >= 0:
      let labelVals = cs.scanColumn(result.labelCol)
      let lv = if row < labelVals.len: labelVals[row] else: nullVal()
      result.labels[row] = if lv.isNumeric: float32(lv.toFloat()) else: 0.0'f32

  fs.groups[grp.name] = result

proc getFeatureMatrix*(grp: FeatureGroup): Tensor =
  ## Return materialised features as a 2D Tensor[nRows × totalDim].
  result = newTensor(dtF32, @[grp.nRows, grp.totalDim])
  if grp.matData.len > 0:
    for i, v in grp.matData:
      result.setF32(i, v)

proc getLabelVector*(grp: FeatureGroup): Tensor =
  ## Return labels as a 1D Tensor[nRows].
  result = newTensor(dtF32, @[grp.nRows])
  for i, v in grp.labels: result.setF32(i, v)

# ─── Train/test split ─────────────────────────────────────────────────────

proc trainTestSplit*(grp: FeatureGroup; ratio = 0.8'f32):
    tuple[xTrain, xTest, yTrain, yTest: Tensor] =
  let n      = grp.nRows
  let nTrain = int(float32(n) * ratio)
  let nTest  = n - nTrain
  let dim    = grp.totalDim

  result.xTrain = newTensor(dtF32, @[nTrain, dim])
  result.xTest  = newTensor(dtF32, @[nTest,  dim])
  result.yTrain = newTensor(dtF32, @[nTrain])
  result.yTest  = newTensor(dtF32, @[nTest])

  for i in 0 ..< nTrain:
    for j in 0 ..< dim:
      result.xTrain.setF32(i * dim + j, grp.matData[i * dim + j])
    if grp.labels.len > i:
      result.yTrain.setF32(i, grp.labels[i])

  for i in 0 ..< nTest:
    let si = nTrain + i
    for j in 0 ..< dim:
      result.xTest.setF32(i * dim + j, grp.matData[si * dim + j])
    if grp.labels.len > si:
      result.yTest.setF32(i, grp.labels[si])

proc describeGroup*(grp: FeatureGroup): string =
  result = &"FeatureGroup '{grp.name}'\n"
  result &= &"  rows={grp.nRows}  totalDim={grp.totalDim}\n"
  result &= &"  features ({grp.features.len}):\n"
  for fd in grp.features:
    result &= &"    {fd.name}: {fd.transform} dim={fd.outputDim}"
    result &= &" mean={fd.mean:.4f} std={fd.std:.4f}\n"
