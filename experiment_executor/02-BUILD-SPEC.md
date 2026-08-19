# Experiment Executor — Build Specification

**Revision 2 — user-identity architecture.**
**Audience:** an AI coding agent implementing this end to end.
**Companion doc:** `01-PROPOSAL.md` (rationale). This document is the contract; where the two disagree, this one wins.

---

## 0. Rules for the implementing agent

Read these before writing any code.

1. **Do not invent alternatives to what is specified here.** Table names, column names, enum values, endpoints and IPC message types are contracts — other components depend on the exact strings.
2. **The operator is always the authenticated caller.** Never accept an operator identity from the request body. If you find yourself adding an `operator_email` parameter, you have made a mistake.
3. **Every request is authorised against the caller's role on the claimed workcell.** No endpoint returns workcell data without that check.
4. **Never run protocol code in the app process.** Always the runner subprocess.
5. **Never skip the preflight gate or the deck quarantine** (§7.0, §7.5). These are hardware-safety requirements, not features.
6. **The desktop app holds no service-account key, no database credential and no GCS credential.** Its only secrets are an OAuth client secret (which for an installed app is not confidential per RFC 8252) and an in-memory refresh token. Do not add `google-cloud-storage` or any database driver to `ee-app`'s dependencies — **there is a test asserting this.** All data access goes through the control plane; all file transfer goes through signed URLs it mints.
7. Build milestones in order (§2); do not advance until acceptance criteria pass.
8. **Ask before deviating.** If a requirement appears impossible or contradictory, stop and report rather than improvising.

### Versions

| Component | Version |
|---|---|
| Python | 3.11 |
| PySide6 | ≥6.7 |
| PyLabRobot | 0.2.2 |
| FastAPI | ≥0.115 |
| SQLAlchemy | 2.0.x |
| Alembic | ≥1.13 |
| Pydantic | 2.x |
| AlloyDB for PostgreSQL | PG 16-compatible |
| Local dev / CI database | stock `postgres:16` |
| `jsonschema` | ≥4.21 (draft 2020-12) |
| `google-auth`, `google-auth-oauthlib`, `google-cloud-storage` | latest |
| `google-cloud-alloydb-connector` | latest |

**Use PySide6, not PyQt.** Licensing (proposal §9).

---

## 1. Repository layout

```
experiment-executor/
├── pyproject.toml                 # uv/hatch workspace
├── packages/
│   ├── ee-common/                 # shared, no I/O
│   │   └── src/ee_common/
│   │       ├── enums.py           # ALL enums. single source of truth.
│   │       ├── ipc.py             # runner <-> app message models
│   │       ├── backends.py        # BackendAdapter protocol, PreflightResult
│   │       └── schema_forms.py    # JSON Schema + x-ui validation helpers
│   │
│   ├── ee-control-plane/          # FastAPI, deploys to Cloud Run
│   │   ├── src/ee_control_plane/
│   │   │   ├── main.py
│   │   │   ├── auth.py            # TokenVerifier impls -> CallerContext
│   │   │   ├── db.py              # AlloyDB connector / local PG factory
│   │   │   ├── models.py          # SQLAlchemy ORM
│   │   │   ├── schemas.py         # Pydantic request/response
│   │   │   ├── gcs.py             # signed URLs, object metadata
│   │   │   ├── routers/
│   │   │   │   ├── session.py     # whoami, workcell resolve, heartbeat
│   │   │   │   ├── protocols.py
│   │   │   │   └── runs.py
│   │   │   └── sweeper.py         # stale-run reconciliation
│   │   ├── alembic/
│   │   └── Dockerfile
│   │
│   ├── ee-runner/                 # protocol subprocess
│   │   └── src/ee_runner/
│   │       ├── __main__.py        # python -m ee_runner
│   │       ├── harness.py         # abort event, command gate
│   │       ├── loader.py          # load protocol module from disk
│   │       ├── emit.py            # JSONL stdout writer
│   │       └── backends/
│   │           ├── __init__.py    # ADAPTERS registry
│   │           ├── chatterbox.py
│   │           └── star.py
│   │
│   └── ee-app/                    # PySide6 desktop
│       └── src/ee_app/
│           ├── __main__.py
│           ├── config.py          # /etc/experiment-executor/config.toml
│           ├── auth.py            # OAuth loopback flow + token cache
│           ├── api_client.py
│           ├── spool.py           # local SQLite event spool
│           ├── logs.py            # local run logs + GCS sync worker
│           ├── run_controller.py  # subprocess lifecycle + abort ladder
│           ├── formgen.py         # JSON Schema -> Qt widgets
│           └── views/
│               ├── sign_in.py
│               ├── protocol_list.py
│               ├── input_form.py
│               ├── run_monitor.py
│               └── needs_attention.py
│
├── tools/
│   ├── register_protocol.py       # admin CLI
│   └── grant_role.py              # admin CLI
└── examples/protocols/
    └── serial_dilution/
        ├── protocol.py
        └── inputs.schema.json
```

---

## 2. Milestones

| # | Milestone | Acceptance criteria |
|---|---|---|
| **M0** | IAP bootstrap | Custom OAuth client (type **Desktop app**) created; client ID added to `programmatic_clients`. A throwaway `GET /v1/_debug/claims` returns an assertion whose `email` is the signing-in human's address. Observed `aud` recorded. **Blocks everything.** |
| **M1** | DB schema + migrations | `alembic upgrade head` builds all 8 tables on `postgres:16` **and** AlloyDB; `downgrade base` reverses. Seed creates 1 workcell, 3 users with each role. |
| **M1b** | AlloyDB connectivity | Control plane on Cloud Run with Direct VPC egress reaches AlloyDB via the connector using **IAM auth, no password**. `/healthz` returns DB round-trip latency. |
| **M2** | Auth + authorisation | Signed-in user resolves to a `users` row (auto-created). User with no role on the claimed workcell → 403. `viewer` cannot start a run → 403. **Test proves a caller cannot read another workcell's protocol by UUID → 404.** `run.app` URL unreachable. |
| **M3** | Protocol registration CLI | Uploads script + schema, records generation and crc32c, and `GET /v1/protocols` returns it for the owning workcell only. |
| **M4** | Runner + preflight + abort ladder | Runner executes a chatterbox protocol, emits well-formed JSONL, aborts at a command boundary. Tests cover all 3 escalation levels and a deliberately unresponsive runner reaching SIGKILL. A `DIRTY` preflight prevents `setup()` being called. |
| **M5** | Run lifecycle API | Full create → events → complete flow persists. Concurrent-run attempt rejected by the DB constraint, not app logic. |
| **M6** | PySide6 shell | Sign-in → protocol list → run monitor → abort, end to end against a real control plane. |
| **M7** | Form generation | All supported types render, validate, and produce a resolved document passing server-side validation. |
| **M8** | Resilience | `kill -9` the app mid-run → next launch reconciles to `UNKNOWN` and quarantines. Network cut mid-run → run completes, events flush on reconnect, **token expiry does not interrupt the run**. |

---

## 3. Enums — `ee_common/enums.py`

**Single source of truth.** Postgres native enums mirror these exactly.

