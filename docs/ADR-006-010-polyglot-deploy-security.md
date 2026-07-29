# ADR-006: Полиглотная экосистема

**Статус:** accepted  
**Дата:** 2025-01

---

## Принцип выбора языка

> Каждый язык используется там, где он даёт **объективное** техническое
> преимущество — не для количества строчек в резюме.

---

## Go — Gateway + nimdbctl

**Почему Go:**
- Goroutine per connection — тысячи клиентов без callback hell
- Статический бинарник без зависимостей — `nimdbctl` распространяется
  как единый файл (как kubectl, helm, terraform)
- `net/http` + `swaggo` → Swagger за минуты
- `context` — propagation timeout/cancel через цепочку вызовов к шардам
- Circuit breaker нативно выражается через channel-паттерны

**Что конкретно реализует Go:**

| Компонент | Роль |
|-----------|------|
| `nimdbctl` | CLI-bootstrapper: init, up, status, join, benchmark |
| API Gateway | REST/gRPC façade, auth, rate-limit, consistent-hash routing |
| Prometheus exporter | `/metrics` endpoint, custom collectors |
| Load tester | Внутренний stress-тест (аналог vegeta) |

**Почему НЕ для движка:** GC-паузы, отсутствие SIMD-intrinsics, нет union-типов для page layout.

---

## Java — JDBC-драйвер + Spring-сервис

**Почему Java:**
- JDBC SPI — стандартный интерфейс для `java.sql.*`; реализовав его,
  получаем совместимость с DBeaver, Hibernate, Spring Data без изменений
- Spring Boot — зрелый стек для model-serving: Caffeine cache, Micrometer
  метрики, Spring Security, actuator healthcheck из коробки
- JVM — правильный рантайм для сервисов с долгим временем жизни и
  оптимизацией JIT (в отличие от движка, где нужна предсказуемая latency)

**Что конкретно реализует Java:**

| Компонент | Роль |
|-----------|------|
| `nimdb-jdbc` | `java.sql.Driver` + `Connection` + `Statement` + `ResultSet` |
| Spring model-serving | Загружает Linear/KMeans из Model Registry, кэширует, инференс |
| JNI bridge (опц.) | Вызов `libnimdb.so` для embedded mode |

---

## Python — Драйвер + RecSys

**Почему Python:**
- DB-API 2.0 (`PEP 249`) — стандарт для Python-драйверов; `pandas.read_sql`
  работает без изменений
- ML-ecosystem: PyTorch, scikit-learn, FAISS, sentence-transformers —
  Python, нравится нам это или нет, остаётся lingua franca ML
- Arrow zero-copy: `pyarrow.RecordBatch` → pandas DataFrame без копирования

**Что конкретно реализует Python:**

| Компонент | Роль |
|-----------|------|
| `nimdb-python` driver | DB-API 2.0, Arrow-десериализация результатов |
| RecSys pipeline | Ingestion → embedding training → candidate gen → ranking |
| two-tower модель | PyTorch, экспорт эмбеддингов в NimDB VECTOR |
| FastAPI serving | Тонкий inference endpoint поверх NimDB KNN |

---

## C/C++ — SIMD-библиотека

**Почему C/C++:**
- Единственный язык, дающий *гарантированный* доступ к AVX2/AVX-512 intrinsics
  (`<immintrin.h>`) без надежды на "компилятор сам векторизует"
- `libnimdb_simd.so` — переиспользуется из Python (ctypes), Java (JNI),
  и самим Nim-движком через FFI: один раз написанный SIMD-код работает везде
- Позволяет получить измеримые цифры: "ручной AVX2 dot = 8.4 GFLOPs vs
  auto-vectorized Nim = 5.1 GFLOPs" — конкретная строчка в резюме

**Что конкретно реализует C:**

| Компонент | Роль |
|-----------|------|
| `simd_f32.c` | AVX2/NEON dot, L2, cosine — с prefetch и FMA |
| `pq_encode.c` | Product Quantization ADC — SIMD lookup table summation |
| `libnimdb.h` | C ABI header для всех клиентов |
| (опц.) мобильный клиент | `libnimdb.a` → JNI (Android) / bridging header (iOS) |

---

## Frontend — Console

**Почему отдельный фронт (не просто REPL):**
- Визуализация consistent-hash ring (живая, с анимацией нод) —
  нельзя показать в терминале
- Vector search demo: 2D-проекция (UMAP/t-SNE) эмбеддингов, интерактивный KNN
- Model Registry UI: версии, метрики, A/B test ratio — для презентации проекта

**Стек:** SvelteKit (компактнее React, TypeScript, SSR из коробки) + D3.js для визуализации.

---

---

# ADR-007: Монорепозиторий

**Статус:** accepted  
**Дата:** 2025-01

## Контекст

7 компонентов на 5 разных языках. Нужно решить: монорепо vs полирепо.

## Принятое решение: монорепо

**За монорепо в данном контексте:**
- Протокол (`protocol/SPEC.md`) — единая точка правды. Изменение
  опкода видно одновременно во всех драйверах, нет синхронизации
  между репозиториями.
- Test vectors — общие для Go/Java/Python/C; один `make test-vectors`
  проверяет все реализации протокола.
