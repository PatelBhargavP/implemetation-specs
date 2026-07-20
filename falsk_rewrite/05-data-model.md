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
- Any other current domain tables (trial histories, conversational logs, plan/session metadata) — **enumerate them from the old codebase's models/Alembic history and preserve**. (Action for coding agent: complete the Phase 0 schema inventory before writing migrations; list them in the migration PR.)

## 3. New tables (execution & reconciliation domain — additive)

These implement the durable-execution decoupling (doc 02 §5). All app-owned, all via repositories.

**`executions`**
- `id` (uuid, pk), `session_id` (fk logical link to the session that approved it), `user_id`, `plan_id`/plan snapshot ref, `status` (`queued|running|completed|failed|interrupted|cancelled`), `attempts` (int, default 0 — crash-recovery retry counter, capped at 3 per doc 02 §7), `last_completed_step_seq` (int, nullable — resume boundary), `created_at`, `started_at`, `finished_at`, `error` (nullable structured), `result_artifact_refs` (jsonb: GCS refs).

**`execution_steps`**
- `id` (pk), `execution_id` (fk), `dag_node_id`, `seq`, `status`, `started_at`, `finished_at`, `inputs`/`outputs` (jsonb, compact — large blobs go to GCS with refs here), `device`/driver info, `error`.

**`execution_events`**
- `id` (pk), `execution_id` (fk), `ts`, `type`, `payload` (jsonb). Append-only event log used for live broadcast replay and post-hoc audit. This is the execution-domain analog of an event stream — **not** ADK events.

**`analysis_jobs`**
- `id` (pk), `session_id`, `execution_id` (nullable), `status`, `attempts` (int, default 0 — crash-recovery retry counter, capped at 3 per doc 02 §7), timestamps, `inputs_ref`, `result_refs` (jsonb: standard curves, concentrations, QC, report GCS paths), `error`.

**`session_state_outbox`** (only if §6 of doc 02 is enabled)
- `id` (pk), `session_id`, `dedupe_key` (unique), `delta_payload` (jsonb), `status` (`pending|applied|failed`), `created_at`, `applied_at`, `attempts`.

## 4. Repository & DatabaseService rules

- One repository class per entity; methods are intention-revealing (`ExecutionRepository.mark_running`, `.append_event`, `.set_terminal`, …), not generic CRUD dumps.
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
- `execution_events` is append-only; never updated in place.
- Crash-recovery retries are bounded: `attempts` is incremented per resume and capped at **3** before the row goes to `failed` (doc 02 §7). Retries resume from `last_completed_step_seq`; completed steps are never re-run, and non-idempotent steps require confirmation before replay.
- The `session_state_outbox` table and its idempotency (`dedupe_key`) apply **only if** the outbox is ever built — it is **out of scope** for this rewrite (doc 02 §6, doc 08 Q2). Do not create the table unless that decision is reopened.
- Foreign-key links from execution rows to `session_id` are **logical** references for querying/history; they must **not** create a write dependency from workers onto the ADK-owned `sessions` table (workers never write `sessions`).
