# FALSK Background & Rewrite Decisions

> This is the original background brief for FALSK, updated to record every decision made during
> the rewrite-planning cycle. The **top half** describes the system as-is (the starting point);
> the **"Rewrite Decisions"** section captures what was resolved and now governs the build. Where a
> challenge or the old mechanism has been superseded, it is annotated inline with a → pointer to the
> governing spec doc (`falsk_rewrite/00`–`08`).

Falsk is a platform for laboratory automation, enabling researchers to plan, execute, and analyze scientific experiments.

## Functional Capabilities

1. **Experiment Planning** — researchers define experimental goals (e.g. assays). The system parses protocol documents and coordinates virtual hardware experts to design, optimize, and validate a sequence of lab steps (a DAG workflow diagram).
2. **Resource and Deck Estimation** — estimates resources (tips, plates, reagents); maps physical labware configurations onto virtual instruments.
3. **Plan Execution** — executes finalized workflows deterministically, via hardware simulators or physical equipment (liquid handlers, plate readers, transfer arms). The server runs locally and connects robots over USB using `pyrobot` for DAG execution. A future network-based execution option is planned.
4. **Data Analysis** — processes plate-reader data (standard curves, concentration calculations, QC) and produces analytical reports.

## Technology Stack (as-is)

- **UI:** single-page React app (TypeScript + Vite). *(→ served by the backend; see Decision 9.)*
- **Backend:** Python web app using **Quart** for HTTP REST + async WebSocket. *(→ being rewritten to **FastAPI**; Decision 1.)*
- **Agents:** Google Agent Development Kit (ADK) running LLMs with specialized instructions.
- **Database:** managed PostgreSQL (AlloyDB) for session metadata, trial histories, conversational logs. Alembic migrations, SQLAlchemy engine, a repository class per entity, and a `DatabaseService` for updates.
- **Storage:** Google Cloud Storage (GCS) for experiment artifacts, reports, raw data.
- **Execution env:** containerized Docker on VMs or Cloud Run; deployed to a VM behind a load balancer for long-lived sockets. Target load: ~4–10 parallel users.
- **Security/Routing:** Identity-Aware Proxy (IAP) authenticates and injects identity headers. Redis/Fakeredis maps WebSocket connections and routes broadcast messages across instances.
- **API keys:** a dedicated **API key manager service** loads/manages API keys and handles rotation. *(→ frozen, used as-is; Decision 12.)*

### System wiring (as-is)

Researchers interact with the React frontend over a persistent WebSocket. On a prompt, the backend authenticates, generates a session, and triggers an async orchestrator task — the **Supervisor Agent** (the root/orchestrator; its name is a frozen asset) — that coordinates planner + hardware-compiling agents to design a workflow. The plan is pushed to the frontend for visualization. On approval, the backend executes the plan via background loops that bypass LLMs and talk directly to hardware/MCP drivers, streaming live status over WebSockets. The first WS message calls the orchestrator with a Redis broadcast callback; every subsequent agent call forwards that callback so the UI keeps receiving updates.

### Session init & management (as-is — preserved)

`create_new` sentinel handshake: UI opens a socket with `session_id = create_new`; on the first prompt the server mints a real session and replies on the same socket with the AI response **plus** the new `session_id`; the UI then reconnects with that id as a query param (and in the URL). Loading an existing session uses that id from the start. *(→ preserved verbatim as a frozen contract; doc 04 §7.)*

### Google ADK & the "Turn-Aware" mechanism (as-is)

The old system isolated ADK behind `google-adk.py` and used a `SharedContext` class plus a bespoke **Turn-Aware** mechanism: one in-memory session reference per turn; sub-agents get a read-only snapshot and return diff packages; the parent aggregates diffs and commits atomically at end-of-turn — built to avoid optimistic-concurrency (OCC) conflicts from nested agents each loading/writing a different session snapshot.

> **→ RESOLUTION (Decision 7):** The Turn-Aware **implementation is removed**. Its goal — a single serial writer per turn — now comes free from using **raw ADK**: one `Runner` invocation per turn means all sub-agents share one `InvocationContext` + one session, and ADK applies each event's `state_delta` via `append_event` serially. Combined with a per-session turn lock (Decision 3), OCC conflicts on the session are structurally impossible. The diff-aggregation harness and `SharedContext` are **not** ported. (doc 02 §8.)