```python
from enum import StrEnum

class Role(StrEnum):
    VIEWER   = "viewer"
    OPERATOR = "operator"
    ADMIN    = "admin"

    @property
    def can_execute(self) -> bool:
        return self in (Role.OPERATOR, Role.ADMIN)

class DeckState(StrEnum):
    READY           = "ready"            # safe to start a run
    NEEDS_ATTENTION = "needs_attention"  # blocked until acknowledged

class PreflightStatus(StrEnum):
    CLEAN       = "clean"        # instrument verified safe to initialise
    DIRTY       = "dirty"        # tips/tools detected — BLOCK
    UNSUPPORTED = "unsupported"  # backend cannot introspect
    ERROR       = "error"        # check itself failed — treat as DIRTY

class RunStatus(StrEnum):
    PENDING   = "pending"     # created, runner not started
    RUNNING   = "running"
    COMPLETED = "completed"   # terminal
    ABORTED   = "aborted"     # terminal, operator-initiated
    FAILED    = "failed"      # terminal, protocol raised or preflight blocked
    UNKNOWN   = "unknown"     # terminal, crash/heartbeat loss

TERMINAL_RUN_STATUSES = {
    RunStatus.COMPLETED, RunStatus.ABORTED,
    RunStatus.FAILED, RunStatus.UNKNOWN,
}

class TerminationReason(StrEnum):
    NORMAL                = "normal"
    OPERATOR_ABORT        = "operator_abort"
    PROTOCOL_EXCEPTION    = "protocol_exception"
    RUNNER_CRASH          = "runner_crash"
    HEARTBEAT_LOST        = "heartbeat_lost"
    APP_RESTART_ORPHANED  = "app_restart_orphaned"
    PREFLIGHT_BLOCKED     = "preflight_blocked"

class AbortEscalation(StrEnum):
    NONE        = "none"
    COOPERATIVE = "cooperative"
    SIGTERM     = "sigterm"
    SIGKILL     = "sigkill"

class RunEventType(StrEnum):
    CREATED            = "created"
    RUNNER_STARTED     = "runner_started"
    PREFLIGHT_STARTED  = "preflight_started"
    PREFLIGHT_RESULT   = "preflight_result"
    SETUP_COMPLETE     = "setup_complete"
    STEP_STARTED       = "step_started"
    STEP_COMPLETED     = "step_completed"
    LOG                = "log"
    ABORT_REQUESTED    = "abort_requested"
    ABORT_ESCALATED    = "abort_escalated"
    TEARDOWN_ATTEMPTED = "teardown_attempted"
    TERMINATED         = "terminated"
```

---

## 4. Database schema

**AlloyDB for PostgreSQL** (PG 16-compatible). Initial Alembic migration. All timestamps `TIMESTAMPTZ`. All PKs `UUID DEFAULT gen_random_uuid()` (requires `pgcrypto`).

> **Use only standard PostgreSQL.** No AlloyDB-specific features. Every statement must run unmodified on `postgres:16`, because that is what CI uses (§11). The instance is shared with other experimental applications — **create a dedicated database, and do not alter instance-level settings.**

```sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TYPE role_enum              AS ENUM ('viewer','operator','admin');
CREATE TYPE deck_state_enum        AS ENUM ('ready','needs_attention');
CREATE TYPE run_status_enum        AS ENUM ('pending','running','completed','aborted','failed','unknown');
CREATE TYPE termination_reason_enum AS ENUM (
    'normal','operator_abort','protocol_exception',
    'runner_crash','heartbeat_lost','app_restart_orphaned','preflight_blocked');
CREATE TYPE abort_escalation_enum  AS ENUM ('none','cooperative','sigterm','sigkill');
CREATE TYPE preflight_status_enum  AS ENUM ('clean','dirty','unsupported','error');

-- ── identity ───────────────────────────────────────────────
-- Rows are auto-created on first authenticated request.
-- Creating a user grants NOTHING; roles come only from user_workcells.
CREATE TABLE users (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email      TEXT NOT NULL UNIQUE,
    first_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at  TIMESTAMPTZ
);
CREATE UNIQUE INDEX users_email_lower_idx ON users (lower(email));

-- ── workcell = instrument = machine (1:1, so one table) ────
CREATE TABLE workcells (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    slug              TEXT NOT NULL UNIQUE,   -- path-safe, used as GCS prefix
    header            TEXT NOT NULL,          -- shown in the app title bar
    description       TEXT,
    backend_kind      TEXT,                   -- 'star' | 'chatterbox' | ...
    deck_state        deck_state_enum NOT NULL DEFAULT 'ready',
    deck_state_reason TEXT,
    last_hostname     TEXT,                   -- telemetry; see §5.2 heartbeat
    last_app_version  TEXT,
    last_seen_at      TIMESTAMPTZ,
    is_active         BOOLEAN NOT NULL DEFAULT true,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE user_workcells (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    workcell_id UUID NOT NULL REFERENCES workcells(id) ON DELETE CASCADE,
    role        role_enum NOT NULL,
    granted_by  TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, workcell_id)
);

-- ── protocols ──────────────────────────────────────────────
CREATE TABLE protocols (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workcell_id UUID NOT NULL REFERENCES workcells(id) ON DELETE CASCADE,
    name        TEXT NOT NULL,
    description TEXT,
    is_active   BOOLEAN NOT NULL DEFAULT true,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (workcell_id, name)
);

CREATE TABLE protocol_versions (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    protocol_id        UUID NOT NULL REFERENCES protocols(id) ON DELETE CASCADE,
    version            INTEGER NOT NULL,
    script_gcs_object  TEXT   NOT NULL,   -- protocols/<slug>/<name>/v<n>/protocol.py
    script_generation  BIGINT NOT NULL,   -- GCS generation. PIN READS TO THIS.
    script_crc32c      TEXT   NOT NULL,
    schema_gcs_object  TEXT   NOT NULL,
    schema_generation  BIGINT NOT NULL,
    schema_crc32c      TEXT   NOT NULL,
    input_schema       JSONB  NOT NULL,   -- cached; GCS remains source of truth
    entrypoint         TEXT   NOT NULL DEFAULT 'run',
    registered_by      TEXT,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (protocol_id, version)
);

-- ── runs ───────────────────────────────────────────────────
CREATE TABLE runs (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workcell_id           UUID NOT NULL REFERENCES workcells(id),
    protocol_version_id   UUID NOT NULL REFERENCES protocol_versions(id),
    operator_user_id      UUID NOT NULL REFERENCES users(id),

    -- provenance snapshot: denormalised on purpose
    protocol_name         TEXT   NOT NULL,
    protocol_version      INTEGER NOT NULL,
    script_generation     BIGINT NOT NULL,
    script_crc32c         TEXT   NOT NULL,

    resolved_inputs       JSONB  NOT NULL,   -- defaults materialised
    input_schema_snapshot JSONB  NOT NULL,

    status                run_status_enum NOT NULL DEFAULT 'pending',
    termination_reason    termination_reason_enum,
    abort_escalation      abort_escalation_enum NOT NULL DEFAULT 'none',
    aborted_by_user_id    UUID REFERENCES users(id),
    preflight_status      preflight_status_enum,
    preflight_detail      JSONB,
    error_message         TEXT,
    error_traceback       TEXT,
    last_step_index       INTEGER,
    last_step_name        TEXT,
    exit_code             INTEGER,

    hostname              TEXT,
    app_version           TEXT,
    log_uri               TEXT,             -- gs://<bucket>/run-logs/<run_id>/
    log_uploaded_at       TIMESTAMPTZ,      -- NULL = still local-only
    log_upload_attempts   INTEGER NOT NULL DEFAULT 0,

    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    started_at            TIMESTAMPTZ,
    ended_at              TIMESTAMPTZ,
    last_heartbeat_at     TIMESTAMPTZ
);

-- structural guarantee of one active run per workcell (= per instrument)
CREATE UNIQUE INDEX runs_one_active_per_workcell
    ON runs (workcell_id)
    WHERE status IN ('pending','running');

CREATE INDEX runs_workcell_created_idx ON runs (workcell_id, created_at DESC);
CREATE INDEX runs_heartbeat_idx ON runs (last_heartbeat_at)
    WHERE status IN ('pending','running');

CREATE TABLE run_events (
    id          BIGSERIAL PRIMARY KEY,
    run_id      UUID NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
    seq         INTEGER NOT NULL,          -- runner-assigned, monotonic per run
    event_type  TEXT NOT NULL,             -- RunEventType
    payload     JSONB NOT NULL DEFAULT '{}'::jsonb,
    emitted_at  TIMESTAMPTZ NOT NULL,      -- runner clock
    recorded_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (run_id, seq)                   -- makes event POST idempotent
);
CREATE INDEX run_events_run_seq_idx ON run_events (run_id, seq);

CREATE TABLE deck_acknowledgements (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workcell_id       UUID NOT NULL REFERENCES workcells(id),
    acknowledged_by   UUID NOT NULL REFERENCES users(id),
    preceding_run_id  UUID REFERENCES runs(id),
    note              TEXT,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

> `runs.protocol_name`, `protocol_version`, `script_generation`, `script_crc32c` and `input_schema_snapshot` are denormalised deliberately. A run record must stay fully interpretable even if the protocol is later deleted or re-registered. Do not normalise this away.

> `run_events.UNIQUE (run_id, seq)` is what makes event submission safely retryable — the offline spool depends on it. Insert with `ON CONFLICT DO NOTHING`.

---

## 5. Control plane

### 5.0 Connectivity — AlloyDB is VPC-private

**Cloud Run cannot reach AlloyDB out of the box.** AlloyDB has no public IP here, and the failure looks like a generic connection timeout.

1. The AlloyDB cluster already exists and is shared. **Create a new database on it; do not modify instance-level configuration.**
2. Deploy with **Direct VPC egress** into the instance's VPC:
   ```bash
   gcloud run deploy experiment-executor \
     --no-allow-unauthenticated \
     --ingress internal-and-cloud-load-balancing \
     --no-default-url \
     --network=<vpc> --subnet=<subnet> \
     --vpc-egress=private-ranges-only \
     --service-account=control-plane@<project>.iam.gserviceaccount.com
   ```
   Prefer Direct VPC egress over a Serverless VPC Access connector — fewer moving parts.
3. **Authenticate with IAM, not a password:**
   ```python
   from google.cloud.alloydbconnector import AsyncConnector, IPTypes
   # ip_type=IPTypes.PRIVATE, enable_iam_auth=True
   ```
   Grant `roles/alloydb.client` and `roles/serviceusage.serviceUsageConsumer` to the control-plane service account, and add it as an IAM database user:
   ```bash
   gcloud alloydb users create control-plane@<project>.iam \
     --cluster=<cluster> --region=<region> --type=IAM_BASED
   ```
   Note the service-account username drops the `.gserviceaccount.com` suffix.
4. `--vpc-egress=private-ranges-only` keeps GCS and Google's token endpoints on the public path.

Local dev and CI use plain `postgres:16` over TCP. Keep engine construction in **one factory function** in `db.py` branching on `settings.ENV`.

> AlloyDB does not scale to zero, but the instance is already running for other applications, so this adds no idle cost beyond storage.

### 5.1 Auth — `auth.py`

Three deployment shapes; application code is identical, only `AUTH_MODE` differs.

| `AUTH_MODE` | Shape | Identity source |
|---|---|---|
| `iap` | **Default.** External HTTPS LB + IAP → Cloud Run | `x-goog-iap-jwt-assertion` |
| `local` | Local dev / CI | `DEV_FAKE_USER_EMAIL` env var |

#### Provisioning prerequisites

**The OAuth client ID must be in IAP's `programmatic_clients` allowlist.** Google's docs carry this instruction in the desktop *user-account* section, not only the service-account sections. Without it every lab machine is rejected at the edge with no application log.

```yaml
# gcloud iap settings set settings.yaml --project=<project> ...
access_settings:
  oauth_settings:
    programmatic_clients: ["<desktop-client-id>.apps.googleusercontent.com"]
