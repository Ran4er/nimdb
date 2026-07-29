# NDP — NimDB Data Protocol
## Спецификация v1.0

**Статус:** DRAFT → ACCEPTED  
**Дата:** 2025-01  
**Применимость:** все клиентские драйверы (Go, Java, Python, C)

---

## 1. Обзор

NDP (NimDB Data Protocol) — бинарный, фреймированный, мультиплексированный
протокол поверх TCP. Один TCP-коннект поддерживает несколько параллельных
запросов через `request_id` (pipelining).

```
TCP Stream
 ┌─────────────────────────────────────────────┐
 │  Frame 1  │  Frame 2  │  Frame 3  │  ...    │
 └─────────────────────────────────────────────┘

Frame
 ┌────────────────────────────────────────────┐
 │ length(4) │ opcode(1) │ flags(1) │ ver(1)  │
 │ request_id(8) │  payload (length bytes)     │
 └────────────────────────────────────────────┘
```

**Транспорт:** TCP (обязательно), TLS (опционально, включается в конфиге).  
**Byte order:** little-endian для всех числовых полей.  
**Кодировка строк:** UTF-8.

---

## 2. Структура фрейма

### 2.1 Заголовок (15 байт, фиксированный)

```
Offset  Size  Тип      Поле         Описание
──────────────────────────────────────────────────────────────────
0       4     uint32   length       Длина payload в байтах (БЕЗ заголовка)
4       1     uint8    opcode       Код операции (см. раздел 3)
5       1     uint8    flags        Битовые флаги (см. 2.2)
6       1     uint8    version      Версия протокола = 0x01
7       8     uint64   request_id   Уникальный ID запроса (клиент задаёт)
──────────────────────────────────────────────────────────────────
Total:  15 bytes
```

После заголовка идут `length` байт payload.
Если `length == 0`, payload отсутствует (только заголовок).

### 2.2 Флаги

```
Bit  Название          Описание
──────────────────────────────────────────────────────────────────
0    FLAG_COMPRESS      payload сжат LZ4 (planned, не в v1.0)
1    FLAG_ENCRYPTED     payload дополнительно зашифрован (AES-GCM)
2    FLAG_STREAM_MORE   есть ещё DATA_CHUNK фреймы с тем же request_id
3    FLAG_LAST_CHUNK    последний DATA_CHUNK в стриме
4    FLAG_ARROW         payload — Arrow RecordBatch IPC format
5–7  зарезервированы   должны быть 0
```

### 2.3 Правила мультиплексирования

- Клиент выбирает `request_id` самостоятельно (обычно монотонный счётчик).
- Сервер отвечает с тем же `request_id`.
- Несколько запросов можно отправить не дожидаясь ответа (pipeline).
- Ответы могут прийти в любом порядке — клиент матчит по `request_id`.
- `request_id = 0` зарезервирован для server-push уведомлений (gossip events).

---

## 3. Opcodes

### 3.1 Клиент → Сервер

```
Opcode  Hex   Название         Описание
────────────────────────────────────────────────────────────────────────
0x01    01    HELLO            Handshake: версия, аутентификация
0x02    02    QUERY            SQL-запрос (SELECT/INSERT/...)
0x03    03    PREPARE          Подготовить параметризованный запрос
0x04    04    EXECUTE          Выполнить prepared statement с параметрами
0x05    05    CANCEL           Отменить выполняющийся request_id
0x06    06    BEGIN            Начать транзакцию
0x07    07    COMMIT           Зафиксировать транзакцию
0x08    08    ROLLBACK         Откатить транзакцию
0x10    10    VECTOR_INSERT    Вставить вектор в VECTOR-таблицу
0x11    11    VECTOR_SEARCH    KNN-поиск
0x12    12    VECTOR_RANGE     Поиск в радиусе
0x20    20    GRAPH_QUERY      GQL-запрос (MATCH/PAGERANK/SHORTESTPATH)
0x21    21    GRAPH_MUTATE     Добавить/удалить узлы/рёбра
0x30    30    TRAIN_MODEL      Запустить обучение модели
0x31    31    PREDICT          Инференс одной строки
0x32    32    MODEL_INFO       Информация о версиях модели
0x33    33    MODEL_PROMOTE    Повысить версию в production
0x40    40    STREAM_FETCH     Продолжить получение стрима (flow control)
0x50    50    PING             Проверка соединения
0x51    51    CLOSE            Закрыть соединение
0xF0    F0    ADMIN            Административные команды (только admin-роль)
```