## Current Challenges (as-is) — and how the rewrite addresses them

1. **A single planning turn takes ~30 minutes.** → Addressed by the latency plan: instrument first, then parallelize independent experts (`ParallelAgent`), then model-tier (Flash-class for mechanical steps — approved). Prompts stay frozen; only wiring and `model=` change. **Target: p50 ≤ 15 min** (doc 08 Q5). (doc 03 §7.)
2. **Background writes crossing turn boundaries lose/￼stale state.** → Addressed by decoupling: background work (execution/analysis) is its own durable domain in the `executions` table, never ADK session state; results re-enter the conversation by the next turn *reading* them (pull model). "Turn ends before the job finishes" is no longer a failure mode. (doc 02 §5, Decisions 4 & 6.)
3. **A 2,000-line monolithic server file.** → Addressed by a modular FastAPI layout with a ~400-line module budget and CI size checks; the monolith must not reappear. (doc 04 §1, doc 07.)

## Expectations (unchanged intent)

Robust avoidance of OCC while persisting ADK session state in DB; ground-up rewrite on **FastAPI**; preserve agent prompts + tools, rewrite the harness; use **Google ADK in raw form**; keep a seam so the agent execution layer can later move to **Vertex AI Agent Engine** (server as connection broker) without building it now; IAP stays the authenticator (upsert user + cache in Redis from auth headers).

---

## Rewrite Decisions (resolved during this planning cycle)

These are binding and are reflected in the `falsk_rewrite` spec set. Ordered by topic, each notes the governing doc.