- `nimdbctl up` поднимает всё из одного места — проще для demo.
- Один человек (ты) управляет всем; overhead полирепо не оправдан.

**Структура:**
```
nimdb/
├── core/           # Nim engine
├── protocol/       # SPEC.md, test_vectors/, opcodes.md
├── drivers/
│   ├── go/         # Go driver (используется gateway-ем)
│   ├── java/       # nimdb-jdbc
│   ├── python/     # nimdb-python (DB-API 2.0)
│   └── c/          # libnimdb.so + SIMD library
├── services/
│   ├── gateway/    # Go REST/gRPC gateway
│   ├── recsys/     # Python ML pipeline
│   └── model-serving/ # Java Spring
├── console/        # SvelteKit frontend
├── deploy/
│   ├── nimdbctl/   # Go CLI bootstrapper
│   ├── docker/     # Dockerfiles
│   ├── compose/    # docker-compose.yml templates
│   └── grafana/    # dashboards JSON
└── docs/
    ├── adr/        # этот каталог
    └── spec/       # NDP-PROTOCOL.md и другие спеки
```

---

---

# ADR-008: Деплой — nimdbctl + Docker

**Статус:** accepted  
**Дата:** 2025-01

## Принятое решение

**`nimdbctl`** — единый Go-бинарник (статический, cross-compiled) для операций:

```
nimdbctl init          # интерактивный wizard → nimdb.toml
nimdbctl up            # старт локально или docker-compose up
nimdbctl cluster add-node <addr>
nimdbctl cluster status
nimdbctl benchmark     # встроенный load test
nimdbctl shell         # подключение к REPL
nimdbctl export <table> <file.arrow>
```

**Генерация конфига:** `nimdbctl init` задаёт вопросы и генерирует:
- `nimdb.toml` — конфиг ноды
- `docker-compose.yml` — для кластера из N нод с правильными сетями и volumes
- `prometheus.yml` — scrape config для метрик

**Формат конфига:**
```toml
[node]
id   = "node1"
host = "0.0.0.0"
port = 5433         # NDP wire protocol

[cluster]
seeds       = ["node2:5433", "node3:5433"]
replication = 3
mode        = "pa-el"   # или "strong"

[storage]
data_dir    = "/var/lib/nimdb"
buffer_pool = "512MB"
wal_sync    = "per_commit"   # или "async" для batch workload

[modes]
default = "oltp"   # oltp | olap | vector | hybrid

[ml]
model_registry = true
feature_store  = true

[gateway]
enabled = true
port    = 8080
swagger = true
```

---

---

# ADR-009: Наблюдаемость

**Статус:** accepted  
**Дата:** 2025-01

## Три столпа наблюдаемости

**Метрики (Prometheus + Grafana):**
- `nimdb_queries_total{type="SELECT|INSERT|TRAIN|VECTOR_SEARCH"}`
- `nimdb_query_latency_p99_ms`
- `nimdb_buffer_pool_hit_rate`
- `nimdb_wal_flush_latency_ms`
- `nimdb_hnsw_search_latency_ms`
- `nimdb_model_predict_latency_ms`
- `nimdb_gossip_alive_nodes`

**Трассировка (OpenTelemetry):**
- Трейс через цепочку: `curl → Go gateway → Nim core → (HNSW | heap scan)`
- Span'ы: `parse_query`, `plan`, `buffer_pool_pin`, `wal_write`, `hnsw_search`
- Экспорт в Jaeger (локально) или OTLP endpoint

**Логи (структурированные, JSON):**
- WAL-операции: LSN, txnId, type, latency
- Slow query log: запросы > 100ms с планом выполнения
- Gossip события: node up/down/suspect

---

---

# ADR-010: Безопасность и приватность

**Статус:** accepted  
**Дата:** 2025-01

## Транспортная безопасность

- **mTLS между нодами** (gossip + репликация) — ноды аутентифицируют
  друг друга по сертификатам, выданным CA кластера
- **TLS на NDP-порту** — опционально, включается в `nimdb.toml`
- **Токен-аутентификация на gateway** — JWT, проверяется в Go gateway,
  Nim-движок работает без аутентификации внутри доверенной сети

## Приватность ML-моделей (connection к дипломной теме)

Опциональный режим: **DP-SGD (Differentially Private SGD)**
для `TRAIN MODEL TYPE linear|logistic`:

- Gaussian noise добавляется к градиентам (σ параметр)
- ε-δ privacy budget отслеживается в Model Registry
- Практический результат: модель не "запоминает" отдельные записи

Это прямое применение темы дипломной работы (Rényi DP, certified robustness)
к реальной системе — сильный аргумент на защите.

```toml
[ml.privacy]
enabled = true
epsilon = 1.0
delta   = 1e-5
noise_multiplier = 1.1
max_grad_norm    = 1.0
```

## RBAC (Role-Based Access Control)

- Роли: `admin`, `writer`, `reader`, `ml_user` (может делать TRAIN/PREDICT)
- Хранятся в системной таблице `_nimdb_users` (OLTP, реплицируется)
- Проверяются на gateway; Nim-движок принимает только авторизованные
  соединения с signed session token
