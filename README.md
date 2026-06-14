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
Rejected because: fetches data for all 36 combinations even when only 1 or 2 are being requested — unnecessarily refreshing combinations nobody asked for. The batch request also carries higher network bandwidth than a single combination request (though not dramatically so given only 36 combinations exist), and the specific user who triggered the cache miss experiences higher latency waiting for all 36 results to be processed. Also adds implementation complexity around parsing and storing batch responses, and handling partial failures within a batch.

**Option 3 — Background job refreshing all 36 every 5 minutes**
A scheduled job proactively refreshes all combinations before they expire, so users always read from a warm cache.
Rejected because: always fetches all 36 regardless of demand, requires a job scheduler and failure handling, and adds significant complexity beyond what the assignment requires.

### Final Decision

Option 1 — per-combination on-demand cache. It is the simplest approach, only calls upstream for combinations that are actually requested, and works correctly under realistic traffic where a few popular combinations account for most requests.

**Known tradeoff:** in the theoretical worst case where all 36 combinations are requested continuously across every 5-minute window, upstream calls could reach 36 × 12 × 24 = **10,368/day** — exceeding the 1,000 limit. If this limit is hit, the upstream API returns HTTP 429. Our service handles this gracefully by returning a clear descriptive error to the user.

If worst-case correctness became a hard requirement on a **single server**, either Option 2 (batching all 36 in a single upstream request on demand) or Option 3 (background job with batching internally) would cap calls at 288/day.

However, both options still have limitations in a **multi-instance deployment**. Option 2 — multiple instances could simultaneously find a stale cache and all fire a batch request, multiplying quota usage by the number of instances. Option 3 — each instance would run its own background job, again multiplying calls proportionally.

Solving this correctly at scale requires isolating upstream API calls to a **dedicated single-instance cache refresh service** responsible only for keeping the cache warm, while the dynamic pricing service instances only read from the cache and never call upstream directly. This eliminates quota multiplication regardless of how many pricing service instances are running. However, running that refresh service as a single instance introduces a single point of failure. To make it highly available, multiple instances of the refresh service would need to run — but only one should be active at any given time to avoid quota multiplication. This is solved through **leader election** — a distributed coordination mechanism where instances elect one leader to do the work while others remain on standby. If the leader goes down, a standby takes over automatically. Tools commonly used for this include **Apache Zookeeper**, **etcd**, **Consul**, a **Redis distributed lock**, a **Kubernetes CronJob** (which guarantees single execution), or a managed external scheduler like **AWS EventBridge**. This is how cache refresh infrastructure would be set up at large scale — but it represents significant infrastructure complexity well beyond the scope of this assignment.

## Setup & Running

### Prerequisites

