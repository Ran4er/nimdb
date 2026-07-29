## executor.nim — Query executor
##
## Evaluates SQL AST statements against the storage layer.
## Returns ResultSet for queries, or affected row count for DML.

import std/[tables, strutils, math, sequtils, algorithm]
import ../storage/[types, heap_file]
import ../catalog/[schema, catalog]
import ../transaction/[txn_manager]
import ../index/btree
import ast, parser

type
  ResultColumn* = object
    name*: string
    kind*: ColKind

  ResultSet* = object
    cols*: seq[ResultColumn]
    rows*: seq[Row]

  ExecResult* = object
    resultSet*:   ResultSet
    rowsAffected*: int
    message*:      string

  ## Engine holds all runtime state
  Engine* = ref object
    catalog*:    Catalog
    wal*:        WAL
    bp*:         BufferPool
    txnMgr*:     TxnManager
    heaps*:      Table[ObjId, HeapFile]   ## tableId → heap
    indexes*:    Table[string, BTree]      ## indexName → btree
    dataDir*:    string

# ─── Engine lifecycle ─────────────────────────────────────────────────────

proc newEngine*(dataDir: string): Engine =
  createDir(dataDir)
  let w   = openWAL(dataDir / "nimdb.wal")
  let bp  = newBufferPool(w)
  let cat = newCatalog(dataDir)
  result  = Engine(catalog: cat, wal: w, bp: bp,
                   txnMgr: newTxnManager(w),
                   dataDir: dataDir)
  # Re-open heap files for all catalog tables
  for e in cat.allTables():
    let hf = openHeapFile(e.schema.tableId, e.dataPath, bp, w)
    result.heaps[e.schema.tableId] = hf

proc getHeap(eng: Engine; tableId: ObjId; path: string): HeapFile =
  if tableId in eng.heaps: return eng.heaps[tableId]
  let hf = openHeapFile(tableId, path, eng.bp, eng.wal)
  eng.heaps[tableId] = hf
  hf

proc closeEngine*(eng: Engine) =
  eng.bp.flushAll()
  eng.wal.closeWAL()

# ─── Expression evaluation ────────────────────────────────────────────────

proc evalExpr*(e: Expr; schema: TableSchema; row: Row): Value

proc applyLike(text, pat: string): bool =
  ## Simple LIKE with % and _ wildcards.
  var si, pi = 0
  var starIdx = -1; var matchIdx = 0
  while si < text.len:
    if pi < pat.len and (pat[pi] == '_' or pat[pi] == text[si]):
      inc si; inc pi
    elif pi < pat.len and pat[pi] == '%':
      starIdx = pi; matchIdx = si; inc pi
    elif starIdx >= 0:
      pi = starIdx + 1; inc matchIdx; si = matchIdx
    else: return false
  while pi < pat.len and pat[pi] == '%': inc pi
  pi == pat.len

