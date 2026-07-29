# NimDB — Architecture Decision Records

> ADR (Architecture Decision Record) — формальный документ, фиксирующий
> архитектурное решение: **контекст**, почему именно оно было принято,
> какие альтернативы рассматривались и каковы последствия.
>
> Статусы: `proposed` → `accepted` → `deprecated` / `superseded by ADR-XXX`

---

## Index

| №    | Название                                     | Статус     | Дата       |
|------|----------------------------------------------|------------|------------|
| [000](ADR-000-overview.md)  | Этот файл — навигация              | –          | 2025-01    |
| [001](ADR-001-engine-nim.md) | Движок базы данных на Nim          | accepted   | 2025-01    |
| [002](ADR-002-wire-protocol.md) | Бинарный wire-протокол NDP      | accepted   | 2025-01    |
| [003](ADR-003-storage-modes.md) | Режимы хранения OLTP/OLAP/VECTOR/HYBRID | accepted | 2025-01 |
| [004](ADR-004-distribution.md) | Модель распределения PA/EL       | accepted   | 2025-01    |
| [005](ADR-005-ml-philosophy.md) | Философия ML-интеграции          | accepted   | 2025-01    |
| [006](ADR-006-polyglot.md) | Полиглотная экосистема            | accepted   | 2025-01    |
| [007](ADR-007-monorepo.md) | Монорепозиторий                   | accepted   | 2025-01    |
| [008](ADR-008-deploy.md)   | Деплой: nimdbctl + Docker         | accepted   | 2025-01    |
| [009](ADR-009-observability.md) | Наблюдаемость                   | accepted   | 2025-01    |
| [010](ADR-010-security.md) | Безопасность и приватность        | accepted   | 2025-01    |

---

## Контекст проекта

**NimDB** — ML-ориентированная распределённая база данных, разработанная
для демонстрации архитектурных, системных и ML-инженерных компетенций.

Ключевые свойства системы в целом:

```
Движок (Nim)
  └─ хранение:   heap files, WAL, buffer pool, MVCC
  └─ режимы:     OLTP / OLAP (columnar) / VECTOR (HNSW+PQ) / HYBRID
  └─ ML:         linear, logistic, k-means, feature store, model registry
  └─ граф:       PropertyGraph, PageRank, Dijkstra, BFS, WCC
  └─ dist:       gossip, consistent hashing, PA/EL replication

Протокол (NDP — NimDB Data Protocol)
  └─ бинарный, фреймированный, мультиплексированный
  └─ поддерживает: SQL, GQL, VECTOR_SEARCH, STREAM_RESULT (Arrow chunks)

Экосистема
  └─ Go:     gateway (REST/gRPC/Swagger) + nimdbctl (bootstrapper CLI)
  └─ Java:   JDBC-драйвер + Spring model-serving
  └─ Python: DB-API 2.0 driver + recsys (candidate gen + ranking)
  └─ C/C++:  SIMD-библиотека AVX2/AVX-512, опционально C-клиент
  └─ Web:    Console (SQL playground, ring topology, vector search demo)

Применение
  └─ рекомендательная система: full pipeline от ингестии до serving
```

---

## Принципы, которые проходят через все ADR

1. **Протокол — контракт.** Все клиенты реализуют один wire-протокол.
   Это доказывает переносимость, а не просто "написал 4 бэкенда".

2. **Обоснованный выбор языка.** Каждый язык используется там, где
   он даёт объективное преимущество — а не для количества.

3. **Данные не покидают движок без нужды.** ML-вычисления
   (train/predict/cluster) работают поверх heap scan — один проход,
   без материализации в Python/pandas.

4. **Измеримость.** Каждое архитектурное решение имеет метрику,
   по которой можно судить о его успехе (latency p99, GFLOPs, recall@10...).
