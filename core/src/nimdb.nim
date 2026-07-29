## nimdb.nim — NimDB v0.2.0 entry point
import std/[os, strutils, parseopt, terminal, times, sequtils, tables, math, random]
import storage/[types, wal, buffer_pool]
import catalog/[schema, catalog]
import sql/[executor, vector_ops]
import ml/[tensor, vector_index, linear, kmeans, model_registry,
           simd_ops, arrow_export]
import graph/[graph_store, graph_algo, gql]
import transaction/mvcc
import engine/modes
import server/server
import distributed/node

const Version* = "0.2.0"

let Banner = """
╔══════════════════════════════════════════════════════════════════════╗
║  NimDB v0.2.0  — ML-native database engine                          ║
║  Storage: OLTP · OLAP · VECTOR · HYBRID  |  MVCC snapshot isolation ║
║  ML:  SIMD · PQ quantize · Linear/Logistic · K-Means · Registry     ║
║  Graph: PropertyGraph · GQL · PageRank · Dijkstra · BFS/WCC         ║
╚══════════════════════════════════════════════════════════════════════╝"""

proc printResult(res: ExecResult) =
  if res.resultSet.rows.len > 0 or res.resultSet.cols.len > 0:
    var widths = res.resultSet.cols.mapIt(max(it.name.len, 6))
    for row in res.resultSet.rows:
      for i, v in row:
        if i < widths.len: widths[i] = max(widths[i], ($v).len)
    for i, c in res.resultSet.cols:
      stdout.write(c.name.alignLeft(widths[i] + 2))
    echo ""
    echo "-".repeat(widths.foldl(a + b + 2, 0))
    for row in res.resultSet.rows:
      for i, v in row:
        stdout.write(($v).alignLeft(widths[min(i, widths.len-1)] + 2))
      echo ""
    let n = res.resultSet.rows.len
    styledEcho fgGreen, "(" & $n & " row" & (if n!=1:"s" else:"") & ")"
  if res.message.len > 0: styledEcho fgGreen, res.message
  if res.rowsAffected > 0 and res.resultSet.cols.len == 0:
    styledEcho fgYellow, $res.rowsAffected & " row(s) affected"