1. **FastAPI, greenfield, ADK-raw.** Rewrite from the ground up on FastAPI; use ADK as raw as possible behind a single `AdkRuntime` boundary; preserve behavior, rewrite only the harness. (doc 00, doc 01, doc 03.)
2. **The coding agent HAS the old code.** Antigravity has full read access to the old codebase; all frozen assets are extracted from it in Phase 0 (not exported separately). Its harness code is a reference only — never ported. (doc 00 A6, doc 06 §0.)
3. **Concurrent turns on one session → reject.** A second in-flight prompt on the same `session_id` is rejected with a structured `409 SESSION_BUSY`. No queuing. Enforced by a cross-instance per-session advisory lock. (doc 02 §4, doc 04 §7.)
4. **Live UI stream, no outbox.** The requirement "UI needs a stream of events" is served by the Broadcaster (workers → Redis → WebSocket), persisted in the existing `chat_messages` table. The session-reflection **outbox is out of scope** — background results re-enter agent memory via the next-turn pull model. (doc 02 §5–6.)
5. **Crash recovery = bounded 3-attempt retry.** On process restart, interrupted executions auto-retry up to 3 times, then mark `failed` (user re-trigger). **Safety:** resume from the last completed DAG step; never re-run a completed step; non-idempotent steps (irreversible liquid transfers) require confirmation before replay. (doc 02 §7.)
6. **One new table only: `executions`.** Durable, turn-independent record of **robot plan executions** — the fix for challenge #2, not logging and not speed. Per-step DAG progress inlined as jsonb. **Reuses** existing `chat_messages` (UI events) and `session_metadata` (session extras/sharing). Dropped: `execution_events`, `execution_steps`, `analysis_jobs`, `session_state_outbox`. If a suitable old table exists, extend it additively instead. (doc 05 §3.)
6b. **Analysis is a frozen sub-agent, not a background job** (doc 08 Q15). It runs in-turn like other agents; outputs go to ADK session state + GCS artifacts. No `AnalysisWorker`, no analysis table, no `kind` discriminator on `executions`. Only the robot execution loop is a background worker. (doc 01 §3.3, doc 02 §3.)
7. **Turn-Aware removed** (see resolution above). (doc 02 §8.)
8. **Agents built once, explicitly.** The agent tree is built once at startup (lifespan) and reused across all sessions/turns — **no per-session init**. Composition is explicit in `agents/factory.py`; the root/orchestrator agent is the **Supervisor Agent** (name frozen). The old `AGENT_CONFIG` name→directory **dispatch dictionary is removed** (ADK resolves delegation by `agent.name`); `agent_config.yaml` is **kept** as the factory's declarative per-agent tuning table (model/tier, temperature, token limits, tool attachment). Prompts/tools **and agent names** stay frozen. (doc 00 §4, doc 03 §1.1–§1.2, §4.)
9. **Single service; `/api/*` + SPA.** No separate UI server and none added. All app endpoints live under `/api/*`; FastAPI serves the compiled React `index.html` from the base path (static mount registered after API/WS/health). The UI has no client-side router, so no history-fallback is added now. Health/readiness stay at root. (doc 04 §9–§10, doc 00 NG7.)
10. **`uv` for packaging.** `pyproject.toml` + committed `uv.lock`; `uv sync --frozen`; `uv run`. No `requirements.txt`/Poetry/`pip install`. (doc 04 §1, doc 06 §0, doc 07.)
11. **`legacy/` quarantine.** All current code moves to a top-level `legacy/` folder (in the same repo), unchanged and read-only; the new app is built greenfield alongside. New code never imports from `legacy/`; frozen assets are copied out with hash checks; `legacy/` is excluded from package/lint/type-check/tests/Docker. Existing **Alembic history is copied forward**, not restarted. (doc 06 §0, doc 07 #13.)
12. **API key manager: frozen, rotation-aware.** The existing key manager service is used **as-is**, unaltered, through its own interface. All API keys (incl. ADK model creds) come through it — never from env/config in new code, never a reimplementation. Consumed rotation-safely so rotation takes effect without a restart. Constructed once in lifespan. (doc 00 §4, doc 03 §2.1, doc 04 §2–3, doc 07 #14.)
13. **FastAPI auth + structured errors.** IAP identity extracted in middleware (user upsert + Redis cache), **trusting the headers** (no JWT crypto verification — doc 08 Q13), with a config-gated local bypass impossible in the cloud profile; a global exception handler returns structured envelopes (`400/422/500` with codes, no stack-trace leakage). **Authz is owner-only** (other users' resources → 404); **sharing is by snapshot → recipient creates a new session** (doc 08 Q12, doc 04 §5.2). Local dev runs without IAP via the `AUTH_MODE=local` config bypass (doc 04 §5.1), which is startup-asserted impossible in the cloud profile. (doc 04 §5–§6.)
15. **Deployment: VM** behind a load balancer for persistent sockets (doc 08 Q14). Confirms in-process execution workers are viable as specified. Cloud Run would need always-on/min-instance config — not built now. (doc 01 §5.)
14. **Antigravity delivery.** Execution is spec-driven in Antigravity: specs + `legacy/` in one workspace, an always-on rules file (`.agents/rules/falsk.md`), a gated `/phase` workflow, and a runbook (`ANTIGRAVITY.md`). CI enforces the doc 07 §5 grep/AST gates from Phase 0. (doc 06, `ANTIGRAVITY.md`.)

## Open items

**Resolved since first draft:** O2 latency target → **p50 ≤ 15 min** (Q5); O5 deployment → **VM** (Q14); plus Q7 (tiering OK), Q9 (Vertex seam-only), Q10 (no schema changes), Q11 (frontend as-is), Q12 (owner-only + snapshot share), Q13 (trust headers), Q15 (analysis is a sub-agent).

**Still open (both low-risk, non-blocking):**

- **O1 — OCC root cause (doc 08 Q4).** Confirm the old orchestration ran sub-agents as separate `Runner` invocations / reloaded the session per agent (the assumed cause the Phase 2 fix rests on). If it already ran one invocation and still hit OCC, a stack trace is needed before Phase 2.
- **O6 — Parity goldens source (doc 08 Q8).** Capture golden outputs from the running old system (preferred) vs reconstruct from logs.

**Nice-to-have clarifications (do not block):**

- **O3 — API key manager interface.** How a caller obtains the current key (fetch-on-use / subscribe-on-rotation / short-TTL accessor); pins the rotation-safe wiring in doc 03 §2.1. Otherwise resolved in Phase 0 from `legacy/`.
- **O4 — Expert panel shape.** Fixed per run, or varies by assay type? Decides whether the doc 03 §1.2 runtime-selection extension is ever built.
