# NimDB

**ML-native распределённая база данных**, спроектированная и разрабатываемая
как масштабный portfolio-проект: от storage-движка на Nim до полиглотной
экосистемы драйверов и сервисов на Go, Java, Python и C.

> Это не production-продукт, а инженерный проект для демонстрации
> архитектурных, системных и ML-инженерных компетенций — от low-level
> оптимизации до распределённых систем и протокольного дизайна.

---

## Идея

Классические БД оптимизированы под один класс нагрузки (OLTP *или* OLAP).
ML-пайплайны проходят через несколько классов подряд: точечные вставки →
аналитические сканы → поиск по эмбеддингам → обучение модели → инференс.
NimDB — попытка сделать один движок, который закрывает весь путь, вместо
склейки Postgres + ClickHouse + Pinecone + отдельного feature store.

Философия и все trade-off'ы задокументированы как ADR — см.
[`docs/adr/`](docs/adr/ADR-000-index.md), начиная с
[философии ML-интеграции](docs/adr/ADR-006-010-polyglot-deploy-security.md).

**Ключевой принцип:** *compute where data lives*. Обучение линейной/логистической
регрессии, k-means и извлечение фичей происходят прямо во время скана
хранилища — без выгрузки в pandas/PyTorch. Экспорт в Python-экосистему
(Arrow zero-copy) остаётся, но как дополнение, а не обязательный шаг.

---

## Архитектура на верхнем уровне

```
                     ┌────────────────────────────┐
                     │   Console (frontend)       │
                     │   SQL/GQL playground,      │
                     │   ring topology, vec search│
                     └────────────┬───────────────┘
                                  │ REST / WS
                     ┌────────────▼─────────────┐
                     │   Go API Gateway         │
                     │   REST + gRPC + Swagger  │
                     └────────────┬─────────────┘
                                  │ NDP (бинарный протокол)
        ┌─────────────────────────┼─────────────────────────┐
        │                         │                         │
┌───────▼───────┐        ┌────────▼────────┐      ┌─────────▼────────┐
│ Java JDBC     │        │ Python driver   │      │  C client lib    │
│ driver        │        │ (DB-API 2.0)    │      │ (libnimdb.so)    │
└───────┬───────┘        └────────┬────────┘      └─────────┬────────┘
        │                         │                         │
┌───────▼─────────┐      ┌────────▼────────┐      ┌─────────▼──────────┐
│ Spring model-   │      │ recsys pipeline │      │  SIMD library      │
│ serving         │      │ (PyTorch)       │      │  (AVX2/AVX-512)    │
└─────────────────┘      └─────────────────┘      └────────────────────┘
                                  │
                     ┌────────────▼───────────────┐
                     │       NimDB Core           │
                     │  OLTP · OLAP · VECTOR ·    │
                     │  HYBRID   |   MVCC · WAL   │
                     │  gossip · consistent hash  │
                     └────────────────────────────┘

  nimdbctl (Go)  →  генерирует nimdb.toml / docker-compose.yml,
                    поднимает кластер, показывает топологию кольца
```

Полное обоснование каждого слоя — в ADR:
[движок на Nim](docs/adr/ADR-001-engine-nim.md) ·
[протокол NDP](docs/adr/ADR-002-wire-protocol.md) ·
[режимы хранения](docs/adr/ADR-003-005-storage-dist-ml.md) ·
[полиглотная экосистема](docs/adr/ADR-006-010-polyglot-deploy-security.md)

---

## Структура репозитория

```
nimdb/
├── core/           # Nim engine — storage, SQL, ML, graph, MVCC, gossip
├── protocol/        # NDP-PROTOCOL.md — спека wire-протокола + test vectors
├── drivers/
│   ├── go/           # Go-клиент протокола (используется gateway)
│   ├── java/         # JDBC-драйвер
│   ├── python/       # DB-API 2.0 драйвер
│   └── c/             # libnimdb.so + SIMD-библиотека (AVX2/AVX-512)
├── gateway/          # Go: REST/gRPC + Swagger, роутинг по consistent-hash ring
├── ml/recsys/        # Python: end-to-end рекомендательная система на NimDB
├── console/          # Frontend: SQL/GQL playground, визуализация кластера
├── deploy/
│   ├── nimdbctl/      # Go CLI: init/up/status/cluster/benchmark
│   ├── docker-compose/
│   └── grafana/       # дашборды
└── docs/
    ├── adr/            # Architecture Decision Records
    └── spec/            # доп. спеки (пока протокол лежит в /protocol)
```

---

## Статус компонентов

Проект разрабатывается последовательно — от движка к экосистеме.
Ниже честный снимок того, что реализовано, что в работе, что запланировано.

