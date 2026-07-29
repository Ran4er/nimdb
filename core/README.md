# NimDB

PostgreSQL-inspired, ML-native database engine written in Nim.

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────┐
│                    CLIENT / REPL / SERVER                │
│          SQL Protocol + Special ML Commands              │
└──────────────┬───────────────────────────────────────────┘
               │
┌──────────────▼───────────────────────────────────────────┐
│                     SQL LAYER                            │
│  Lexer → Parser → AST → Executor                        │
│  (SELECT / INSERT / UPDATE / DELETE / CREATE / DROP)     │
└──────┬──────────────┬──────────────────┬─────────────────┘
       │              │                  │
┌──────▼──────┐ ┌─────▼──────┐  ┌───────▼────────┐
│  OLTP Mode  │ │ OLAP Mode  │  │  VECTOR Mode   │
│             │ │            │  │                │
│ Heap Files  │ │  Columnar  │  │  HNSW Index    │
│ B+ Tree idx │ │  Chunks    │  │  Tensor Store  │
│ WAL + ACID  │ │ RLE/Delta  │  │  Cosine/L2/Dot │
└──────┬──────┘ └─────┬──────┘  └───────┬────────┘
       └──────────────┼──────────────────┘
                      │
┌─────────────────────▼────────────────────────────────────┐
│                  STORAGE LAYER                           │
│                                                          │
│  Buffer Pool (LRU, Clock eviction, 2048 frames = 16 MB) │
│  WAL (Write-Ahead Log, LSN chain, CRC32, force-flush)   │
│  Heap File (8 KB pages, slot array, variable tuples)    │
│  Page (PageHeader + SlotArray + TupleData)              │
└──────────────────────────────────────────────────────────┘
               │
┌──────────────▼───────────────────────────────────────────┐
│               ML LAYER                                   │
│                                                          │
│  Tensor (F32/F64/I32/I64/Bool, arbitrary shape)         │
│  Feature Store (transforms, materialise, train/test)     │
│  Column stats (mean, std, min, max)                      │
│  Softmax, normalize, dot, L2-dist, cosine-sim           │
└──────────────────────────────────────────────────────────┘
               │
┌──────────────▼───────────────────────────────────────────┐
│            DISTRIBUTED LAYER  (PA/EL)                   │
│                                                          │
│  Consistent Hashing Ring (150 vnodes / node)            │
│  Gossip Protocol (SWIM-inspired, heartbeat + merge)     │
│  Shard Router (primary + N-1 async replicas)            │
│  PA = Partition-tolerant + Available                    │
│  EL = Eventually consistent + Low Latency               │
└──────────────────────────────────────────────────────────┘
```

---

## Engine Modes

| Mode       | Storage      | Index       | Transactions | Best for                       |
|------------|--------------|-------------|--------------|--------------------------------|
| **OLTP**   | Heap pages   | B+ Tree     | Full ACID    | Inserts, short queries         |
| **OLAP**   | Column chunks| —           | No           | Aggregates, feature extraction |
| **VECTOR** | Heap + HNSW  | HNSW (ANN)  | No           | Embeddings, similarity search  |
| **HYBRID** | Both         | Both        | For hot rows | Mixed workloads                |

---

## SQL Quick Start

```sql
-- OLTP table
CREATE TABLE users (
  id     INT4 PRIMARY KEY,
  name   TEXT NOT NULL,
  score  FLOAT8,
  active BOOL
);

INSERT INTO users VALUES (1, 'Alice', 0.95, true);
INSERT INTO users VALUES (2, 'Bob',   0.72, true);

SELECT name, score
  FROM users
 WHERE active = true AND score > 0.8
 ORDER BY score DESC
 LIMIT 10;

UPDATE users SET score = 1.0 WHERE id = 1;
DELETE FROM users WHERE active = false;

-- Aggregates
SELECT count(*), avg(score), min(score), max(score)
  FROM users;