### 3.2 Сервер → Клиент

```
Opcode  Hex   Название         Описание
────────────────────────────────────────────────────────────────────────
0x80    80    HELLO_ACK        Подтверждение handshake + session token
0x81    81    RESULT_META      Схема результата (колонки + типы)
0x82    82    DATA_CHUNK       Порция данных (строки или Arrow RecordBatch)
0x83    83    RESULT_DONE      Конец результата + статистика
0x84    84    ROW_COUNT        Количество затронутых строк (INSERT/UPDATE/DELETE)
0x85    85    PREPARED_ACK     Подтверждение PREPARE + statement_id
0x86    86    TXN_ACK          Подтверждение BEGIN/COMMIT/ROLLBACK
0x87    87    VECTOR_RESULT    Результат KNN-поиска
0x88    88    GRAPH_RESULT     Результат GQL-запроса
0x89    89    TRAIN_STARTED    Обучение начато (async)
0x8A    8A    TRAIN_PROGRESS   Прогресс обучения (epoch, loss)
0x8B    8B    TRAIN_DONE       Обучение завершено + метрики
0x8C    8C    MODEL_INFO_RESP  Ответ на MODEL_INFO
0x90    90    PONG             Ответ на PING
0xE0    E0    ERROR            Ошибка (код + сообщение)
0xE1    E1    NOTICE           Предупреждение (не останавливает выполнение)
0xF0    F0    SERVER_EVENT     Push-уведомление (gossip: node up/down)
```

---

## 4. Payload форматы

### 4.1 HELLO (клиент → сервер)

```
Field              Type      Size   Описание
──────────────────────────────────────────────────────────
protocol_version   uint8     1      Должно быть 0x01
client_name_len    uint8     1      Длина имени клиента
client_name        bytes     N      UTF-8: "nimdb-go/1.0"
auth_type          uint8     1      0x00=none, 0x01=token, 0x02=mtls
token_len          uint16    2      0 если auth_type=0x00
token              bytes     M      JWT токен или пусто
session_flags      uint16    2      bit0=want_arrow, bit1=want_compress
```

### 4.2 HELLO_ACK (сервер → клиент)

```
Field              Type      Size   Описание
──────────────────────────────────────────────────────────
server_version     uint8     1      Версия сервера (0x01)
session_id         uint64    8      Уникальный ID сессии
server_flags       uint16    2      Подтверждённые флаги (echo session_flags)
node_id_len        uint8     1
node_id            bytes     N      UTF-8: "node1:5433"
```

### 4.3 QUERY (клиент → сервер)

```
Field              Type      Size   Описание
──────────────────────────────────────────────────────────
txn_id             uint64    8      0 = auto-transaction
sql_len            uint32    4      Длина SQL-строки
sql                bytes     N      UTF-8 SQL
fetch_size         uint32    4      Строк за один DATA_CHUNK (0 = all at once)
format             uint8     1      0x00=row, 0x01=arrow
```

### 4.4 RESULT_META (сервер → клиент)

```
Field              Type      Size   Описание
──────────────────────────────────────────────────────────
col_count          uint16    2
[для каждой колонки]:
  name_len         uint16    2
  name             bytes     N      UTF-8
  type_id          uint8     1      см. раздел 5 (Type System)
  nullable         uint8     1      0x00=not null, 0x01=nullable
  type_param       uint32    4      для VECTOR: dimension; для TEXT: max_len
```

