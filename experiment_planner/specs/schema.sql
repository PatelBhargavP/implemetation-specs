-- =============================================================================
-- Protocol Workcell Platform — PostgreSQL schema
--
-- Companion to:
--   adr/ADR-001-authentication-and-identity.md
--   adr/ADR-002-sandbox-topology.md
--   adr/ADR-003-protocol-revisions-and-export-contract.md
--
-- Target: AlloyDB for PostgreSQL (PostgreSQL 15+ compatible).
--   Decided 2026-08-19: AlloyDB, cost not being the primary constraint.
--   Verify at provisioning time that the 'citext' and 'pgcrypto' extensions are
--   enabled on the cluster; both are used below.
--   Nothing in this file depends on AlloyDB-specific features, so it remains
--   portable to Cloud SQL if that decision is ever revisited.
--
-- This file is the contract. Migrations should be generated from it, not
-- hand-written alongside it. Comments marked WHY: exist because the obvious
-- alternative is wrong; do not "simplify" them away.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";   -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS "citext";     -- case-insensitive email


-- =============================================================================
-- ENUMS
-- =============================================================================

-- WHY: 'owner' is a role, not a column on workcells. Authorization reads from
-- exactly one place (collaborators), so there is no owner_id/collaborators
-- drift to reconcile. Exactly one owner per workcell is enforced by index.
CREATE TYPE collaborator_role AS ENUM ('owner', 'editor', 'viewer');

CREATE TYPE protocol_status AS ENUM ('idle', 'provisioning', 'running', 'error');

CREATE TYPE sandbox_status AS ENUM (
    'provisioning', 'running', 'stopping', 'stopped', 'failed'
);

CREATE TYPE turn_event_kind AS ENUM (
    'user_message',      -- prompt submitted by a user
    'agent_delta',       -- streamed chunk of agent output
    'agent_message',     -- completed agent message
    'tool_call',
    'file_changed',      -- agent wrote a file
    'manual_edit',       -- user saved a file (mirrored here for the UI timeline)
    'turn_start',
    'turn_end',
    'error'
);

CREATE TYPE simulation_status AS ENUM ('passed', 'failed', 'not_run');


-- =============================================================================
-- USERS  (ADR-001)
-- =============================================================================

CREATE TABLE users (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    -- WHY: the IAP subject is the stable identity key. Email addresses are
    -- reassigned when staff turn over; keying on email would let a new hire
    -- inherit a departed colleague's workcell access. See ADR-001 P2.
    iap_subject     text        NOT NULL,

    email           citext      NOT NULL,
    display_name    text,

    is_admin        boolean     NOT NULL DEFAULT false,
    is_active       boolean     NOT NULL DEFAULT true,

    created_at      timestamptz NOT NULL DEFAULT now(),
    last_seen_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT users_iap_subject_key UNIQUE (iap_subject),
    CONSTRAINT users_email_key       UNIQUE (email)
);

COMMENT ON COLUMN users.iap_subject IS
    'Stable IAP subject. Source: verified JWT "sub" claim. Never derived from email.';
COMMENT ON COLUMN users.email IS
    'Mutable. Display and invite-lookup only. Never a foreign key target.';
COMMENT ON COLUMN users.is_admin IS
    'Ownership-transfer endpoint only (ADR-001 P7). May instead be sourced from '
    'config; if so, drop this column rather than maintaining two sources.';

-- Rows are created transparently by the identity dependency on first request
-- (ADR-001 P3). The upsert MUST be atomic — two concurrent first requests from
-- the same new user must not both insert:
--
--   INSERT INTO users (iap_subject, email, display_name)
--   VALUES ($1, $2, $3)
--   ON CONFLICT (iap_subject) DO UPDATE
--     SET email = EXCLUDED.email,
--         display_name = EXCLUDED.display_name,
--         last_seen_at = now()
--   RETURNING *;
--
-- Do NOT run this unconditionally on every request; read through a cache and
-- upsert only on miss, throttling last_seen_at to ~1 write per 5 min per user.


