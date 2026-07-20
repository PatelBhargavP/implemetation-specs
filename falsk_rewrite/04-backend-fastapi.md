# FALSK Rewrite — 04 · FastAPI Backend Spec

> Replaces the ~2,000-line monolith. Every module has a single responsibility; no file holds "all the endpoints."

## 1. Project layout

```
app/
  main.py                 # FastAPI app factory + lifespan (startup/shutdown wiring)
  config.py               # pydantic-settings; env-driven; profiles: local/cloud/test
  container.py            # dependency wiring (services, repos, AdkRuntime, Broadcaster)
  api/
    deps.py               # FastAPI dependencies: auth context, db session, services
    errors.py             # exception→envelope mapping, handler registration
    middleware.py         # request id, logging, IAP auth extraction
    rest/
      sessions.py         # /sessions ...
      plans.py            # /plans ...
      executions.py       # /executions ...
      artifacts.py        # /artifacts ...
      health.py           # /healthz, /readyz
    ws/
      chat.py             # WebSocket endpoint + session-init lifecycle
      protocol.py         # WS message schemas (in/out), versioned
  services/               # business logic (doc 01 §2)
  integration/
    adk_runtime.py        # doc 03
    broadcaster.py        # Redis pub/sub ↔ WS registry
    hardware_gateway.py   # pyrobot / MCP driver interface (impl may be stubbed per env)
  data/
    database.py           # DatabaseService: async engine, session factory, tx scope
    models.py             # SQLAlchemy ORM models (existing schema preserved)
    repositories/         # one module per entity
  workers/
    execution_worker.py
    analysis_worker.py
    outbox_reconciler.py
    supervisor.py         # lifespan-managed task registry + crash recovery
  domain/
    exceptions.py         # typed domain exceptions
    schemas.py            # pydantic DTOs for API I/O
  telemetry/
    logging.py  tracing.py
tests/
  unit/  integration/  contract/  parity/
migrations/               # Alembic (existing history preserved)
```

**Hard rule:** no module may exceed a reasonable size (target ≤ ~400 lines); if a router or service grows past that, split by resource/use-case. The monolith must not reappear in disguise.

## 2. App factory & lifespan

- `create_app()` builds the FastAPI app, registers routers, middleware, and exception handlers, and installs a **lifespan** context that: constructs config, DatabaseService (engine/pool), Redis/Broadcaster, `AdkRuntime` (single Runner + shared session/artifact services), and the worker `supervisor`; and tears them down cleanly on shutdown (drain workers, close pools, close Redis).
- No global singletons constructed at import time. Everything is created in lifespan and exposed via the DI container so tests can substitute fakes.

## 3. Dependency injection

- Use FastAPI `Depends` for request-scoped values: the authenticated `AuthContext`, a per-request DB session/unit-of-work, and service instances resolved from the container.
- Services are singletons where stateless; DB sessions are per-request and closed by the dependency's teardown. Never share a DB session across requests or across background tasks.

## 4. Data-transfer & validation

- All request/response bodies are pydantic models in `domain/schemas.py`. No raw dicts across the API boundary.
- WS messages are pydantic models in `api/ws/protocol.py`, **versioned** (include a `type` and a protocol version) and **compatible with the current frontend contract** (doc 00 §4). Any change to the wire contract is flagged in doc 08 before implementing.

## 5. Authentication layer (IAP identity)

FALSK does not authenticate users itself — **IAP** does (NG4). The backend trusts IAP and records identity.

- **Middleware/dependency `require_identity`:**
  1. Read IAP identity headers (`X-Goog-Authenticated-User-Id`, `X-Goog-Authenticated-User-Email`, and — where available — the signed `X-Goog-IAP-JWT-Assertion`). Extract stable user id + email.
  2. **Upsert the user** into the `users` table (idempotent) and **cache** the record in Redis keyed by user id, with a TTL, to avoid a DB hit per request. Cache-aside: check Redis → miss → DB upsert/read → populate Redis.
  3. Build an `AuthContext(user_id, email, roles?)` and attach it to the request (context var / `request.state`) for downstream use.
- **Fail-safe behavior (production trusts IAP, but code must not assume it):**
  - If identity headers are entirely absent in a context that requires them → `401 UNAUTHENTICATED`. Do **not** silently allow anonymous access.
  - Provide a **config-gated local-dev bypass** (`AUTH_MODE=local`) that injects a fixed dev identity, so the app runs without IAP locally. This bypass must be impossible to enable in the cloud profile.
  - Optionally verify the IAP JWT assertion signature/audience when configured (recommended for defense-in-depth); behind a config flag so local/dev without IAP still works.
