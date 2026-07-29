## server.nim — TCP server
##
## Simple line-protocol (like redis-inline):
##   Client sends: SQL statement or special command, terminated by newline
##   Server replies: result lines, terminated by ".\n" (success) or "!error\n"
##
## Special commands (not SQL):
##   \mode <table> <oltp|olap|vector|hybrid>   — change table mode
##   \vecinsert <table> <id> <f1,f2,...>        — insert vector
##   \vecsearch <table> <f1,f2,...> k=<k>       — KNN search
##   \materialise <featureGroup>                — run feature materialisation
##   \stats <table> <col>                       — column statistics
##   \info                                      — server info

import std/[net, asyncnet, asyncdispatch, strutils, sequtils, tables]
import ../storage/types
import ../catalog/schema
import ../sql/executor
import ../ml/[tensor, vector_index, feature_store]
import ../engine/modes

type
  ClientSession* = ref object
    conn*:     AsyncSocket
    engine*:   Engine
    bufIn*:    string

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

proc sendOk(conn: AsyncSocket; msg: string) {.async.} =
  await conn.send(msg & "\n.\n")

proc sendErr(conn: AsyncSocket; msg: string) {.async.} =
  await conn.send("ERROR: " & msg & "\n!\n")

# ─── Special command handlers ─────────────────────────────────────────────

proc handleVecInsert(srv: Server; conn: AsyncSocket;
                     args: seq[string]) {.async.} =
  ## \vecinsert <table> <extId> <f1,f2,...,fn>
  if args.len < 3:
    await conn.sendErr("Usage: \\vecinsert <table> <id> <f1,f2,...>")
    return
  let tname = args[0]
  let extId = try: parseInt(args[1]) except: -1
  let fvals = args[2].split(',').mapIt(
    try: parseFloat(it.strip()) except: 0.0)
  let vec = vectorF32(fvals.mapIt(float32(it)))

  let entry = srv.engine.catalog.getTable(tname)
  let tid   = entry.schema.tableId
  if tid notin srv.vecIdxs:
    let cfg = srv.modeReg.getMode(tid)
    srv.vecIdxs[tid] = newHNSWIndex(
      metric = case cfg.vecMetric
               of "l2": dmL2; of "dot": dmDot; else: dmCosine,
      M = cfg.hnswM, efC = cfg.hnswEfC, efS = cfg.hnswEfS)
  srv.vecIdxs[tid].insert(vec, int64(extId))
  await conn.sendOk("Inserted vector id=" & $extId & " dim=" & $vec.len)

proc handleVecSearch(srv: Server; conn: AsyncSocket;
                     args: seq[string]) {.async.} =
  ## \vecsearch <table> <f1,f2,...> k=<k>
  if args.len < 2:
    await conn.sendErr("Usage: \\vecsearch <table> <f1,...> k=<k>")
    return
  let tname = args[0]
  var k     = 10
  var fPart = args[1]
  if args.len >= 3 and args[2].startsWith("k="):
    k = try: parseInt(args[2][2..^1]) except: 10
  let fvals = fPart.split(',').mapIt(
    try: parseFloat(it.strip()) except: 0.0)
  let query = vectorF32(fvals.mapIt(float32(it)))

  let entry = srv.engine.catalog.getTable(tname)
  let tid   = entry.schema.tableId
  if tid notin srv.vecIdxs:
    await conn.sendErr("No vector index for table: " & tname)
    return
  let results = srv.vecIdxs[tid].knnSearch(query, k)
  var lines = "id\tdistance\n"
  for r in results:
    lines &= $r.extId & "\t" & $r.distance & "\n"
  lines &= "(" & $results.len & " neighbours)"
  await conn.sendOk(lines)

proc handleStats(srv: Server; conn: AsyncSocket;
                 args: seq[string]) {.async.} =
  if args.len < 2:
    await conn.sendErr("Usage: \\stats <table> <col>")
    return
  # Would need to scan columnar store — stub for now
  await conn.sendOk("Column stats: (run \\materialise first to populate OLAP store)")

proc handleInfo(srv: Server; conn: AsyncSocket) {.async.} =
  let msg = """NimDB v0.1.0
Modes: OLTP | OLAP | VECTOR | HYBRID
Storage: 8 KB heap pages, WAL, LRU buffer pool
Indexes: B+ Tree (OLTP), HNSW ANN (VECTOR)
ML: Tensor storage, feature materialisation, train/test split
Distribution: PA/EL, consistent hashing, gossip failure detection
"""
  await conn.sendOk(msg)

proc handleMode(srv: Server; conn: AsyncSocket;
                args: seq[string]) {.async.} =
  if args.len < 2:
    await conn.sendErr("Usage: \\mode <table> <oltp|olap|vector|hybrid>")
    return
  let tname = args[0]
  let mode  = try: parseMode(args[1]) except: modeOLTP
  let entry = srv.engine.catalog.getTable(tname)
  var cfg   = defaultConfig(mode)
  srv.modeReg.setMode(entry.schema.tableId, cfg)
  await conn.sendOk("Table '" & tname & "' mode → " & $mode &
                    "\n" & modeDescription(mode))

# ─── Client handler ───────────────────────────────────────────────────────

proc handleClient(srv: Server; conn: AsyncSocket) {.async.} =
  await conn.send("NimDB 0.1.0 ready. Type SQL or \\help\n")
  var buf = ""
  while true:
    let line = try: await conn.recvLine() except: ""
    if line.len == 0: break
    let trimmed = line.strip()
    if trimmed.len == 0: continue

    if trimmed.startsWith("\\"):
      let parts = trimmed[1..^1].splitWhitespace()
      if parts.len == 0: continue
      let cmd = parts[0].toLowerAscii()
      let args = parts[1..^1]
      case cmd
      of "vecinsert":   await srv.handleVecInsert(conn, args)
      of "vecsearch":   await srv.handleVecSearch(conn, args)
      of "stats":       await srv.handleStats(conn, args)
      of "info":        await srv.handleInfo(conn)
      of "mode":        await srv.handleMode(conn, args)
      of "help":
        await conn.sendOk(
          "Commands:\n" &
          "  SQL statements (SELECT/INSERT/UPDATE/DELETE/CREATE/DROP)\n" &
          "  \\mode <table> <oltp|olap|vector|hybrid>\n" &
          "  \\vecinsert <table> <id> <f1,f2,...>\n" &
          "  \\vecsearch <table> <f1,...> k=<k>\n" &
          "  \\stats <table> <col>\n" &
          "  \\info\n" &
          "  \\quit")
      of "quit", "exit": break
      else: await conn.sendErr("Unknown command: " & cmd)
    else:
      # SQL statement — may span multiple lines until ';'
      buf &= trimmed & " "
      if not trimmed.endsWith(";") and not trimmed.endsWith("\\"):
        # Keep accumulating
        discard
      try:
        let res = srv.engine.execute(buf.strip())
        buf = ""
        var out = ""
        if res.resultSet.rows.len > 0 or res.resultSet.cols.len > 0:
          out = formatResultSet(res.resultSet)
        else:
          out = res.message
        await conn.sendOk(out)
      except CatchableError as e:
        buf = ""
        await conn.sendErr(e.msg)

  conn.close()

proc serve*(srv: Server) {.async.} =
  srv.socket = newAsyncSocket()
  srv.socket.setSockOpt(OptReuseAddr, true)
  srv.socket.bindAddr(srv.port)
  srv.socket.listen()
  echo "NimDB listening on port ", int(srv.port)
  while true:
    let conn = await srv.socket.accept()
    asyncCheck srv.handleClient(conn)
