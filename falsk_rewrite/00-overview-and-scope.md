# FALSK Rewrite — 00 · Overview, Scope & Preservation Boundary

> **Audience:** the coding agent (Antigravity) implementing this rewrite, plus human reviewers. The coding agent **has full access to the old codebase** and must use it as the source of truth for all frozen assets (§4); the *author* of these specs did not, which is why extraction steps are spelled out explicitly.
> **Status:** authoritative spec. Where this document and older code disagree, this document wins — *except* for the frozen assets defined in §4, which are copied verbatim.
> **Read order:** 00 → 01 → 02 → 03 → 04 → 05 → 06 → 07. Doc 08 collects open questions.

---

## 1. Why we are rewriting

FALSK is a laboratory-automation platform: researchers describe an experiment (e.g. an assay), a multi-agent system parses protocols and designs a validated DAG workflow, resources/deck are estimated, the plan is executed deterministically against liquid handlers / plate readers / transfer arms, and results are analyzed into reports.

The current implementation works but is not maintainable or scalable:

1. **A single planning turn takes ~30 minutes.** Unacceptable for interactive use.
2. **State-synchronization fragility.** Even with the bespoke "Turn-Aware" mechanism, background processes that write to ADK session state after a turn ends produce lost updates or stale in-turn state (an optimistic-concurrency / lifecycle problem).
3. **A ~2,000-line monolithic server file** holds every endpoint and most logic — untestable, hard to reason about, and full of AI-generated bloat ("slop").

This rewrite is a **greenfield reimplementation** on **FastAPI**, using **Google ADK in as raw a form as possible**, that preserves all existing functionality and agent behavior while fixing the three problems above.

## 2. Goals

- **G1 — Robust session-state management.** Eliminate optimistic-concurrency-control (OCC) conflicts on the ADK session store, and eliminate lost/stale updates from background processes. This is the highest-priority goal. See doc 02.
- **G2 — Interactive latency.** Bring a planning turn from ~30 min toward single-digit minutes through measurement-first instrumentation, parallel agent fan-out, and model tiering. See doc 03 §7.
- **G3 — Maintainable modular backend.** Replace the monolith with a layered FastAPI application: routers → services → repositories, with the ADK integration isolated behind one module. See doc 04.
- **G4 — Correct, structured API surface.** FastAPI auth layer that reads IAP identity headers, and a global exception handler that returns structured error envelopes (400/401/403/404/409/422/500…). See doc 04 §5–6.
- **G5 — Preserve agent intelligence.** Agent prompts and tool contracts are treated as frozen assets (§4). Only the harness around them is rewritten.
- **G6 — Future portability to Vertex AI.** Structure the execution layer so the agent runtime can later move to Vertex AI Agent Engine with the server acting as a connection broker, **without** building that now. See doc 01 §6.

## 3. Non-goals (do NOT do these)

- **NG1** — Do **not** change agent prompts, reasoning strategies, or tool input/output contracts (see §4 and doc 07).
- **NG2** — Do **not** redesign the PostgreSQL/AlloyDB schema destructively or abandon Alembic. Additive migrations only (doc 05 §5).
- **NG3** — Do **not** implement network-based (remote) robot execution or the Vertex AI runtime in this rewrite. Design *seams* for them; leave them unimplemented behind interfaces.
- **NG4** — Do **not** replace IAP with an in-app authentication/identity provider. IAP remains the authenticator; the app trusts and records identity headers.
- **NG5** — Do **not** introduce new infrastructure dependencies (message brokers, new datastores) beyond what is specified here (Postgres/AlloyDB, Redis, GCS). If you believe one is needed, raise it in doc 08 rather than adding it.
- **NG6** — Do **not** "improve" or refactor frozen prompt/tool text for style. Copy exactly.
- **NG7** — Do **not** add a separate service/server for the UI. The compiled React app is served by the same FastAPI process (`index.html` at the base path; app endpoints under `/api/*`), exactly as today (doc 04 §10). No standalone frontend host, no client-side router added in this rewrite.

## 4. Preservation boundary — what is FROZEN vs REWRITTEN

**FROZEN (ported verbatim; behavior must be identical):**

