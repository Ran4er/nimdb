## vector_ops.nim — SQL extensions for ML/vector/graph operations
##
## New SQL syntax handled here:
##
##   -- Vector type in DDL (stored as BYTES with magic header)
##   CREATE TABLE embeddings (id INT4, vec VECTOR(128), label TEXT)
##
##   -- Vector distance operators in WHERE / ORDER BY
##   SELECT id FROM embeddings
##    ORDER BY vec_distance(vec, ARRAY[0.1, 0.2, ...]) ASC
##    LIMIT 10
##
##   -- In-DB training
##   TRAIN MODEL 'price_model' TYPE linear
##     ON products FEATURES (weight, volume, category_enc) PREDICT price
##     OPTIONS (lr=0.01, reg=l2, epochs=5)
##
##   -- In-DB prediction (as a column expression in SELECT)
##   SELECT id, PREDICT('price_model', weight, volume, category_enc) AS pred
##     FROM products
##
##   -- Graph queries (routed to GQL executor)
##   GRAPH MATCH (p:Person)-[:KNOWS]->(q:Person)
##     WHERE p.age > 25 RETURN p, q LIMIT 50
##
##   -- PageRank
##   GRAPH PAGERANK LIMIT 10
##
##   -- Cluster assignment
##   TRAIN KMEANS 'segments' ON users FEATURES (score, age) K=5
##   SELECT id, CLUSTER('segments', score, age) AS segment FROM users

import std/[strutils, sequtils, tables, parseutils, math]
import ../storage/types
import ../catalog/schema
import ../ml/[tensor, vector_index, linear, kmeans, model_registry, simd_ops]
import ../graph/[graph_store, gql]

# ─── VECTOR column magic ──────────────────────────────────────────────────

const VecMagic* = 0x4E56_4543'u32   ## "NVEC"

proc encodeVectorCol*(v: seq[float32]): seq[byte] =
  ## Encode a float32 vector as a BYTES column value.
  ## Format: [magic:u32][dim:u32][data:dim×f32]
  result = newSeq[byte](8 + v.len * 4)
  lePut32(result, 0, VecMagic)
  lePut32(result, 4, uint32(v.len))
  for i, f in v:
    lePut32(result, 8 + i * 4, cast[uint32](f))

proc decodeVectorCol*(raw: seq[byte]): seq[float32] =
  if raw.len < 8: return
  if leGet32(raw, 0) != VecMagic: return
  let dim = int(leGet32(raw, 4))
  result  = newSeq[float32](dim)
  for i in 0 ..< dim:
    result[i] = cast[float32](leGet32(raw, 8 + i * 4))

proc isVectorCol*(v: Value): bool =
  v.kind == ckBytes and v.raw.len >= 8 and
  leGet32(v.raw, 0) == VecMagic

proc valueToVec*(v: Value): seq[float32] =
  if v.kind != ckBytes: return
  decodeVectorCol(v.raw)

# ─── Distance functions (SQL-callable) ────────────────────────────────────

type DistFn* = enum dfCosine, dfL2, dfDot

proc vecDistanceSql*(a, b: Value; fn = dfL2): float32 =
  let va = valueToVec(a)
  let vb = valueToVec(b)
  if va.len == 0 or vb.len == 0 or va.len != vb.len:
    return Inf.float32
  case fn
  of dfL2:
    l2distF32Seq(va, vb)
  of dfCosine:
    1.0'f32 - cosineSimFused(
      cast[ptr float32](unsafeAddr va[0]),
      cast[ptr float32](unsafeAddr vb[0]), va.len)
  of dfDot:
    -dotF32Seq(va, vb)   ## negate → smallest = largest dot

proc parseArrayLiteral*(s: string): seq[float32] =
  ## Parse "[0.1, 0.2, 0.3]" or "ARRAY[0.1,0.2]" into float32 seq.
  var clean = s.strip()
  if clean.toLowerAscii().startsWith("array"): clean = clean[5..^1]
  clean = clean.strip(chars = {'[', ']', '(', ')'})
  for part in clean.split(','):
    let t = part.strip()
    if t.len > 0:
      try: result.add(parseFloat(t).float32) except: discard

# ─── TRAIN command ────────────────────────────────────────────────────────

type
  TrainSpec* = object
    modelName*:   string
    modelType*:   string      ## "linear" | "logistic" | "kmeans"
    tableName*:   string
    features*:    seq[string] ## column names
    targetCol*:   string      ## predict column (empty for kmeans)
    k*:           int         ## for kmeans
    lr*:          float32
    reg*:         string      ## "none" | "l1" | "l2"
    regLambda*:   float32
    epochs*:      int
    batchSize*:   int

