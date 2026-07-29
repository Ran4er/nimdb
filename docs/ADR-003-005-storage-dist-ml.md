# ADR-003: Режимы хранения OLTP / OLAP / VECTOR / HYBRID

**Статус:** accepted  
**Дата:** 2025-01

---

## Контекст

ML-workload неоднородны: одни запросы — точечные вставки/обновления
(OLTP), другие — аналитические сканы по миллионам строк (OLAP),
третьи — поиск ближайших соседей в пространстве эмбеддингов (VECTOR).
Традиционные БД оптимизированы под один класс — мы хотим поддержать все три
в одном движке, потому что ML-pipeline проходит через все три на разных этапах.

---

## Принятое решение: 4 режима на уровне таблицы

Режим задаётся при `CREATE TABLE ... WITH (mode = '...')` и влияет на:
1. **Физическое хранение** — row heap vs column chunks
2. **Индексирование** — B+ tree vs HNSW vs none
3. **Транзакционность** — MVCC vs append-only
4. **Оптимизатор запросов** — row-at-a-time vs vectorised scan

| Режим  | Хранение | Индекс | TX | Лучший для |
|--------|----------|--------|----|------------|
| OLTP   | Heap (8 KB pages, slot array) | B+ tree | MVCC | INSERT/UPDATE/DELETE, точечные чтения |
| OLAP   | Columnar chunks (RLE/Delta) | — | append-only | GROUP BY, COUNT, AVG, batch ML-features |
| VECTOR | Heap (метаданные) + HNSW in-mem | HNSW + PQ | — | KNN, cosine/L2/dot similarity |
| HYBRID | OLTP for hot, OLAP for cold | оба | MVCC | смешанная нагрузка |

### HYBRID-тиринг

Порог определяется параметром `hot_threshold` (строк в OLTP-сегменте).
Когда OLTP-сегмент превышает порог, фоновый worker материализует
данные в OLAP-чанки (RLE/Delta). Запросы видят оба сегмента и объединяют
результаты (merge на уровне row iterator).

---

## Последствия

- Один `SELECT` должен уметь работать со смешанными режимами при JOIN
- Оптимизатор нужно расширить cost-based выбором: heap scan vs column scan
- VECTOR-индекс при старте движка восстанавливается из heap-данных (rebuild)

---

---

# ADR-004: Модель распределения — PA/EL (PACELC)

**Статус:** accepted  
**Дата:** 2025-01

---

## Контекст

PACELC — расширение CAP теоремы: в нормальной работе (нет partition)
система выбирает между **консистентностью (C)** и **задержкой (L)**.
ML-системы типично предпочитают low latency и eventual consistency:
чуть устаревший эмбеддинг — допустимо; sub-10ms ответ — критично.

---

## Принятое решение: PA/EL

- **PA** (Partition-tolerant + Available): при разрыве сети ноды
  продолжают обслуживать запросы со своими локальными данными.
  Строгая согласованность не гарантируется в момент partition.
- **EL** (Eventually consistent + Low latency): в нормальной работе
  запись подтверждается после локального write + WAL flush, репликация
  на остальные ноды — **асинхронная**. Клиент получает ACK быстро.

### Компоненты

1. **Consistent Hashing Ring** (150 vnodes/node) — детерминированное
   присвоение ключей шардам, минимальное перебалансирование при добавлении/удалении ноды.

2. **Gossip протокол** (SWIM-inspired) — decentralized обнаружение
   отказов без single point of failure. Heartbeat каждые N секунд,
   merge состояния при контакте с K случайными peer-нодами.

3. **Replication factor = 3** по умолчанию. Write: 1 (async остальные).
   Read: 1 (ближайшая replica). Для критических данных — tunable quorum.

4. **Anti-entropy** через Merkle-дерево хешей страниц — периодическая
   сверка и восстановление расхождений между репликами.

### Сознательный trade-off

Для ML-workload (feature store, embedding search, model inference)
eventual consistency — правильный выбор. Для транзакционных данных
(пользователи, заказы) можно переключить отдельную таблицу в
`OLTP` режим с quorum-writes (readQuorum=2, writeQuorum=2 при RF=3).

---

## Последствия

- Нужен механизм conflict resolution при concurrent writes на разные реплики.
  Решение: last-write-wins по timestamp (для ML-данных достаточно),
  опционально — CRDT для счётчиков.
- Клиент должен поддерживать retry при получении ошибки от недоступной ноды
  (gateway автоматически ретраит на другую реплику).

---

---

# ADR-005: Философия ML-интеграции

**Статус:** accepted  
**Дата:** 2025-01

---

## Контекст

Много "ML-баз данных" делают одно из двух: либо просто добавляют
vector search поверх обычной БД, либо пытаются заменить PyTorch/sklearn.
Оба подхода неоптимальны. Нам нужна чёткая философия.

---

## Принятое решение: "Compute where data lives"

### Что NimDB делает ЛУЧШЕ PyTorch/sklearn

| Операция | PyTorch/sklearn | NimDB |
|----------|-----------------|-------|
| Feature extraction | Выгружай все данные, потом трансформируй | Один проход heap scan = фичи |
| Incremental training | Нужен re-fit или ручной partial_fit | `TRAIN MODEL` через partialFit в scan callback |
| Model serving | Отдельный inference server | `PREDICT(model, col1, col2)` внутри `SELECT` |
| KNN search | scikit + faiss отдельно | HNSW/PQ встроены, ответ за <10ms |
| Data versioning | DVC, отдельный инструмент | WAL + MVCC — данные версионируются бесплатно |
| Model versioning | MLflow, отдельный сервис | Model Registry встроен в движок |

### Что NimDB НЕ делает и не должен

- Обучение нейронных сетей (многослойных) — PyTorch лучше на GPU
- Трансформеры, диффузионные модели — не наш уровень
- Замена feature store для петабайтных данных (Feast, Tecton) — не масштаб

### Точки интеграции с PyTorch/Python

- Arrow IPC export → pandas DataFrame → любой Python ML-инструмент
- Хранение готовых эмбеддингов (из PyTorch) как VECTOR-колонок
- Candidate generation через HNSW → fine-ranking в PyTorch

### Встроенные алгоритмы

Только те, где локальное выполнение (без выгрузки данных) даёт
значимый выигрыш по скорости или удобству:

1. **Linear / Logistic regression** — online SGD во время scan
2. **K-Means / Mini-batch K-Means** — сегментация без выгрузки
3. **PCA** (power iteration) — снижение размерности прямо в движке
4. **HNSW** — ANN поиск как первый класс, не внешняя библиотека
5. **Product Quantization** — сжатие эмбеддингов 32× с ~95% recall

---

## Последствия

- ML-операции реализуются как SQL-расширения (`TRAIN`, `PREDICT`, `CLUSTER`,
  `VECTOR_SEARCH`) — не сторонний CLI/скрипт, а часть языка запросов
- Модели хранятся в движке (serialized weights в catalog) — репликация
  и версионирование "бесплатно" через существующую инфраструктуру
- Python-экосистема не вытесняется, а дополняется: Arrow zero-copy
  handoff обеспечивает бесшовную интеграцию