-- Transactions
BEGIN;
INSERT INTO users VALUES (3, 'Charlie', 0.88, true);
ROLLBACK;
```

---

## ML Commands (REPL / Server)

```
# Switch a table to vector mode
\mode embeddings vector

# Insert a 4-dim embedding
\vecinsert embeddings 42 0.1,0.9,0.3,0.7

# Find 5 nearest neighbours
\vecsearch embeddings 0.1,0.8,0.4,0.6 k=5

# Column statistics (after materialise)
\stats users score

# Server info
\info
```

---

## Tensor API (Nim code)

```nim
import nimdb/ml/tensor

let a = vectorF32([1.0'f32, 0.0, 0.0])
let b = vectorF32([0.6'f32, 0.8, 0.0])

echo cosineSimF32(a, b)   # 0.6
echo l2distF32(a, b)      # ~0.56
echo dot(a, b)             # 0.6

let mat = newTensor(dtF32, @[100, 128])  # 100 × 128 matrix
echo mat.shape             # @[100, 128]
```

---

## Feature Store (Nim code)

```nim
import nimdb/ml/feature_store

var fs = newFeatureStore()
var grp = FeatureGroup(
  name: "user_features",
  features: @[
    FeatureDef(name: "score",  sourceCol: 2, transform: tkStandardize),
    FeatureDef(name: "active", sourceCol: 3, transform: tkBoolToFloat),
  ],
  labelCol: 2
)
# After fs.materialise(grp, colStore):
let (xTrain, xTest, yTrain, yTest) = grp.trainTestSplit(0.8)
```

---

## Distribution (PA/EL)

```nim
import nimdb/distributed/node

let cfg    = paelConfig(factor = 3)  # 3 replicas, async writes
let router = newShardRouter("node1:5433", cfg)
router.ring.addNode("node2:5433")
router.ring.addNode("node3:5433")

echo router.routeInfo("user:42")
# key=user:42 primary=node2:5433 replicas=3 reachable=3 readQ=1
```

---

## Build

```bash
cd nimdb
nimble build          # compile
nimble test           # run tests
./nimdb               # REPL mode
./nimdb --mode=server --port=5433   # server mode
./nimdb --demo        # seed data + show queries
```

---

## File Structure

```
nimdb/
├── nimdb.nimble
├── src/
│   ├── nimdb.nim                 # Entry point + REPL
│   ├── storage/
│   │   ├── types.nim             # Core types, LE helpers
│   │   ├── page.nim              # 8 KB page, slot array
│   │   ├── wal.nim               # Write-Ahead Log
│   │   ├── buffer_pool.nim       # LRU buffer pool (Clock)
│   │   ├── heap_file.nim         # Table heap files
│   │   └── columnar.nim          # Column chunks, RLE/Delta
│   ├── catalog/
│   │   ├── schema.nim            # Types, Value, Row, encode/decode
│   │   └── catalog.nim           # System catalog (JSON persistence)
│   ├── sql/
│   │   ├── ast.nim               # SQL AST nodes
│   │   ├── lexer.nim             # SQL tokeniser
│   │   ├── parser.nim            # Recursive descent parser
│   │   └── executor.nim          # Query executor
│   ├── index/
│   │   └── btree.nim             # B+ tree index
│   ├── transaction/
│   │   ├── lock_manager.nim      # 2PL S/X locks
│   │   └── txn_manager.nim       # Begin/commit/abort
│   ├── ml/
│   │   ├── tensor.nim            # Tensor type + ops
│   │   ├── vector_index.nim      # HNSW ANN index
│   │   └── feature_store.nim     # Feature materialisation
│   ├── engine/
│   │   └── modes.nim             # OLTP/OLAP/VECTOR/HYBRID
│   ├── distributed/
│   │   └── node.nim              # Consistent hashing + gossip
│   └── server/
│       └── server.nim            # Async TCP server
└── tests/
    └── test_basic.nim
```