proc evalExpr*(e: Expr; schema: TableSchema; row: Row): Value =
  if e.isNil: return boolVal(true)
  case e.kind
  of ekLit:
    return e.lit
  of ekStar:
    return boolVal(true)
  of ekCol:
    let name = e.col.toLowerAscii()
    let idx  = schema.colIndex(name)
    if idx < 0:
      raise newException(SQLError, "Unknown column: " & e.col)
    if idx < row.len: row[idx]
    else: nullVal()
  of ekBinOp:
    let lv = evalExpr(e.left, schema, row)
    # Short-circuit AND/OR
    if e.op == boAnd:
      if lv.kind == ckBool and not lv.b: return boolVal(false)
      let rv = evalExpr(e.right, schema, row)
      return boolVal(lv.kind == ckBool and lv.b and rv.kind == ckBool and rv.b)
    if e.op == boOr:
      if lv.kind == ckBool and lv.b: return boolVal(true)
      let rv = evalExpr(e.right, schema, row)
      return boolVal((lv.kind == ckBool and lv.b) or (rv.kind == ckBool and rv.b))
    let rv = evalExpr(e.right, schema, row)
    case e.op
    of boEq:   return boolVal(lv == rv)
    of boNe:   return boolVal(lv != rv)
    of boLt:   return boolVal(lv < rv)
    of boLe:   return boolVal(lv <= rv)
    of boGt:   return boolVal(rv < lv)
    of boGe:   return boolVal(rv <= lv)
    of boAdd:
      if lv.isNumeric and rv.isNumeric:
        if lv.kind == ckFloat8 or rv.kind == ckFloat8:
          return floatVal(lv.toFloat() + rv.toFloat())
        return int8Val(lv.toInt64() + rv.toInt64())
      if lv.kind == ckText and rv.kind == ckText:
        return textVal(lv.text & rv.text)
    of boSub:
      if lv.isNumeric and rv.isNumeric:
        if lv.kind == ckFloat8 or rv.kind == ckFloat8:
          return floatVal(lv.toFloat() - rv.toFloat())
        return int8Val(lv.toInt64() - rv.toInt64())
    of boMul:
      if lv.isNumeric and rv.isNumeric:
        if lv.kind == ckFloat8 or rv.kind == ckFloat8:
          return floatVal(lv.toFloat() * rv.toFloat())
        return int8Val(lv.toInt64() * rv.toInt64())
    of boDiv:
      if lv.isNumeric and rv.isNumeric:
        let d = rv.toFloat()
        if d == 0.0: raise newException(SQLError, "Division by zero")
        if lv.kind == ckFloat8 or rv.kind == ckFloat8:
          return floatVal(lv.toFloat() / d)
        return int8Val(lv.toInt64() div rv.toInt64())
    of boMod:
      if lv.isNumeric and rv.isNumeric:
        return int8Val(lv.toInt64() mod rv.toInt64())
    of boLike:
      if lv.kind == ckText and rv.kind == ckText:
        return boolVal(applyLike(lv.text, rv.text))
    else: discard
    return nullVal()
  of ekUnOp:
    case e.uop
    of uoNeg:
      let v = evalExpr(e.operand, schema, row)
      if v.kind == ckInt4:   return intVal(-v.i4)
      if v.kind == ckInt8:   return int8Val(-v.i8)
      if v.kind == ckFloat8: return floatVal(-v.f8)
    of uoNot:
      let v = evalExpr(e.operand, schema, row)
      if v.kind == ckBool: return boolVal(not v.b)
    of uoIsNull:
      let v = evalExpr(e.operand, schema, row)
      return boolVal(v.kind == ckNull)
    of uoIsNotNull:
      let v = evalExpr(e.operand, schema, row)
      return boolVal(v.kind != ckNull)
    return nullVal()
  of ekFunc:
    case e.fname
    of "count":
      return int8Val(1)   # handled specially in aggregation
    of "upper":
      let v = evalExpr(e.fargs[0], schema, row)
      if v.kind == ckText: return textVal(v.text.toUpperAscii())
    of "lower":
      let v = evalExpr(e.fargs[0], schema, row)
      if v.kind == ckText: return textVal(v.text.toLowerAscii())
    of "length", "len":
      let v = evalExpr(e.fargs[0], schema, row)
      if v.kind == ckText: return intVal(int32(v.text.len))
    of "abs":
      let v = evalExpr(e.fargs[0], schema, row)
      if v.kind == ckFloat8: return floatVal(abs(v.f8))
      if v.kind in {ckInt4, ckInt8}: return int8Val(abs(v.toInt64()))
    of "coalesce":
      for arg in e.fargs:
        let v = evalExpr(arg, schema, row)
        if v.kind != ckNull: return v
      return nullVal()
    of "now":
      return textVal($now())
    else: discard
    return nullVal()
  of ekCast:
    let v = evalExpr(e.castExpr, schema, row)
    case e.castTo
    of ckInt4:   return intVal(int32(v.toInt64()))
    of ckInt8:   return int8Val(v.toInt64())
    of ckFloat8: return floatVal(v.toFloat())
    of ckText:   return textVal($v)
    of ckBool:
      return boolVal(v.kind == ckBool and v.b or
                     v.kind == ckInt4 and v.i4 != 0 or
                     v.kind == ckInt8 and v.i8 != 0)
    else: return v

