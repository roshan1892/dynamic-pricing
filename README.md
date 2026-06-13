# Dynamic Pricing Proxy

A Ruby on Rails service that acts as a caching proxy for Tripla's dynamic pricing model.

## The Problem

Tripla's AI pricing model calculates hotel room rates in real time, but it is computationally expensive to run. The API is rate-limited to **1,000 calls per day** via a single token.

The current implementation calls the upstream API on every user request. At 10,000+ requests per day, that blows through the daily quota almost immediately.

**Key insight:** Tripla's data team confirmed a fetched rate stays accurate for **5 minutes**. This means we can cache each result and serve it to many users before it needs refreshing.

## Constraints

| Constraint | Value |
|---|---|
| User requests to handle per day | 10,000+ |
| Upstream API calls allowed per day | 1,000 |
| Rate validity window | 5 minutes |
| Unique parameter combinations | 4 seasons × 3 hotels × 3 rooms = 36 |

Caching reduces upstream calls when the same combination is requested more than once within a 5-minute window. The effectiveness depends entirely on traffic distribution.

**Theoretical worst case:** all 36 combinations requested continuously every 5 minutes, all day — 36 × 12 × 24 = **10,368 upstream calls/day**, exceeding the 1,000 limit.

**Real-world traffic:** having all 36 combinations actively requested within every single 5-minute window simultaneously is highly unlikely. In practice, traffic concentrates on a small number of popular combinations, and those combinations get requested repeatedly within each 5-minute window — meaning one upstream call serves many users. Under realistic traffic patterns, this solution stays well within the 1,000 calls/day quota.

## Solution

Introduce a caching layer between users and the upstream API:

```
User Request
     ↓
Rails Proxy (this service)
     ↓ cache hit → return cached rate (no upstream call)
     ↓ cache miss / stale → call upstream, store result, return rate
Upstream Rate API (expensive, 1,000 calls/day)
```

### Options Considered

> Note: "cache" here refers to the concept — temporary storage to avoid repeating expensive upstream calls. The specific technology used to implement it is discussed in the Design Decisions section.

**Option 1 — Per-combination on-demand cache (chosen)**
Cache each `(period, hotel, room)` combination independently. On a user request, check the cache first — if fresh (< 5 minutes old), serve it directly. If stale or missing, call the upstream API, store the result, and return it.

**Option 2 — Batch all 36 combinations on any cache miss for a request**
When any combination is stale, fetch all 36 in a single upstream request (the API supports batching natively) and refresh the entire cache at once. This caps worst-case upstream calls at 1 call per 5-minute window × 12 × 24 = **288 calls/day** regardless of traffic distribution.
Rejected because: fetches data for all 36 combinations even when only 1 or 2 are being requested — unnecessarily refreshing combinations nobody asked for. The batch request also carries significantly higher network bandwidth and takes longer to process than a single combination request, meaning the specific user who triggered the cache miss experiences higher latency waiting for all 36 results. Also adds implementation complexity around parsing and storing batch responses, and handling partial failures within a batch.

**Option 3 — Background job refreshing all 36 every 5 minutes**
A scheduled job proactively refreshes all combinations before they expire, so users always read from a warm cache.
Rejected because: always fetches all 36 regardless of demand, requires a job scheduler and failure handling, and adds significant complexity beyond what the assignment requires.


### Final Decision

Option 1 — per-combination on-demand cache. It is the simplest approach, only calls upstream for combinations that are actually requested, and works correctly under realistic traffic where a few popular combinations account for most requests.

**Known tradeoff:** in the theoretical worst case where all 36 combinations are requested continuously across every 5-minute window, upstream calls could reach 36 × 12 × 24 = **10,368/day** — exceeding the 1,000 limit. If this limit is hit, the upstream API returns HTTP 429. Our service handles this gracefully by returning a clear descriptive error to the user. If worst-case correctness became a hard requirement, switching to Option 2 (batching all 36 in a single upstream request) would cap calls at 288/day. Option 3 (background job) could also achieve this but only if it uses batching internally — otherwise it faces the same worst-case problem.

