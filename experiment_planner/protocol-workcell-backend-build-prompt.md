# Build Request: Sandboxed Multi-Protocol Agent Workspace — Backend & Infra

Build a web application where users create **protocols** — each an isolated, sandboxed workspace where a coding agent (Antigravity SDK) generates and edits files from natural-language prompts. Protocols are grouped into **workcells**. A workcell is the sharing boundary: you invite collaborators to a workcell, not to an individual protocol, and everyone with access to a workcell can see all protocols inside it.

This replaces an earlier draft that used "project" as both the isolation unit and the sharing unit — those are now two different things.

## Core model

- **Workcell** — a named grouping of protocols, owned by a user, shared with collaborators. This is the ACL boundary.
- **Protocol** — the isolated execution unit. One protocol = one sandbox = one GCS prefix. Belongs to exactly one workcell.
- Access to a workcell grants access to every protocol inside it, subject to the collaborator's role.

**Forward-compatibility requirement, not built now:** protocols within the same workcell should later be able to reference each other's files (e.g., protocol B reads a file protocol A produced). Nothing needs to implement this yet, but the storage layout below is chosen specifically so that adding it later is a permissions change, not a data migration — don't flatten protocol storage in a way that would require restructuring to support this.

---

## Repository layout

```
/
├── frontend/            # React — see the separate UI prompt document
├── backend-api/         # Python — the only service the frontend talks to
├── sandbox-controller/  # Python — internal-only, manages sandbox lifecycle
├── sandbox-runtime/     # Container image that becomes the ephemeral sandbox itself
└── README.md
```

## `backend-api/` — Python (FastAPI recommended)

- **Auth**: user login/session handling (provider not yet decided — pick one, isolate it behind an interface).
- **Workcell CRUD** and **collaborator management** (invite/remove, role assignment).
- **Protocol CRUD**, scoped to a parent workcell.
- **ACL enforcement**: every request checked against the workcell's collaborator list before touching any protocol inside it — check once at the workcell level, not per protocol.
- **Proxying**: forwards a protocol's file/chat requests to its running sandbox when one exists; otherwise reads/lists directly from that protocol's GCS prefix.
- **Sandbox orchestration trigger**: calls `sandbox-controller`, never GCP infra directly.
- Holds the only GCP-facing service account. End users never get individual GCP credentials.

### Key endpoints (indicative)
- `GET/POST /workcells`, `GET /workcells/{id}`
- `POST /workcells/{id}/collaborators`
- `GET /workcells/{id}/protocols`, `POST /workcells/{id}/protocols`
- `GET /protocols/{id}/files`, `GET /protocols/{id}/files/{path}` — proxy to sandbox if running, else read from GCS
- `PUT /protocols/{id}/files/{path}` — manual save from the UI editor. Proxy to sandbox if running (see agent-awareness flow below); otherwise write directly to GCS and log the edit.
- `POST /protocols/{id}/sandbox/start` — async, returns immediately
- `WS /protocols/{id}/session` — multiplexed chat + file events

## `sandbox-controller/` — Python

Its own private Cloud Run service (`--no-allow-unauthenticated`), only invokable by `backend-api`'s service account. Kept separate so a slow provisioning call never blocks fast UI-facing requests.

- `POST /sandboxes` — create one, given `protocol_id` + its GCS prefix
- `DELETE /sandboxes/{id}` — flush to GCS, tear down
- `GET /sandboxes/{id}/status`
- `POST /reconcile` — sweeps `sandbox_sessions` for anything past the idle threshold, triggered by Cloud Scheduler on a short interval (Cloud Run scales to zero, so nothing self-monitors between requests)

**Deployment fork:** Cloud Run Sandbox pattern (Gen2 + gVisor + per-sandbox token) as a standalone Cloud Run service is the recommended default. GKE Agent Sandbox, if chosen instead, is more idiomatic run in-cluster as a Kubernetes controller rather than reached from Cloud Run.

## `sandbox-runtime/` — the ephemeral sandbox image