- **Agent prompts / instructions** — every system/agent instruction string. Copied byte-for-byte into the new `agents/` package. If the current code composes prompts from fragments, preserve the composition logic so the *rendered* prompt is identical.
- **Tool contracts** — each tool's name, parameter schema, semantics, and return shape. Tool *implementations* may be re-homed into the new module layout, but their signatures and observable behavior must not change.
- **Domain algorithms** — resource/deck estimation math, standard-curve/concentration/QC calculations, and the DAG execution semantics (`pyrobot` driver protocol). Port logic faithfully; wrap, don't rewrite, the numerics.
- **Database schema & Alembic history** — existing tables (including `sessions`, `users`) and migration chain are preserved; changes are additive (doc 05).
- **Externally observable API + WebSocket message contracts** — message shapes the existing React frontend depends on (see doc 04 §7 and the session-init lifecycle) must remain compatible, unless doc 08 resolves otherwise.
- **API key manager service** — the existing service that loads/manages API keys and performs key rotation is **used as-is, unaltered**. Port it verbatim from `legacy/` (or depend on it in place if it is a separate package) and consume it through its existing interface. The new harness obtains all API keys through this service; it does **not** reimplement key loading, storage, or rotation, and does not read keys from env/config directly (doc 03 §2.1, doc 04 §3, guardrail doc 07 #14).

**REWRITTEN (the "harness"):**

- The HTTP/WebSocket server (monolith → modular FastAPI).
- Session/turn lifecycle and the ADK integration layer.
- Orchestration wiring (how agents are composed and invoked) — behavior of each agent preserved, but *how they are run* (single-invocation, parallel fan-out) is redesigned.
- State-persistence strategy (OCC solution, execution store, background reconciliation).
- Auth middleware, error handling, config, logging/telemetry, dependency injection, tests.

**Rule of thumb for the coding agent:** if an asset encodes *what the agent thinks or computes*, freeze it. If it encodes *how requests are served, state is stored, or agents are wired together*, rewrite it per these specs.

## 5. Assumptions carried into this spec

These were defaulted because the interactive clarification did not complete; doc 08 asks the user to confirm. **Do not treat assumptions as settled requirements where doc 08 flags them.**

- **A1** — The 30-min latency has **not** been formally profiled. The spec therefore mandates instrumentation *before* optimization (doc 03 §7).
- **A2** — Background writers include the **plan-execution loop**, **long-running agent subtasks**, and **async data-analysis jobs**. The state design treats all three with one pattern (doc 02 §5).
- **A3** — Concurrency scale: **4–10 parallel users**, few sessions each. The design targets correctness at this scale with a single-region deployment; it does not need global horizontal scale.
- **A4** — Deployment stays on **Cloud Run / VM behind a load balancer** with sticky WebSocket routing; **Vertex AI is future-proofed, not built** (NG3, G6).
- **A5** — One active **turn per session at a time** is acceptable (a user does not need two concurrent in-flight prompts on the same session). This underpins the per-session serialization in doc 02.
- **A6** — The coding agent **has read access to the old codebase**. All frozen assets (prompts, tool contracts, schema, API/WS contracts) are extracted directly from it during Phase 0 (doc 06 §0); no external export is needed. Greenfield still means a **new repo/structure** — old code is a *reference and extraction source*, never copy-paste material for harness code.

## 6. Glossary

- **Turn** — one user prompt and the complete agent processing it triggers, ending when a final response is committed. Maps to one (or few, tightly controlled) ADK `Runner.run_async` invocation(s).
- **Invocation** — a single `Runner.run_async` call. All agents/sub-agents inside it share one `InvocationContext` and one in-memory session; ADK serializes `append_event` within it.
- **ADK session state** — conversational/agent state persisted by ADK's `DatabaseSessionService` in the `sessions` table. Owned exclusively by the turn's invocation.
- **Execution state** — durable state of a *running plan* (DAG progress, step results). Lives in dedicated tables (doc 05), **not** in ADK session state. Written by background workers.
- **Delta / state_delta** — ADK's mechanism for state changes carried on an `Event.actions.state_delta` and applied by `append_event`.
- **Broadcast callback** — the Redis-pub/sub function passed into the first agent call so live events reach the correct WebSocket connection (doc 04 §8).
