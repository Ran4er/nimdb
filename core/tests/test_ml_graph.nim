## test_ml_graph.nim — Tests for v0.2 ML and graph features

import std/[unittest, math, sequtils, tables]
import ../src/ml/[tensor, simd_ops, quantize, linear, kmeans, model_registry]
import ../src/graph/[graph_store, graph_algo, gql]
import ../src/transaction/mvcc
import ../src/storage/types
import ../src/catalog/schema

# ─── SIMD ops ─────────────────────────────────────────────────────────────

suite "SIMD vector ops":
  test "dot product accuracy":
    let a = @[1.0'f32, 2.0, 3.0, 4.0]
    let b = @[4.0'f32, 3.0, 2.0, 1.0]
    let d = dotF32Seq(a, b)
    check abs(d - 20.0'f32) < 1e-4'f32

  test "dot large vector":
    let n  = 10_000
    var a  = newSeq[float32](n)
    var b  = newSeq[float32](n)
    for i in 0..<n: a[i] = 1.0'f32; b[i] = 1.0'f32
    let d = dotF32Seq(a, b)
    check abs(d - float32(n)) < 1.0'f32   # allow fp rounding

  test "l2 distance":
    let a = @[1.0'f32, 0.0, 0.0]
    let b = @[0.0'f32, 1.0, 0.0]
    let d = l2distF32Seq(a, b)
    check abs(d - sqrt(2.0'f32)) < 1e-5'f32

  test "cosine fused":
    let a = @[1.0'f32, 0.0, 0.0]
    let b = @[1.0'f32, 0.0, 0.0]
    let c = cosineSimFused(
      cast[ptr float32](unsafeAddr a[0]),
      cast[ptr float32](unsafeAddr b[0]), 3)
    check abs(c - 1.0'f32) < 1e-5'f32

  test "matvec":
    # 2x3 matrix * 3-vector
    let A = @[1.0'f32, 0.0, 0.0,
              0.0'f32, 1.0, 0.0]
    let x = @[5.0'f32, 7.0, 9.0]
    let y = matvecF32Seq(A, x, 2, 3)
    check abs(y[0] - 5.0'f32) < 1e-5'f32
    check abs(y[1] - 7.0'f32) < 1e-5'f32

# ─── INT8 Quantization ────────────────────────────────────────────────────

suite "INT8 quantization":
  test "quantise and dequantise":
    let orig  = @[0.0'f32, 0.5, 1.0, -0.5, -1.0]
    let q     = quantiseINT8(orig)
    let back  = dequantise(q)
    for i in 0..<orig.len:
      check abs(back[i] - orig[i]) < 0.02'f32   # <2% error

  test "dot approximation":
    let a = @[0.1'f32, 0.9, 0.3, -0.4, 0.7]
    let b = @[0.8'f32, 0.2, -0.5, 0.6, 0.1]
    let exact = dotF32Seq(a, b)
    let qa    = quantiseINT8(a)
    let qb    = quantiseINT8(b)
    let approx = dotINT8(qa, qb)
    check abs(approx - exact) < 0.05'f32   # <5% error

# ─── Product Quantization ─────────────────────────────────────────────────

suite "Product Quantization":
  test "encode decode":
    var vecs: seq[seq[float32]]
    for i in 0..99:
      vecs.add(@[float32(i mod 10), float32(i div 10),
                 float32(i mod 5), float32(i div 5)])
    let book = trainPQ(vecs, M = 2, iters = 5)
    check book.M == 2; check book.Ds == 2; check book.D == 4

    let orig    = @[3.0'f32, 7.0, 2.0, 4.0]
    let code    = book.encode(orig)
    let decoded = book.decode(code)
    check code.codes.len == 2
    check decoded.len == 4

  test "knn via ADC":
    var vecs: seq[seq[float32]]
    for i in 0..49:
      vecs.add(@[float32(i), float32(i mod 10)])
    let book  = trainPQ(vecs, M = 1, iters = 10)
    let idx   = newPQIndex(book)
    for i, v in vecs: idx.insert(v, int64(i))
    let query   = @[25.0'f32, 5.0]
    let results = idx.knnSearch(query, 3)
    check results.len == 3

# ─── Linear Regression ────────────────────────────────────────────────────

suite "Linear regression":
  test "perfect linear fit":
    var X: seq[seq[float32]]; var y: seq[float32]
    for i in 1..100:
      X.add(@[float32(i)])
      y.add(2.0'f32 * float32(i) + 1.0'f32)
    let m = newLinearModel(1, lr = 0.001'f32)
    m.fit(X, y, epochs = 50)
    check m.score(X, y) > 0.99'f32

  test "online partialFit":
    let m = newLinearModel(1, lr = 0.01'f32)
    for i in 1..500:
      m.partialFit(@[float32(i)], 3.0'f32 * float32(i))
    check m.predict(@[100.0'f32]) > 250.0'f32

  test "serialise and restore":
    let m = newLinearModel(3)
    m.fit(@[@[1.0'f32, 2.0, 3.0]], @[6.0'f32], epochs = 1)
    let blob = m.toBytes()
    let m2   = linearFromBytes(blob)
    check m2.nFeatures == 3
    check abs(m.predict(@[1.0'f32, 2.0, 3.0]) -
              m2.predict(@[1.0'f32, 2.0, 3.0])) < 1e-5'f32

# ─── K-Means ──────────────────────────────────────────────────────────────

suite "K-Means clustering":
  test "basic convergence":
    ## Two clear clusters
    var X: seq[seq[float32]]
    for i in 0..49: X.add(@[float32(i) * 0.01'f32, 0.0'f32])
    for i in 0..49: X.add(@[10.0'f32 + float32(i) * 0.01'f32, 0.0'f32])
    let m = newKMeans(2)
    m.fit(X)
    check m.converged
    ## Centroids should be near 0.25 and 10.25
    var c0 = m.centroids[0][0]; var c1 = m.centroids[1][0]
    if c0 > c1: swap(c0, c1)
    check c0 < 1.0'f32; check c1 > 9.0'f32

  test "elbow method returns k range":
    var X: seq[seq[float32]]
    for i in 0..99: X.add(@[float32(i mod 10), float32(i div 10)])
    let scores = elbowScores(X, kMin = 2, kMax = 6)
    check scores.len == 5
    let best = suggestK(scores)
    check best >= 2 and best <= 6

# ─── Model Registry ───────────────────────────────────────────────────────

suite "Model registry":
  setup:
    import std/os; createDir("/tmp/nimdb_test_reg")

  test "register and retrieve":
    let reg = newModelRegistry("/tmp/nimdb_test_reg")
    let m   = newLinearModel(2)
    var met: Table[string, float64]; met["r2"] = 0.95
    let v = reg.register("mymodel", mkLinear, m.toBytes(), met)
    check v == 0
    let m2 = reg.getLinearModel("mymodel")
    check not m2.isNil
    check m2.nFeatures == 2

  test "version promotion and rollback":
    let reg = newModelRegistry("/tmp/nimdb_test_reg")
    var met: Table[string, float64]
    met["r2"] = 0.90
    discard reg.register("m2", mkLinear, @[], met)
    met["r2"] = 0.95
    discard reg.register("m2", mkLinear, @[], met)
    reg.promote("m2", 1)
    check reg.describe("m2").contains("v1")
    reg.rollback("m2")
    check reg.describe("m2").contains("v0")

# ─── Graph Store ──────────────────────────────────────────────────────────

suite "Graph store":
  test "add nodes and edges":
    let gs = newGraphStore("/tmp")
    let a  = gs.addNode(@["Person"], @[("name", textVal("Alice"))])
    let b  = gs.addNode(@["Person"], @[("name", textVal("Bob"))])
    let e  = gs.addEdge(a, b, "KNOWS")
    check gs.nodeCount() >= 2
    check gs.edgeCount() >= 1
    check gs.neighbours(a).contains(b)

  test "label index":
    let gs = newGraphStore("/tmp")
    let a  = gs.addNode(@["Car"], @[("brand", textVal("Toyota"))])
    let b  = gs.addNode(@["Car"], @[("brand", textVal("Honda"))])
    discard gs.addNode(@["Person"], @[])
    let cars = gs.nodesByLabel("Car")
    check a in cars; check b in cars
    check cars.len == 2

suite "Graph algorithms":
  test "BFS hops":
    let gs = newGraphStore("/tmp")
    let n1 = gs.addNode(@["N"])
    let n2 = gs.addNode(@["N"])
    let n3 = gs.addNode(@["N"])
    discard gs.addEdge(n1, n2, "E"); discard gs.addEdge(n2, n3, "E")
    check gs.shortestHops(n1, n3) == 2
    check gs.shortestHops(n1, n1) == 0

  test "PageRank sums to 1":
    let gs = newGraphStore("/tmp")
    let a = gs.addNode(@["N"]); let b = gs.addNode(@["N"])
    let c = gs.addNode(@["N"])
    discard gs.addEdge(a, b, "E"); discard gs.addEdge(b, c, "E")
    discard gs.addEdge(c, a, "E")
    let pr = gs.pageRank()
    var total = 0.0
    for _, v in pr: total += v
    check abs(total - 1.0) < 0.01

  test "WCC finds components":
    let gs = newGraphStore("/tmp")
    let a  = gs.addNode(@["N"]); let b = gs.addNode(@["N"])
    let c  = gs.addNode(@["N"])  ## isolated
    discard gs.addEdge(a, b, "E")
    let wcc = gs.wcc()
    check wcc.nComps == 2

  test "Dijkstra shortest path":
    let gs = newGraphStore("/tmp")
    let a = gs.addNode(@["N"]); let b = gs.addNode(@["N"])
    let c = gs.addNode(@["N"])
    discard gs.addEdge(a, b, "E", @[("weight", floatVal(1.0))])
    discard gs.addEdge(b, c, "E", @[("weight", floatVal(2.0))])
    discard gs.addEdge(a, c, "E", @[("weight", floatVal(10.0))])
    let (d, path) = gs.shortestPath(a, c)
    check abs(d - 3.0) < 0.01   ## a->b->c = 3, better than direct 10
    check path.len == 3

# ─── MVCC ─────────────────────────────────────────────────────────────────

suite "MVCC visibility":
  test "own insert is visible":
    let cl = newCommitLog()
    cl.markCommitted(TxnId(1))
    let hdr = TupleHdr(xmin: TxnId(1), xmax: TxnId(0))
    let snap = Snapshot(txnId: TxnId(2), minActive: TxnId(2))
    check isVisible(hdr, snap, cl)

  test "uncommitted insert not visible":
    let cl   = newCommitLog()   ## txn 1 never committed
    let hdr  = TupleHdr(xmin: TxnId(1), xmax: TxnId(0))
    let snap = Snapshot(txnId: TxnId(2), minActive: TxnId(2))
    check not isVisible(hdr, snap, cl)

  test "deleted tuple not visible":
    let cl = newCommitLog()
    cl.markCommitted(TxnId(1))
    cl.markCommitted(TxnId(2))
    let hdr  = TupleHdr(xmin: TxnId(1), xmax: TxnId(2))
    let snap = Snapshot(txnId: TxnId(3), minActive: TxnId(3))
    check not isVisible(hdr, snap, cl)

  test "tuple deleted after snapshot still visible":
    let cl = newCommitLog()
    cl.markCommitted(TxnId(1))
    ## txn 3 deletes AFTER our snapshot was taken
    let hdr  = TupleHdr(xmin: TxnId(1), xmax: TxnId(3))
    var active: HashSet[TxnId]; active.incl(TxnId(3))
    let snap = Snapshot(txnId: TxnId(2), minActive: TxnId(2),
                        activeTxns: active)
    check isVisible(hdr, snap, cl)   ## deleter was active at snapshot

when isMainModule:
  echo "Running NimDB v0.2 test suite..."