proc handleMLCmd(eng: Engine; mlCtx: MLContext; line: string): bool =
  let up = line.strip().toUpperAscii()

  if up.startsWith("TRAIN "):
    let spec = parseTrainSpec(line)
    if spec.modelType in ["linear", "logistic"]:
      echo "Training " & spec.modelType & " model '" & spec.modelName & "'..."
      let entry  = eng.catalog.getTable(spec.tableName)
      let schema = entry.schema
      var X: seq[seq[float32]]; var y: seq[float32]
      let featIdxs = spec.features.mapIt(schema.colIndex(it))
      let targIdx  = schema.colIndex(spec.targetCol)
      let hf = eng.getHeap(schema.tableId, entry.dataPath)
      hf.scan(proc(tid: auto; data: seq[byte]): bool =
        let row = decodeTuple(data, schema.cols.len)
        var feats = newSeq[float32](featIdxs.len)
        for i, fi in featIdxs:
          if fi >= 0 and fi < row.len and row[fi].isNumeric:
            feats[i] = float32(row[fi].toFloat())
        X.add(feats)
        if targIdx >= 0 and targIdx < row.len and row[targIdx].isNumeric:
          y.add(float32(row[targIdx].toFloat()))
        true)
      let reg = case spec.reg.toLowerAscii()
                of "l1": rkL1; of "l2": rkL2; else: rkNone
      let m = newLinearModel(featIdxs.len, spec.lr, reg, spec.regLambda)
      m.fit(X, y, spec.epochs, spec.batchSize)
      let sc = m.score(X, y)
      styledEcho fgCyan, "  R2 = " & $sc
      var metrics: Table[string, float64]
      metrics["r2"] = float64(sc)
      let ver = mlCtx.registry.register(spec.modelName, mkLinear,
                                        m.toBytes(), metrics, int64(X.len))
      styledEcho fgGreen, "Registered as v" & $ver
    elif spec.modelType == "kmeans":
      echo "Training K-Means k=" & $spec.k & "..."
      let entry  = eng.catalog.getTable(spec.tableName)
      let schema = entry.schema
      var X: seq[seq[float32]]
      let featIdxs = spec.features.mapIt(schema.colIndex(it))
      let hf = eng.getHeap(schema.tableId, entry.dataPath)
      hf.scan(proc(tid: auto; data: seq[byte]): bool =
        let row = decodeTuple(data, schema.cols.len)
        var feats = newSeq[float32](featIdxs.len)
        for i, fi in featIdxs:
          if fi >= 0 and fi < row.len and row[fi].isNumeric:
            feats[i] = float32(row[fi].toFloat())
        X.add(feats); true)
      let m = newKMeans(spec.k)
      m.fit(X)
      mlCtx.kmeansMap[spec.modelName] = m
      styledEcho fgGreen, m.describe()
    return true

  if up.startsWith("GRAPH "):
    let gqlQuery = line[6..^1].strip()
    let rows = mlCtx.graphStore.execGQL(gqlQuery)
    if rows.len == 0: styledEcho fgYellow, "(no results)"
    else:
      for row in rows:
        for k, v in row: stdout.write(k & "=" & v & "  ")
        echo ""
      styledEcho fgGreen, "(" & $rows.len & " rows)"
    return true

  if up.startsWith("\\ADDNODE "):
    let parts = line.strip()[9..^1].splitWhitespace()
    if parts.len > 0:
      var props: PropMap
      for kv in parts[1..^1]:
        let p = kv.split('=')
        if p.len == 2: props.add((p[0], textVal(p[1])))
      let id = mlCtx.graphStore.addNode(@[parts[0]], props)
      styledEcho fgGreen, "Node id=" & $id
    return true

  if up.startsWith("\\ADDEDGE "):
    let parts = line.strip()[9..^1].splitWhitespace()
    if parts.len >= 3:
      let id = mlCtx.graphStore.addEdge(
        int64(parseInt(parts[0])), int64(parseInt(parts[2])), parts[1])
      styledEcho fgGreen, "Edge id=" & $id
    return true

  if up.startsWith("\\BENCH"):
    let gflo = benchDot(1_000_000, 20)
    styledEcho fgCyan, &"SIMD dot: {gflo:.2f} GFLOPs (1M elems, 20 iters)"
    return true

  if up.startsWith("\\EXPORT "):
    let parts = line.strip()[8..^1].splitWhitespace()
    if parts.len >= 2:
      let entry = eng.catalog.getTable(parts[0])
      var rows: seq[Row]
      let hf = eng.getHeap(entry.schema.tableId, entry.dataPath)
      hf.scan(proc(tid: auto; data: seq[byte]): bool =
        rows.add(decodeTuple(data, entry.schema.cols.len)); true)
      exportToArrow(rows, entry.schema, parts[1])
      writeReaderScript(parts[1])
      styledEcho fgGreen, "Exported " & $rows.len & " rows -> " & parts[1]
    return true

  false

proc helpText(): string = """
SQL:
  CREATE TABLE t (id INT4, name TEXT, score FLOAT8)
  INSERT / SELECT / UPDATE / DELETE / BEGIN / COMMIT / ROLLBACK

ML:
  TRAIN MODEL 'name' TYPE linear|logistic|kmeans
        ON table FEATURES (c1,c2) PREDICT col
        OPTIONS (lr=0.01, reg=l2, epochs=5, k=8)

Graph:
  GRAPH MATCH (n:Label)-[:TYPE]->(m:Label) LIMIT 20
  GRAPH PAGERANK LIMIT 10
  GRAPH SHORTESTPATH FROM <id> TO <id>
  \addnode <Label> key=val ...
  \addedge <fromId> <TYPE> <toId>

Tools:
  \bench               SIMD benchmark
  \export <table> <f>  Arrow IPC export (zero-copy to pandas)
  \models              list ML models
  \info                server info
  \quit"""