proc matchesWhere(e: Expr; schema: TableSchema; row: Row): bool =
  if e.isNil: return true
  let v = evalExpr(e, schema, row)
  v.kind == ckBool and v.b

# ─── Schema helpers ───────────────────────────────────────────────────────

proc buildRow(schema: TableSchema; colExprs: seq[Expr]; row: Row): Row =
  result = newSeq[Value](colExprs.len)
  for i, e in colExprs:
    result[i] = evalExpr(e, schema, row)

proc projectRow(schema: TableSchema; items: seq[SelectItem]; row: Row): Row =
  result = newSeq[Value](items.len)
  for i, si in items:
    result[i] = evalExpr(si.expr, schema, row)

proc resultCols(schema: TableSchema; items: seq[SelectItem]): seq[ResultColumn] =
  for i, si in items:
    var name = si.alias
    if name.len == 0:
      case si.expr.kind
      of ekCol:  name = si.expr.col
      of ekStar: name = "*"
      of ekFunc: name = si.expr.fname
      else:      name = "col" & $i
    let kind = case si.expr.kind
      of ekLit: si.expr.lit.kind
      of ekCol:
        let idx = schema.colIndex(si.expr.col)
        if idx >= 0: schema.cols[idx].kind else: ckText
      else: ckText
    result.add(ResultColumn(name: name, kind: kind))

# ─── SELECT execution ─────────────────────────────────────────────────────

proc execSelect(eng: Engine; s: Stmt; txnId: TxnId): ExecResult =
  let entry  = eng.catalog.getTable(s.fromTable)
  let schema = entry.schema
  let hf     = eng.getHeap(schema.tableId, entry.dataPath)

  # Expand * in select items
  var items = s.selItems
  var expandedItems: seq[SelectItem]
  for si in items:
    if si.expr.kind == ekStar:
      for col in schema.cols:
        expandedItems.add(SelectItem(
          expr: Expr(kind: ekCol, col: col.name), alias: ""))
    else:
      expandedItems.add(si)
  items = expandedItems

  var rows: seq[Row]

  hf.scan(proc(tid: TupleId; data: seq[byte]): bool =
    let row = decodeTuple(data, schema.cols.len)
    if matchesWhere(s.whereExpr, schema, row):
      rows.add(row)
    true
  )

  # Apply DISTINCT
  if s.distinct:
    var seen: seq[Row]
    var unique: seq[Row]
    for r in rows:
      if r notin seen: seen.add(r); unique.add(r)
    rows = unique

  # Aggregate (GROUP BY / aggregate functions)
  # Simple aggregation without GROUP BY
  let hasAgg = items.anyIt(it.expr.kind == ekFunc and
                it.expr.fname in ["count", "sum", "avg", "min", "max"])
  if hasAgg and s.groupBy.len == 0:
    var aggRow = newSeq[Value](items.len)
    var counts = newSeq[int](items.len)
    for row in rows:
      for i, si in items:
        if si.expr.kind == ekFunc:
          case si.expr.fname
          of "count": aggRow[i] = int8Val(int64(rows.len))
          of "sum":
            let v = evalExpr(si.expr.fargs[0], schema, row)
            if v.isNumeric:
              if aggRow[i].kind == ckNull: aggRow[i] = v
              else: aggRow[i] = int8Val(aggRow[i].toInt64() + v.toInt64())
          of "avg":
            let v = evalExpr(si.expr.fargs[0], schema, row)
            if v.isNumeric:
              aggRow[i] = floatVal(
                (aggRow[i].toFloat() * float64(counts[i]) + v.toFloat()) /
                float64(counts[i] + 1))
            inc counts[i]
          of "min":
            let v = evalExpr(si.expr.fargs[0], schema, row)
            if aggRow[i].kind == ckNull or v < aggRow[i]: aggRow[i] = v
          of "max":
            let v = evalExpr(si.expr.fargs[0], schema, row)
            if aggRow[i].kind == ckNull or aggRow[i] < v: aggRow[i] = v
          else: discard
        elif aggRow[i].kind == ckNull:
          aggRow[i] = evalExpr(si.expr, schema, row)
    rows = if rows.len > 0: @[aggRow] else: @[]
  else:
    # Project
    var projected: seq[Row]
    for row in rows:
      projected.add(projectRow(schema, items, row))
    rows = projected

  # ORDER BY
  if s.orderBy.len > 0:
    let ob = s.orderBy
    rows.sort(proc(a, b: Row): int =
      for o in ob:
        let ai = if o.expr.kind == ekCol:
                   schema.colIndex(o.expr.col)
                 else: -1
        let av = if ai >= 0 and ai < a.len: a[ai] else: nullVal()
        let bv = if ai >= 0 and ai < b.len: b[ai] else: nullVal()
        var cmp = if av < bv: -1 elif bv < av: 1 else: 0
        if o.dir == odDesc: cmp = -cmp
        if cmp != 0: return cmp
      0
    )

  # OFFSET / LIMIT
  if s.offsetVal > 0:
    rows = if s.offsetVal < rows.len: rows[s.offsetVal..^1] else: @[]
  if s.limitVal >= 0 and rows.len > s.limitVal:
    rows.setLen(s.limitVal)

  ExecResult(resultSet: ResultSet(cols: resultCols(schema, items), rows: rows),
             rowsAffected: rows.len)

