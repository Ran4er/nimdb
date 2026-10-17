import std/[net, asyncnet, asyncdispatch, strutils, sequtils, tables, options]
import ../storage/types
import ../catalog/schema
import ../catalog/catalog
import ../sql/executor
import ../ml/[tensor, vector_index, feature_store]
import ../engine/modes

import ../protocol/frame
import ../protocol/types

type
  ClientSession* = ref object
    conn*:     AsyncSocket
    engine*:   Engine

  Server* = ref object
    socket*:   AsyncSocket
    engine*:   Engine
    vecIdxs*:  Table[ObjId, HNSWIndex]
    featStore*: FeatureStore
    modeReg*:  ModeRegistry
    port*:     Port

proc newServer*(engine: Engine; port = 5433): Server =
  Server(
    engine:    engine,
    vecIdxs:   initTable[ObjId, HNSWIndex](),
    featStore: newFeatureStore(),
    modeReg:   newModeRegistry(),
    port:      Port(port)
  )

# ─── Result formatting ────────────────────────────────────────────────────

proc formatResultSet(rs: ResultSet): string =
  if rs.cols.len == 0: return ""
  var lines: seq[string]
  # Header
  lines.add(rs.cols.mapIt(it.name).join("\t"))
  lines.add(rs.cols.mapIt("-".repeat(it.name.len + 4)).join("\t"))
  # Rows
  for row in rs.rows:
    lines.add(row.mapIt($it).join("\t"))
  lines.add("(" & $rs.rows.len & " row" & (if rs.rows.len != 1: "s" else: "") & ")")
  lines.join("\n")

# ─── Сетевые хелперы для протокола ────────────────────────────────────────

proc sendFrame(conn: AsyncSocket; opcode: ServerOpcode; payloadMsg: string; reqId: uint64 = 0) {.async.} =
  let f = Frame(
    opcode: uint8(opcode),
    flags: 0,
    version: 1,
    requestId: reqId,
    payload: cast[seq[byte]](payloadMsg)
  )
  await writeFrame(conn, f)

proc sendOk(conn: AsyncSocket; msg: string; reqId: uint64 = 0) {.async.} =
  await sendFrame(conn, opNotice, msg, reqId)

proc sendErr(conn: AsyncSocket; msg: string; reqId: uint64 = 0) {.async.} =
  await sendFrame(conn, opError, msg, reqId)

# ─── Special command handlers ─────────────────────────────────────────────

