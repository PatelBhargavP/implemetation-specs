# FALSK Rewrite — 02 · State & Concurrency Design

> This is the centerpiece of the rewrite. It resolves challenge #2 (OCC conflicts and lost background updates). Read it fully before implementing anything in docs 03–05.

## 1. Root-cause analysis

The current pain comes from two distinct problems that the bespoke "Turn-Aware" layer only partly addresses.

**Problem A — OCC conflicts during a turn.** ADK's `DatabaseSessionService` uses optimistic concurrency: `append_event` checks that the session has not changed since it was loaded (stale-session detection) and raises on conflict. If the orchestration runs sub-agents as **separate `Runner` invocations** — each loading its own snapshot of the same `session_id` and each calling `append_event` — their writes race and conflict. The custom fix (sub-agents return diffs, parent aggregates, one atomic commit at end of turn) is essentially a hand-rolled version of what ADK already provides *inside a single invocation*.

> **Key ADK fact.** Within **one** `Runner.run_async` invocation, every agent and sub-agent shares one `InvocationContext` and one in-memory session. ADK applies each non-partial event's `state_delta` via `append_event` **incrementally and serially**, in order. There is no intra-invocation OCC conflict because there is a single writer. Sub-agents read the up-to-date shared session; they do not each reload from the DB.

**Problem B — background writes crossing turn boundaries.** The background process that matters here is the **plan-execution loop** (the robot DAG run, which bypasses LLMs and can outlast the turn that launched it). If such a process writes to ADK session state after the originating turn has ended, it will either (a) fail/overwrite because it holds a stale session snapshot, or (b) have its update silently dropped because the turn already committed and closed. This is a *lifecycle* mismatch: background work outlives turns, but ADK session state is turn-scoped. *(Analysis is **not** in this category — it is an in-turn sub-agent, doc 08 Q15.)*

## 2. Design principles