### 4.5 DATA_CHUNK — Row format (format=0x00)

```
Field              Type      Size   Описание
──────────────────────────────────────────────────────────
row_count          uint32    4
[для каждой строки]:
  [для каждой колонки согласно RESULT_META]:
    is_null        uint8     1      0x01 = NULL
    value          bytes     ?      см. раздел 5
```

### 4.6 DATA_CHUNK — Arrow format (format=0x01, FLAG_ARROW=1)

```
Payload = Arrow IPC RecordBatch message (стандартный формат).
Клиент читает его как pyarrow.RecordBatch / ArrowRecordBatch (Java).
Заголовок Arrow IPC включает схему в первом батче (schema message).
```

### 4.7 RESULT_DONE (сервер → клиент)

```
Field              Type      Size   Описание
──────────────────────────────────────────────────────────
rows_total         uint64    8      Всего строк в результате
exec_time_us       uint64    8      Время выполнения, микросекунды
rows_scanned       uint64    8      Строк прочитано (до WHERE-фильтра)
plan_hint_len      uint16    2      Длина текстового плана (может быть 0)
plan_hint          bytes     N      UTF-8 текст плана выполнения
```

### 4.8 VECTOR_INSERT (клиент → сервер)

```
Field              Type      Size   Описание
──────────────────────────────────────────────────────────
table_id           uint32    4      ObjId таблицы
ext_id             int64     8      Внешний ключ (связь с основной таблицей)
dimension          uint32    4      Размерность вектора
format             uint8     1      0x00=float32, 0x01=int8 (quantised)
data               bytes     dim*4  float32 little-endian (или dim*1 для int8)
metadata_len       uint16    2      Произвольные метаданные (JSON)
metadata           bytes     N
```

### 4.9 VECTOR_SEARCH (клиент → сервер)

```
Field              Type      Size   Описание
──────────────────────────────────────────────────────────
table_id           uint32    4
k                  uint32    4      Число ближайших соседей
metric             uint8     1      0x00=cosine, 0x01=l2, 0x02=dot
ef_search          uint32    4      HNSW ef parameter (качество поиска)
use_pq             uint8     1      0x01 = использовать PQ-индекс (быстрее)
dimension          uint32    4
format             uint8     1      0x00=float32, 0x01=int8
query              bytes     dim*4
filter_sql_len     uint16    2      SQL WHERE для пост-фильтрации (может быть 0)
filter_sql         bytes     N
```

### 4.10 VECTOR_RESULT (сервер → клиент)

```
Field              Type      Size   Описание
──────────────────────────────────────────────────────────
result_count       uint32    4
[для каждого результата]:
  ext_id           int64     8
  distance         float32   4
  metadata_len     uint16    2
  metadata         bytes     N
```

### 4.11 TRAIN_MODEL (клиент → сервер)

```
Field              Type      Size   Описание
──────────────────────────────────────────────────────────
model_name_len     uint8     1
model_name         bytes     N
model_type         uint8     1      0x01=linear, 0x02=logistic, 0x03=kmeans
                                    0x04=pca, 0x05=custom
table_id           uint32    4
feature_count      uint8     1
feature_cols       uint8[]   N      индексы колонок-признаков
target_col         uint8     1      индекс целевой колонки (0xFF = нет)
options_json_len   uint16    2      JSON с гиперпараметрами
options_json       bytes     N      {"lr":0.01,"epochs":5,"k":8,...}
async              uint8     1      0x01 = не ждать завершения
```

### 4.12 GRAPH_QUERY (клиент → сервер)

```
Field              Type      Size   Описание
──────────────────────────────────────────────────────────
query_type         uint8     1      0x01=MATCH, 0x02=PAGERANK,
                                    0x03=SHORTESTPATH, 0x04=BFS, 0x05=WCC
limit              uint32    4      Max результатов
gql_len            uint32    4      Длина GQL-строки
gql                bytes     N      UTF-8 GQL
params_json_len    uint16    2
params_json        bytes     N      {"src":1,"dst":42} для SHORTESTPATH
```