- **WebSocket auth:** identity is extracted **at connection time** (IAP headers are present on the WS upgrade request) and bound to the connection. Every message on that socket inherits the connection's `AuthContext`; do not re-trust per-message client-supplied identity.

## 6. Global exception handling & structured errors (Goal G4)

Single, consistent error envelope for **every** error path (REST and, where applicable, WS control errors):

```json
{
  "error": {
    "code": "SESSION_BUSY",
    "message": "A turn is already running for this session.",
    "status": 409,
    "request_id": "…",
    "details": { }
  }
}
```

- **Typed domain exceptions** in `domain/exceptions.py`, each carrying a stable `code` and an HTTP `status`. Examples: `UnauthenticatedError(401)`, `ForbiddenError(403)`, `NotFoundError(404)`, `ValidationError(422)`, `SessionBusyError(409)`, `LlmCallsExceededError(409)`, `HardwareUnavailableError(503)`, `ConflictError(409)`, `InternalError(500)`.
- **Registered handlers** map: domain exceptions → their `status`+`code`; FastAPI/pydantic `RequestValidationError` → `422 VALIDATION_ERROR` with field details; any unhandled `Exception` → `500 INTERNAL_ERROR` with a generic message (never leak stack traces or internals to the client) while logging full detail server-side with the `request_id`.
- **Never** return bare FastAPI default error bodies. All errors go through the envelope. Include `request_id` in every response (success and error) via middleware for traceability.
- WS errors are delivered as a typed `error` message on the socket using the same `code`/`message` fields, and never crash the connection unless fatal.

## 7. WebSocket session lifecycle (matches current frontend behavior)

Implement exactly this lifecycle (from the user's clarification):

1. **New session:** user clicks "new session" → UI sets local `session_id = "create_new"` and opens a socket. On the first user prompt sent over that socket, the server sees `session_id == "create_new"`, **mints a real session** (ADK `get_or_create_session` + `sessions` row), runs the turn, and replies **on the same socket** with the AI response **plus the new `session_id`**.
2. **Reconnect with real id:** the UI updates its state to the new `session_id`, **tears down the `create_new` socket, opens a new socket** with `session_id` as a **query param**, and adds `session_id` to the URL. All subsequent messages flow on this channel.
3. **Load existing session:** opening a session by id establishes the socket with that `session_id` query param **from the start**; no `create_new` handshake.

Server requirements:
- The WS router accepts the optional `session_id` query param; `create_new` (or its absence on the first message) triggers minting.
- Bind `AuthContext` at connect (doc 04 §5). Register the connection in the `Broadcaster` registry (Redis) keyed by `session_id`/connection id so any instance can push to it.
- On disconnect, deregister from the broadcaster; **do not** cancel background executions tied to the session (they are decoupled — doc 02 §5) — they keep running and will re-report on the next connect via the pull model.
- Enforce one active turn per session (doc 02 §4): a second concurrent prompt on the same session is rejected with a structured `SESSION_BUSY` WS error. No queuing. (Decision confirmed — doc 08 Q1.)

## 8. Broadcaster (Redis pub/sub)

- Preserves the current mechanism: the first agent call receives a **broadcast callback** that publishes events to Redis; subsequent agent/tool calls forward the same callback so the UI keeps receiving updates (doc 03 `on_event`).
- `Broadcaster` maps `session_id`/connection → owning instance via Redis; publishes events to a channel the owning instance subscribes to; that instance writes to the live WebSocket. This is what lets a background worker on any instance push updates to a socket homed elsewhere.
- Behind an interface with a `Fakeredis` implementation for local/test (doc 01 §5).

## 9. REST surface (indicative; preserve current contracts where they exist)

- `GET /healthz`, `GET /readyz` — liveness/readiness (readiness checks DB + Redis).
- `GET /sessions`, `GET /sessions/{id}`, `POST /sessions`, `DELETE /sessions/{id}` — session metadata & history (read via `read_session_state`).
- `GET /plans/{id}`, `POST /plans/{id}/execute` — plan retrieval & approval→execution trigger.
- `GET /executions/{id}`, `GET /executions/{id}/events` — execution status/stream (reads execution store).
- `GET /artifacts/{ref}` — signed-URL or proxied fetch of GCS artifacts (reports/plots/raw data).
- Any endpoint the current frontend already calls must keep its path/shape unless doc 08 resolves a change.
