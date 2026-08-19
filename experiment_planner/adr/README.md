# Architecture Decisions

Decision log for the Protocol Workcell platform. Every architectural choice an
implementing agent needs is either **accepted** below with an ADR, or **open**
below with the trade-off stated. Nothing is left implicit.

**If you are implementing: read the ADRs before writing code.** They contain
numbered provisions (P1, P2, …) that are binding. Each provision exists because
the obvious alternative produces a specific, named failure.

---

## Accepted

| ADR | Title | Decision in one line |
|---|---|---|
| [ADR-001](ADR-001-authentication-and-identity.md) | Authentication and Identity | IAP is the sole authentication boundary; a `users` table keyed on IAP subject is the app's identity source of truth. |
| [ADR-002](ADR-002-sandbox-topology.md) | Sandbox Topology | GKE Agent Sandbox as the per-protocol execution unit; the turn lock lives in the sandbox, not in `backend-api`. |
| [ADR-003](ADR-003-protocol-revisions-and-export-contract.md) | Protocol Revisions and the Export Contract | Immutable numbered revisions are the unit that leaves this system, for consumption by the future execution app. |
| [ADR-004](ADR-004-single-driver-concurrency.md) | Single-Driver Concurrency Model | One driver per protocol; every other collaborator gets read-only observer mode with live chat, not an error. |
| [ADR-005](ADR-005-runtime-profiles-and-dependencies.md) | Runtime Profiles and Dependencies | Staged. Stage 1 is a fixed pinned image with `runtime_profile` recorded from day one and failed-import telemetry as the evidence base for Stage 2. |

**Also settled, not warranting their own ADR:**

- **Roles are `owner` / `editor` / `viewer`.** Enforced at the API layer. The
  non-obvious rule: a **viewer must not be able to send a chat prompt**, because
  prompting causes the agent to mutate files. See `specs/schema.sql`.
- **Sharing targets existing users only** during the pilot. Invitations to users
  who have never signed in return `422 user_not_found` (ADR-001 P6).
- **Ownership transfer is an admin endpoint**, no end-user UI (ADR-001 P7).
- **Physical instrument execution is out of scope.** A separate application will
  consume published revisions and run them with its own safety checks (ADR-003).
- **Database: AlloyDB for PostgreSQL.** Cost is not the primary constraint.
  Nothing in `specs/schema.sql` depends on AlloyDB-specific features, so the
  choice stays reversible. Confirm `citext` and `pgcrypto` are enabled at
  provisioning time.
- **File content lives in Cloud Storage, not Postgres.** This makes ADR-002 P4
  (manifest-last commit, object versioning, flush on every `turn_end`)
  **mandatory rather than optional** — it is the only thing between a mid-flush
  pod eviction and a silently corrupted protocol.

---

## Closed decisions

All four previously-open decisions were resolved on 2026-08-19.

| # | Decision | Outcome |
|---|---|---|
| D-1 | Cloud SQL vs. AlloyDB | **AlloyDB.** Cost not a constraint. Schema unchanged and portable. |
| D-2 | File content in Postgres vs. object storage | **Cloud Storage.** No `protocol_files` table. ADR-002 P4 becomes mandatory. |
| D-3 | Package installation in the sandbox | **Staged** — see [ADR-005](ADR-005-runtime-profiles-and-dependencies.md). Stage 1 is a fixed pinned image. |
| D-4 | Concurrent editors on one protocol | **Single driver**, others read-only — see [ADR-004](ADR-004-single-driver-concurrency.md). |

### Cheap things decided now that prevent expensive migrations later

Two fields exist from the first commit despite having exactly one value today.
Both are deliberate; do not "simplify" them away:

- **`runtime_profile`** on `protocols` and in every revision manifest
  (ADR-005 P1). Without it, introducing a second runtime later means a schema
  migration, a manifest version bump, and a body of revisions whose runtime is
  permanently unknowable.
- **Failed-import telemetry** in the sandbox (ADR-005 P2). This is the entire
  evidence base for the Stage 2 design and cannot be reconstructed
  retroactively.

---

## Open — deferred by design

Nothing blocks implementation. These are decisions deliberately postponed, each
with the trigger that should reopen it.

| # | Question | Reopen when |
|---|---|---|
| O-1 | **Runtime profiles (ADR-005 Stage 2).** Named, versioned images plus a workcell-level `lib/` mount for custom deck resources and helper modules. | Failed-import telemetry shows recurring demand, or a PyLabRobot version split becomes necessary. |
| O-2 | **Per-protocol dependency manifests (ADR-005 Stage 3).** Resolution in a builder service outside the sandbox against a private mirror. | Stages 1–2 demonstrably fail real needs. Do not build speculatively. |
| O-3 | **Takeover / request-control (ADR-004).** An observer asking the driver for control, or forced takeover after prolonged idleness. | Pilot users hit the driver lock often enough to complain. |
| O-4 | **`lib/` versioning against the export contract.** A revision importing from a shared `lib/` is not fully reproducible unless `lib/` is pinned too — a genuine gap in ADR-003's contract. | Resolve as part of O-1. Do not ship `lib/` without answering it. |
| O-5 | **`turn_events` volume.** `agent_delta` rows are high-volume; compact into the completed message on `turn_end`, or partition by protocol. | Before load testing, not after. |
| O-6 | **Revision retention policy.** Revisions are append-only with no deletion path, by design. | When storage volume justifies archival. |

---

## Still to write

| Artifact | Why it matters | Status |
|---|---|---|
| `specs/openapi.yaml` | The API contract. Frontend and backend are built by separate agents; the generated TypeScript client is what stops them disagreeing on shapes and error codes. 31 operations, 23 schemas. | **Written** — structurally validated (all `$ref`s resolve, path params declared, operationIds unique, no orphan components) |
| `specs/testing-strategy.md` | The interesting logic — sandbox lifecycle, turn locking, hydrate/flush — is untestable against real GCP. Needs `FakeSandboxController`, a fake object-storage server, IAP header injection in dev, and integration tests for the three save paths plus the idle reaper. Without this you get high coverage on CRUD and none on what actually breaks. | Not started |

---

## Reading order for an implementing agent

1. This file — know what is decided and what is not.
2. `adr/ADR-001` — how identity works; nothing else makes sense first.
3. `specs/schema.sql` — the data model, with rationale inline.
4. `adr/ADR-002` — the sandbox, the turn lock, the durable event log.
5. `adr/ADR-003` — revisions and the export contract.
6. `adr/ADR-004` — who can write to a protocol, and what everyone else sees.
7. `adr/ADR-005` — the runtime environment and why dependencies are fixed.
8. The two original build prompts at the repository root, for product intent.

### The three locks — do not confuse them

They have different scopes, different causes, and different UI treatments:

| Lock | Scope | Cause | UI treatment |
|---|---|---|---|
| **Role** | Workcell | Caller is a `viewer` | Controls absent entirely |
| **Driver** (ADR-004) | Protocol | Another collaborator holds the session | Observer banner naming the driver; `409 not_driver` |
| **Turn** (ADR-002 P1) | Protocol, momentary | The agent is mid-turn | "Agent is working — editing paused"; `409` from the sandbox |

A user can be an editor, *and* be the driver, and still be unable to save —
because the agent is mid-turn. The three checks are independent, all three are
enforced server-side, and the UI must never render them as the same state.

Where an original build prompt and an ADR conflict, **the ADR wins** — the ADRs
were written to correct specific errors in those prompts, and each says which.