### 4.13 ERROR (сервер → клиент)

```
Field              Type      Size   Описание
──────────────────────────────────────────────────────────
error_code         uint32    4      см. раздел 6
severity           uint8     1      0x00=notice, 0x01=warning, 0x02=error,
                                    0x03=fatal
sqlstate_len       uint8     1      Длина SQLSTATE (5 символов или 0)
sqlstate           bytes     5      SQLSTATE (совместимость с JDBC)
message_len        uint16    2
message            bytes     N      UTF-8 сообщение об ошибке
detail_len         uint16    2      Дополнительные детали (stack trace, hint)
detail             bytes     N
```

---

## 5. Система типов

### 5.1 Type IDs (в RESULT_META)

```
TypeID  Hex   Название    Wire формат
─────────────────────────────────────────────────────────────────────
0x01    01    NULL        0 байт (только is_null=1)
0x02    02    BOOL        1 байт: 0x00=false, 0x01=true
0x03    03    INT4        4 байта, little-endian int32
0x04    04    INT8        8 байт, little-endian int64
0x05    05    FLOAT4      4 байта, IEEE 754 float32 LE
0x06    06    FLOAT8      8 байт, IEEE 754 float64 LE
0x07    07    TEXT        uint32 length + UTF-8 bytes
0x08    08    BYTES       uint32 length + raw bytes
0x09    09    TIMESTAMP   8 байт, Unix nanoseconds int64 LE
0x0A    0A    DATE        4 байта, days since 1970-01-01 int32 LE
0x0B    0B    DECIMAL     uint8 precision + uint8 scale + 16 bytes (128-bit)
0x10    10    VECTOR_F32  uint32 dim + dim*4 float32 LE
0x11    11    VECTOR_I8   uint32 dim + dim*1 int8 (quantised)
0x12    12    TENSOR      uint8 ndim + ndim*uint32 shape + data bytes
0x20    20    JSON        uint32 length + UTF-8 JSON
0x21    21    GRAPH_NODE  (сериализованный NodeRecord)
0x22    22    GRAPH_EDGE  (сериализованный EdgeRecord)
0xFF    FF    UNKNOWN     Неизвестный тип (клиент должен пропустить по length)
```

### 5.2 NULL-представление

В Row format: перед каждым значением стоит байт `is_null`.
Если `is_null = 0x01`, то bytes значения отсутствуют (length = 0).

В Arrow format: стандартный Arrow null bitmap.

---

## 6. Коды ошибок

```
Code    Hex     Название                    Описание
──────────────────────────────────────────────────────────────────────────
1000    03E8    ERR_UNKNOWN                 Неизвестная ошибка
1001    03E9    ERR_PARSE                   Ошибка парсинга SQL/GQL
1002    03EA    ERR_SYNTAX                  Синтаксическая ошибка
1003    03EB    ERR_SEMANTIC                Семантическая ошибка (неизвестная колонка)
2000    07D0    ERR_TABLE_NOT_FOUND         Таблица не существует
2001    07D1    ERR_TABLE_EXISTS            Таблица уже существует
2002    07D2    ERR_COLUMN_NOT_FOUND        Колонка не существует
2003    07D3    ERR_TYPE_MISMATCH           Несовместимые типы
3000    0BB8    ERR_TXN_CONFLICT            Конфликт транзакций (retry возможен)
3001    0BB9    ERR_TXN_DEADLOCK            Deadlock обнаружен
3002    0BBA    ERR_TXN_TIMEOUT             Timeout ожидания блокировки
3003    0BBB    ERR_TXN_ABORTED             Транзакция была отменена
4000    0FA0    ERR_STORAGE                 Ошибка хранилища
4001    0FA1    ERR_WAL_CORRUPT             Повреждение WAL
4002    0FA2    ERR_PAGE_CORRUPT            Повреждение страницы
4003    0FA3    ERR_DISK_FULL               Диск заполнен
5000    1388    ERR_VECTOR_DIM_MISMATCH     Несовпадение размерностей вектора
5001    1389    ERR_MODEL_NOT_FOUND         Модель не существует
5002    138A    ERR_MODEL_TYPE_MISMATCH     Неверный тип модели
5003    138B    ERR_TRAINING_FAILED         Ошибка обучения
6000    1770    ERR_AUTH_FAILED             Ошибка аутентификации
6001    1771    ERR_PERMISSION_DENIED       Нет прав на операцию
6002    1772    ERR_SESSION_EXPIRED         Сессия истекла
7000    1B58    ERR_CLUSTER_UNAVAILABLE     Кластер недоступен
7001    1B59    ERR_NODE_NOT_FOUND          Нода не найдена в кольце
7002    1B5A    ERR_REPLICATION_LAG         Отставание репликации превышает порог
```

