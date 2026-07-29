## catalog.nim — System catalog: table registry, persistence
##
## The catalog is stored in a special "_catalog" heap file.
## On startup we replay it to rebuild the in-memory registry.

import std/[tables, locks, json, os, strutils]
import ../storage/types
import schema

type
  IndexInfo* = object
    name*:    string
    indexId*: ObjId
    tableId*: ObjId
    colIdx*:  int      ## which column is indexed
    unique*:  bool

  TableEntry* = object
    schema*:   TableSchema
    dataPath*: string   ## path to heap file
    indexes*:  seq[IndexInfo]

  Catalog* = ref object
    mu*:       Lock
    tables*:   Table[string, TableEntry]  ## name → entry
    byId*:     Table[ObjId, string]       ## tableId → name
    nextObjId*: ObjId
    metaPath*: string   ## JSON persistence file

# ─── Catalog lifecycle ────────────────────────────────────────────────────

proc newCatalog*(dataDir: string): Catalog =
  result = Catalog(
    metaPath:   dataDir / "catalog.json",
    nextObjId:  ObjId(1)
  )
  initLock(result.mu)

  if fileExists(result.metaPath):
    try:
      let js = parseFile(result.metaPath)
      result.nextObjId = ObjId(js["nextObjId"].getInt())
      for tname, tnode in js["tables"]:
        var entry = TableEntry()
        entry.schema.name    = tname
        entry.schema.tableId = ObjId(tnode["tableId"].getInt())
        entry.dataPath       = tnode["dataPath"].getStr()
        for cnode in tnode["cols"]:
          entry.schema.cols.add ColDef(
            name:       cnode["name"].getStr(),
            kind:       ColKind(cnode["kind"].getInt()),
            notNull:    cnode["notNull"].getBool(),
            primaryKey: cnode["pk"].getBool()
          )
        for inode in tnode["indexes"]:
          entry.indexes.add IndexInfo(
            name:    inode["name"].getStr(),
            indexId: ObjId(inode["indexId"].getInt()),
            tableId: entry.schema.tableId,
            colIdx:  inode["colIdx"].getInt(),
            unique:  inode["unique"].getBool()
          )
        result.tables[tname] = entry
        result.byId[entry.schema.tableId] = tname
    except:
      discard  # start fresh if corrupt

proc save*(cat: Catalog) =
  ## Persist catalog to JSON.
  var root = newJObject()
  root["nextObjId"] = %int(cat.nextObjId)
  var tablesNode = newJObject()
  for name, entry in cat.tables:
    var t = newJObject()
    t["tableId"]  = %int(entry.schema.tableId)
    t["dataPath"] = %entry.dataPath
    var cols = newJArray()
    for c in entry.schema.cols:
      var cn = newJObject()
      cn["name"] = %c.name
      cn["kind"] = %int(c.kind)
      cn["notNull"] = %c.notNull
      cn["pk"] = %c.primaryKey
      cols.add(cn)
    t["cols"] = cols
    var idxs = newJArray()
    for ix in entry.indexes:
      var ixn = newJObject()
      ixn["name"]    = %ix.name
      ixn["indexId"] = %int(ix.indexId)
      ixn["colIdx"]  = %ix.colIdx
      ixn["unique"]  = %ix.unique
      idxs.add(ixn)
    t["indexes"] = idxs
    tablesNode[name] = t
  root["tables"] = tablesNode
  writeFile(cat.metaPath, $root)

# ─── Table operations ─────────────────────────────────────────────────────

proc createTable*(cat: Catalog; schema: TableSchema; dataPath: string) =
  acquire(cat.mu)
  defer: release(cat.mu)
  if cat.tables.hasKey(schema.name):
    raise newException(CatalogError, "Table already exists: " & schema.name)
  cat.tables[schema.name] = TableEntry(schema: schema, dataPath: dataPath)
  cat.byId[schema.tableId] = schema.name
  cat.save()

proc dropTable*(cat: Catalog; name: string): TableEntry =
  acquire(cat.mu)
  defer: release(cat.mu)
  if not cat.tables.hasKey(name):
    raise newException(CatalogError, "Table not found: " & name)
  result = cat.tables[name]
  cat.byId.del(result.schema.tableId)
  cat.tables.del(name)
  cat.save()

proc getTable*(cat: Catalog; name: string): TableEntry =
  acquire(cat.mu)
  defer: release(cat.mu)
  if not cat.tables.hasKey(name):
    raise newException(CatalogError, "Table not found: " & name)
  cat.tables[name]

proc getTableById*(cat: Catalog; id: ObjId): TableEntry =
  acquire(cat.mu)
  defer: release(cat.mu)
  if not cat.byId.hasKey(id):
    raise newException(CatalogError, "Table not found by id: " & $id)
  cat.tables[cat.byId[id]]

proc tableExists*(cat: Catalog; name: string): bool =
  acquire(cat.mu)
  defer: release(cat.mu)
  cat.tables.hasKey(name)

proc allTables*(cat: Catalog): seq[TableEntry] =
  acquire(cat.mu)
  defer: release(cat.mu)
  for _, e in cat.tables: result.add(e)

proc allocObjId*(cat: Catalog): ObjId =
  acquire(cat.mu)
  defer: release(cat.mu)
  result = cat.nextObjId
  inc cat.nextObjId

proc addIndex*(cat: Catalog; tableName: string; idx: IndexInfo) =
  acquire(cat.mu)
  defer: release(cat.mu)
  if not cat.tables.hasKey(tableName):
    raise newException(CatalogError, "Table not found: " & tableName)
  cat.tables[tableName].indexes.add(idx)
  cat.save()

proc colIndex*(schema: TableSchema; colName: string): int =
  ## Return 0-based column index, or -1 if not found.
  for i, c in schema.cols:
    if c.name.toLowerAscii() == colName.toLowerAscii():
      return i
  -1