-- =============================================================================
-- WORKCELLS  — the sharing / ACL boundary
-- =============================================================================

CREATE TABLE workcells (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name        text        NOT NULL,
    created_by  uuid        NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT workcells_name_not_blank CHECK (length(btrim(name)) > 0)
);

COMMENT ON COLUMN workcells.created_by IS
    'Historical provenance only. NOT authoritative for ownership — current '
    'ownership is collaborators.role = ''owner''. Do not use for authorization.';


-- =============================================================================
-- COLLABORATORS  — the single source of truth for authorization
-- =============================================================================

CREATE TABLE collaborators (
    workcell_id uuid              NOT NULL REFERENCES workcells (id) ON DELETE CASCADE,

    -- WHY NOT NULL: pilot scope shares only with users who have already signed
    -- in (ADR-001 P6). The invite endpoint returns 422 user_not_found when no
    -- row matches the email. Adding pending invitations later means a separate
    -- table, not a nullable column here.
    user_id     uuid              NOT NULL REFERENCES users (id) ON DELETE RESTRICT,

    role        collaborator_role NOT NULL,
    added_by    uuid              REFERENCES users (id) ON DELETE SET NULL,
    added_at    timestamptz       NOT NULL DEFAULT now(),

    PRIMARY KEY (workcell_id, user_id)
);

-- WHY: exactly one owner per workcell, enforced by the database. Ownership
-- transfer demotes and promotes in a single transaction; this index makes a
-- botched transfer fail loudly instead of leaving zero or two owners.
CREATE UNIQUE INDEX collaborators_one_owner_per_workcell
    ON collaborators (workcell_id)
    WHERE role = 'owner';

-- Drives the workcell-list screen. Without it, the landing page table-scans.
CREATE INDEX collaborators_user_idx ON collaborators (user_id);

-- ON DELETE RESTRICT on user_id is deliberate: a user who still owns a workcell
-- cannot be deleted. Offboarding must transfer ownership first (ADR-001 P7).

-- ROLE SEMANTICS — enforce at the API layer, all three of them:
--   viewer : read files, read chat history, read revisions.
--            MUST NOT send chat prompts, start a sandbox, save files, or
--            publish revisions.
--            WHY: sending a prompt causes the agent to mutate files. A viewer
--            who can chat is an editor with extra steps.
--   editor : everything a viewer can do, plus prompt, save, start sandboxes,
--            publish revisions, create protocols.
--   owner  : everything an editor can do, plus manage collaborators, rename
--            and delete the workcell, and transfer ownership.


-- =============================================================================
-- PROTOCOLS  — the isolation unit
-- =============================================================================

CREATE TABLE protocols (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workcell_id   uuid            NOT NULL REFERENCES workcells (id) ON DELETE CASCADE,
    name          text            NOT NULL,
    status        protocol_status NOT NULL DEFAULT 'idle',

    -- Storage root. Working state lives under <storage_prefix>/working/ and
    -- published revisions under <storage_prefix>/revisions/{n}/ (ADR-003 P2).
    -- Nesting under the workcell is what makes a future cross-protocol
    -- reference a permissions grant rather than a data migration.
    storage_prefix text           NOT NULL,

    -- WHY: recorded from day one even though exactly one profile exists in
    -- Stage 1 (ADR-005 P1). Adding it later means a migration plus a manifest
    -- version bump plus revisions whose runtime is permanently unknowable.
    runtime_profile text          NOT NULL DEFAULT 'plr-stage1',

    -- WHY: per-protocol monotonic counter for turn_events.seq. Allocated with
    -- UPDATE ... RETURNING inside the append transaction. Serializes event
    -- writes per protocol, which is free — a protocol has one writer anyway
    -- (ADR-002 P1) — and yields a gapless cursor for WebSocket replay.
    event_seq     bigint          NOT NULL DEFAULT 0,

    created_by    uuid            NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
    created_at    timestamptz     NOT NULL DEFAULT now(),
    updated_at    timestamptz     NOT NULL DEFAULT now(),

    CONSTRAINT protocols_name_not_blank CHECK (length(btrim(name)) > 0),
    CONSTRAINT protocols_name_unique_in_workcell UNIQUE (workcell_id, name),
    CONSTRAINT protocols_storage_prefix_key UNIQUE (storage_prefix)
);