proc parseTrainSpec*(sql: string): TrainSpec =
  ## Parse: TRAIN MODEL 'name' TYPE linear|logistic|kmeans
  ##          ON table FEATURES (c1,c2,...) PREDICT col
  ##          OPTIONS (lr=0.01, reg=l2, lambda=0.001, epochs=5, k=8)
  result = TrainSpec(lr: 0.01'f32, reg: "l2", regLambda: 0.0001'f32,
                     epochs: 5, batchSize: 64, k: 8)
  let parts = sql.splitWhitespace()
  var i     = 0
  proc eat(s: string): bool =
    if i < parts.len and parts[i].toUpperAscii() == s.toUpperAscii():
      inc i; true else: false

  discard eat("TRAIN"); discard eat("MODEL")
  if i < parts.len:
    result.modelName = parts[i].strip(chars = {'\''})
    inc i

  discard eat("TYPE")
  if i < parts.len: result.modelType = parts[i].toLowerAscii(); inc i

  discard eat("ON")
  if i < parts.len: result.tableName = parts[i]; inc i

  ## FEATURES (c1, c2, ...)
  if eat("FEATURES"):
    var buf = ""
    while i < parts.len and not parts[i].toUpperAscii().startsWith("PREDICT"):
      buf &= parts[i] & " "; inc i
    result.features = buf.strip(chars = {'(', ')', ' '}).split(',')
                         .mapIt(it.strip())

  discard eat("PREDICT")
  if i < parts.len and not parts[i].toUpperAscii().startsWith("OPTION"):
    result.targetCol = parts[i]; inc i

  ## OPTIONS (key=val, ...)
  if eat("OPTIONS"):
    var buf = ""
    while i < parts.len: buf &= parts[i] & " "; inc i
    for opt in buf.strip(chars = {'(', ')', ' '}).split(','):
      let kv = opt.strip().split('=')
      if kv.len < 2: continue
      case kv[0].strip().toLowerAscii()
      of "lr":       result.lr        = parseFloat(kv[1].strip()).float32
      of "reg":      result.reg       = kv[1].strip()
      of "lambda":   result.regLambda = parseFloat(kv[1].strip()).float32
      of "epochs":   result.epochs    = parseInt(kv[1].strip())
      of "batch":    result.batchSize = parseInt(kv[1].strip())
      of "k":        result.k         = parseInt(kv[1].strip())
      else: discard

# ─── Execution context for ML ops ────────────────────────────────────────

type
  MLContext* = ref object
    registry*:  ModelRegistry
    vecIdxs*:   Table[string, HNSWIndex]   ## model name → HNSW
    kmeansMap*: Table[string, KMeansModel]
    graphStore*: GraphStore

proc newMLContext*(dataDir: string): MLContext =
  MLContext(
    registry:   newModelRegistry(dataDir),
    vecIdxs:    initTable[string, HNSWIndex](),
    kmeansMap:  initTable[string, KMeansModel](),
    graphStore: newGraphStore(dataDir)
  )

# ─── PREDICT SQL function ─────────────────────────────────────────────────

proc predictLinear*(ctx: MLContext; modelName: string;
                    features: seq[float32]): float32 =
  let m = ctx.registry.getLinearModel(modelName)
  if m.isNil: return 0.0'f32
  m.predict(features)

proc predictCluster*(ctx: MLContext; modelName: string;
                     features: seq[float32]): int =
  if modelName notin ctx.kmeansMap: return -1
  ctx.kmeansMap[modelName].assign(features)

# ─── KNN vector search ────────────────────────────────────────────────────

proc knnVectorSearch*(ctx: MLContext; indexName: string;
                      query: seq[float32]; k: int): seq[(int64, float32)] =
  if indexName notin ctx.vecIdxs: return
  let results = ctx.vecIdxs[indexName].knnSearch(vectorF32(query), k)
  for r in results: result.add((r.extId, r.distance))

# ─── Graph command routing ────────────────────────────────────────────────

proc execGraphQuery*(ctx: MLContext; gqlQuery: string): seq[seq[(string, string)]] =
  ## Execute GQL and return list of rows as (key,value) pairs.
  let rows = execGQL(ctx.graphStore, gqlQuery)
  for row in rows:
    var r: seq[(string, string)]
    for k, v in row: r.add((k, v))
    result.add(r)

# ─── Describe helpers for REPL ────────────────────────────────────────────

proc describeMLContext*(ctx: MLContext): string =
  result = "ML Context:\n"
  let models = ctx.registry.listModels()
  result &= "  Models (" & $models.len & "): " & models.join(", ") & "\n"
  result &= "  Vector indexes (" & $ctx.vecIdxs.len & "): " &
            toSeq(ctx.vecIdxs.keys).join(", ") & "\n"
  result &= "  K-Means models (" & $ctx.kmeansMap.len & "): " &
            toSeq(ctx.kmeansMap.keys).join(", ") & "\n"
  result &= "  Graph: " & ctx.graphStore.stats()