proc handleVecInsert(srv: Server; conn: AsyncSocket;
                     args: seq[string]; reqId: uint64) {.async.} =
  if args.len < 3:
    await conn.sendErr("Usage: vecinsert <table> <id> <f1,f2,...>", reqId)
    return
  let tname = args[0]
  
  var extId = -1
  try:
    extId = parseInt(args[1])
  except ValueError:
    discard

  # Разворачиваем mapIt с try в безопасный цикл
  var fvals: seq[float32] = @[]
  for s in args[2].split(','):
    try:
      fvals.add(parseFloat(s.strip()).float32)
    except ValueError:
      fvals.add(0.0'f32)
      
  let vec = vectorF32(fvals)

  let entry = srv.engine.catalog.getTable(tname)
  let tid   = entry.schema.tableId
  
  if tid notin srv.vecIdxs:
    let cfg = srv.modeReg.getMode(tid)
    let metricVal = case cfg.vecMetric
      of "l2": dmL2
      of "dot": dmDot
      else: dmCosine
      
    srv.vecIdxs[tid] = newHNSWIndex(
      metric = metricVal,
      M = cfg.hnswM, 
      efC = cfg.hnswEfC, 
      efS = cfg.hnswEfS
    )
    
  srv.vecIdxs[tid].insert(vec, int64(extId))
  await conn.sendOk("Inserted vector id=" & $extId & " dim=" & $vec.len, reqId)

proc handleVecSearch(srv: Server; conn: AsyncSocket;
                     args: seq[string]; reqId: uint64) {.async.} =
  if args.len < 2:
    await conn.sendErr("Usage: vecsearch <table> <f1,...> k=<k>", reqId)
    return
  let tname = args[0]
  var k     = 10
  var fPart = args[1]
  
  if args.len >= 3 and args[2].startsWith("k="):
    try:
      k = parseInt(args[2][2..^1])
    except ValueError:
      k = 10

  # Разворачиваем mapIt с try в безопасный цикл
  var fvals: seq[float32] = @[]
  for s in fPart.split(','):
    try:
      fvals.add(parseFloat(s.strip()).float32)
    except ValueError:
      fvals.add(0.0'f32)
      
  let query = vectorF32(fvals)

  let entry = srv.engine.catalog.getTable(tname)
  let tid   = entry.schema.tableId
  
  if tid notin srv.vecIdxs:
    await conn.sendErr("No vector index for table: " & tname, reqId)
    return
    
  let results = srv.vecIdxs[tid].knnSearch(query, k)
  var lines = "id\tdistance\n"
  for r in results:
    lines &= $r.extId & "\t" & $r.distance & "\n"
  lines &= "(" & $results.len & " neighbours)"
  await conn.sendFrame(opResultDone, lines, reqId)

proc handleStats(srv: Server; conn: AsyncSocket;
                 args: seq[string]; reqId: uint64) {.async.} =
  if args.len < 2:
    await conn.sendErr("Usage: stats <table> <col>", reqId)
    return
  await conn.sendOk("Column stats: (run materialise first to populate OLAP store)", reqId)

proc handleInfo(srv: Server; conn: AsyncSocket; reqId: uint64) {.async.} =
  let msg = """NimDB v0.1.0
Modes: OLTP | OLAP | VECTOR | HYBRID
Storage: 8 KB heap pages, WAL, LRU buffer pool
Indexes: B+ Tree (OLTP), HNSW ANN (VECTOR)
ML: Tensor storage, feature materialisation, train/test split
Distribution: PA/EL, consistent hashing, gossip failure detection
"""
  await conn.sendOk(msg, reqId)

proc handleMode(srv: Server; conn: AsyncSocket;
                args: seq[string]; reqId: uint64) {.async.} =
  if args.len < 2:
    await conn.sendErr("Usage: mode <table> <oltp|olap|vector|hybrid>", reqId)
    return
  let tname = args[0]
  
  var mode = modeOLTP
  try:
    mode = parseMode(args[1])
  except CatchableError:
    discard
    
  let entry = srv.engine.catalog.getTable(tname)
  var cfg   = defaultConfig(mode)
  srv.modeReg.setMode(entry.schema.tableId, cfg)
  await conn.sendOk("Table '" & tname & "' mode → " & $mode & "\n" & modeDescription(mode), reqId)

# ─── Client handler ───────────────────────────────────────────────────────

proc handleClient(srv: Server; conn: AsyncSocket) {.async.} =
  await conn.sendFrame(opHelloAck, "NimDB 0.1.0 Binary Protocol Ready")
  
  while true:
    # ИСПРАВЛЕНИЕ ЗДЕСЬ: Разделяем объявление переменной и блок try/except
    var f: Frame
    try: 
      f = await readFrame(conn)
    except IOError, EOFError:
      break
      
    let reqId = f.requestId
    let opOpt = toClientOpcode(f.opcode)
    
    if opOpt.isNone():
      await conn.sendErr("Unknown client opcode: " & $f.opcode, reqId)
      continue
      
    let op = opOpt.get()
    let payloadStr = cast[string](f.payload).strip()

    try:
      case op
      of opQuery, opExecute:
        let res = srv.engine.execute(payloadStr)
        var outMsg = ""
        if res.resultSet.rows.len > 0 or res.resultSet.cols.len > 0:
          outMsg = formatResultSet(res.resultSet)
        else:
          outMsg = res.message
        await conn.sendFrame(opResultDone, outMsg, reqId)

      of opVectorInsert:
        let args = payloadStr.splitWhitespace()
        await srv.handleVecInsert(conn, args, reqId)

      of opVectorSearch:
        let args = payloadStr.splitWhitespace()
        await srv.handleVecSearch(conn, args, reqId)

      of opAdmin:
        let args = payloadStr.splitWhitespace()
        if args.len > 0:
          let cmd = args[0].toLowerAscii()
          let cmdArgs = args[1..^1]
          case cmd
          of "stats": await srv.handleStats(conn, cmdArgs, reqId)
          of "info":  await srv.handleInfo(conn, reqId)
          of "mode":  await srv.handleMode(conn, cmdArgs, reqId)
          else: await conn.sendErr("Unknown admin command: " & cmd, reqId)
        else:
          await conn.sendErr("Empty admin command", reqId)

      of opPing:
        await conn.sendFrame(opPong, "PONG", reqId)

      of opClose:
        break 

      else:
        await conn.sendErr("Opcode not yet implemented: " & $op, reqId)

    except CatchableError as e:
      await conn.sendErr("Server execution error: " & e.msg, reqId)

  conn.close()

proc serve*(srv: Server) {.async.} =
  srv.socket = newAsyncSocket()
  srv.socket.setSockOpt(OptReuseAddr, true)
  srv.socket.bindAddr(srv.port)
  srv.socket.listen()
  echo "NimDB Binary Server listening on port ", int(srv.port)
  while true:
    let conn = await srv.socket.accept()
    asyncCheck srv.handleClient(conn)