```

IAP substitutes its own identity before Cloud Run's IAM check, so:

```bash
# IAP's service agent invokes Cloud Run — NOT the human users
gcloud beta services identity create --service=iap.googleapis.com --project=$PROJECT
gcloud run services add-iam-policy-binding experiment-executor \
  --member="serviceAccount:service-$PROJECT_NUMBER@gcp-sa-iap.iam.gserviceaccount.com" \
  --role="roles/run.invoker"

# humans (or a Workspace group) get IAP access
gcloud iap web add-iam-policy-binding \
  --member="group:lab-operators@example.com" \
  --role="roles/iap.httpsResourceAccessor"
```

**`--ingress internal-and-cloud-load-balancing` and `--no-default-url` are both mandatory.** LB-based IAP secures the load-balancer path only; the default `run.app` URL otherwise bypasses IAP entirely. **Add a deployment smoke test that curls the `run.app` URL and asserts it is unreachable.**

#### Verifying the assertion

```python
@dataclass(frozen=True)
class CallerContext:
    user_id: UUID
    email: str
    workcell_id: UUID
    role: Role

class IapAssertionVerifier:
    async def verified_email(self, request: Request) -> str:
        assertion = request.headers.get("x-goog-iap-jwt-assertion")
        if not assertion:
            raise HTTPException(401, "missing IAP assertion")
        last_err = None
        for aud in settings.IAP_EXPECTED_AUDIENCES:      # list, see below
            try:
                claims = id_token.verify_token(
                    assertion, ga_requests.Request(), audience=aud,
                    certs_url="https://www.gstatic.com/iap/verify/public_key",
                )
                if claims.get("iss") != "https://cloud.google.com/iap":
                    raise ValueError("unexpected issuer")
                email = claims.get("email")
                if not email:
                    raise ValueError("assertion has no email claim")
                return email
            except Exception as e:
                last_err = e
        _log_unverified_audience(assertion)
        raise HTTPException(401, f"IAP assertion rejected: {last_err}")
```

Three deliberate details:

1. **Do not use `x-goog-authenticated-user-email`.** It is unsigned and namespace-prefixed (`accounts.google.com:...`). The JWT `email` claim is signed and, for a Workspace user, a plain address.
2. **`IAP_EXPECTED_AUDIENCES` is a list.** Google documents the Cloud Run assertion audience as `/projects/PROJECT_NUMBER/locations/REGION/services/SERVICE_NAME`, but does not distinguish Cloud-Run-behind-an-LB from direct mode — and a serverless NEG behind an external ALB *is* a `backendService`, which uses `/projects/PROJECT_NUMBER/global/backendServices/SERVICE_ID`. **Which arrives in the LB setup is unconfirmed.** Configure both.
3. **On total failure, log the unverified `aud` at WARNING**, decoded without verification purely to emit the string. Safe because nothing is trusted from it, and it turns an opaque 401 into a one-line config fix.

```python
def _log_unverified_audience(assertion: str) -> None:
    try:
        payload = json.loads(base64.urlsafe_b64decode(assertion.split(".")[1] + "=="))
        logger.warning("IAP assertion failed; observed aud=%r — add to "
                       "IAP_EXPECTED_AUDIENCES if legitimate.", payload.get("aud"))
    except Exception:
        logger.warning("IAP assertion failed and could not be decoded")
```

`LocalVerifier` returns `settings.DEV_FAKE_USER_EMAIL`. **Fail hard at import time if `AUTH_MODE == "local"` and `ENV != "local"`.**

#### The shared dependency

Every workcell-scoped endpoint depends on `get_caller`. The client declares its workcell via the **`X-Workcell-Id` header**; the server authorises it.

```python
async def get_caller(
    request: Request,
    x_workcell_id: UUID = Header(...),
    db: AsyncSession = Depends(get_db),
) -> CallerContext:
    email = await VERIFIER.verified_email(request)

    # Auto-create the user. THIS GRANTS NOTHING.
    user = await upsert_user(db, email)     # sets last_seen_at

    row = await db.execute(
        select(UserWorkcell.role, Workcell.id)
        .join(Workcell, Workcell.id == UserWorkcell.workcell_id)
        .where(UserWorkcell.user_id == user.id,
               UserWorkcell.workcell_id == x_workcell_id,
               Workcell.is_active.is_(True))
    )
    result = row.first()
    if result is None:
        raise HTTPException(403, "no role on this workcell")
    role, workcell_id = result
    return CallerContext(user.id, email, workcell_id, Role(role))