---

## 7. Жизненный цикл сессии

```
Клиент                                    Сервер
  │                                          │
  │──── TCP connect ──────────────────────▶ │
  │──── HELLO (req_id=1) ─────────────────▶ │
  │◀─── HELLO_ACK (req_id=1) ───────────── │
  │                                          │
  │──── BEGIN (req_id=2) ─────────────────▶ │
  │◀─── TXN_ACK (req_id=2, txn_id=42) ──── │
  │                                          │
  │──── QUERY (req_id=3, txn_id=42) ──────▶ │
  │◀─── RESULT_META (req_id=3) ──────────── │
  │◀─── DATA_CHUNK (req_id=3, FLAG_MORE) ── │
  │◀─── DATA_CHUNK (req_id=3, FLAG_LAST) ── │
  │◀─── RESULT_DONE (req_id=3) ──────────── │
  │                                          │
  │──── QUERY (req_id=4) ─────────────────▶ │  ← pipeline: не ждём ответа req_id=3
  │──── COMMIT (req_id=5, txn_id=42) ─────▶ │
  │◀─── TXN_ACK (req_id=5) ─────────────── │  ← ответы могут прийти не по порядку
  │◀─── ROW_COUNT (req_id=4) ────────────── │
  │                                          │
  │──── CLOSE (req_id=6) ─────────────────▶ │
  │◀─── TCP close ───────────────────────── │
```

### Обработка ошибок в транзакции

Если сервер вернул `ERROR` во время транзакции — транзакция переходит
в состояние `ABORTED`. Клиент обязан отправить `ROLLBACK` перед
следующим запросом (или переиспользовать соединение только после rollback).

---

## 8. Streaming для больших результатов

Для OLAP-запросов и ML-pipeline результат может быть гигабайтным.
Протокол поддерживает back-pressure через `STREAM_FETCH`:

```
Клиент                                    Сервер
  │──── QUERY (fetch_size=1000) ──────────▶ │
  │◀─── RESULT_META ─────────────────────── │
  │◀─── DATA_CHUNK (1000 rows, FLAG_MORE) ─ │  ← сервер останавливается
  │                                          │    и ждёт STREAM_FETCH
  │ (клиент обрабатывает 1000 строк)         │
  │──── STREAM_FETCH (req_id) ────────────▶ │
  │◀─── DATA_CHUNK (1000 rows, FLAG_MORE) ─ │
  │──── STREAM_FETCH ──────────────────────▶ │
  │◀─── DATA_CHUNK (547 rows, FLAG_LAST) ── │
  │◀─── RESULT_DONE ─────────────────────── │
```

Если `fetch_size = 0`, сервер отправляет все данные сразу (no back-pressure).
Используется для маленьких результатов или Arrow-режима (Arrow оптимально
большими батчами).

---

## 9. Test vectors