CREATE INDEX protocols_workcell_idx ON protocols (workcell_id);

COMMENT ON COLUMN protocols.status IS
    'Denormalized for list rendering. Derived from the active sandbox_sessions '
    'row; that row is authoritative. Never gate a decision on this column.';


-- =============================================================================
-- PROTOCOL REVISIONS  — immutable, the export contract  (ADR-003)
-- =============================================================================

CREATE TABLE protocol_revisions (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    protocol_id     uuid        NOT NULL REFERENCES protocols (id) ON DELETE RESTRICT,
    revision_number integer     NOT NULL,

    label           text,
    storage_prefix  text        NOT NULL,

    -- Full export manifest (ADR-003). Includes manifest_version, files with
    -- sha256, runtime image digest and pinned library versions, and simulation
    -- result. Columns below are extracted for queryability, not as substitutes.
    manifest        jsonb       NOT NULL,

    manifest_version text       NOT NULL,
    sim_status      simulation_status NOT NULL,

    -- The exact environment that produced this revision. Both are required by
    -- the future execution app to decide whether it can safely run this
    -- revision at all (ADR-003, ADR-005 P1).
    runtime_profile text        NOT NULL,
    runtime_image_digest text,

    published_by    uuid        NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
    published_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT protocol_revisions_number_unique UNIQUE (protocol_id, revision_number),
    CONSTRAINT protocol_revisions_number_positive CHECK (revision_number > 0),
    CONSTRAINT protocol_revisions_prefix_key UNIQUE (storage_prefix)
);

CREATE INDEX protocol_revisions_protocol_idx
    ON protocol_revisions (protocol_id, revision_number DESC);

-- WHY: ON DELETE RESTRICT rather than CASCADE. A published revision is an audit
-- record that a future execution app may reference. Deleting a protocol must
-- not silently erase what was published from it; archive instead.

-- Immutability is enforced here, not left to application discipline (ADR-003 P1).
CREATE OR REPLACE FUNCTION forbid_revision_mutation() RETURNS trigger AS $$
BEGIN
    RAISE EXCEPTION
        'protocol_revisions is append-only (ADR-003 P1); attempted % on revision %',
        TG_OP, OLD.id;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER protocol_revisions_immutable
    BEFORE UPDATE OR DELETE ON protocol_revisions
    FOR EACH ROW EXECUTE FUNCTION forbid_revision_mutation();

-- Allocate revision_number inside the publishing transaction:
--   SELECT coalesce(max(revision_number), 0) + 1
--     FROM protocol_revisions WHERE protocol_id = $1 FOR UPDATE;
-- The uniqueness constraint is the backstop if two publishes race.


-- =============================================================================
-- SANDBOX SESSIONS  (ADR-002)
-- =============================================================================

CREATE TABLE sandbox_sessions (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    protocol_id      uuid           NOT NULL REFERENCES protocols (id) ON DELETE CASCADE,

    -- GKE Agent Sandbox claim identity. Null while provisioning.
    sandbox_ref      text,
    status           sandbox_status NOT NULL DEFAULT 'provisioning',

    -- WHY: this column IS the driver lock (ADR-004 P1). The user who started the
    -- active session is the protocol's driver; every other collaborator gets
    -- read-only observer mode. Deliberately not a separate lock table — two
    -- sources of truth for "who holds this protocol" drift, and the drift is
    -- invisible until someone is wrongly locked out.
    started_by       uuid           REFERENCES users (id) ON DELETE SET NULL,

    -- Drives the disconnect-grace-period release in ADR-004 P3. Null while the
    -- driver's WebSocket is connected; set when it drops.
    driver_disconnected_at timestamptz,

    -- WHY two timestamps: reaping is lease-based, not activity-based
    -- (ADR-002 P5). A sandbox grinding through a long agent turn with no user
    -- interaction has a stale last_activity_at but a fresh heartbeat_at, and
    -- must NOT be reaped. Reap on heartbeat staleness; use last_activity_at
    -- only for the idle-timeout policy.
    last_activity_at timestamptz    NOT NULL DEFAULT now(),
    heartbeat_at     timestamptz    NOT NULL DEFAULT now(),

    created_at       timestamptz    NOT NULL DEFAULT now(),
    ended_at         timestamptz,
    error_message    text
);