def require_execute(caller: CallerContext = Depends(get_caller)) -> CallerContext:
    if not caller.role.can_execute:
        raise HTTPException(403, "role does not permit execution")
    return caller
```

**Every query filters on `caller.workcell_id`.** A protocol or run belonging to another workcell must return **404, not 403** — a 403 confirms it exists.

> `upsert_user` creates the row and **never** creates a `user_workcells` row. A new user authenticates successfully and then gets 403 on everything until an admin grants a role. That separation is the security model: IAP controls who reaches the service; `user_workcells` controls what they can do.

#### Bootstrap procedure — run before building anything else

The linchpin assumption is that the IAP assertion's `email` claim is the signing-in human's address.

1. Deploy a stub with `AUTH_MODE=iap` and one route, `GET /v1/_debug/claims`, returning the full decoded claim set (no `X-Workcell-Id` dependency). **Delete before M6.**
2. Sign in from a lab machine with a real Workspace account.
3. Confirm `email` is the plain address, and record the observed `aud`.
4. Pin `IAP_EXPECTED_AUDIENCES` to what you saw.

Do not proceed past M2 until this returns the expected email.

### 5.2 Endpoints

All under `/v1`. All except `/session/whoami` require `X-Workcell-Id` and `get_caller`.

#### `GET /session/whoami`
No workcell header. Returns the caller's identity and every workcell they hold a role on — lets the app detect a misconfigured `workcell_id` and say something useful.
```jsonc
{ "user_id": "...", "email": "operator@lab.org",
  "workcells": [ { "id": "...", "slug": "wc-alpha", "header": "Alpha STAR", "role": "operator" } ] }
```

#### `POST /session/heartbeat`
```jsonc
// req
{ "hostname": "lab-pc-04", "app_version": "0.1.0", "backend_kind": "star" }
// res
{ "workcell": { "id": "...", "slug": "wc-alpha", "header": "Alpha STAR" },
  "role": "operator",
  "deck_state": "ready", "deck_state_reason": null,
  "orphaned_run_id": null }
```
Updates `workcells.last_hostname`, `last_app_version`, `last_seen_at`. Called at launch and every 60 s.

> **`last_hostname` is telemetry, not enforcement.** A workcell suddenly reporting from a different machine is exactly what an administrator wants to see when someone has copied a config file — log a `WARNING` on change, never reject. Rejecting would break legitimate re-provisioning.

#### `GET /protocols`
Active protocols for `caller.workcell_id` with latest-version summary.

#### `GET /protocols/{protocol_id}/versions/latest`
404 if not in the caller's workcell.
```jsonc
{ "protocol_version_id": "...", "name": "serial_dilution", "version": 3,
  "entrypoint": "run", "input_schema": { /* JSON Schema + x-ui */ },
  "script_crc32c": "..." }
```

#### `POST /runs`  — depends on `require_execute`
```jsonc
// req  — NOTE: no operator field. The caller is the operator.
{ "protocol_version_id": "...", "inputs": { /* raw */ },
  "operator_confirmed_deck_clear": false }
```
Server-side, one transaction, this order:

1. Load `protocol_version`; 404 if not in the caller's workcell.
2. Reload workcell; **409 `deck_not_ready`** if `deck_state != 'ready'`.
3. Validate `inputs` against `input_schema` → **422** with per-field errors.
4. **Resolve defaults** into `resolved_inputs` (§9.3).
5. Insert the `runs` row, `status='pending'`, `operator_user_id = caller.user_id`, with the full provenance snapshot. Unique violation on `runs_one_active_per_workcell` → **409 `run_already_active`**.
6. Insert a `created` run_event with `seq = 0`.
7. Mint a **V4 signed URL**, 5-minute expiry, pinned to `script_generation`.

```jsonc
// res 201
{ "run_id": "...", "script_download_url": "https://storage.googleapis.com/...&generation=17...",
  "script_crc32c": "...", "entrypoint": "run", "resolved_inputs": { ... } }
```

#### `POST /runs/{run_id}/heartbeat`
```jsonc
// req {}   res { "ok": true }
```
Bumps `last_heartbeat_at` only. **The app calls this every 30 s for the whole run**, independent of event traffic.

> Without this there is a real bug: `last_heartbeat_at` would otherwise only be bumped by events, so a single long step emitting nothing for over 5 minutes — normal for a plate-level operation — would be swept to `unknown` while the robot is still running.

#### `POST /runs/{run_id}/events`
Batch, idempotent via `(run_id, seq)`.
```jsonc
// req
{ "events": [ { "seq": 12, "event_type": "step_started",
                "payload": {"index":3,"name":"aspirate"},
                "emitted_at": "2026-08-19T10:00:00Z" } ] }
// res { "accepted": 1, "duplicates": 0 }
```
Side effects: bump `last_heartbeat_at`; on first `runner_started` set `status='running'` and `started_at`; maintain `last_step_index`/`last_step_name`; record `preflight_status`/`preflight_detail` from `preflight_result`.

#### `POST /runs/{run_id}/complete`
```jsonc
{ "status": "aborted", "termination_reason": "operator_abort",
  "abort_escalation": "cooperative", "exit_code": 0,
  "error_message": null, "error_traceback": null,
  "last_step_index": 7, "last_step_name": "dispense", "log_uri": "gs://..." }
```
`aborted_by_user_id` is set from the **caller**, not the body. Sets terminal status and `ended_at`. **If `status` is anything other than `completed`, also set `workcells.deck_state = 'needs_attention'`** with a reason — server-side, never trusting the client to do it. Idempotent.

#### `POST /session/ack-deck-reset` — depends on `require_execute`
```jsonc
{ "preceding_run_id": "...", "note": "tips removed, deck cleared" }
```
Inserts `deck_acknowledgements` with `acknowledged_by = caller.user_id`; sets `deck_state='ready'`.

#### `POST /runs/{run_id}/log-upload-url`
Mints signed **upload** URLs for the run's log bundle. 404 if the run is not in the caller's workcell.
```jsonc
// req
{ "files": ["events.jsonl", "stderr.log", "run.json"] }
// res
{ "upload_urls": { "events.jsonl": "https://storage.googleapis.com/...",
                   "stderr.log":   "https://...",
                   "run.json":     "https://..." },
  "expires_in": 900,
  "log_uri": "gs://<bucket>/run-logs/<run_id>/" }
```
V4 signed URLs, `PUT` method, 15-minute expiry, each scoped to exactly one object under `run-logs/<run_id>/`. **Do not mint a prefix-wide or wildcard URL.** Increments `log_upload_attempts`.

#### `POST /runs/{run_id}/log-uploaded`
Called after all objects are uploaded. Sets `log_uri` and `log_uploaded_at`. Idempotent.

#### `GET /runs/{run_id}/logs`
Returns signed **download** URLs for a previously synced run, so history stays inspectable.
```jsonc
// res 200
{ "log_uri": "gs://...", "uploaded_at": "...",
  "download_urls": { "events.jsonl": "https://...", "stderr.log": "https://..." } }
// res 404 — never uploaded; the client falls back to local disk
{ "detail": "logs not synced for this run" }
```

#### `GET /runs?limit=50`
Recent runs for the caller's workcell. Includes `log_uploaded_at` so the history view knows whether to offer a remote or local log.

### 5.3 Sweeper — `sweeper.py`

60 s `asyncio` task at startup (Cloud Scheduler → authenticated endpoint is the production shape).

```sql
UPDATE runs SET status = 'unknown',
                termination_reason = 'heartbeat_lost',
                ended_at = now()
WHERE status IN ('pending','running')
  AND COALESCE(last_heartbeat_at, created_at) < now() - interval '5 minutes'