- Antigravity SDK/harness.
- Thin internal API (`GET /files`, `GET /files/{path}`, `PUT /files/{path}`, `WS /chat`), reachable only from `backend-api`.
- Entrypoint script: hydrate the working directory from the protocol's GCS prefix on start; flush back on stop signal and at checkpoints.
- On `PUT /files/{path}`: write to disk, then inject a note into the live Antigravity conversation (e.g. "user manually edited {path}") so the agent's next turn reflects the change rather than working from stale assumptions. See "Manual edits and agent awareness" below.

### Hard isolation requirements
- gVisor sandboxing, `runAsNonRoot`, all Linux capabilities dropped.
- No host networking, no hostPath mounts.
- No general internet egress — allowlist only the model API endpoint. No package-registry access; the toolchain is baked into the image.
- Fixed, minimal base image.
- **Default mount scope is exactly one protocol's GCS prefix — nothing else.** Cross-protocol file references (see forward-compatibility note above) would later mean explicitly mounting a sibling protocol's prefix read-only; this must stay an explicit, per-request grant, never a default.

---

## Manual edits and agent awareness

Files can be edited two ways: by the agent through chat, or directly by the user in the UI's file editor. The agent must always know when the second thing happened — otherwise it risks overwriting a user's manual change or reasoning about stale file contents.

- **Sandbox running, agent between turns:** the write goes straight to the sandbox (via the `PUT /files/{path}` behavior above), which injects an awareness note into the live conversation immediately. The next agent turn already knows.
- **Sandbox idle:** the write goes straight to GCS (the protocol has no live conversation to notify). Log the edit instead. When a sandbox is next started for this protocol, the entrypoint script checks for unconsumed edits after hydrating and primes the agent's first turn with a summary (e.g. "since your last session, the user manually edited: file_a.py, file_b.py") before any new user prompt is processed.
- **Agent mid-turn:** the UI blocks editing during this state, but that's a client-side convenience, not a guarantee — `backend-api` must independently reject `PUT /protocols/{id}/files/{path}` (e.g. `409 Conflict`) whenever the protocol's sandbox has a turn actively in progress, so a stale client or a race can't slip a write in while the agent is actively writing the same files.
- This means `backend-api` needs to track turn-in-progress state per protocol. `sandbox-runtime`'s internal API should emit `turn_start`/`turn_end` events over the same channel used for chat streaming, so `backend-api` can both reject writes appropriately and relay the state to the frontend to drive the editor lock. If `backend-api` runs multiple instances, make sure the instance handling a protocol's live WebSocket session is also the one a given write request reaches — or back this with a shared low-latency store instead of per-instance memory.

Both write paths log to the same table so the "consumed" bookkeeping is consistent regardless of which path was taken.

## Data model (Postgres / Cloud SQL)

```
workcells(id, name, owner_id, created_at)
collaborators(workcell_id, user_id, role)
protocols(id, workcell_id, name, status, gcs_prefix, sandbox_ref, created_at, updated_at)
sandbox_sessions(id, protocol_id, sandbox_ref, status, last_activity_at, created_at)
file_edits(id, protocol_id, path, edited_by_user_id, edited_at, consumed_by_agent)
```

Note `collaborators` keys off `workcell_id`, not `protocol_id` — this is what makes sharing a workcell-level action.

## Storage (GCS)

```
gs://<bucket>/workcells/{workcell_id}/protocols/{protocol_id}/
```

Nesting protocols under their workcell is deliberate: it's what lets a future "reference another protocol's files" feature grant read-only access to a sibling prefix under the same workcell root, without moving any data.

## Non-functional requirements

- **Scale-to-zero by default** — no protocol should cost compute while idle.
- **File browsing works without an active sandbox** — read from GCS directly when idle.
- **Single active session per protocol** — Antigravity's harness writes directly to disk with no locking; don't allow two concurrent live sessions against one protocol's sandbox.

## Explicitly open / not decided
- Auth provider for end users.
- Cloud Run Sandbox vs. GKE Agent Sandbox (default recommendation: Cloud Run Sandbox).
- Implementation of cross-protocol file referencing (deferred by design, see above).
- Whether collaborator roles differentiate view vs. edit access within a shared workcell, or are uniform.