- **P1 — One invocation per turn.** A planning turn is a single `Runner.run_async` invocation. The **Supervisor Agent** (root/orchestrator) + planner + hardware experts are ADK **sub-agents composed inside that invocation**, never separate runner calls or separate sessions. This makes ADK the single serial writer and eliminates intra-turn OCC (Problem A).
- **P2 — Never mutate `session.state` directly.** All state changes flow through ADK's sanctioned paths: `output_key`, `EventActions.state_delta`, or `CallbackContext`/`ToolContext` mutations (which ADK folds into the event's `state_delta`). A `Session` object read outside a managed context is **read-only**. Direct mutation is not persisted and is forbidden (doc 07 hard rule).
- **P3 — Separate two state domains.** *Conversational/agent state* (ADK sessions) and *execution state* (running robot plans) are different lifecycles and live in different stores. The execution worker owns execution state and never touches ADK session state directly (fixes Problem B). (Analysis is agent state, not a separate domain — it's an in-turn sub-agent.)
- **P4 — One turn at a time per session.** Turns on the same `session_id` are serialized by a per-session lock (A5). This removes cross-turn OCC on the session row without global locking.
- **P5 — Results re-enter the conversation by reading, not by background writing.** When a completed background job's result must inform the agent, the *next turn* reads it from the execution store via a tool. The default path never writes background results into ADK session state. An optional outbox (§6) covers the rare case where an immediate in-session reflection is required.

## 3. State taxonomy — what lives where

| State | Store | Written by | Lifecycle |
|---|---|---|---|
| Conversation history, agent scratch, plan draft, approvals | ADK `sessions` table via `DatabaseSessionService` | The turn's single invocation (ADK `append_event`) | Turn-scoped writes; persists across turns |
| Cross-session per-user prefs | ADK `user:`-prefixed state | Turn invocation | Persistent per user |
| App-wide constants/config surfaced to agents | ADK `app:`-prefixed state | Rare, controlled turns | Persistent |
| Ephemeral within one invocation | ADK `temp:`-prefixed state | Any agent in the invocation | Discarded after invocation (never persisted) |
| Execution runtime: DAG status, per-step progress, device telemetry | `executions` (single table; per-step progress inlined as jsonb — doc 05 §3) | `ExecutionWorker` (background) via repositories | Independent of turns; long-lived |
| Analysis (standard curves / concentration / QC) | ADK session state + GCS artifacts (NOT a background job — analysis is a frozen **sub-agent**, doc 08 Q15) | The analysis sub-agent, in-turn | Turn-scoped like other agents |
| UI event stream (events broadcast to the UI) | **existing** `chat_messages` table (reused, unaltered — doc 05 §2) | Turn invocation / broadcaster | Persistent |
| App session extras (session sharing, etc.) | **existing** `session_metadata` table (reused, unaltered — doc 05 §2) | App services | Per-session |
| Artifacts (plots, reports, raw data) | GCS via ADK `GcsArtifactService` and/or `ArtifactService` | Turn invocation and/or workers | Persistent, versioned |
| WebSocket conn ↔ instance mapping | Redis | WS router | Connection-scoped |

**Guardrail:** background workers have **no code path** that calls `append_event` on an ADK session except through the OutboxReconciler (§6). Enforce by keeping `session_service` out of worker dependencies.

## 4. Turn model & per-session serialization

`TurnService.run_turn(session_id, user, message)`:

1. **Acquire per-session turn lock.** Use a Postgres advisory lock keyed by a hash of `session_id` (`pg_advisory_xact_lock` / session-level advisory lock), so serialization holds **across backend instances**, not just within one process. (An in-process `asyncio.Lock` keyed by session is insufficient at >1 instance.) If a turn is already active, **reject with `409 SESSION_BUSY`** (structured error, doc 04 §6). No queuing. (Decision confirmed — doc 08 Q1.)
2. **Run one invocation.** Call `AdkRuntime.run_turn(...)` → single `Runner.run_async`. Stream events to the broadcaster.
3. **Release lock** on completion/error (advisory locks auto-release at transaction/connection end — ensure the lock's scope wraps the whole turn).

Because ADK is the single serial writer inside the invocation (P1) and turns are serialized per session (P4), the ADK session row has exactly one writer at any moment. **OCC conflicts on the session are structurally impossible under normal operation.** If `append_event` ever still raises a stale-session error, treat it as a bug/telemetry signal, not something to paper over with retries (log + surface; see §7).

## 5. Background writes — the durable-execution pattern (fixes Problem B)

This is the core fix. Background work is modeled as **its own durable domain**, not as a mutation of conversational state.

**Rules:**

1. When a turn approves a plan (or requests analysis), the turn invocation records the *intent and identifiers* into ADK session state (e.g. `execution_id`) via a normal `state_delta`, then hands off. The turn ends normally.
2. `ExecutionService` creates the durable `executions` row **before** returning, so the job's authoritative record exists independent of any session/turn.
3. The background worker writes **only** to the `executions` table and GCS, and **only** publishes live UI updates via the `Broadcaster` (which persist to the existing `chat_messages` table like any other UI event). It never loads or writes the ADK session. Its writes are ordinary repository writes under their own short transactions — no OCC against the session, ever.
4. **Result re-entry (default, P5):** the next time the user prompts, the turn's agents obtain execution/analysis results through a **tool** (e.g. `get_execution_status(execution_id)`, `get_analysis_result(job_id)`) that reads the execution store. Results thus enter agent reasoning *pulled by a live invocation*, which legitimately writes them into session state via that invocation's `state_delta`. Nothing is lost if the original turn finished first, because the execution store — not session state — is the source of truth.

This means: **"turn completes before background process completes" is no longer a failure mode.** The background process was never depending on the turn staying open; it persists to its own store and the UI keeps updating via Redis broadcast regardless of turn state.

### 5.1 Why not keep the background process "in the current turn context"?

Because a turn is a single, bounded invocation (P1) and must complete to release the per-session lock and return the response to the user. Holding it open for a multi-minute robot run would (a) serialize the user out of their own session, (b) reintroduce the stale-snapshot problem, and (c) couple UI responsiveness to hardware. Decoupling is deliberate.

### 5.2 Why not give the background process its own ADK session/turn?

A background job spinning its own invocation to write the *same* session reintroduces Problem A (two writers, OCC). If a job genuinely needs to *append to the conversation* mid-run, use the outbox (§6), which funnels all such writes through one controlled, serialized applier under the per-session lock.

## 6. Optional: session_state_outbox + OutboxReconciler — **NOT built in this rewrite** (decision: doc 08 Q2)

Bhargav confirmed the actual requirement is the **live UI event stream**, which §5 already provides via the Broadcaster (workers → Redis → WebSocket) without touching ADK session state. The outbox is therefore **out of scope**; this section is retained as the sanctioned design *if* a future need arises for background results to enter the agent's conversational memory before the user's next prompt (e.g. a proactive agent comment on job completion). Do not implement it speculatively.

- Background worker writes a row to `session_state_outbox`: `{session_id, delta_payload, created_at, status=pending}`. This is a plain DB write, no ADK involvement.
- `OutboxReconciler` (a single background task, or a per-session serialized handler) drains pending rows: for each, it **acquires the per-session turn lock** (P4), opens a minimal ADK invocation (or uses `session_service.append_event` directly with a system event carrying the `state_delta`), applies the delta, marks the row `applied`. Because it takes the same lock, it never races a live turn.
- The reconciler is **idempotent**: deltas carry a dedupe key; re-applying an already-applied delta is a no-op. This tolerates worker retries and crashes.

This preserves the "single serial writer per session" invariant even for asynchronous reflections.

## 7. Concurrency invariants & failure handling

- **INV-1** Exactly one writer to a given ADK session at any instant (guaranteed by P1 + P4 + §6).
- **INV-2** Background workers never write ADK session state except via the OutboxReconciler.
- **INV-3** No code mutates `session.state` directly (P2).
- **INV-4** Turn serialization holds across instances (advisory lock, not in-process lock).
- **Failure handling:** if `append_event` raises a stale/conflict error, do **not** silently retry-loop. Log with full context (session_id, invocation_id), emit a telemetry counter, fail the turn with `409` and a structured error. A recurring conflict means an invariant is violated and must be fixed, not masked. (A single bounded retry after reload is acceptable for the outbox reconciler only.)
- **Crash recovery (policy confirmed — doc 08 Q3):** on startup, the `ExecutionWorker` supervisor scans for `executions` rows in non-terminal states (`queued`/`running`) with no live task and **automatically retries them up to 3 attempts** (tracked by the `attempts` counter on the `executions` row). After the 3rd failed attempt the row is marked `failed` and requires explicit user re-trigger. The execution store being authoritative makes recovery well-defined. **Hardware-safety constraints on retry:**
  - Resume from the **last completed DAG step boundary** recorded in `executions.progress` / `last_completed_step_seq` — never blindly re-run steps already marked completed.
  - Any step that is not **verifiably idempotent** (e.g. an irreversible liquid transfer) must not be auto-replayed; such a step requires hardware-state confirmation (or user acknowledgement) before the retry proceeds. If confirmation is unavailable, halt and mark `interrupted` for that step rather than risk a double-dispense.
  - Each retry emits a broadcast event (captured in the existing `chat_messages` table like any other UI event) so the UI stream reflects the attempt (doc 04 §8).

## 8. What happens to the existing "Turn-Aware" mechanism

- Its **intent is preserved**, its **implementation is replaced** by ADK-native single-invocation semantics (P1). The custom "load one session ref per turn / sub-agents return diffs / parent aggregates / atomic end-of-turn commit" logic is **removed** in favor of ADK's own per-event `state_delta` + `append_event` within one invocation.
- The one scenario the old mechanism was reaching for and ADK does not cover natively — background/async reflections into a session — is handled explicitly by §5 (pull model; the default and only built path), not by keeping a session reference alive across a turn boundary. (§6's outbox is the sanctioned-but-unbuilt fallback if a proactive in-conversation reflection is ever required — doc 08 Q2.)
- **Guardrail:** do not port the old diff-aggregation code. If, during implementation, a case appears that seems to need it, stop and record it in doc 08 rather than resurrecting the pattern.
