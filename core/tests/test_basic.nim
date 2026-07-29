## test_basic.nim — Integration tests for NimDB

import std/[unittest, os, strutils, sequtils]
import ../src/storage/[types, page, wal, buffer_pool, heap_file]
import ../src/catalog/[schema, catalog]
import ../src/sql/executor
import ../src/ml/[tensor, vector_index, feature_store]
import ../src/engine/modes
import ../src/distributed/node

const TestDir = "/tmp/nimdb_test_" & $getCurrentProcessId()

suite "Page operations":
  test "init and insert":
    var pg: Page
    pg.initPage(PageId(0))
    check pg.hdr().pageId == PageId(0)
    check pg.hdr().slotCount == 0

    let data = [1'u8, 2, 3, 4, 5]
    let si = pg.insertTuple(data)
    check si == 0
    check pg.hdr().slotCount == 1

    var buf: seq[byte]
    check pg.getTuple(0'u16, buf)
    check buf == @[1'u8, 2, 3, 4, 5]

  test "delete and update":
    var pg: Page
    pg.initPage(PageId(1))
    let si = pg.insertTuple([10'u8, 20, 30])
    check pg.deleteTuple(uint16(si))
    var buf: seq[byte]
    check not pg.getTuple(uint16(si), buf)

suite "WAL":
  setup: createDir(TestDir)
  teardown: removeDir(TestDir)

  test "write and replay":
    let w = openWAL(TestDir / "test.wal")
    let txn = TxnId(1)
    discard w.logBegin(txn)
    let lsn = w.logInsert(txn, InvalidLSN, ObjId(1), PageId(0), 0, [42'u8, 43])
    discard w.logCommit(txn, lsn)
    w.closeWAL()

    let w2 = openWAL(TestDir / "test.wal")
    var count = 0
    var foundInsert = false
    w2.replay(proc(rec: WalRecord) =
      inc count
      if rec.recType == walInsert: foundInsert = true)
    check count >= 3
    check foundInsert
    w2.closeWAL()

suite "Schema encode/decode":
  test "round-trip basic types":
    let row: Row = @[
      intVal(42'i32),
      textVal("hello"),
      floatVal(3.14),
      boolVal(true),
      nullVal()
    ]
    let enc = encodeTuple(row)
    let dec = decodeTuple(enc, 5)
    check dec[0] == intVal(42'i32)
    check dec[1] == textVal("hello")
    check dec[3] == boolVal(true)
    check dec[4] == nullVal()

suite "SQL Engine":
  setup:
    createDir(TestDir)
  teardown:
    removeDir(TestDir)

  test "CREATE TABLE and INSERT and SELECT":
    let eng = newEngine(TestDir)
    defer: eng.closeEngine()

    discard eng.execute("CREATE TABLE t (id INT4, name TEXT, val FLOAT8)")
    discard eng.execute("INSERT INTO t VALUES (1, 'Alice', 3.14)")
    discard eng.execute("INSERT INTO t VALUES (2, 'Bob', 2.72)")
    discard eng.execute("INSERT INTO t VALUES (3, 'Charlie', 1.41)")

    let res = eng.execute("SELECT * FROM t")
    check res.resultSet.rows.len == 3

  test "WHERE filter":
    let eng = newEngine(TestDir)
    defer: eng.closeEngine()
    discard eng.execute("CREATE TABLE nums (x INT4, y FLOAT8)")
    for i in 1..10:
      discard eng.execute("INSERT INTO nums VALUES (" & $i & ", " & $(float(i)*1.5) & ")")
    let res = eng.execute("SELECT x FROM nums WHERE x > 5")
    check res.resultSet.rows.len == 5

  test "UPDATE and DELETE":
    let eng = newEngine(TestDir)
    defer: eng.closeEngine()
    discard eng.execute("CREATE TABLE scores (id INT4, score FLOAT8)")
    discard eng.execute("INSERT INTO scores VALUES (1, 0.5)")
    discard eng.execute("INSERT INTO scores VALUES (2, 0.9)")
    discard eng.execute("UPDATE scores SET score = 1.0 WHERE id = 1")
    discard eng.execute("DELETE FROM scores WHERE id = 2")
    let res = eng.execute("SELECT * FROM scores")
    check res.resultSet.rows.len == 1
    check $res.resultSet.rows[0][1] == "1.0"

  test "ORDER BY and LIMIT":
    let eng = newEngine(TestDir)
    defer: eng.closeEngine()
    discard eng.execute("CREATE TABLE items (id INT4, v FLOAT8)")
    for i in [3, 1, 4, 1, 5, 9, 2, 6]:
      discard eng.execute("INSERT INTO items VALUES (" & $i & ", " & $float(i) & ")")
    let res = eng.execute("SELECT id FROM items ORDER BY id ASC LIMIT 3")
    check res.resultSet.rows.len == 3

suite "Tensor and Vector Index":
  test "tensor basics":
    let t = vectorF32([1.0'f32, 0.0, 0.0])
    check t.len == 3
    check abs(t.l2norm() - 1.0'f32) < 1e-5'f32

  test "cosine similarity":
    let a = vectorF32([1.0'f32, 0.0, 0.0])
    let b = vectorF32([1.0'f32, 0.0, 0.0])
    let c = vectorF32([0.0'f32, 1.0, 0.0])
    check abs(cosineSimF32(a, b) - 1.0'f32) < 1e-5'f32
    check abs(cosineSimF32(a, c)) < 1e-5'f32

  test "tensor encode/decode":
    let t = vectorF32([3.14'f32, 2.72, 1.41])
    let enc = encodeTensor(t)
    let dec = decodeTensor(enc)
    check dec.len == 3
    check abs(dec.getF32(0) - 3.14'f32) < 1e-4'f32

  test "HNSW insert and search":
    let idx = newHNSWIndex(metric = dmCosine)
    for i in 0..99:
      let v = vectorF32([float32(i), float32(i mod 10), float32(i mod 5)])
      idx.insert(v, int64(i))
    check idx.nodes.len == 100

    let query = vectorF32([50.0'f32, 0.0, 0.0])
    let results = idx.knnSearch(query, 5)
    check results.len == 5

suite "Consistent Hashing":
  test "ring node assignment":
    let ring = newHashRing()
    ring.addNode("node1:5433")
    ring.addNode("node2:5433")
    ring.addNode("node3:5433")
    let n1 = ring.getNode("key1")
    let n2 = ring.getNode("key2")
    check n1.len > 0
    check n2.len > 0

  test "replica nodes":
    let ring = newHashRing()
    ring.addNode("n1:5433"); ring.addNode("n2:5433"); ring.addNode("n3:5433")
    let replicas = ring.getNodes("mykey", 3)
    check replicas.len == 3
    check replicas[0] != replicas[1]

suite "Engine Modes":
  test "mode config":
    let cfg = defaultConfig(modeVECTOR)
    check cfg.mode == modeVECTOR
    check cfg.supportsVectorSearch()
    check not cfg.supportsColumnarScan()

  test "OLAP mode config":
    let cfg = defaultConfig(modeOLAP)
    check cfg.supportsColumnarScan()
    check not cfg.supportsTransactions()

when isMainModule:
  echo "Running NimDB test suite..."