| Компонент | Статус | Комментарий |
|---|---|---|
| `core/storage` (page, WAL, buffer pool, heap file) | ✅ реализовано | 8 KB pages, LRU/Clock eviction, CRC32 WAL |
| `core/sql` (lexer, parser, executor) | ✅ реализовано | SELECT/INSERT/UPDATE/DELETE/DDL, агрегаты |
| `core/transaction` (2PL, MVCC) | 🚧 в работе | `mvcc.nim` написан, интеграция с heap file — в процессе |
| `core/ml` (tensor, HNSW, PQ, linear, k-means, registry) | ✅ реализовано | SIMD auto-vectorized ops, model registry с версиями |
| `core/graph` (PropertyGraph, GQL, PageRank, Dijkstra) | ✅ реализовано | базовые алгоритмы + мини-GQL парсер |
| `core/distributed` (gossip, consistent hashing) | ✅ реализовано | SWIM-inspired, PA/EL replication config |
| **NDP протокол — спека** | ✅ готова | [`protocol/NDP-PROTOCOL.md`](protocol/NDP-PROTOCOL.md) |
| **NDP протокол — реализация в core** | 🚧 в работе | `core/src/protocol/` — frame/codec/payloads |
| Go gateway + Swagger | ⏳ план | после стабилизации протокола в core |
| `nimdbctl` | ⏳ план | генерация `nimdb.toml`, docker-compose |
| Java JDBC driver | ⏳ план | |
| Python driver + recsys | ⏳ план | |
| C SIMD library (AVX2/AVX-512) | ⏳ план | сравнение с auto-vectorized Nim-версией |
| Frontend console | ⏳ план | |

Легенда: ✅ реализовано и покрыто тестами · 🚧 в активной разработке · ⏳ запланировано (ADR готов).

---

## Быстрый старт (core уже сейчас)

```bash
cd core
nimble build
./nimdb                              # REPL
./nimdb --mode=demo                  # демо: relational + graph + ML + SIMD bench
./nimdb --mode=server --port=5433    # текстовый debug-протокол (временный, см. ниже)
```

Подробности по движку, SQL-диалекту и ML-командам — в
[`core/README.md`](core/README.md).

> ⚠️ Сетевой протокол сейчас — временный line-protocol для отладки
> (см. ADR-002: он сознательно не является основным транспортом).
> Основной бинарный протокол NDP реализуется в `core/src/protocol/`
> согласно [спеке](protocol/NDP-PROTOCOL.md).

---

## Документация

- **ADR** (архитектурные решения с обоснованием и альтернативами):
  [`docs/adr/ADR-000-index.md`](docs/adr/ADR-000-index.md)
- **Wire-протокол NDP** (opcodes, форматы фреймов, коды ошибок, test vectors):
  [`protocol/NDP-PROTOCOL.md`](protocol/NDP-PROTOCOL.md)
- **Движок** (SQL-диалект, режимы хранения, ML-команды, файловая структура):
  [`core/README.md`](core/README.md)

---

## Почему так спроектировано (коротко)

- **Nim для движка** — компилируется в C, даёт control над памятью
  без GC-пауз в критических путях (`--mm:arc`), при этом продуктивнее
  писать, чем на чистом C. См. [ADR-001](docs/adr/ADR-001-engine-nim.md).
- **Собственный бинарный протокол**, а не готовый PG-wire/gRPC — чтобы
  показать полный контроль над форматом и протокольный дизайн, при этом
  оставаясь тестируемым через byte-точные test vectors.
  См. [ADR-002](docs/adr/ADR-002-wire-protocol.md).
- **Каждый язык экосистемы выбран по объективному критерию**, не для
  количества: Go — сетевые сервисы и CLI, Java — JDBC SPI и enterprise
  serving, Python — ML-экосистема, C — гарантированный доступ к SIMD.
  См. [ADR-006](docs/adr/ADR-006-010-polyglot-deploy-security.md).
- **PA/EL, не CP** — для ML-нагрузки (эмбеддинги, фичи, инференс)
  низкая latency важнее строгой консистентности; критичные таблицы
  можно явно переключить в строгий режим. См.
  [ADR-004](docs/adr/ADR-003-005-storage-dist-ml.md).

---

## Roadmap

1. ✅ Движок: storage, SQL, ML-примитивы, граф, distribution — базовая версия
2. 🚧 NDP-протокол в core (frame/codec/payloads/dispatch) + MVCC-интеграция
3. ⏳ Go: gateway (REST/Swagger) + `nimdbctl` (bootstrap CLI)
4. ⏳ Python: driver + end-to-end recsys (candidate gen + ranking)
5. ⏳ Java: JDBC-драйвер + Spring model-serving
6. ⏳ C: SIMD-библиотека с прямыми AVX2/AVX-512 intrinsics + бенчмарк vs Nim
7. ⏳ Frontend console
8. ⏳ (опционально) DP-SGD приватность в `TRAIN MODEL` — связка с дипломной темой

---

## Лицензия

MIT — см. [`LICENSE`](LICENSE).