RETURNING workcell_id;
```
Then set `deck_state='needs_attention'` on every returned workcell.

---

## 6. Protocol contract

### 6.1 Layout in GCS

Bucket has **object versioning enabled**.

```
gs://<bucket>/protocols/<workcell-slug>/<protocol-name>/v<n>/protocol.py
gs://<bucket>/protocols/<workcell-slug>/<protocol-name>/v<n>/inputs.schema.json
gs://<bucket>/run-logs/<run_id>/events.jsonl
gs://<bucket>/run-logs/<run_id>/stderr.log
gs://<bucket>/run-logs/<run_id>/run.json
```

**Lab machines have no direct GCS access and no GCS credential.** Every transfer — protocol download and log upload alike — uses a short-lived signed URL minted by the control plane *after* the workcell and role checks pass, scoped to a single object.

> Do not grant operators `roles/storage.objectViewer` or any other bucket role. See §0 rule 6 and proposal §4.3 — a standing grant would bypass the workcell scoping that only the control plane enforces.

### 6.2 The script

```python
# examples/protocols/serial_dilution/protocol.py
from pylabrobot.liquid_handling import LiquidHandler
from pylabrobot.resources import Deck

async def run(ctx, inputs: dict) -> None:
    deck = Deck.load_from_json_file(ctx.deck_file)
    lh = LiquidHandler(backend=ctx.backend, deck=deck)
    ctx.register_liquid_handler(lh)      # REQUIRED for teardown on abort

    await lh.setup()
    ctx.event("setup_complete")

    tips  = lh.deck.get_resource("tip_rack")
    plate = lh.deck.get_resource("plate")

    for i in range(inputs["dilution"]["steps"]):
        async with ctx.step(i, f"dilution_{i}"):     # abort gate — §7.3
            await lh.pick_up_tips(tips[f"A{i+1}"])
            await lh.aspirate(plate[f"A{i+1}"], vols=inputs["dilution"]["volume_ul"])
            await lh.dispense(plate[f"A{i+2}"], vols=inputs["dilution"]["volume_ul"])
            await lh.return_tips()
```

Rules for protocol authors:

- The entrypoint **must** be `async def`.
- **Must** call `ctx.register_liquid_handler(lh)` immediately after constructing it, or the harness cannot attempt teardown on abort.
- All work **must** be wrapped in `async with ctx.step(...)`. That is the only place cancellation can land.
- **Must not** call `sys.exit`, install signal handlers, or spawn processes.
- **Must not** perform preflight or safety checks. Those belong to the harness (§7.0).

---

## 7. Runner — `ee-runner`

### 7.0 Backend adapters — where instrument-specific safety lives

**Decision: safety checks belong to the runner harness, never to the protocol and never to registration.**

1. **Ordering makes it impossible for the protocol.** Preflight must run *before* `setup()`, because `setup()` is the dangerous operation. Protocol code runs after the handler exists — it is the thing being gated, so it cannot be the gate.
2. **Safety invariants must not be delegable.** One author who forgets reintroduces the hazard for one protocol — the worst failure distribution, because everything else still looks correct.
3. **Registration cannot know runtime state.** Whether tips are mounted *right now* is a physical fact at run time.
4. **Protocols must stay portable.** Backend-agnosticism is PyLabRobot's central value.

**Genericity is preserved by an adapter, not by pushing work into protocols.**

```python
# ee_common/backends.py
@dataclass(frozen=True)
class PreflightResult:
    status: PreflightStatus
    detail: dict          # backend-specific, opaque to the app
    message: str          # operator-facing, one line

class BackendAdapter(Protocol):
    kind: str
    supports_preflight: bool
    supports_firmware_abort: bool
    async def connect(self, config: dict) -> Any: ...
    async def preflight(self, backend: Any) -> PreflightResult: ...
    async def teardown(self, lh: Any) -> tuple[bool, str | None]: ...
```

```python
# ee_runner/backends/__init__.py
ADAPTERS: dict[str, type[BackendAdapter]] = {
    "chatterbox": ChatterboxAdapter,
    "star":       StarAdapter,
}
```

Adding a backend is one new file plus one registry line. **No change to the runner core, app, API or schema.**

#### 7.0.1 `StarAdapter.preflight`

```python
class StarAdapter:
    kind = "star"
    supports_preflight = True
    supports_firmware_abort = False

    async def preflight(self, backend) -> PreflightResult:
        try:
            presences = await backend.request_tip_presence()
        except Exception as e:
            # A failed check is NOT a pass.
            return PreflightResult(PreflightStatus.ERROR, {"error": repr(e)},
                                   "Could not verify instrument state.")
        dirty = [i for i, p in enumerate(presences) if p]
        if dirty:
            return PreflightResult(PreflightStatus.DIRTY,
                                   {"channels_with_tips": dirty},
                                   f"Tips or tools detected on channels {dirty}.")
        return PreflightResult(PreflightStatus.CLEAN,
                               {"channels_with_tips": []}, "Channels clear.")
```

> **Verify on real hardware before trusting this.** `request_tip_presence()` must be reachable after IO connect but *before* the full `setup()` sequence. PyLabRobot's own `setup()` awaits it after the Z-safety move and before `initialize_pip()`, which is the ordering needed — but calling it standalone may require `_setup_done`, and `setup(skip_pip=True)` carries a source TODO saying it does not fully gate instrument-init moves.
>
> **If it cannot be called pre-`setup()`, do not fake it.** Return `UNSUPPORTED` and fall back to operator confirmation (§7.0.3). An automated check that silently runs too late is worse than none, because the UI would claim verification that never happened.

#### 7.0.2 Firmware abort — resolved: none exists

Recorded so nobody re-litigates it:

- `STARBackend.stop()` is host-side teardown only — stops the USB reader thread, fails pending futures. **It transmits nothing to the instrument.**
- No abort / halt / cancel / e-stop method on `STARBackend` or `HamiltonLiquidHandler`.
- No VENUS-style interactive recovery; faults surface as raised exceptions.
- The cover interlock is **not pollable** — it appears as `CoverCloseError` on the next command.
- Raw firmware access exists (`send_command(module, command, …, wait=False)`), so an abort could be sent if Hamilton documents one. **Do not speculatively send raw firmware commands to a live instrument.** Leave `supports_firmware_abort = False`.

The §7.4 ladder is therefore the complete stop mechanism, and **physically halting a moving STAR means the hardware e-stop or cover.** State this in operator training; never imply in the UI that software can stop the machine.

#### 7.0.3 How the app consumes the result

| Status | App behaviour |
|---|---|
| `clean` | Proceed to `setup()` and the protocol. |
| `dirty` | **Abort before setup.** Terminate as `failed` / `preflight_blocked`, quarantine, show the detail. |
| `error` | Same as `dirty`. A check that failed is not a check that passed. |
| `unsupported` | Blocking operator confirmation — "This instrument cannot report its state automatically. Confirm the deck is clear." Recorded on the run. |

`chatterbox` returns `CLEAN` unconditionally. A backend with no adapter entry is a **hard startup error**, never a silent `unsupported`.

### 7.1 Invocation

```bash
python -m ee_runner \
  --run-id <uuid> \
  --script /var/lib/experiment-executor/runs/<run_id>/protocol.py \
  --inputs /var/lib/experiment-executor/runs/<run_id>/inputs.json \
  --entrypoint run \
  --deck-file /etc/experiment-executor/deck.json \
  --backend star \                # key into ADAPTERS
  [--operator-confirmed-clear]    # only when preflight returned 'unsupported'
