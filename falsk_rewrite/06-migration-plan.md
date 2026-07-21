# FALSK Rewrite — 06 · Migration & Implementation Plan

> Greenfield rebuild **in the same repo**: move all current code into `legacy/`, build the new app fresh at the repo root alongside it. `legacy/` is a read-only reference for frozen-asset extraction and parity — never imported by new code. Build in vertical slices, prove parity continuously, cut over once. Each phase ends with a gate the coding agent must pass before proceeding.

## 0. Phase 0 — Legacy quarantine, inventory & scaffolding (no new behavior yet)

- **Move all current code into a top-level `legacy/` folder** as the first commit, unchanged. This preserves the old system verbatim for extraction/parity while the new app is built at the repo root. Do **not** edit files inside `legacy/`. Rationale: keeps both trees in one Antigravity workspace so the agent can read the old code and write the new code side by side.
- **Inventory current assets from `legacy/`** (doc 00 A6): extract the exact agent prompts (including any composition logic that renders them), tool signatures/return shapes, the current DB schema + Alembic history, the current REST paths (note the `/api/*` prefix — doc 04 §9), the current WS message shapes/path, and the **API key manager service** (its module + public interface — doc 00 §4; capture how callers obtain a key and how rotation surfaces, so it can be wired rotation-safely per doc 03 §2.1). Record the `legacy/`-relative source path for each asset. Produce a checked-in `INVENTORY.md` listing every frozen asset (doc 00 §4) with its source location and a content hash. **Gate:** inventory reviewed and signed off before any agent code is copied.
- **Old-code usage rule:** `legacy/` is authoritative for *frozen assets* and a behavioral reference for parity, but its harness code (server, session handling, Turn-Aware layer) must **not** be ported — that is exactly the code being replaced (doc 00 §4, doc 02 §8). New code must never `import` from `legacy/` (guardrail doc 07 #13).
- **Alembic continuity (critical):** the preserved DB is governed by the *existing* migration chain. **Copy** the existing `migrations/versions/` history into the new app's Alembic directory so its revision history is intact and new revisions append to the current head — do **not** start a fresh Alembic history, or autogenerate will try to recreate tables that already exist (doc 05 §5, §5.1).
- **Scaffold** the layout (doc 04 §1): config, DatabaseService, DI container, logging/tracing, health endpoints, empty routers, test harness, CI. Nothing calls ADK yet.
- **Tooling: `uv` is the package manager** (already in use on the current project). Project metadata and all dependencies live in `pyproject.toml` with a committed `uv.lock`; use dependency groups (e.g. `dev`) for test/lint tooling. CI and Docker install with `uv sync --frozen` (never `pip install`); run tooling via `uv run` (`uv run pytest`, `uv run alembic upgrade head`, `uv run ruff check`). Do not introduce `requirements.txt`, Poetry, or pip-based flows. **Exclude `legacy/`** from the new app's package, `uv` workspace, lint/type-check, test collection, and the Docker build context (e.g. `.dockerignore`) so old code is never installed, imported, or shipped.
- **Scaffold** the layout (doc 04 §1): config, DatabaseService, DI container, logging/tracing, health endpoints, empty routers, test harness, CI. Nothing calls ADK yet.
- **Tooling: `uv` is the package manager** (already in use on the current project). Project metadata and all dependencies live in `pyproject.toml` with a committed `uv.lock`; use dependency groups (e.g. `dev`) for test/lint tooling. CI and Docker install with `uv sync --frozen` (never `pip install`); run tooling via `uv run` (`uv run pytest`, `uv run alembic upgrade head`, `uv run ruff check`). Do not introduce `requirements.txt`, Poetry, or pip-based flows.
- **Gate 0:** app boots, `/healthz` green, CI runs unit tests, lint/type-check pass.

## 1. Phase 1 — Data & auth foundation

- Wire SQLAlchemy async + Alembic against a dev AlloyDB/Postgres; confirm ADK-owned tables are excluded from app autogenerate (doc 05 §5.1).
- Implement `UserRepository` + IAP identity middleware + Redis-cached user upsert (doc 04 §5), including the config-gated local bypass.
- Implement the structured error envelope + global handlers (doc 04 §6).
- **Gate 1:** authenticated request round-trips with identity resolved and cached; all error paths return the envelope; auth bypass impossible in cloud profile (tested).

## 2. Phase 2 — ADK runtime (single-invocation turns)

- Port frozen agents/prompts/tools into `app/agents/` verbatim (doc 03 §1); contract-test tools against captured schemas.
- Port the frozen **API key manager service** verbatim and wire ADK model credentials through it, rotation-safely (doc 03 §2.1). No env/config key reads in new code.
- Implement `AdkRuntimeImpl` with a single process Runner, `DatabaseSessionService`, `GcsArtifactService` (doc 03 §2).
- Implement `TurnService` with the per-session advisory lock (doc 02 §4) and one-invocation `run_turn`.
- Implement WebSocket chat + session-init lifecycle (doc 04 §7) + Broadcaster (doc 04 §8).
- **Gate 2 (parity, functional):** for a fixed set of representative prompts, the new system produces plans equivalent to the current system (golden-output comparison, doc 03 §8). State is written only via `append_event`; no direct `session.state` mutation (assert in tests). **This gate proves challenge #2 (OCC) is resolved:** run concurrent-turn and rapid-fire tests and show zero OCC conflicts.

## 3. Phase 3 — Execution & analysis (background, decoupled)

- Implement `ExecutionService` + `ExecutionWorker` + the single `executions` table (doc 05 §3), driving `HardwareGateway` (real pyrobot/USB where available; a deterministic simulator otherwise). First check Phase 0 inventory — if the old schema already has a suitable execution/job table, extend it additively instead of adding a new one.
- **Analysis is a frozen sub-agent, not a worker** (doc 08 Q15): it's ported in Phase 2 as part of the agent tree (doc 03 §1) and runs in-turn. No `AnalysisWorker`, no analysis table. Nothing to build here beyond confirming the analysis sub-agent's tools produce byte-faithful curves/concentration/QC (parity, doc 06 §6).
- Implement the worker `supervisor` (lifespan-managed tasks + crash recovery, doc 04 §1 / doc 02 §7).
- Implement result re-entry via tools (doc 02 §5 pull model). The outbox + reconciler is **out of scope** (doc 08 Q2) — do not build it; the live UI stream is served by the Broadcaster.
- Implement crash recovery with **bounded 3-attempt retry** resuming from `last_completed_step_seq`, honoring the non-idempotent-step safety rule (doc 02 §7).
- **Gate 3 (background robustness):** start an execution, end the originating turn immediately, and confirm the execution completes, persists results, and streams UI updates throughout — **nothing lost** (directly demonstrates challenge #2's background case is fixed). Kill and restart the process mid-execution and confirm: it resumes from the last completed step, retries at most 3 times, marks `failed` after the 3rd, and never re-runs a completed step.

## 4. Phase 4 — Latency (measure → parallelize → tier)

- Land tracing/instrumentation; capture a real slow-turn breakdown (doc 03 §7 step 1). **Required artifact:** the before-trace.
- Convert independent experts to `ParallelAgent`; apply model tiering where safe.
- **Gate 4:** documented before/after meeting **p50 ≤ 15 min** per turn (doc 08 Q5). No behavior regression vs Gate 2 golden outputs.

## 5. Phase 5 — Hardening & cutover

- Full error-path coverage, load test at 4–10 concurrent users with live executions, WebSocket reconnection/affinity test behind the load balancer, artifact serving, readiness/liveness under dependency failure.
- Security pass: no secret/stack leakage; **owner-only authz** on session/artifact/execution access (other users' resources return 404), and the snapshot-sharing path (doc 04 §5.1, doc 08 Q12). IAP JWT verification is **not** built (trust headers — doc 08 Q13).
- **Cutover:** deploy alongside the old system; route a subset of users; compare; then switch. Because the DB schema is preserved and additive, both systems can read the same `sessions`/`users` during transition (validate ADK session compatibility first — doc 08).
- **Gate 5:** parity + latency + robustness gates all green in a production-like environment; rollback plan documented.

## 6. Parity checklist (must all hold before cutover)

- [ ] Every frozen prompt renders byte-identical to current (spot-checked + hashed).
- [ ] Every tool matches name/params/return shape (contract tests green).
- [ ] Representative prompts produce equivalent plans (golden comparison).
- [ ] Resource/deck estimation and analysis numerics match current outputs within tolerance.
- [ ] DAG execution semantics match (same step order/results against the simulator).
- [ ] All current REST paths + WS message shapes still satisfied by the frontend (no UI change required), or deviations approved in doc 08.
- [ ] Zero OCC conflicts under concurrent/rapid-turn tests.
- [ ] Background jobs survive turn end with no lost updates.
- [ ] Structured error envelope on every error path.

## 7. Sequencing note

Phases are ordered so the **hardest risk (state/OCC, Gate 2 & Gate 3)** is proven early, before latency polish. Do not begin Phase 4 until Gates 2 and 3 pass — a fast system with wrong state is worse than a slow correct one.
