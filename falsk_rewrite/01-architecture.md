# FALSK Rewrite — 01 · Target Architecture

## 1. Component map

The system is one deployable FastAPI service (the **backend**) plus external managed services. Internally the backend is layered; layers may only call downward.

```
┌──────────────────────────────────────────────────────────────────┐
│  React SPA (TypeScript + Vite)  — unchanged contract               │
│  Compiled build served BY the FastAPI service (index.html @ base;  │
│  no separate UI server; app endpoints under /api/*) — doc 04 §10   │
└───────────────┬───────────────────────────────┬──────────────────┘
                │ HTTPS: / (SPA) + /api/* (REST)  │ WSS (WebSocket)
                ▼                                ▼
        ┌───────────────────────  IAP  ───────────────────────┐
        │  Identity-Aware Proxy: authenticates, injects        │
        │  X-Goog-Authenticated-User-* identity headers        │
        └───────────────┬──────────────────────────────────────┘
                        ▼
┌──────────────────────────────────────────────────────────────────┐
│  FastAPI backend (per instance)                                    │
│                                                                    │
│  ── API layer ────────────────────────────────────────────────    │
│   REST routers      WebSocket router     middleware:               │
│   (sessions, plans, (chat channel)        - IAP auth               │
│    executions,                            - request id / logging   │
│    artifacts,                             - global exception → err  │
│    health)                                  envelope               │
│                                                                    │
│  ── Service layer ────────────────────────────────────────────    │
│   SessionService   TurnService     ExecutionService                │
│   PlanService      ArtifactService  UserService                    │
│   (analysis lives in a frozen sub-agent + tools, not a service §3.3)│
│                                                                    │
│  ── Integration layer ────────────────────────────────────────    │
│   AdkRuntime (isolated ADK wrapper: Runner, session svc,           │
│               artifact svc, agent tree built once, orchestration)  │
│   Broadcaster (Redis pub/sub ↔ WebSocket registry)                 │
│   HardwareGateway (pyrobot / MCP drivers, USB) — interface         │
│                                                                    │
│  ── Data layer ───────────────────────────────────────────────    │
│   DatabaseService + Repositories (SQLAlchemy async)                │
│                                                                    │
│  ── Background workers (in-process asyncio tasks) ────────────     │
│   ExecutionWorker   (robot DAG runs only)                          │
│   (AnalysisWorker: none — analysis is an in-turn sub-agent §3.3)   │
│   (OutboxReconciler: out of scope — doc 02 §6)                     │
└───────┬───────────────────┬───────────────────┬──────────────────┘
        ▼                   ▼                   ▼
   AlloyDB (Postgres)    Redis / Fakeredis    GCS
   - ADK sessions        - WS conn mapping    - artifacts, reports,
   - existing app tables - pub/sub broadcast    raw data
     (users, session_metadata,
      chat_messages, …)
   - executions (1 new table)
```

## 2. Layering rules (enforced; see doc 07)

- **API layer** does I/O translation only: parse/validate request, call one service method, serialize response. No business logic, no direct DB, no direct ADK calls.
- **Service layer** holds business logic and transaction boundaries. Services depend on repositories and the integration layer, never on FastAPI request/response objects.
- **Integration layer** wraps ADK, Redis, and hardware behind narrow interfaces so they can be swapped (e.g. ADK `DatabaseSessionService` → `VertexAiSessionService`) without touching services.
- **Data layer** is the only place that talks to the database. One repository per entity; `DatabaseService` owns the async engine/session factory and transaction scope.
- **Dependencies flow one direction.** No upward imports. Cross-cutting concerns (auth context, request id) travel via FastAPI dependency injection / context vars, not globals.

## 3. Primary flows

### 3.1 Interactive planning turn (fast path, LLM-driven)

1. Frontend sends a user prompt over the session's WebSocket (session-init lifecycle in doc 04 §7).
2. WS router resolves the authenticated user (from IAP headers captured at connect) and the `session_id`, then hands off to `TurnService.run_turn(...)`.
3. `TurnService` acquires the **per-session turn lock** (doc 02 §4), then invokes `AdkRuntime.run_turn(...)` — **one** `Runner.run_async` invocation whose root is the orchestrator agent.
4. The orchestrator composes planner + hardware-expert sub-agents *inside the same invocation* (ADK sub-agents / `ParallelAgent` for independent experts). All agents share one session; ADK applies each event's `state_delta` via `append_event` incrementally and serially. **No sub-agent opens its own session or its own runner.**
5. As events stream, `AdkRuntime` forwards them to the `Broadcaster` (Redis publish) which pushes to the owning WebSocket. The DAG plan is streamed to the frontend for visualization.
6. When the invocation completes, the turn lock is released. Final state is already persisted by ADK. `TurnService` returns.