```

Launched with `start_new_session=True` so it gets its own process group — required for group signalling in §7.4.

> **Confirm the chatterbox class name against the installed PyLabRobot 0.2.2** — it has been both `ChatterboxBackend` and `LiquidHandlerChatterboxBackend` across releases. Resolve it in exactly one place.

### 7.2 IPC — newline-delimited JSON

**stdout = runner → app.** One compact JSON object per line, flushed immediately. stderr is captured separately as unstructured text and is not parsed.

```jsonc
{"seq":1,  "t":"runner_started",     "ts":"...", "payload":{"pid":4211,"backend":"star"}}
{"seq":2,  "t":"preflight_started",  "ts":"...", "payload":{}}
{"seq":3,  "t":"preflight_result",   "ts":"...", "payload":{
    "status":"clean","detail":{"channels_with_tips":[]},"message":"Channels clear."}}
{"seq":4,  "t":"setup_complete",     "ts":"...", "payload":{}}
{"seq":5,  "t":"step_started",       "ts":"...", "payload":{"index":0,"name":"dilution_0"}}
{"seq":6,  "t":"log",                "ts":"...", "payload":{"level":"info","message":"..."}}
{"seq":7,  "t":"step_completed",     "ts":"...", "payload":{"index":0,"name":"dilution_0","duration_ms":8123}}
{"seq":90, "t":"abort_requested",    "ts":"...", "payload":{}}
{"seq":91, "t":"teardown_attempted", "ts":"...", "payload":{"ok":true,"error":null}}
{"seq":92, "t":"terminated",         "ts":"...", "payload":{
    "outcome":"aborted", "termination_reason":"operator_abort",
    "last_step_index":7,"last_step_name":"dilution_7",
    "error_message":null,"error_traceback":null}}
```

`seq` starts at 1 (0 is reserved for the control plane's `created` event). `t` values map 1:1 onto `RunEventType`.

**stdin = app → runner.** One message: `{"t":"abort"}`.

Model both directions with Pydantic in `ee_common/ipc.py`. The runner reads stdin on a dedicated `asyncio` task so it stays responsive while a command is in flight.

### 7.3 Harness — `harness.py`

```python
class ProtocolAborted(Exception): ...

class RunContext:
    def __init__(self, backend, deck_file, emitter):
        self._abort = asyncio.Event()
        self._lh = None
        self.backend = backend
        self.deck_file = deck_file
        self._emit = emitter
        self.last_step_index: int | None = None
        self.last_step_name: str | None = None

    def register_liquid_handler(self, lh): self._lh = lh
    def request_abort(self): self._abort.set()
    def event(self, name, **payload): self._emit(name, payload)

    @asynccontextmanager
    async def step(self, index: int, name: str):
        # THE ABORT GATE. Checked before the command, never during it.
        if self._abort.is_set():
            raise ProtocolAborted(f"aborted before step {index} ({name})")
        self.last_step_index, self.last_step_name = index, name
        self._emit("step_started", {"index": index, "name": name})
        t0 = time.monotonic()
        try:
            yield
        finally:
            self._emit("step_completed", {
                "index": index, "name": name,
                "duration_ms": int((time.monotonic() - t0) * 1000)})

    async def attempt_teardown(self) -> tuple[bool, str | None]:
        """Best effort. Must never raise."""
        if self._lh is None:
            return False, "no liquid handler registered"
        try:
            await asyncio.wait_for(self._lh.stop(), timeout=20)
            return True, None
        except Exception as e:
            return False, repr(e)
```

> **Be honest about what this does not do.** PyLabRobot exposes no cancel primitive; an in-flight firmware command runs to completion regardless. The gate stops the *next* command. Never describe this as an emergency stop in the UI or docs.

Runner `main` — **preflight gates everything**:

```python
adapter = ADAPTERS[args.backend]()          # KeyError = hard startup failure
backend = await adapter.connect(config)

emit("preflight_started", {})
pf = (await adapter.preflight(backend)) if adapter.supports_preflight else \
     PreflightResult(PreflightStatus.UNSUPPORTED, {},
                     "Backend cannot report instrument state.")
emit("preflight_result", {"status": pf.status, "detail": pf.detail,
                          "message": pf.message})

if pf.status in (PreflightStatus.DIRTY, PreflightStatus.ERROR):
    # Exit BEFORE lh.setup(). Nothing has moved. This is the whole point.
    emit("terminated", {"outcome": "failed",
                        "termination_reason": "preflight_blocked",
                        "error_message": pf.message})
    sys.exit(0)

if pf.status is PreflightStatus.UNSUPPORTED and not args.operator_confirmed_clear:
    emit("terminated", {"outcome": "failed",
                        "termination_reason": "preflight_blocked",
                        "error_message": "Operator confirmation required."})
    sys.exit(0)

try:
    await entrypoint(ctx, inputs)
    outcome, reason = "completed", "normal"
except ProtocolAborted:
    outcome, reason = "aborted", "operator_abort"
    ok, err = await ctx.attempt_teardown()
    emit("teardown_attempted", {"ok": ok, "error": err})
except Exception as e:
    outcome, reason = "failed", "protocol_exception"
    ok, err = await ctx.attempt_teardown()
    emit("teardown_attempted", {"ok": ok, "error": err})
    error_message, error_traceback = str(e), traceback.format_exc()
finally:
    emit("terminated", {...})
    sys.stdout.flush()
sys.exit(0)   # exits 0 even for a failed protocol; outcome is in the payload
```

### 7.4 Abort ladder — `run_controller.py` (app side)

Exact timings. Contract values.

| Level | Action | Wait | On timeout |
|---|---|---|---|
| 1 `cooperative` | Write `{"t":"abort"}` to stdin, flush | **30 s** for `terminated` + exit | → 2 |
| 2 `sigterm` | `os.killpg(pgid, SIGTERM)` | **10 s** | → 3 |
| 3 `sigkill` | `os.killpg(pgid, SIGKILL)` | 5 s | log; report anyway |

Record the highest level reached in `runs.abort_escalation`; emit `abort_escalated` at each transition. After the process is gone, **always** `POST /runs/{id}/complete`, even at level 3 — a run that ended badly must still be recorded.

### 7.5 Deck quarantine — non-negotiable

When a run ends as anything other than `completed`:

1. Control plane sets `workcells.deck_state = 'needs_attention'` in `/complete` — server-side, never relying on the client.
2. On the next launch or heartbeat the app receives `deck_state: "needs_attention"` and shows `NeedsAttentionView` **as a blocking modal**.
3. **Start run** is disabled everywhere in this state.
4. Clearing requires an operator/admin caller plus explicit confirmation that the deck was physically inspected, then `POST /session/ack-deck-reset`.

Dialog copy must state the actual hazard:

> **Deck requires inspection.** The previous run did not complete normally, so the software does not know the physical state of the instrument. Tips or grippers may still be mounted. Starting a new run now can cause the initialisation routine to collide with mounted hardware. Physically inspect and clear the deck before continuing.

---

## 8. Desktop app — `ee-app`

### 8.1 Config — `/etc/experiment-executor/config.toml`

Written by an administrator at provisioning. Root-owned, `0444`. **The operator never edits this.**

```toml
[api]
base_url = "https://executor.lab.example.com"   # the IAP-fronted LB hostname

[workcell]
# Which instrument this computer is physically wired to.
# Sent as X-Workcell-Id; the server authorises the operator against it.
id = "3f2a...-...."

[oauth]
# Desktop-app OAuth client. The "secret" is not confidential for installed
# apps, per RFC 8252 — do not treat it as one, but do not publish it either.
client_id     = "1234567890-abcdefg.apps.googleusercontent.com"
client_secret = "GOCSPX-..."
loopback_port = 0        # 0 = ephemeral; must be registered as http://localhost

[runtime]
work_dir            = "/var/lib/experiment-executor"
deck_file           = "/etc/experiment-executor/deck.json"
backend             = "star"
log_retention_days  = 30           # synced runs only; unsynced are never deleted
log_max_bytes       = 5_000_000_000
```

Override for dev only via `EE_CONFIG_PATH`.

> **`workcell.id` is the one client-asserted value in the system.** The server still authorises the operator against it, so it cannot grant access the operator lacks — but a wrong value means protocols for the wrong instrument. See proposal §4.4. Mitigation is procedural (admin-written, root-owned) plus the persistent workcell display in §8.3.

### 8.2 Sign-in — `auth.py`

OAuth 2.0 **loopback** flow for desktop apps. OOB (`urn:ietf:wg:oauth:2.0:oob`) is no longer supported; the separate loopback deprecation applies only to iOS/Android/Chrome client types, not desktop.

```python
from google_auth_oauthlib.flow import InstalledAppFlow
from google.auth.transport.requests import Request