# ─── INSERT execution ─────────────────────────────────────────────────────

proc execInsert(eng: Engine; s: Stmt; txnId: TxnId; prevLsn: var LSN): ExecResult =
  let entry  = eng.catalog.getTable(s.insTable)
  let schema = entry.schema
  let hf     = eng.getHeap(schema.tableId, entry.dataPath)

  # Map declared columns to schema indices
  var colMap: seq[int]
  if s.insCols.len == 0:
    colMap = toSeq(0 ..< schema.cols.len)
  else:
    for cn in s.insCols:
      let idx = schema.colIndex(cn)
      if idx < 0: raise newException(SQLError, "Unknown column: " & cn)
      colMap.add(idx)

  var count = 0
  for valExprs in s.insVals:
    var row = newSeq[Value](schema.cols.len)
    for i, e in valExprs:
      if i >= colMap.len: break
      row[colMap[i]] = evalExpr(e, schema, row)
    # NULL check
    for i, c in schema.cols:
      if c.notNull and row[i].kind == ckNull:
        raise newException(SQLError, "NOT NULL violation on column: " & c.name)
    let encoded = encodeTuple(row)
    discard hf.insert(encoded, txnId, prevLsn)
    inc count

  ExecResult(rowsAffected: count, message: "INSERT " & $count)

# ─── UPDATE execution ─────────────────────────────────────────────────────

proc execUpdate(eng: Engine; s: Stmt; txnId: TxnId; prevLsn: var LSN): ExecResult =
  let entry  = eng.catalog.getTable(s.updTable)
  let schema = entry.schema
  let hf     = eng.getHeap(schema.tableId, entry.dataPath)

  var toUpdate: seq[(TupleId, Row)]
  hf.scan(proc(tid: TupleId; data: seq[byte]): bool =
    let row = decodeTuple(data, schema.cols.len)
    if matchesWhere(s.updWhere, schema, row):
      var newRow = row
      for (colName, expr) in s.updSets:
        let idx = schema.colIndex(colName)
        if idx < 0: raise newException(SQLError, "Unknown column: " & colName)
        newRow[idx] = evalExpr(expr, schema, row)
      toUpdate.add((tid, newRow))
    true
  )

  var count = 0
  for (tid, newRow) in toUpdate:
    let encoded = encodeTuple(newRow)
    if hf.update(tid, encoded, txnId, prevLsn): inc count

  ExecResult(rowsAffected: count, message: "UPDATE " & $count)

# ─── DELETE execution ─────────────────────────────────────────────────────

