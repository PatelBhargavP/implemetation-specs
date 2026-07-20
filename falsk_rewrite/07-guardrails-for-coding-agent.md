# FALSK Rewrite — 07 · Guardrails for the Coding Agent (Antigravity)

> These are binding constraints, not suggestions. The implementing agent must not deviate. When a guardrail conflicts with something you want to do, **stop and record the conflict in doc 08** rather than deviating.

## 1. Hard rules (never violate)

1. **Do not alter frozen assets** (doc 00 §4): agent prompts render byte-identical; tool names, parameters, and return shapes are unchanged. No "cleanup" or rewording of prompts.
2. **Never mutate `session.state` directly.** All ADK state changes go through `output_key`, `EventActions.state_delta`, or `ToolContext`/`CallbackContext` (doc 02 P2). A fetched `Session` is read-only outside a managed context.
3. **One invocation per turn.** Do not implement multi-agent orchestration as multiple `Runner` invocations or multiple sessions per turn. Use ADK sub-agent composition inside one invocation (doc 02 P1, doc 03 §4).
4. **Background workers never write ADK session state** except through the OutboxReconciler (doc 02 §5–6). `session_service` must not be a dependency of any worker.
5. **No destructive schema changes.** Additive Alembic migrations only; ADK-owned tables excluded from app migrations (doc 05 §5).
6. **No new infrastructure** beyond Postgres/AlloyDB, Redis, GCS (doc 00 NG5). No new brokers/datastores/queues.
7. **IAP stays the authenticator** (doc 00 NG4). Do not build an in-app login/identity provider.
8. **No ADK imports outside `app/integration/adk_runtime.py`** and `app/agents/` (doc 03 §2). Services stay ADK-agnostic.
9. **The monolith must not reappear.** No "god" module holding all endpoints/logic. Respect the layering and module-size limits (doc 04 §1).
10. **Do not implement out-of-scope features:** remote/network robot execution and the Vertex AI runtime are seams only (doc 00 NG3, doc 01 §6). Leave documented stubs.
11. **No secret or stack-trace leakage** to clients; all errors go through the structured envelope (doc 04 §6).

## 2. Required patterns

- Async-first; no blocking calls on the event loop; blocking/USB/CPU work in an executor (doc 01 §4).
- Dependency injection via the container + FastAPI `Depends`; construct heavy services once in lifespan, not per request (doc 04 §2–3).
- Typed config from env (pydantic-settings); no literals/secrets in code.
- Typed domain exceptions mapped to HTTP status/codes (doc 04 §6).
- Repositories are the only DB access; services own transactions; workers use short transactions (doc 05 §4).
- Structured logging with `request_id`/`session_id`/`invocation_id` on every log line; OpenTelemetry tracing wired through ADK (doc 03 §7).

## 3. Definition of Done (per module/PR)

A change is done only when:

- Unit tests cover the module's logic; contract tests cover any touched tool/WS/REST contract; relevant parity tests still pass (doc 06 §6).
- Type-check (mypy/pyright) and lint pass with zero new errors.
- No `session.state` direct write; no ADK import outside the allowed modules (add a CI check/grep gate for both — see §5).
- Error paths return the envelope; new endpoints documented (OpenAPI).
- New tables ship with an Alembic up/down migration and are excluded-or-included correctly vs ADK tables.
- The PR description states which frozen assets it touched (should be "none" except in the initial verbatim port) and links the relevant spec sections.

## 4. Anti-slop rules (fight the bloat that motivated the rewrite)

- No dead code, no speculative abstractions, no "just in case" parameters, no commented-out blocks, no duplicated logic across modules.
- No copy-pasted boilerplate that a shared helper would remove; but no premature framework-building either. Prefer the smallest clear implementation.
- Every module has a single, statable responsibility; if you can't state it in one sentence, split it.
- Docstrings state *why*, not restate *what* the code obviously does.
- Do not generate large auto-written scaffolds you don't wire up. Every file added must be reachable and used.

## 5. Automated enforcement (add these to CI)

- **Grep/AST gate 1:** fail the build if `\.state\[` assignment or `session.state[...] =` appears anywhere outside sanctioned contexts.
- **Grep/AST gate 2:** fail if `google.adk` is imported outside `app/integration/adk_runtime.py` and `app/agents/`.
- **Grep/AST gate 3:** fail if `Runner(` / `run_async(` is instantiated/called outside `adk_runtime.py`.
- **Grep gate 4:** fail if any worker module imports the session service.
- **Prompt-hash check:** store a hash of each frozen prompt; CI fails if a rendered prompt hash changes without an explicit approved override.
- **Module-size lint:** warn/fail past the size budget (doc 04 §1).
- **Migration check:** CI runs `alembic upgrade head` + `downgrade` on a scratch DB; autogenerate against ADK tables must produce no diff.

## 6. When to stop and ask (escalate to doc 08, do not guess)

- Any case that seems to require a second invocation per turn, a background write to session state, the old diff-aggregation logic, a destructive schema change, or a new infra dependency.
- Any frozen asset that appears internally inconsistent or that you cannot reproduce byte-identically.
- Any WS/REST contract you must change to make the frontend work.
- Any latency optimization (esp. model tiering) that could change agent outputs.
