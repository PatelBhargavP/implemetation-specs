# FALSK Rewrite — 05 · Data Model & Persistence Spec

> Preserve the existing AlloyDB schema and Alembic history. Additions are additive migrations only. Keep the existing repository + `DatabaseService` pattern.

## 1. Persistence stack (unchanged)

- **AlloyDB (PostgreSQL)** via **SQLAlchemy** (async engine).
- **Alembic** for schema versioning — the existing migration chain is retained; new work appends new revisions.
- **`DatabaseService`** owns the async engine and session factory and exposes a transaction scope (unit-of-work). **Repositories** (one per table/entity) encapsulate all queries. No SQL or ORM access outside repositories (doc 01 §2).

## 2. Existing tables (preserved — do NOT restructure destructively)

- **`sessions`** — ADK session persistence, managed by ADK's `DatabaseSessionService`. **This is ADK-owned.** Treat its schema as controlled by the ADK library version; do not hand-edit its columns. Application code reads/writes it only through ADK (doc 02, doc 03), never via app repositories.
  - Note: ADK's `DatabaseSessionService` manages its own storage models (`StorageSession`, `StorageAppState`, `StorageUserState`) and performs auto-migration of *its* tables. Keep app Alembic migrations from colliding with ADK-managed tables — segregate (see §5.1).
- **`users`** — user records; upserted from IAP identity (doc 04 §5). App-owned via `UserRepository`.
- **`session_metadata`** — existing app-owned per-session extras (session sharing, and any other app-level session attributes). **Preserved and reused as-is.** The rewrite does **not** add a parallel table for session extras; anything the app needs to hang off a session that is not ADK conversational state goes here (doc 02 §3). Do not fold execution/job status into this table — those have a different lifecycle (see §3). **Sharing model (preserved, doc 08 Q12):** sharing is done by creating a **snapshot** and sharing it; the recipient uses the snapshot to create a **new** session of their own — there is no shared live session. Whatever table/column backs snapshots today is extracted in Phase 0 and preserved; authz elsewhere is owner-only (doc 04 §5).
- **`chat_messages`** — existing app-owned table that captures the events broadcast to the UI (the conversational/event stream). **Preserved and reused as-is; do NOT alter it.** It is the store of record for UI event replay. The rewrite adds **no** parallel event-log table (see §3, and the removed `execution_events` note in §3.1).
- Any other current domain tables (trial histories, plan metadata, etc.) — **enumerate them from the old codebase's models/Alembic history and preserve**. (Action for coding agent: complete the Phase 0 schema inventory before writing migrations; list them in the migration PR.)

## 3. New table — exactly ONE, and only because existing tables can't serve it

The rewrite adds a **single** app-owned table: `executions`. It exists for **durability/correctness, not logging and not speed** — it is the fix for the reported failure "turn completes before the background process completes → state updates lost" (doc 02 §5, Problem B). It is deliberately *not* ADK session state (which loses background writes to OCC + turn lifecycle) and *not* `session_metadata`/`chat_messages` (wrong lifecycle — see §3.1). Before creating it, the coding agent must check Phase 0 inventory: **if the old schema already has a suitable execution/job table, extend it additively instead of creating a new one.**

**`executions`** (plan/robot executions only — the one durable background domain; analysis is NOT here, see §3.1)
- `id` (uuid, pk)
- `session_id` (logical fk to the session that approved it), `user_id`
- `plan_id` / plan snapshot ref
- `status` (`queued|running|completed|failed|interrupted|cancelled`)
- `attempts` (int, default 0 — crash-recovery retry counter, capped at 3 per doc 02 §7)
- `progress` (jsonb) — per-step DAG progress **inlined here** (each entry: `seq`, `dag_node_id`, `status`, timestamps, compact inputs/outputs, device/driver info, error). Large blobs go to GCS with refs, not into this column.
- `last_completed_step_seq` (int, nullable — crash-recovery resume boundary; read from `progress`)
- `created_at`, `started_at`, `finished_at`, `error` (nullable structured)
- `result_refs` (jsonb: GCS refs — plan/execution artifacts)

### 3.1 What was removed and what it maps to

- ~~`execution_steps`~~ — **collapsed** into `executions.progress` (jsonb) + `last_completed_step_seq`. A separate table is only justified if the UI issues step-level SQL queries or step telemetry volume is large; if Phase 0 shows that need, promote `progress` to a child table then (flag in doc 08). Default: inline.
- ~~`execution_events`~~ — **removed. Reuse the existing `chat_messages` table** for the UI event stream / broadcast replay. If Phase 0 finds execution telemetry is finer-grained than what belongs in the chat transcript, write that overflow to **GCS** (referenced from `result_refs`), not a new hot table.
- ~~`analysis_jobs`~~ — **not needed. Analysis is an ADK sub-agent, not a background job** (doc 08 Q15). It runs inside the single-invocation turn; its outputs go to ADK session state (agent) + GCS artifacts via the artifact service. No table, no worker. (If large-dataset analysis ever must detach from a turn, reopen — doc 08 Q15.)
- ~~`session_state_outbox`~~ — already out of scope (doc 02 §6, doc 08 Q2). Not created.

## 4. Repository & DatabaseService rules

- One repository class per entity; methods are intention-revealing (`ExecutionRepository.mark_running`, `.update_progress`, `.set_terminal`, …), not generic CRUD dumps.
- Repositories accept an injected async session; the **service layer** owns the transaction boundary (one unit-of-work per logical operation). Background workers open **short** transactions per write — never hold a transaction open across a hardware step.
- **Isolation:** background-worker writes to execution tables and app reads must not deadlock with ADK's session writes. Because the two domains are in different tables and turns are serialized per session (doc 02 §4), contention is minimal by design.
- Use `jsonb` for flexible/nested payloads; index `session_id`, `execution_id`, and `status` where queried. Keep large binary/raw data in **GCS**, storing only references in Postgres (doc 03 §5).

## 5. Alembic policy

- **Additive only.** New tables and new nullable columns. **No** destructive drops/renames of existing columns in this rewrite. If a true schema change is unavoidable, it must be a separate, reviewed, backward-compatible migration flagged in doc 08.
- Every schema change ships as an Alembic revision with a tested `downgrade`.
- Migrations are reviewed against the schema inventory extracted from the old codebase's SQLAlchemy models + Alembic history (doc 06 §0), cross-checked against the live DB where possible.

### 5.1 ADK-managed tables vs app-managed tables

- ADK's `DatabaseSessionService` auto-creates/migrates its own tables. **Do not** put ADK tables under app Alembic control, and **do not** let app migrations alter them. Document clearly which tables are ADK-owned vs app-owned. If ADK and app share the same database (they do), ensure Alembic's `include_object`/`include_name` config **excludes** ADK-managed tables from autogenerate so migrations never try to drop or modify them.

## 6. Data-integrity invariants

- An `executions` row exists **before** any `ExecutionWorker` task starts (doc 02 §5) — the durable record is authoritative and independent of turn lifecycle.
- The UI event stream lives in the existing `chat_messages` table (reused, unaltered); the rewrite adds no parallel event-log table.
- `session_metadata` is reused for app session extras (sharing, etc.); execution/job status is never folded into it.
- Crash-recovery retries are bounded: `attempts` is incremented per resume and capped at **3** before the row goes to `failed` (doc 02 §7). Retries resume from `last_completed_step_seq` (read from `progress`); completed steps are never re-run, and non-idempotent steps require confirmation before replay.
- Foreign-key links from execution rows to `session_id` are **logical** references for querying/history; they must **not** create a write dependency from workers onto the ADK-owned `sessions` table (workers never write `sessions`).