SCOPES = ["openid", "email"]

def sign_in(cfg) -> Credentials:
    flow = InstalledAppFlow.from_client_config(
        {"installed": {
            "client_id": cfg.oauth.client_id,
            "client_secret": cfg.oauth.client_secret,
            "auth_uri": "https://accounts.google.com/o/oauth2/v2/auth",
            "token_uri": "https://oauth2.googleapis.com/token",
        }},
        scopes=SCOPES,
    )
    # access_type=offline is REQUIRED to receive a refresh token.
    creds = flow.run_local_server(
        port=cfg.oauth.loopback_port, open_browser=True,
        access_type="offline", prompt="consent",
    )
    return creds        # creds.id_token is the IAP bearer token
```

Rules:

- **Send `creds.id_token`, not the access token**, as `Authorization: Bearer <id_token>`. IAP wants an ID token.
- ID tokens last about an hour. Refresh with `creds.refresh(Request())`, which **updates `creds.id_token`** — no user prompt. Refresh at 5 minutes before expiry.
- **Do not persist the refresh token.** Hold it in memory only. On a shared lab machine, closing the app must end the session so the next operator signs in as themselves. Provide an explicit **Sign out** control for shift handover.
- **A 401 mid-session triggers one silent refresh, then a re-prompt.** Never loop.

> **Open item — spike before committing to `InstalledAppFlow`.** Google's IAP desktop example includes an undocumented `cred_ref=true` authorization-URL parameter whose effect is unknown, and it is unclear whether `google-auth-oauthlib` forwards extra kwargs cleanly. If the spike fails, hand-roll the flow: it is a local HTTP listener, a browser open, and one `POST https://oauth2.googleapis.com/token`.

**Token expiry must never interrupt a run in progress** (§8.5). If a refresh fails mid-run, keep running and keep spooling; re-authenticate when connectivity returns.

### 8.3 Screens

| View | Purpose |
|---|---|
| `StartupView` | Load config, sign in, `POST /session/heartbeat`, reconcile orphaned run. If the caller has no role on the configured workcell, call `/session/whoami` and show a **useful** error naming the configured workcell and what the user *does* have access to. |
| `NeedsAttentionView` | Blocking modal (§7.5). |
| `ProtocolListView` | Protocols for this workcell. |
| `InputFormView` | Generated form (§9) + a **Review** panel showing resolved values before start. |
| `RunMonitorView` | Live status, current step, scrolling log, elapsed time, **Abort** button. |
| `RunHistoryView` | Recent runs, read-only, **with a log viewer** — remote if synced, local otherwise (§8.4b). Shows a per-run sync indicator. |

**The workcell header and the signed-in operator's email are both persistently visible in the title bar.** The likeliest error in this system is a correct protocol at the wrong instrument; the second likeliest is the previous operator's session still being active. The interface should make both hard to miss.

### 8.4 Run monitor

- Reads runner stdout on a `QThread` with a queue; **never block the Qt event loop**.
- Runs a `QTimer` posting `/runs/{id}/heartbeat` every 30 s. A failed heartbeat is logged, never fatal.
- Appends each event to `{work_dir}/runs/{run_id}/events.jsonl` **before** enqueuing for upload. Local disk is the durable record.
- Abort button → confirmation dialog with this exact copy:

> **Abort this run?** The run cannot be resumed — it must be restarted from the beginning. The current instrument command will finish before the run stops. Afterwards the deck must be physically inspected before another run can start.
>
> `[Keep running]` `[Abort run]` — *Keep running* is the default button.

### 8.4b Run logs — `logs.py`

**Local-first. The machine driving a robot must never depend on the network to record what it did.**

#### Files, written during the run

Under `{work_dir}/runs/{run_id}/`:

| File | Written by | Content |
|---|---|---|
| `events.jsonl` | app | Every runner event, appended and **flushed immediately** |
| `stderr.log` | app | Raw runner stderr streamed straight to disk, unparsed |
| `run.json` | app | Metadata snapshot: run id, workcell, protocol name/version/generation/crc32c, resolved inputs, operator email, app version, start/end, outcome |

Rules:

- Open all three at run start; `flush()` after every write. **Do not buffer** — power loss mid-run must leave whatever reached disk intact.
- `events.jsonl` is written **before** the event is queued to the spool (§8.5). Disk is the durable record; the API is the copy.
- Write `run.json` twice: once at start with what is known, once at end with the outcome.
- Never write logs under `/tmp`.

#### Upload, after the run ends

Sequence, on a background worker:

1. `POST /runs/{id}/log-upload-url` with the file list.
2. `PUT` each file to its signed URL.
3. `POST /runs/{id}/log-uploaded`.
4. On success, mark locally synced. On failure, leave it and retry.

Retry policy: exponential backoff 30 s → 30 min, indefinitely, **and a sweep on every app launch** so a lab that was offline for a day catches up on reconnect. **An upload failure is never a run failure and must never surface as a blocking error** — a small "N runs pending sync" indicator is sufficient.

Track pending uploads in the same SQLite database as the event spool, table `pending_log_uploads(run_id, created_at, attempts, last_error)`.

#### Retention

- **Never delete an unsynced run's files.** Not on a timer, not under disk pressure, not ever.
- Synced runs are retained `runtime.log_retention_days` (default 30), then deleted by a launch-time sweep.
- If the work directory exceeds `runtime.log_max_bytes` (default 5 GB), delete oldest **synced** runs first and log a warning. If only unsynced runs remain, warn loudly and delete nothing.

#### Reading logs later

`RunHistoryView` opens any past run:

- `log_uploaded_at` non-null → `GET /runs/{id}/logs`, fetch and display.
- Otherwise → read from local disk.
- Neither available (synced, then locally pruned, and now offline) → say so plainly rather than showing an empty view.

### 8.5 Offline spool — `spool.py`

SQLite at `{work_dir}/spool.db`, table `pending_events(run_id, seq, event_type, payload, emitted_at)`.

- Every event written to the spool first, then flushed by a background worker in batches of ≤100.
- Retry with exponential backoff, 5 s → 5 min, indefinitely.
- **A flush failure must never abort a run, block the UI, or raise into the run path.** Log and move on.
- On success delete flushed rows. Duplicates are harmless — `(run_id, seq)` is unique.

### 8.6 Startup reconciliation

If `heartbeat` returns a non-null `orphaned_run_id`:

1. Flush any spooled events for that run first.
2. `POST /runs/{id}/complete` with `status: "unknown"`, `termination_reason: "app_restart_orphaned"`.
3. Server sets `deck_state='needs_attention'`; show `NeedsAttentionView`.

---

## 9. Form generation — `formgen.py`

### 9.1 Supported subset

**Implement exactly this. Reject anything else at registration time with a clear error.**

| JSON Schema | Widget |
|---|---|
| `boolean` | `QCheckBox` |
| `integer` (`minimum`/`maximum`/`multipleOf`) | `QSpinBox` |
| `number` (`minimum`/`maximum`) | `QDoubleSpinBox` |
| `string` | `QLineEdit` |
| `string` + `enum` | `QComboBox` |
| `string` + `x-ui.widget: "textarea"` | `QPlainTextEdit` |
| `object` | `QGroupBox` — **nesting depth 1 only** |

**Arrays are not supported.** A schema containing `"type": "array"` must be rejected by `register_protocol.py` with an explicit message. Do not silently ignore it.

### 9.2 `x-ui` extension

```jsonc
{
  "type": "object",
  "properties": {
    "dilution": {
      "type": "object", "title": "Dilution settings",
      "properties": {
        "steps":     { "type": "integer", "title": "Number of steps",
                       "minimum": 1, "maximum": 11, "default": 5 },
        "volume_ul": { "type": "number", "title": "Volume (µL)",
                       "minimum": 1, "maximum": 300, "default": 100,
                       "x-ui": { "help": "Per-transfer volume" } }
      },
      "required": ["steps", "volume_ul"]
    },
    "use_filter_tips": { "type": "boolean", "title": "Use filter tips", "default": true }
  },
  "required": ["dilution"],
  "x-ui": { "order": ["dilution", "use_filter_tips"] }
}
```