-- WHY: one live sandbox per protocol (ADR-002 R5). The Antigravity harness
-- writes to disk without locking; two concurrent sessions corrupt the workspace.
-- A partial unique index makes this the database's problem, not a race in
-- application code.
CREATE UNIQUE INDEX sandbox_sessions_one_active_per_protocol
    ON sandbox_sessions (protocol_id)
    WHERE status IN ('provisioning', 'running', 'stopping');

-- Reconcile sweep (ADR-002 P5).
CREATE INDEX sandbox_sessions_reaper_idx
    ON sandbox_sessions (heartbeat_at)
    WHERE status IN ('provisioning', 'running');


-- =============================================================================
-- TURN LEASES  — startup race guard for the sandbox-idle case  (ADR-002 P1)
-- =============================================================================

-- The authoritative turn lock lives INSIDE the sandbox, which is the single
-- writer. This table covers only the window where no sandbox exists yet and two
-- users both try to start one. TTL-bounded so a crashed starter cannot deadlock
-- a protocol forever.
CREATE TABLE turn_leases (
    protocol_id uuid PRIMARY KEY REFERENCES protocols (id) ON DELETE CASCADE,
    held_by     uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    sandbox_ref text,
    acquired_at timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL,

    CONSTRAINT turn_leases_ttl_sane CHECK (expires_at > acquired_at)
);

CREATE INDEX turn_leases_expiry_idx ON turn_leases (expires_at);


-- =============================================================================
-- TURN EVENTS  — durable, resumable conversation log  (ADR-002 P2)
-- =============================================================================

-- WHY this table exists at all: no WebSocket survives beyond ~60 minutes
-- (ADR-001 P8) and clients disconnect routinely. A turn keeps running in the
-- sandbox when its socket drops. Without a durable log, closing a laptop lid
-- loses an in-flight turn's output irrecoverably.
CREATE TABLE turn_events (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    protocol_id uuid            NOT NULL REFERENCES protocols (id) ON DELETE CASCADE,

    -- Gapless, per-protocol, monotonic. Clients reconnect with ?since=<seq>.
    -- Allocated from protocols.event_seq via UPDATE ... RETURNING.
    seq         bigint          NOT NULL,

    session_id  uuid            REFERENCES sandbox_sessions (id) ON DELETE SET NULL,
    turn_id     uuid,

    kind        turn_event_kind NOT NULL,
    actor_user_id uuid          REFERENCES users (id) ON DELETE SET NULL,
    payload     jsonb           NOT NULL DEFAULT '{}'::jsonb,
    created_at  timestamptz     NOT NULL DEFAULT now(),

    CONSTRAINT turn_events_seq_unique UNIQUE (protocol_id, seq)
);

-- Serves both replay (?since=) and initial history load.
CREATE INDEX turn_events_replay_idx ON turn_events (protocol_id, seq);

COMMENT ON COLUMN turn_events.kind IS
    'manual_edit rows mirror file_edits into the conversation timeline so the '
    'UI has one ordered record of everything that touched the protocol.';

-- NOTE: agent_delta rows are high-volume. Either compact them into the
-- completed agent_message on turn_end and delete the deltas, or partition this
-- table by protocol_id. Decide before load testing, not after.


-- =============================================================================
-- FILE EDITS  — manual saves and agent awareness
-- =============================================================================