### 3.2 Plan approval → deterministic execution (background, no LLM)

1. User approves the plan (REST `POST /plans/{id}/execute` or a WS control message).
2. `ExecutionService` creates an `execution` row (status `queued`) and enqueues an in-process `ExecutionWorker` task. It returns immediately (202/ack).
3. `ExecutionWorker` runs the DAG deterministically via `HardwareGateway` (pyrobot/USB), **bypassing all LLMs**. Per step it: writes progress to `executions.progress` (the single execution store, **not** ADK session), and publishes a live update via `Broadcaster` (which is captured in the existing `chat_messages` table like any other UI event).
4. On completion it writes terminal status + artifact refs (GCS) to the execution store. It does **not** write ADK session state directly — see doc 02 §5 for how results re-enter the conversation.

### 3.3 Data analysis (in-turn sub-agent, NOT a background worker)

Analysis is performed by a **frozen ADK sub-agent** with frozen tools (standard curves, concentration, QC), preserved verbatim (doc 08 Q15, doc 00 §4). It runs **inside the single-invocation turn** like any other agent — not as a decoupled LLM-bypassing worker. Its numeric results enter ADK session state via the agent's normal `state_delta`, and report/plot outputs are written to GCS via the artifact service (references recorded in state). There is no `AnalysisWorker`, no analysis job row. *(Only the robot **execution** loop in §3.2 is a background worker.)* If large-dataset analysis ever must run detached from a turn, raise it (doc 08 Q15) before changing this.

## 4. Concurrency & runtime model

- The backend is **async-first** (FastAPI + `asyncio`). All DB access uses SQLAlchemy async; no blocking calls on the event loop.
- Background work runs as **managed asyncio tasks** owned by a lifespan-scoped task registry (not fire-and-forget `create_task`), so tasks are tracked, cancellable, and survive independent of the turn that spawned them. Blocking/CPU-bound or USB-serial work runs in a thread/process executor, not on the loop.
- **Critical decoupling:** a background task's lifetime is independent of the turn that created it. It writes to durable execution tables, so nothing is lost if the originating turn ends first (this directly fixes challenge #2). See doc 02 §5.

## 5. Deployment topology

- Containerized (Docker), deployed to a **VM behind a load balancer** configured for **long-lived WebSocket / session affinity** (target confirmed — doc 08 Q14; VM chosen for the persistent-socket advantage). A VM instance is long-lived, so the **in-process asyncio execution workers survive across turns as designed** (doc 02 §5). *Future note:* if Cloud Run is ever adopted, long robot runs would need a min-instance/always-on worker config (deployment only, no new broker) — not built now.
- **Redis** provides (a) WebSocket-connection → instance mapping and (b) cross-instance pub/sub so any instance can broadcast to a socket homed on another. `Fakeredis` is the local/dev drop-in behind the same `Broadcaster` interface.
- **AlloyDB (PostgreSQL)** for all relational state. **GCS** for artifacts/reports/raw data.
- Target scale: **4–10 concurrent users** (A3). Horizontal scale is supported by the Redis broadcast fabric but not a design driver.
- **IAP** sits in front and authenticates every request; the backend never sees unauthenticated traffic in production (but must still fail safe if headers are absent — doc 04 §5).

## 6. Future path: Vertex AI Agent Engine (design seam only — do NOT build)

The integration layer must make the agent runtime swappable so a later migration needs no service-layer changes:

- All ADK entry points go through the single `AdkRuntime` interface (doc 03 §2). Services never import ADK types directly.
- Session persistence is behind ADK's `BaseSessionService` abstraction; today it binds to `DatabaseSessionService`, later to `VertexAiSessionService`, selected by config.
- In the future model, the backend becomes a **broker**: it holds the UI WebSocket and relays events to/from a remote Agent Engine invocation instead of running the Runner in-process. Keep `Broadcaster` and `AdkRuntime` cleanly separable so the transport (in-process event stream vs remote stream) can change while the UI contract stays fixed.
- **Guardrail:** implement only the in-process `DatabaseSessionService` binding now. Provide the interface and a config switch; leave the Vertex binding as a documented `NotImplementedError` stub.

## 7. Cross-cutting concerns

- **Config** — typed settings (pydantic-settings) from env; no literals in code. Distinct profiles for local (Fakeredis, SQLite/Postgres) vs cloud.
- **Logging/telemetry** — structured JSON logs with request/turn/session/invocation ids; OpenTelemetry tracing wired through ADK (doc 03 §7) so latency is measurable.
- **Error handling** — one global exception handler produces the structured envelope (doc 04 §6). Services raise typed domain exceptions; the API layer maps them to HTTP status.
- **Security** — trust boundary is IAP; identity extracted once per connection/request and carried in an auth context. No secrets in logs.