## Failure Modes Identified

| Failure | Our Service Returns | Error Code | Handling |
|---|---|---|---|
| Missing or invalid parameters | 400 | `INVALID_PARAMETERS` | Validated before hitting cache or upstream |
| Network timeout to upstream API | 503 | `UPSTREAM_TIMEOUT` | Return descriptive error |
| Upstream API unreachable | 503 | `UPSTREAM_TIMEOUT` | Return descriptive error |
| Rate limit exhausted (assumed HTTP 429 — not explicitly documented in API spec) | 503 | `RATE_LIMIT_EXCEEDED` | Return descriptive error |
| Upstream API returned non-2xx response (3xx, 4xx, 5xx) | 503 | `UPSTREAM_ERROR` | Return descriptive error — logged with specific event per status range for internal observability |
| Unreadable response (not valid JSON) | 503 | `UPSTREAM_ERROR` | Return descriptive error |
| Rate missing in successful response | 503 | `RATE_NOT_FOUND` | Defensive — not a documented API behaviour, but the existing code uses a safe navigation operator (`&.dig`) suggesting the original author anticipated this case |
| Concurrent requests for same stale key | — | — | Only one upstream call fires — cache stampede prevention |
| Unexpected internal error (bug, SQLite failure, etc.) | 500 | `INTERNAL_ERROR` | Caught by controller safety net — always returns JSON, never an HTML error page |

Note: upstream failures return **503 (Service Unavailable)** rather than 500 — the problem is with the external dependency, not our service itself.

## API

### `GET /api/v1/pricing`

**Parameters** (all required):

| Parameter | Valid Values |
|---|---|
| `period` | `Summer`, `Autumn`, `Winter`, `Spring` |
| `hotel` | `FloatingPointResort`, `GitawayHotel`, `RecursionRetreat` |
| `room` | `SingletonRoom`, `BooleanTwin`, `RestfulKing` |

**Success response — HTTP 200:**
```json
{ "rate": "12000" }
```

**Error response structure:**
```json
{
  "code": "MACHINE_READABLE_ERROR_CODE",
  "message": "Human readable description of what went wrong and any relevant next steps."
}
```

**Examples:**
```json
{ "code": "INVALID_PARAMETERS", "message": "Invalid period. Must be one of: Summer, Autumn, Winter, Spring" }
{ "code": "RATE_LIMIT_EXCEEDED", "message": "The upstream pricing API daily quota has been exhausted. Please try again later." }
{ "code": "UPSTREAM_TIMEOUT",    "message": "The upstream pricing API did not respond in time. Please try again." }
{ "code": "UPSTREAM_ERROR",      "message": "The upstream pricing API returned an unexpected error (HTTP 500)." }
{ "code": "RATE_NOT_FOUND",      "message": "No rate was returned for the requested combination." }
{ "code": "INTERNAL_ERROR",     "message": "An unexpected error occurred. Please try again." }
```

## Observability

Every request emits structured JSON log events, making it easy to monitor behaviour, diagnose issues, and derive metrics in a log aggregation tool (e.g. Datadog, ELK, CloudWatch).