CREATE TABLE file_edits (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    protocol_id        uuid        NOT NULL REFERENCES protocols (id) ON DELETE CASCADE,
    path               text        NOT NULL,
    edited_by_user_id  uuid        NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
    edited_at          timestamptz NOT NULL DEFAULT now(),

    -- Which write path was taken. Both paths log here so the "consumed"
    -- bookkeeping is uniform.
    via_sandbox        boolean     NOT NULL,

    -- WHY timestamp + session, not a boolean: a boolean cannot answer "when was
    -- this surfaced to the agent, and by which session?" — which is exactly the
    -- question when debugging an agent that acted on stale file contents.
    consumed_at        timestamptz,
    consumed_by_session_id uuid    REFERENCES sandbox_sessions (id) ON DELETE SET NULL,

    CONSTRAINT file_edits_consumed_consistent
        CHECK ((consumed_at IS NULL) = (consumed_by_session_id IS NULL))
);

-- The hydration query: unconsumed edits, oldest first, to prime the agent's
-- first turn after a sandbox starts.
CREATE INDEX file_edits_unconsumed_idx
    ON file_edits (protocol_id, edited_at)
    WHERE consumed_at IS NULL;


-- =============================================================================
-- AUDIT LOG
-- =============================================================================

CREATE TABLE audit_log (
    id            bigserial PRIMARY KEY,
    actor_user_id uuid        REFERENCES users (id) ON DELETE SET NULL,
    action        text        NOT NULL,   -- e.g. 'workcell.owner_transferred'
    target_type   text        NOT NULL,   -- 'workcell' | 'protocol' | 'user'
    target_id     uuid,
    details       jsonb       NOT NULL DEFAULT '{}'::jsonb,
    created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX audit_log_target_idx ON audit_log (target_type, target_id, created_at DESC);
CREATE INDEX audit_log_actor_idx  ON audit_log (actor_user_id, created_at DESC);

-- Minimum actions to record: collaborator added/removed/role changed,
-- ownership transferred, workcell deleted, protocol deleted, revision published.


-- =============================================================================
-- updated_at maintenance
-- =============================================================================

CREATE OR REPLACE FUNCTION touch_updated_at() RETURNS trigger AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER workcells_touch_updated_at
    BEFORE UPDATE ON workcells
    FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE TRIGGER protocols_touch_updated_at
    BEFORE UPDATE ON protocols
    FOR EACH ROW EXECUTE FUNCTION touch_updated_at();


-- =============================================================================
-- AUTHORIZATION — the one query every user-facing route runs
-- =============================================================================

-- Resolve a caller's role on the workcell owning a protocol. Checked ONCE at
-- the workcell level; never per protocol.
--
--   SELECT c.role
--     FROM collaborators c
--     JOIN protocols p ON p.workcell_id = c.workcell_id
--    WHERE p.id = $1 AND c.user_id = $2;
--
-- No row -> 404, not 403. WHY: a 403 confirms the protocol exists, leaking the
-- existence of other teams' work to anyone who can guess an id.

-- Resolve the current driver for a protocol (ADR-004 P1). No row -> no driver,
-- and the caller may acquire one by starting a session.
--
--   SELECT s.started_by, s.created_at
--     FROM sandbox_sessions s
--    WHERE s.protocol_id = $1
--      AND s.status IN ('provisioning', 'running', 'stopping');
--
-- Write-path authorization is therefore a two-step check: role >= editor
-- (collaborators), AND caller = driver (above). A user can pass the first and
-- fail the second; that is observer mode, and it returns 409 not_driver — never
-- 403, which would wrongly imply the user lacks workcell access.


-- =============================================================================
-- DECISION STATUS — see adr/README.md
-- =============================================================================
-- All four previously-open decisions affecting this schema are now closed:
--   D-1  AlloyDB for PostgreSQL.                                      CLOSED
--   D-2  File content in Cloud Storage, not Postgres. No protocol_files
--        table exists, by decision — object storage is authoritative for file
--        content, guarded by the manifest-commit protocol in ADR-002 P4.  CLOSED
--   D-3  Dependencies staged; Stage 1 is a fixed image. See ADR-005.   CLOSED
--   D-4  Single driver per protocol, observers read-only. See ADR-004.  CLOSED
