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
| Rate limit exhausted (assumed HTTP 429 — not explicitly documented in API spec) | 503 | `RATE_LIMIT_EXCEEDED` | Return descriptive error |
| HTTP 5xx — upstream API error | 503 | `UPSTREAM_ERROR` | Return descriptive error |
| Rate missing in successful response | 503 | `RATE_NOT_FOUND` | Defensive — not a documented API behaviour, but the existing code uses a safe navigation operator (`&.dig`) suggesting the original author anticipated this case |
| Concurrent requests for same stale key | — | — | Only one upstream call fires — cache stampede prevention |

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
{ "code": "UPSTREAM_ERROR",      "message": "The upstream pricing API returned an unexpected error." }
{ "code": "RATE_NOT_FOUND",      "message": "No rate was returned for the requested combination." }
```

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

_Design decisions will be documented here as each part of the implementation is completed._