Each log entry includes `timestamp` (ISO 8601), `request_id` (from Rails' `X-Request-Id` header — auto-generated if not provided by the client), `period`, `hotel`, and `room` for full request context. This allows all log lines for a single request to be correlated by `request_id`.

### Log Events

| Event | Level | Fields | When |
|---|---|---|---|
| `cache_hit` | info | `request_id`, `period`, `hotel`, `room` | Fresh rate served from cache — no upstream call |
| `cache_miss` | info | `request_id`, `period`, `hotel`, `room` | Cache empty or stale — upstream call will follow |
| `upstream_api_call` | info | + `duration_ms` | Every upstream API call with response time |
| `cache_store` | info | + `duration_ms` | Rate successfully stored in cache — `duration_ms` is SQLite write time |
| `upstream_rate_limit` | warn | + `body` | HTTP 429 received — daily quota exhausted |
| `upstream_redirect_error` | warn | + `http_code`, `body` | HTTP 3xx received — unexpected redirect, likely a configuration issue |
| `upstream_client_error` | warn | + `http_code`, `body` | HTTP 4xx received — our request was rejected, API contract may have changed |
| `upstream_server_error` | error | + `http_code`, `body` | HTTP 5xx received — upstream service is having problems |
| `upstream_timeout` | error | `request_id`, `period`, `hotel`, `room` | Request timed out |
| `upstream_connection_error` | error | `request_id`, `period`, `hotel`, `room` | Upstream API unreachable |
| `upstream_parse_error` | error | `request_id`, `period`, `hotel`, `room` | Unreadable response from upstream |
| `rate_not_found` | warn | `request_id`, `period`, `hotel`, `room` | Successful response but rate missing for requested combination |
| `unexpected_error` | error | `message`, `backtrace` | Unhandled exception caught by controller safety net |

### Example Log Lines

```json
{"timestamp":"2026-06-13T09:21:15.123Z","request_id":"abc-123","period":"Summer","hotel":"FloatingPointResort","room":"SingletonRoom","event":"cache_miss"}
{"timestamp":"2026-06-13T09:21:15.245Z","request_id":"abc-123","period":"Summer","hotel":"FloatingPointResort","room":"SingletonRoom","event":"upstream_api_call","duration_ms":245}
{"timestamp":"2026-06-13T09:21:15.490Z","request_id":"abc-123","period":"Summer","hotel":"FloatingPointResort","room":"SingletonRoom","event":"cache_store","duration_ms":2}
{"timestamp":"2026-06-13T09:21:16.001Z","request_id":"xyz-456","period":"Summer","hotel":"FloatingPointResort","room":"SingletonRoom","event":"cache_hit"}
```

### Deriving Metrics from Logs

Since logs are structured JSON, a log aggregation tool can derive metrics without any additional instrumentation:
- **Cache hit rate** — count of `cache_hit` ÷ total requests
- **Upstream API latency** — average `duration_ms` from `upstream_api_call` events
- **Error rate** — count of `upstream_error` + `upstream_timeout` + `upstream_connection_error` events
- **Quota consumption** — count of `upstream_api_call` events per day

### Note on Traces

Distributed tracing (e.g. OpenTelemetry) is not implemented — the `request_id` in every log line provides basic request correlation sufficient for this single-service deployment. Full distributed tracing would be the next step if this service communicated with other downstream services.

## Setup & Running

### Prerequisites

- Docker and Docker Compose

### Start the service

```bash
docker compose up -d --build
```

This starts two containers:
- `interview-dev` — the Rails proxy service on port 3000
- `rate-api` — the upstream pricing model on port 8080

### Test the endpoint

```bash
curl 'http://localhost:3000/api/v1/pricing?period=Summer&hotel=FloatingPointResort&room=SingletonRoom'
```

### Run the test suite

```bash
# Full suite
docker compose exec interview-dev ./bin/rails test

# Specific file
docker compose exec interview-dev ./bin/rails test test/controllers/pricing_controller_test.rb
```

### Stop the service

```bash
docker compose down
```

## Design Decisions

### Caching Technology

The core requirement is storing fetched rates temporarily and serving them within a 5-minute validity window to avoid hitting the upstream API on every request. Three options were considered.

---

**Option 1 — In-Memory Store (class variable / Ruby Hash)**

Store cached rates directly in a Ruby class variable inside the Rails app process.

| | |
|---|---|
| Dependencies | None |
| New failure modes | None |
| Works across Puma workers | ❌ No |
| Works across multiple servers | ❌ No |

Rejected because each Puma worker process has completely isolated memory. A rate cached by worker 1 is invisible to worker 2 — they would each call the upstream API independently for the same combination, making the cache ineffective and burning through the 1,000 calls/day quota. This approach does not satisfy even single-server correctness.

---

**Option 2 — Redis**

Redis is a dedicated in-memory data store, purpose-built for caching. It stores data entirely in RAM, making reads and writes extremely fast (~0.1ms). It has native TTL support — key expiry is handled automatically with no timestamp logic needed in application code. It is the industry standard for this exact use case.

| | |
|---|---|
| Dependencies | New Docker service + `redis` gem |
| New failure modes | Redis unavailable, Redis out of memory |
| Works across Puma workers | ✅ Yes |
| Works across multiple servers | ✅ Yes |

Rejected because it introduces Redis as a new network dependency — a separate process that can go down independently of the Rails app. If Redis becomes unavailable, every incoming request becomes a cache miss and hits the upstream API directly. At 10,000 requests/day, this could exhaust the 1,000 calls/day quota very rapidly. Handling this correctly requires Redis health checks, connection error handling, and a deliberate decision on fail-open vs fail-closed behaviour — all additional complexity that introduces more operational risk than it solves at this scale.

It is also worth noting that adding Redis as a docker-compose container does not actually solve the multi-server problem. When `docker compose up` is run on two separate nodes, each node gets its own isolated Redis container with its own data — the same limitation as SQLite. True distributed correctness requires a single dedicated shared Redis host that all app servers point to, which is a significantly larger infrastructure commitment beyond the scope of this assignment.

---

**Option 3 — SQLite (chosen)**

SQLite is not a separate server process like Redis or PostgreSQL. It is a library embedded directly inside the Rails app that reads and writes a single file on disk. There is no network connection, no separate process, and no connection management — if the Rails app is running, SQLite is available. It is already present and configured in the scaffold with zero additional setup required.

| | |
|---|---|
| Dependencies | None — already in scaffold |
| New failure modes | None |
| Works across Puma workers | ✅ Yes — all workers share the same file |
| Works across multiple servers | ❌ No — each server has its own file |

**Why SQLite is sufficient for this assignment:**

The assignment requires handling 10,000+ requests/day. In practice:

| Metric | Value |
|---|---|
| Average requests per second | ~0.12 (10,000 ÷ 86,400) |
| Peak requests per second (assumed 200× average as a conservative worst case) | ~24 |
| Single server capacity — cache-hit path (assumed: 2 CPU cores, 4GB RAM, Puma 2 workers × 5 threads) | ~500–1,000 req/sec |
| Headroom above peak | ~20–40× |

SQLite reads from disk and is fast enough for this use case — cache reads are simple single-row lookups on a table with at most 36 rows, and write locks only activate on a cache miss which is a rare event (at most once per combination per 5-minute window). At 24 peak requests/second, both read latency and write contention are negligible. Even at full single-server capacity (500–1,000 req/sec), SQLite handles concurrent reads comfortably since multiple readers never block each other — only writes require a brief lock, and cache misses remain rare regardless of traffic volume.

Redis is faster than SQLite since it stores data entirely in memory. However the actual latency difference depends heavily on deployment topology — whether Redis is on the same machine, a different node, or a managed service on a separate host — and under typical conditions both are in a similar low-millisecond range that makes no noticeable difference to users at this traffic level.

**Known limitation:** if this service were deployed across multiple servers, each server would have its own SQLite file and the cache would not be shared between instances. In that scenario Redis would be the correct replacement. This is a deliberate tradeoff — the FAQ explicitly states *"production-ready does not mean FAANG-scale"* and to *"choose the most straightforward path."* SQLite solves the actual problem correctly without introducing infrastructure that the assignment does not require.

---

### Upstream Error Response Handling

The upstream API documentation only specifies the happy path response format. Error response format, structure, and HTTP status codes are undocumented. Because of this we return our own structured `{ code, message }` error to the client rather than passing through the upstream response — whose format and stability we cannot rely on.

If the upstream API were to document a structured error format in the future, surfacing the upstream error message alongside our own would improve troubleshooting for clients. For now, the raw upstream response body is logged internally so that it is available for debugging without exposing it to clients.

---

### Cache Table Schema

**Separate columns vs single key column**

Two options were considered for storing the cache key:

- **Single key column** — store `"Summer.FloatingPointResort.SingletonRoom"` as one string with a separate `value` column
- **Separate columns** — store `period`, `hotel`, `room` as individual columns (chosen)

The single key column approach violates **First Normal Form (1NF)** — a fundamental relational database design principle that each column should store one atomic value, not a composite of multiple values squashed into a string. Separate columns keep each field as a distinct meaningful piece of data, making queries explicit and rows human-readable.

**Composite unique index on `(period, hotel, room)`**

A unique index is added across all three columns. This serves two purposes:
- **Data integrity** — the database enforces that only one cached rate can exist per combination, preventing duplicate rows from concurrent writes
- **Upsert support** — when refreshing a stale rate, `upsert` uses this unique index to decide whether to insert a new row or update the existing one, in a single atomic operation

**`null: false` on all columns**

Every column is defined with `null: false`, enforcing at the database level that no row can be stored with missing values. This is a last line of defence — even if application-level logic has a bug, the database will reject incomplete data loudly rather than silently storing corrupt rows.

---

### Cache Stampede Prevention

When a cached rate expires, multiple concurrent requests for the same combination could simultaneously find the cache stale and all call the upstream API — wasting quota and potentially exhausting the 1,000 calls/day limit.

**Within a single Puma process (threads):**

A per-key Mutex with double-checked locking is used:

1. First cache check outside the lock — cache hits require no locking at all, so uncontested requests are never slowed down
2. If stale, acquire a Mutex specific to that cache key — only threads competing for the same combination block each other, unrelated combinations proceed in parallel
3. Second cache check inside the lock — a thread that was waiting may find the cache already refreshed by the thread that held the lock, avoiding a redundant upstream call
4. If still stale after second check — call upstream, store result, return

**Across multiple Puma worker processes:**

A Mutex lives in process memory and is invisible to other processes. Unlike PostgreSQL which supports row-level locking, SQLite only supports table-level locking — meaning a table-level lock held during an upstream HTTP call would block all cache reads across all worker processes for that entire duration. This is too aggressive and would significantly degrade performance.

Given SQLite as the caching solution, the **optimistic approach is the most appropriate choice**. The optimistic approach means no explicit locking is used across processes — each worker proceeds independently, assuming that concurrent access to the same stale entry will be rare. If multiple worker processes simultaneously find a stale entry and all call upstream, `upsert` handles the concurrent writes safely with no data corruption and all processes return a valid fresh rate. The worst case is N extra upstream calls (where N is the number of worker processes) for the same stale combination at the same moment.

In practice this is not a concern for this assignment — Puma is configured with a single worker process by default (`WEB_CONCURRENCY` not set), meaning cross-process stampede cannot occur in our current deployment. The Mutex-based per-key locking fully protects all 5 threads within that single process.

For guaranteed cross-process stampede prevention, the solution would need to move away from SQLite — `PostgreSQL SELECT FOR UPDATE` provides row-level locking that works correctly across processes without blocking unrelated reads, or Redis Redlock provides a distributed lock mechanism. Both are valid production solutions but require infrastructure changes beyond the scope of this assignment.

---

### Puma Worker Process Configuration

A single Puma worker process with 5 threads is used for this assignment. Multiple worker processes were not configured because a single process is more than sufficient for the stated requirement of 10,000 requests/day (0.12 req/sec average, ~24 req/sec at conservative peak). Adding worker processes would increase memory usage and complexity without providing any capacity benefit at this traffic level.

Estimated capacity of a single worker with 5 threads:

| Path | Estimated Max QPS |
|---|---|
| Cache hit (SQLite read + JSON response) | ~100–200 req/sec |
| Mixed (mostly cache hits, occasional miss) | ~80–150 req/sec |
| Pure cache misses (upstream API dominates) | ~10–25 req/sec |

Note: these are informed estimates based on typical Rails/Puma behaviour with SQLite — exact numbers would require a load test. At ~24 req/sec peak, our setup has comfortable headroom even under the most conservative estimate.

If traffic requirements grew significantly, `WEB_CONCURRENCY` could be set to match the number of CPU cores to achieve true parallelism. At that point the cross-process stampede consideration described above would become relevant and the appropriate locking strategy would need to be revisited.