proc execDelete(eng: Engine; s: Stmt; txnId: TxnId; prevLsn: var LSN): ExecResult =
  let entry  = eng.catalog.getTable(s.delTable)
  let schema = entry.schema
  let hf     = eng.getHeap(schema.tableId, entry.dataPath)

  var toDelete: seq[TupleId]
  hf.scan(proc(tid: TupleId; data: seq[byte]): bool =
    let row = decodeTuple(data, schema.cols.len)
    if matchesWhere(s.delWhere, schema, row):
      toDelete.add(tid)
    true
  )

  var count = 0
  for tid in toDelete:
    if hf.delete(tid, txnId, prevLsn): inc count

  ExecResult(rowsAffected: count, message: "DELETE " & $count)

# ─── DDL execution ────────────────────────────────────────────────────────

proc execCreateTable(eng: Engine; s: Stmt; txnId: TxnId): ExecResult =
  if eng.catalog.tableExists(s.ctName):
    if s.ctIfNotExists:
      return ExecResult(message: "Table already exists (skipped)")
    raise newException(CatalogError, "Table already exists: " & s.ctName)

  let tid = eng.catalog.allocObjId()
  let schema = TableSchema(
    name: s.ctName, tableId: tid, cols: s.ctCols)
  let dataPath = eng.dataDir / s.ctName & ".hdb"
  eng.catalog.createTable(schema, dataPath)
  let hf = openHeapFile(tid, dataPath, eng.bp, eng.wal)
  eng.heaps[tid] = hf

  ExecResult(message: "CREATE TABLE")

proc execDropTable(eng: Engine; s: Stmt; txnId: TxnId): ExecResult =
  if not eng.catalog.tableExists(s.dtName):
    if s.dtIfExists: return ExecResult(message: "Table not found (skipped)")
    raise newException(CatalogError, "Table not found: " & s.dtName)

  let entry = eng.catalog.dropTable(s.dtName)
  eng.bp.invalidate(entry.schema.tableId)
  if entry.schema.tableId in eng.heaps:
    eng.heaps[entry.schema.tableId].closeHeapFile()
    eng.heaps.del(entry.schema.tableId)
  try: removeFile(entry.dataPath) except: discard
  ExecResult(message: "DROP TABLE")

# ─── Main execute entry ───────────────────────────────────────────────────

proc execute*(eng: Engine; sql: string): ExecResult =
  let stmt = parse(sql)
  var txnId  = eng.txnMgr.currentTxn()
  var autoTxn = txnId == InvalidTxnId
  if autoTxn: txnId = eng.txnMgr.begin()
  var prevLsn = eng.txnMgr.lastLsn(txnId)

  try:
    result = case stmt.kind
      of skSelect:      eng.execSelect(stmt, txnId)
      of skInsert:      eng.execInsert(stmt, txnId, prevLsn)
      of skUpdate:      eng.execUpdate(stmt, txnId, prevLsn)
      of skDelete:      eng.execDelete(stmt, txnId, prevLsn)
      of skCreateTable: eng.execCreateTable(stmt, txnId)
      of skDropTable:   eng.execDropTable(stmt, txnId)
      of skBegin:
        if autoTxn: autoTxn = false
        eng.txnMgr.setCurrentTxn(eng.txnMgr.begin())
        ExecResult(message: "BEGIN")
      of skCommit:
        eng.txnMgr.commit(txnId)
        autoTxn = false
        ExecResult(message: "COMMIT")
      of skRollback:
        eng.txnMgr.abort(txnId)
        autoTxn = false
        ExecResult(message: "ROLLBACK")
      of skExplain:
        ExecResult(message: "EXPLAIN: " & $stmt.explainStmt.kind)
      of skCreateIndex:
        ExecResult(message: "CREATE INDEX (indexes are in-memory B+ trees)")
    eng.txnMgr.setLastLsn(txnId, prevLsn)
    if autoTxn: eng.txnMgr.commit(txnId)
  except:
    if autoTxn: eng.txnMgr.abort(txnId)
    raise
