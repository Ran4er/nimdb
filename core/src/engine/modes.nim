## modes.nim — Engine operation modes
##
## NimDB supports four first-class modes:
##
##   OLTP    — row-oriented, WAL-backed, full ACID transactions.
##             Best for inserts/updates/deletes, short queries.
##             Storage: heap files  | Indexes: B+ tree
##
##   OLAP    — column-oriented, append-only, vectorised scans.
##             Best for aggregate queries, ML feature extraction.
##             Storage: column chunks (RLE/Delta compressed)
##
##   VECTOR  — embedding store with HNSW ANN index.
##             Best for similarity search, RAG, recommendation.
##             Storage: heap file for metadata + HNSW in-memory
##
##   HYBRID  — automatic tiering: OLTP for recent/hot rows,
##             OLAP for cold/historical, VECTOR for VECTOR columns.
##             Data migrates from hot to cold on a configurable threshold.
##
## The mode is set per-table via:
##   CREATE TABLE ... WITH (mode = 'olap')

import std/[tables, locks, strutils]
import ../storage/types
import ../catalog/schema

type
  EngineMode* = enum
    modeOLTP    = "oltp"
    modeOLAP    = "olap"
    modeVECTOR  = "vector"
    modeHYBRID  = "hybrid"

  ## Per-table mode config
  ModeConfig* = object
    mode*:           EngineMode
    ## HYBRID tuning
    hotThreshold*:   int64   ## rows before promoting to OLAP
    ## VECTOR tuning
    vecDim*:         int     ## embedding dimension (0 = auto-detect)
    vecMetric*:      string  ## "cosine" | "l2" | "dot"
    hnswM*:          int     ## HNSW M parameter
    hnswEfC*:        int     ## HNSW ef construction
    hnswEfS*:        int     ## HNSW ef search
    ## OLAP tuning
    chunkSize*:      int     ## rows per column chunk
    encoding*:       string  ## "auto" | "rle" | "delta" | "dict"

  ModeRegistry* = ref object
    mu*:       Lock
    configs*:  Table[ObjId, ModeConfig]

proc defaultConfig*(mode: EngineMode): ModeConfig =
  ModeConfig(
    mode:           mode,
    hotThreshold:   1_000_000,
    vecDim:         0,
    vecMetric:      "cosine",
    hnswM:          16,
    hnswEfC:        200,
    hnswEfS:        50,
    chunkSize:      65536,
    encoding:       "auto"
  )

proc newModeRegistry*(): ModeRegistry =
  result = ModeRegistry(configs: initTable[ObjId, ModeConfig]())
  initLock(result.mu)

proc setMode*(reg: ModeRegistry; tableId: ObjId; cfg: ModeConfig) =
  acquire(reg.mu); defer: release(reg.mu)
  reg.configs[tableId] = cfg

proc getMode*(reg: ModeRegistry; tableId: ObjId): ModeConfig =
  acquire(reg.mu); defer: release(reg.mu)
  if tableId in reg.configs: reg.configs[tableId]
  else: defaultConfig(modeOLTP)

proc parseMode*(s: string): EngineMode =
  case s.toLowerAscii()
  of "oltp":   modeOLTP
  of "olap":   modeOLAP
  of "vector": modeVECTOR
  of "hybrid": modeHYBRID
  else: raise newException(ValueError, "Unknown mode: " & s)

## ─── Mode capabilities ────────────────────────────────────────────────────

proc supportsTransactions*(mode: EngineMode): bool =
  mode in {modeOLTP, modeHYBRID}

proc supportsVectorSearch*(mode: EngineMode): bool =
  mode in {modeVECTOR, modeHYBRID}

proc supportsColumnarScan*(mode: EngineMode): bool =
  mode in {modeOLAP, modeHYBRID}

proc prefersBatchInsert*(mode: EngineMode): bool =
  mode in {modeOLAP, modeVECTOR, modeHYBRID}

proc modeDescription*(mode: EngineMode): string =
  case mode
  of modeOLTP:
    "OLTP — row storage, WAL, ACID transactions, B+ tree indexes"
  of modeOLAP:
    "OLAP — columnar storage, RLE/Delta compression, vectorised scans"
  of modeVECTOR:
    "VECTOR — embedding storage, HNSW ANN index, cosine/L2/dot similarity"
  of modeHYBRID:
    "HYBRID — automatic hot/cold tiering: OLTP → OLAP, plus VECTOR for embeddings"