`x-ui` keys: `order`, `widget`, `help`, `hidden`.

### 9.3 Default resolution

Shared helper in `ee_common/schema_forms.py`, used by **both** app and control plane so they cannot diverge.

```python
def resolve_defaults(schema: dict, inputs: dict) -> dict:
    """Recursively fill missing properties from `default`.
    Nested objects are recursed into even when absent from `inputs`,
    so an omitted object with defaulted children still materialises."""
```

Validation order everywhere: **resolve defaults, then validate the resolved document.** Never validate raw input. Both sides validate; the server's result is authoritative.

---

## 10. Admin CLIs

### `tools/grant_role.py`
```bash
python tools/grant_role.py --email operator@lab.org \
  --workcell-slug wc-alpha --role operator
```
Creates the `users` row if absent and upserts `user_workcells`. **This is the only way a user gains any capability** — authentication alone grants nothing.

Also prints the IAP binding reminder:
```bash
gcloud iap web add-iam-policy-binding \
  --member="user:operator@lab.org" --role="roles/iap.httpsResourceAccessor"
```

> **Unconfirmed:** the exact resource level for the `iap.httpsResourceAccessor` binding (backend service vs. Cloud Run service vs. project). Verify the correct `gcloud iap web add-iam-policy-binding` resource flags and pin them here. Prefer binding a **Workspace group** over individual users.

### `tools/register_protocol.py`
```bash
python tools/register_protocol.py \
  --workcell-slug wc-alpha --name serial_dilution \
  --script examples/protocols/serial_dilution/protocol.py \
  --schema examples/protocols/serial_dilution/inputs.schema.json \
  --entrypoint run
```
In order:

1. **Validate the schema against the §9.1 subset. Reject arrays and depth > 1.**
2. Confirm the script has `async def <entrypoint>(ctx, inputs)` — parse with `ast`, do **not** import it.
3. Compute next `version` for `(workcell, name)`.
4. Upload both objects; capture `generation` and `crc32c` from the GCS response.
5. Insert `protocol_versions` with the cached `input_schema`.

---

## 11. Testing

### Required unit tests
- `resolve_defaults` — nested objects, absent parents, `false`/`0` defaults not clobbered.
- Schema-subset validator — arrays rejected, depth-2 nesting rejected.
- IPC round-trip — every message type serialises and parses.
- Enum ↔ Postgres enum parity — every Python enum member exists in the DB type.
- `IapAssertionVerifier` — rejects missing assertion, wrong `iss`, wrong `aud`, missing `email`; accepts a correctly signed fixture with a stubbed `certs_url`.
- **`AUTH_MODE=iap` never reads the `Authorization` header** — a request with a valid bearer token but no assertion must 401.
- `AUTH_MODE=local` raises at import when `ENV != "local"`.
- **`ee-app` declares no GCS or database dependency** — assert `google.cloud.storage`, `sqlalchemy`, `asyncpg` and `psycopg` are absent from its resolved dependency set. This is the mechanical guard on §0 rule 6.
- Log retention sweep **never deletes an unsynced run**, including under the size cap.

### Required backend-adapter tests
- **A fake adapter returning `DIRTY` prevents `lh.setup()` from ever being called.** Assert on the mock, not the outcome — this is the property the design rests on.
- `ERROR` treated identically to `DIRTY`.
- `UNSUPPORTED` without `--operator-confirmed-clear` blocks; with it, proceeds.
- Unknown `--backend` fails at startup rather than defaulting.
- **No concrete adapter imported outside `ee_runner/backends/`** — enforce with an import-graph test.

### Required integration tests (stock `postgres:16` via testcontainers)

> CI runs against plain Postgres, never AlloyDB. Safe only because §4 forbids AlloyDB-specific SQL — verify migrations once against the real instance in M1.

- **Authentication grants nothing:** a brand-new email authenticates, a `users` row appears, and every workcell-scoped endpoint returns 403.
- **Cross-workcell isolation:** a caller with a role on workcell A requesting workcell B's protocol UUID → 404. *The most important test in the suite.*
- A caller claiming a workcell they have no role on → 403.
- `viewer` role → 403 on `POST /runs`.
- **`operator_user_id` always equals the authenticated caller** — attempting to inject an operator field in the body has no effect.
- Concurrent run insert violates `runs_one_active_per_workcell`.
- Event POST idempotent — same batch twice → `accepted:N` then `duplicates:N`.
- `/complete` with non-`completed` status sets `deck_state='needs_attention'`.
- Sweeper transitions a stale run to `unknown` and quarantines its workcell.
- **Sweeper does not touch a run emitting no events but heartbeating** — guards the long-step false positive.

### Required runner tests (chatterbox backend, no hardware)
- Happy path emits ordered seqs, terminates `completed`.
- Abort at a step boundary → `aborted`, teardown attempted, exit 0, `abort_escalation='cooperative'`.
- Protocol raising → `failed`, traceback captured, teardown attempted.
- **Unresponsive runner** (ignores stdin and blocks) → escalates through SIGTERM to SIGKILL; run still completed via API with `abort_escalation='sigkill'`.

### Manual test before any hardware
Full flow against the chatterbox backend: sign in → protocol → form → run → abort mid-run → verify quarantine blocks the next run → acknowledge → verify a new run starts.

---

## 12. Definition of done

- [ ] `alembic upgrade head` builds all 8 tables on `postgres:16` and AlloyDB; seed data loads.
- [ ] No AlloyDB-specific SQL — the full migration set runs unmodified on stock `postgres:16`.
- [ ] Control plane deploys with `--no-allow-unauthenticated`, `--ingress internal-and-cloud-load-balancing`, `--no-default-url` and Direct VPC egress, reaching AlloyDB with IAM auth and no stored password.
- [ ] Custom OAuth client (type Desktop app) created and allowlisted in `programmatic_clients`.
- [ ] IAP assertion `email` confirmed to be the signing-in human's address on real infrastructure; `IAP_EXPECTED_AUDIENCES` pinned to the observed value.
- [ ] Smoke test asserts the `run.app` URL is unreachable.
- [ ] `roles/run.invoker` held by the **IAP service agent**; humans hold `roles/iap.httpsResourceAccessor`.
- [ ] `GET /v1/_debug/claims` deleted.
- [ ] A newly authenticated user with no granted role can do nothing.
- [ ] `operator_user_id` is never sourced from a request body anywhere in the codebase.
- [ ] A `DIRTY` preflight demonstrably prevents `setup()` being called.
- [ ] No concrete backend adapter imported outside `ee_runner/backends/`.
- [ ] `request_tip_presence()` verified callable pre-`setup()` on real STAR hardware — **or** `StarAdapter` returns `UNSUPPORTED` and the operator-confirmation path is wired.
- [ ] App runs on Linux against the chatterbox backend end to end.
- [ ] All three abort escalation levels exercised by tests.
- [ ] `kill -9` on the app mid-run → next launch reconciles and quarantines.
- [ ] Network disconnected mid-run → run completes, events flush on reconnect, **and token expiry does not interrupt the run**.
- [ ] No refresh token is written to disk.
- [ ] Every run row has non-null `script_generation` and `script_crc32c`.
- [ ] Every completed run writes `events.jsonl`, `stderr.log` and `run.json` locally, flushed during the run.
- [ ] Logs upload to `run-logs/<run_id>/` via signed URLs; `log_uri` and `log_uploaded_at` recorded.
- [ ] A run whose upload fails still completes normally, retries on the next launch, and is never deleted locally.
- [ ] A past run's logs open from history — remote when synced, local when not.
- [ ] `ee-app` has no GCS client and no database driver in its dependency tree.