proc runRepl(eng: Engine; mlCtx: MLContext) =
  echo Banner
  var buf = ""
  while true:
    stdout.write(if buf.len == 0: "\nNimDB> " else: "     > ")
    stdout.flushFile()
    let line = try: stdin.readLine() except EOFError: "\\quit"
    let trim = line.strip()
    if trim.len == 0: continue
    if trim in ["\\quit","\\q","exit"]: echo "Bye."; break
    if trim == "\\help": echo helpText(); continue
    if trim == "\\models":
      let ms = mlCtx.registry.listModels()
      if ms.len == 0: styledEcho fgYellow, "(no models)"
      else: for m in ms: echo mlCtx.registry.describe(m)
      continue
    if trim == "\\info":
      echo "NimDB v" & Version & "  dataDir=" & eng.dataDir
      echo "Tables: " & $eng.catalog.allTables().len
      echo mlCtx.describeMLContext(); continue
    if handleMLCmd(eng, mlCtx, trim): continue
    buf &= trim & " "
    let rw = trim.splitWhitespace()[0].toUpperAscii()
    let ready = trim.endsWith(";") or
      rw in ["SELECT","INSERT","UPDATE","DELETE","CREATE","DROP",
             "BEGIN","COMMIT","ROLLBACK","EXPLAIN"]
    if ready:
      let sql = buf.strip().strip(chars = {';'})
      buf = ""
      let t0 = epochTime()
      try:
        let res = eng.execute(sql)
        styledEcho fgBlue, &"Time: {(epochTime()-t0)*1000:.2f} ms"
        printResult(res)
      except CatchableError as e:
        buf = ""; styledEcho fgRed, "Error: " & e.msg

proc runDemo(eng: Engine; mlCtx: MLContext) =
  echo "\n=== Relational ==="
  for sql in [
    "CREATE TABLE IF NOT EXISTS products (id INT4, name TEXT, price FLOAT8, qty INT4)",
    "INSERT INTO products VALUES (1,'Widget',9.99,100)",
    "INSERT INTO products VALUES (2,'Gadget',99.99,10)",
    "SELECT * FROM products ORDER BY price DESC",
    "SELECT count(*), avg(price) FROM products"]:
    echo "\n-> " & sql
    try: printResult(eng.execute(sql))
    except CatchableError as e: styledEcho fgRed, e.msg

  echo "\n=== Graph ==="
  let gs = mlCtx.graphStore
  let a = gs.addNode(@["Person"], @[("name", textVal("Alice"))])
  let b = gs.addNode(@["Person"], @[("name", textVal("Bob"))])
  let c = gs.addNode(@["Person"], @[("name", textVal("Charlie"))])
  discard gs.addEdge(a, b, "KNOWS"); discard gs.addEdge(b, c, "KNOWS")
  discard gs.addEdge(a, c, "KNOWS")
  echo "Nodes: " & $gs.nodeCount() & "  Edges: " & $gs.edgeCount()
  for (id, score) in topPageRank(gs, 3):
    echo "  " & $gs.getNode(id) & " pr=" & $score
  let (d, path) = shortestPath(gs, a, c)
  echo "Shortest A->C: " & path.mapIt($it).join("->") & " dist=" & $d

  echo "\n=== SIMD Benchmark ==="
  styledEcho fgCyan, &"Dot product: {benchDot(1_000_000, 10):.2f} GFLOPs"

  echo "\n=== Linear Regression (in-DB) ==="
  var X: seq[seq[float32]]; var y: seq[float32]
  var rng = initRand(42)
  for i in 1..200:
    let q = float32(i mod 50 + 1)
    X.add(@[q]); y.add(10.0'f32 * q + float32(rng.rand(20) - 10))
  let m = newLinearModel(1)
  m.fit(X, y, epochs = 15)
  styledEcho fgCyan, &"R2 = {m.score(X, y):.4f}  predict(25)={m.predict(@[25.0'f32]):.2f}"

proc main() =
  var dataDir = "./nimdb_data"; var port = 5433
  var runMode = "repl"; var doDemo = false
  for kind, key, val in initOptParser(commandLineParams()).getopt():
    case kind
    of cmdLongOption:
      case key
      of "data-dir": dataDir = val; of "port": port = parseInt(val)
      of "mode": runMode = val; of "demo": doDemo = true
      else: discard
    of cmdShortOption:
      case key
      of "d": dataDir = val; of "p": port = parseInt(val)
      else: discard
    else: discard
  createDir(dataDir)
  let eng = newEngine(dataDir)
  let mlCtx = newMLContext(dataDir)
  defer: eng.closeEngine()
  case runMode
  of "server":
    let srv = newServer(eng, port)
    echo Banner; waitFor srv.serve()
  of "demo": eng.runDemo(mlCtx)
  of "repl":
    if doDemo: eng.runDemo(mlCtx)
    eng.runRepl(mlCtx)
  else: echo "Use --mode=repl|server|demo"

when isMainModule: main()