- **Docker with Compose V2** — commands use `docker compose` (not `docker-compose`). [Docker Desktop](https://www.docker.com/products/docker-desktop/) is the recommended installation for Mac and Windows as it includes both Docker and Compose out of the box.

No local Ruby installation is required. The Dockerfile installs Ruby 3.2.6 and all gem dependencies inside the container automatically when you run `docker compose up --build`.

### Start the service

```bash
docker compose up -d --build
```

This starts two containers:
- `interview-dev` — the Rails proxy service on port 3000
- `rate-api` — the upstream pricing model on port 8080

### Test the endpoint

**Mac/Linux:**
```bash
curl 'http://localhost:3000/api/v1/pricing?period=Summer&hotel=FloatingPointResort&room=SingletonRoom'
```

**Windows (CMD):**
```cmd
curl "http://localhost:3000/api/v1/pricing?period=Summer&hotel=FloatingPointResort&room=SingletonRoom"
```

**Windows (PowerShell) — use `curl.exe` to invoke the real curl binary, not the PowerShell alias:**
```powershell
curl.exe "http://localhost:3000/api/v1/pricing?period=Summer&hotel=FloatingPointResort&room=SingletonRoom"
```

### Run the test suite

```bash
# Full suite
docker compose exec interview-dev ./bin/rails test

# Specific file
docker compose exec interview-dev ./bin/rails test test/controllers/pricing_controller_test.rb
```

### Test coverage report

After running the test suite, an HTML coverage report is generated at `coverage/index.html` inside the container. To view it locally:

**macOS:**
```bash
docker compose exec interview-dev cat coverage/index.html > /tmp/coverage.html && open /tmp/coverage.html
```

**Linux:**
```bash
docker compose exec interview-dev cat coverage/index.html > /tmp/coverage.html && xdg-open /tmp/coverage.html
```

**Windows (PowerShell):**
```powershell
docker compose exec interview-dev cat coverage/index.html > $env:TEMP\coverage.html; start $env:TEMP\coverage.html
```

**Windows (Command Prompt):**
```cmd
docker compose exec interview-dev cat coverage/index.html > %TEMP%\coverage.html && start %TEMP%\coverage.html
```

Current coverage: **100%** across all application code (unused Rails boilerplate — `app/channels/`, `app/jobs/` — excluded from measurement as they are auto-generated and not part of this application).

### Reset the upstream API quota (development only)

The upstream rate API enforces a hard limit of 1,000 calls per day. During development, if you exhaust the quota, simply restart the rate-api container to reset it:

```bash
docker compose restart rate-api
```

### Stop the service

```bash
docker compose down
```

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

Note: `rate` is returned as a string (e.g. `"12000"`) — this matches the upstream API's response format exactly. No conversion is applied.

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

## Observability

Every request emits structured JSON log events, making it easy to monitor behaviour, diagnose issues, and derive metrics in a log aggregation tool (e.g. Datadog, ELK, CloudWatch).

Each log entry includes `timestamp` (ISO 8601), `request_id` (from Rails' `X-Request-Id` header — auto-generated if not provided by the client), `period`, `hotel`, and `room` for full request context. This allows all log lines for a single request to be correlated by `request_id`.

### Log Events

| Event | Level | Fields | When |
|---|---|---|---|
| `cache_hit` | info | + `duration_ms` | Fresh rate served from cache — `duration_ms` is SQLite read time |
| `cache_miss` | info | + `duration_ms` | Cache empty or stale and upstream API will be called — `duration_ms` is SQLite read time. Note: if a thread was waiting for a lock and finds the cache already refreshed by another thread, it logs `cache_hit` instead — `cache_miss` is only logged when an upstream call actually follows |
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

## Testing

### Test Strategy

**Integration tests (`test/controllers/pricing_controller_test.rb`)** — 20 tests covering the full request stack from HTTP request to response. These test all meaningful behaviours: cache hits, cache misses, TTL boundaries, all error cases, and edge cases identified during implementation.

**Model unit tests (`test/models/cached_rate_test.rb`)** — 6 tests covering `CachedRate` TTL logic and upsert behaviour in isolation. The model contains the most critical business logic (the 5-minute validity check) so it deserves dedicated unit tests independent of the full stack.

**Client unit tests (`test/lib/rate_api_client_test.rb`)** — 2 tests verifying that transport-level exceptions (`Net::OpenTimeout`, `SocketError`) are correctly translated into domain exceptions (`TimeoutError`, `ConnectionError`). This is `RateApiClient`'s single responsibility and is tested at the right level.

### Why No Separate Service Unit Tests

`PricingService` was considered for dedicated unit tests but integration tests through the controller already exercise every code path in the service — cache hit, cache miss, all error cases. Adding service unit tests would duplicate the same coverage without providing additional confidence. The model and client are the right candidates for isolation testing because they each have a single, independently meaningful responsibility.

### Test Cases

| # | Test | Type | What It Proves |
|---|---|---|---|
| 1 | Happy path — returns rate | Integration | Basic flow works end to end |
| 2 | API fails (500) — returns UPSTREAM_ERROR | Integration | Structured error response on upstream failure |
| 3 | Missing parameters — returns INVALID_PARAMETERS | Integration | Param validation rejects missing fields |
| 4 | Empty parameters — returns INVALID_PARAMETERS | Integration | Param validation rejects empty strings |
| 5 | Invalid period — returns INVALID_PARAMETERS | Integration | Param validation rejects unknown period |
| 6 | Invalid hotel — returns INVALID_PARAMETERS | Integration | Param validation rejects unknown hotel |
| 7 | Invalid room — returns INVALID_PARAMETERS | Integration | Param validation rejects unknown room |
| 8 | Cache hit — API not called | Integration | Core caching — upstream never called when fresh |
| 9 | Cache miss — API called, result stored | Integration | Cache miss triggers upstream call and stores result |
| 10 | Stale cache (> 5 min) — API called, cache updated | Integration | Stale entry refreshed with fresh upstream value |
| 11 | Fresh cache (< 5 min) — API not called | Integration | Fresh entry served without upstream call |
| 12 | Exactly 5 minutes old — treated as stale | Integration | TTL boundary — 5 min is stale, not fresh |
| 13 | API returns 429 — returns RATE_LIMIT_EXCEEDED | Integration | Rate limit handled specifically |
| 14 | API raises TimeoutError — returns UPSTREAM_TIMEOUT | Integration | Timeout handled gracefully |
| 15 | API raises ConnectionError — returns UPSTREAM_TIMEOUT | Integration | Connection failure handled gracefully |
| 16 | API returns malformed JSON — returns UPSTREAM_ERROR | Integration | JSON parse error handled gracefully |
| 17 | Empty rates array — returns RATE_NOT_FOUND | Integration | No matching combination handled gracefully |
| 17b | Rate field missing in object — returns RATE_NOT_FOUND | Integration | Absent rate field handled via `&.dig` |
| 24 | Unexpected exception — returns INTERNAL_ERROR | Integration | Controller safety net always returns JSON |
| 25 | API returns 3xx — returns UPSTREAM_ERROR | Integration | Redirect response handled gracefully |
| 26 | 4xx non-429 — returns UPSTREAM_ERROR | Integration | Client error response handled gracefully |
| 18 | `fetch_fresh` returns nil — no entry | Unit | Model handles empty cache |
| 19 | `fetch_fresh` returns nil — stale entry | Unit | TTL logic correct for stale entries |
| 20 | `fetch_fresh` returns entry — fresh | Unit | TTL logic correct for fresh entries |
| 21 | `fetch_fresh` returns nil — exactly 5 min | Unit | TTL boundary condition |
| 22 | `store` creates new entry | Unit | Upsert creates correctly |
| 23 | `store` updates existing entry | Unit | Upsert updates without duplicate |
| 27 | `Net::OpenTimeout` wrapped as `TimeoutError` | Unit | Transport exception translated to domain exception |
| 28 | `SocketError` wrapped as `ConnectionError` | Unit | Transport exception translated to domain exception |

## AI Tool Usage

This solution was developed with assistance from **Claude** (Anthropic).

**Workflow:** Claude was used as an AI assistant to discuss design decisions, explore tradeoffs, and validate technical approaches throughout the assignment. Options were considered, assumptions were challenged, and reasoning was understood before any implementation decisions were made.

**Parts developed with AI assistance:**
- Design decision analysis and tradeoff evaluation (caching technology, schema design, concurrency strategy, error handling architecture)
- Structured logging design
- Test strategy and test case identification
- README documentation

The design decisions, reasoning, and tradeoffs documented in this README reflect genuine understanding developed through the discussion process — not generated boilerplate.

---

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
| Single server capacity — cache-hit path (assumed: 2 CPU cores, 4GB RAM, Puma 1 worker × 5 threads) | ~100–200 req/sec |
| Headroom above peak | ~4–8× |

SQLite reads from disk and is fast enough for this use case — cache reads are simple single-row lookups on a table with at most 36 rows, and write locks only activate on a cache miss which is a rare event (at most once per combination per 5-minute window). At 24 peak requests/second, both read latency and write contention are negligible. Even at full single-server capacity (~100–200 req/sec), SQLite handles concurrent reads comfortably since multiple readers never block each other — only writes require a brief lock, and cache misses remain rare regardless of traffic volume.

Redis is faster than SQLite since it stores data entirely in memory. However the actual latency difference depends heavily on deployment topology — whether Redis is on the same machine, a different node, or a managed service on a separate host — and under typical conditions both are in a similar low-millisecond range that makes no noticeable difference to users at this traffic level.

**Known limitation:** if this service were deployed across multiple servers, each server would have its own SQLite file and the cache would not be shared between instances. This is a deliberate tradeoff — the FAQ explicitly states *"production-ready does not mean FAANG-scale"* and to *"choose the most straightforward path."* SQLite solves the actual problem correctly without introducing infrastructure that the assignment does not require.

**Scaling to multiple servers — the correct architecture:**

For a multi-server deployment, the cache store must be a single shared service that all app servers connect to — not a container bundled inside each server's `docker-compose.yml`. Adding Redis or PostgreSQL to `docker-compose.yml` would start a separate instance on every server, giving each server its own isolated cache — the same problem as SQLite.

The correct approach is to host the shared store as a dedicated external service:

```
Load Balancer
├── App Server 1 (Rails + Puma) ──┐
├── App Server 2 (Rails + Puma) ──┼──→ Shared Redis or PostgreSQL (dedicated host)
└── App Server 3 (Rails + Puma) ──┘
```

Each app server would be configured with an environment variable pointing to the shared host:
- `REDIS_URL=redis://shared-redis-host:6379` for Redis
- `DATABASE_URL=postgres://shared-pg-host/pricing` for PostgreSQL

This keeps the app container stateless — it contains only the Rails application code, while all shared state lives in the dedicated external service. This is the standard production pattern for horizontally scaled web services.

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

---

### Error Handling Architecture

**Why transport exceptions are caught in `RateApiClient`, not `PricingService`**

`RateApiClient` has one responsibility — make HTTP calls to the upstream API. Everything about that HTTP call, including what can go wrong at the transport level (`Net::OpenTimeout`, `SocketError`, `Errno::ECONNREFUSED`), belongs there. `PricingService` is concerned with business logic — checking the cache, fetching rates, storing results. It should not need to know that the rate comes from HTTP or what low-level transport exceptions HTTP can throw. Keeping these concerns separate makes each class easier to test, reason about, and change independently.

**Why `open_timeout 5` and `read_timeout 15` rather than a single timeout**

These are two distinct failure scenarios:
- `open_timeout` — how long to wait to establish a connection. If we cannot connect within 5 seconds the server is likely down or unreachable — failing fast is correct.
- `read_timeout` — how long to wait for a response after connecting. The upstream API is described as "computationally expensive" — it may take longer to process the request. 15 seconds allows reasonable time for the model to run without blocking a Puma thread indefinitely.

Setting both separately rather than a single `default_timeout` communicates the intent clearly and is more precise about the failure being handled.

**Why upstream failures return HTTP 503 (Service Unavailable) rather than 500 (Internal Server Error)**

503 means "this service is temporarily unavailable" — the problem is with an external dependency, not our service itself. 500 means "our service crashed" — which is inaccurate when the issue is the upstream API being down or rate-limited. This distinction matters for clients and monitoring tools: a 503 signals "retry later", a 500 signals "there is a bug to investigate". The controller's `rescue StandardError` safety net uses 500 — correctly, because an unhandled exception in our own code IS an internal error.