Каждый test vector — это пара `request.bin` / `response.bin` с точными
байтами. Все четыре драйвера (Go, Java, Python, C) тестируются против
одного набора vectors. Vectors хранятся в `protocol/test_vectors/`.

### Vector 01 — HELLO/HELLO_ACK

```
REQUEST (hex):
00 00 00 09        # length = 9 (payload)
01                 # opcode = HELLO
00                 # flags = 0
01                 # version = 1
01 00 00 00 00 00 00 00  # request_id = 1
-- payload (9 bytes) --
01                 # protocol_version = 1
07                 # client_name_len = 7
6E 69 6D 64 62 2D 67 6F  # "nimdb-go" (8 bytes — wait, name_len=7, so 7 bytes)
# Correction: 6E 69 6D 64 62 2D 67  # "nimdb-g" -- just example
00                 # auth_type = none (0x00)
00 00              # token_len = 0
00 00              # session_flags = 0
```

> Полные бинарные vectors генерируются утилитой `nimdbctl gen-vectors`
> и лежат в `protocol/test_vectors/` как `*.bin` файлы с `manifest.json`.

### Структура test vector manifest

```json
{
  "version": "1.0",
  "vectors": [
    {
      "id": "01-hello",
      "description": "Basic handshake without auth",
      "request":  "01-hello-req.bin",
      "response": "01-hello-resp.bin",
      "client_state_after": "authenticated"
    },
    {
      "id": "02-simple-query",
      "description": "SELECT 1+1 AS result",
      "request":  "02-query-req.bin",
      "response": ["02-meta-resp.bin", "02-data-resp.bin", "02-done-resp.bin"]
    }
  ]
}
```

---

## 10. Версионирование протокола

- Поле `version` в заголовке каждого фрейма позволяет определить версию.
- Сервер принимает клиентов версии `version >= 1`.
- Новые opcodes добавляются в зарезервированных диапазонах.
- Breaking changes (изменение существующих форматов) требуют новой major-версии
  и новый `version = 0x02`.
- `HELLO`/`HELLO_ACK` обменивается поддерживаемыми версиями — сервер
  подтверждает минимальную совместимую версию.

---

## 11. Псевдокод парсера фрейма (reference implementation)

```
# Минимальный парсер — одинаков для Go/Java/Python/C

HEADER_SIZE = 15

function read_frame(socket):
    header = socket.read_exact(HEADER_SIZE)
    length    = u32_le(header[0:4])
    opcode    = header[4]
    flags     = header[5]
    version   = header[6]
    request_id = u64_le(header[7:15])

    payload = socket.read_exact(length)

    return Frame {
        opcode:     opcode,
        flags:      flags,
        version:    version,
        request_id: request_id,
        payload:    payload
    }

function write_frame(socket, opcode, flags, request_id, payload):
    header = bytes(15)
    u32_le_into(header[0:4], len(payload))
    header[4] = opcode
    header[5] = flags
    header[6] = 0x01       # version
    u64_le_into(header[7:15], request_id)
    socket.write(header + payload)
```

---

## 12. Контрольный список совместимости драйвера

Драйвер считается совместимым с NDP v1.0 если он:

- [ ] Корректно читает заголовок фрейма (15 байт, LE)
- [ ] Поддерживает pipelining (несколько запросов без ожидания ответа)
- [ ] Обрабатывает DATA_CHUNK со стримингом (FLAG_STREAM_MORE / FLAG_LAST_CHUNK)
- [ ] Поддерживает Arrow format (FLAG_ARROW) как альтернативу row format
- [ ] Корректно обрабатывает все коды ошибок из раздела 6
- [ ] Проходит все test vectors из `protocol/test_vectors/`
- [ ] Реализует HELLO/HELLO_ACK handshake
- [ ] Поддерживает транзакции (BEGIN/COMMIT/ROLLBACK)
- [ ] Поддерживает VECTOR_INSERT / VECTOR_SEARCH
- [ ] Поддерживает TRAIN_MODEL / PREDICT (для ML-ориентированных клиентов)
