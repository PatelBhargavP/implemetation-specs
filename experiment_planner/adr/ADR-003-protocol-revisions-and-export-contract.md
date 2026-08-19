# ADR-003: Protocol Revisions and the Export Contract

**Status:** Accepted
**Date:** 2026-08-19
**Deciders:** Bhargav
**Applies to:** `backend-api`, `frontend`, and the future execution application

---

## Context

This platform is an **authoring and simulation environment**. Researchers use an agent to write PyLabRobot protocols and simulate them here. Physical execution against liquid-handling instruments is explicitly **out of scope** — a **separate application**, built later, will read protocols from this system and run them against real hardware with its own additional safety checks.

That separation is a good architectural boundary. It also creates an obligation that is cheap to meet now and expensive to meet later:

> The future execution app will consume protocols produced here. Whatever it consumes is a **contract**. If that contract is "whatever files happen to be in the workspace right now," the boundary is unusable.

Two specific hazards:

1. **A workspace is a moving target.** The agent edits files continuously. An execution app that reads "the current state of protocol X" can read a half-finished edit, or a version the researcher never intended to run. For a system that moves physical liquid, this is a safety problem, not just an engineering one.
2. **Reproducibility.** A run that happened last month must be traceable to the exact protocol content that produced it. Mutable workspaces cannot provide this.

Nothing about the execution app needs building now. But the *shape of what it will read* must be decided now, because retrofitting immutability into a mutable-workspace model is a data migration plus an audit gap.

## Decision

**Introduce immutable, numbered protocol revisions. A revision — not a workspace — is the unit that leaves this system.**

1. A protocol has a mutable **working state** (what the agent and editor operate on) and zero or more immutable **revisions**.
2. `POST /protocols/{id}/revisions` publishes the current working state as the next revision. Revisions are numbered monotonically per protocol and are **never modified or deleted**.
3. A revision carries an **export manifest**: the file set with content hashes, the runtime and library versions used, the simulation result at publication time, and provenance (who published it, when, from which protocol and workcell).
4. The read side of this contract — `GET /protocols/{id}/revisions/{n}` and its file endpoints — is **implemented now**. The execution app is not.

## Options Considered

### Option A: Immutable revisions with an export manifest — **CHOSEN**

| Dimension | Assessment |
|---|---|
| Complexity | Low-Medium — one table, one endpoint, one storage prefix convention |
| Cost | Storage only; protocol files are small |
| Scalability | High |
| Safety posture | Strong — nothing physical can run from a mutable source |

**Pros**

- Gives the execution app a stable, versioned, safe thing to consume.
- Provides reproducibility and an audit trail for free.
- Publishing is a deliberate researcher action — a natural checkpoint, and a natural place for the future app's safety gate to attach.
- Enables an obvious near-term UI feature (revision history, diff between revisions) at almost no extra cost.

**Cons**

- One more concept in a product already introducing workcells and protocols.
- Requires deciding what "publish" means in the UI during a pilot that has not yet validated the core loop.

### Option B: Execution app reads the live workspace

| Dimension | Assessment |
|---|---|
| Complexity | Lowest now |
| Cost | Lowest now |
| Safety posture | **Poor** |

**Pros:** Nothing to build. No new concepts.
**Cons:** The execution app can read a protocol mid-edit. No reproducibility — "which version ran?" is unanswerable. Any future safety check validates a state that may have changed by the time it runs. For a system driving physical hardware, this is the wrong default.

**Rejected on safety grounds.**

### Option C: Export-on-demand — the execution app requests a snapshot

The execution app calls an endpoint that snapshots the workspace at request time.

**Pros:** No new user-facing concept; snapshots are still immutable once taken.
**Cons:** The snapshot boundary is chosen by the *consumer*, not the *author*. A researcher never explicitly says "this version is ready to run." That removes the human checkpoint, which is precisely the control worth having when the output moves liquid. Also produces unbounded snapshot sprawl with no meaningful identity.

**Rejected** — it optimises away the human sign-off, which is the feature.

## Trade-off Analysis

The trade is **one extra concept now vs. a safety and reproducibility gap later**.

Option B is tempting during a pilot: nothing to build, no new UI. But the cost of adding revisions later is not just the table — it is that every protocol authored in the interim has no revision history, no publication provenance, and no reproducible link to any simulation result. That history cannot be reconstructed.

The decisive argument is the domain. The consumer of this data eventually moves physical liquid in a lab. An architecture where the executable artifact is a mutable directory is one where "the protocol changed between review and execution" is possible. The cost of preventing that now is one table and one endpoint.

Note the scope discipline: **only the publish and read paths are built.** No execution app, no scheduling, no instrument registry, no run tracking. Those belong to the other system and would be speculative here.

## The export contract

This is the interface the future execution app depends on. Treat changes to it as breaking.

```
GET /protocols/{protocol_id}/revisions
GET /protocols/{protocol_id}/revisions/{revision_number}
GET /protocols/{protocol_id}/revisions/{revision_number}/files
GET /protocols/{protocol_id}/revisions/{revision_number}/files/{path}
```

Revision manifest shape:

```jsonc
{
  "protocol_id": "…",
  "workcell_id": "…",
  "revision_number": 4,
  "published_at": "2026-08-19T09:14:00Z",
  "published_by": { "user_id": "…", "email": "…" },
  "label": "optional researcher-supplied note",

  "manifest_version": "1.0",           // contract version — bump on breaking change
  "files": [
    { "path": "protocol.py", "sha256": "…", "size_bytes": 4210 }
  ],

  "runtime": {
    "image_digest": "sha256:…",         // exact sandbox image that produced this
    "python_version": "3.12.x",
    "libraries": { "pylabrobot": "x.y.z" }   // pinned versions, not ranges
  },

  "simulation": {
    "status": "passed | failed | not_run",
    "ran_at": "2026-08-19T09:13:40Z",
    "summary_ref": "…"                  // pointer to stored simulation output
  }
}
```

**`runtime` and `simulation` are the fields that matter most to the consumer.** They let the execution app refuse to run a protocol that was never simulated, or that was authored against a library version it does not have. Omitting them makes the manifest a file list, which is not enough to decide whether something is safe to run.

## Provisions (binding on implementation)

### P1 — Revisions are immutable and append-only

No `UPDATE` or `DELETE` on revision rows or revision storage objects, enforced by database grants where practical, not by convention alone. Revision numbers are allocated per protocol with a uniqueness constraint on `(protocol_id, revision_number)` and assigned inside the publishing transaction.

### P2 — Revision storage is separate from working storage

```
gs://<bucket>/workcells/{workcell_id}/protocols/{protocol_id}/working/
gs://<bucket>/workcells/{workcell_id}/protocols/{protocol_id}/revisions/{n}/
```

The sandbox mounts `working/` only. It must have **no write access** to `revisions/`. Publishing is performed by `backend-api`, never by the agent.

*Why:* An agent able to write to revision storage can rewrite history, defeating the entire mechanism.

### P3 — Publishing requires a settled workspace

`POST /protocols/{id}/revisions` returns `409 Conflict` if an agent turn is in progress (per ADR-002 P1). Publishing mid-turn captures an arbitrary intermediate state.

### P4 — Publishing is an editor-role action

Viewers cannot publish. See ADR-001 and the roles decision in `adr/README.md`.

### P5 — The manifest is versioned from day one

`manifest_version` is present in the first revision ever written. Consumers must reject manifests whose major version they do not recognise.

*Why:* The consumer is a separate application on a separate release cycle. Without a version field, the first contract change requires coordinated deployment of two systems.

### P6 — Simulation status is recorded, never inferred

If a protocol is published without a simulation having been run, `simulation.status` is `"not_run"`. Do not default it to `"passed"`, and do not omit the field. The consuming application decides what to do with an unsimulated protocol; this system's job is to report the truth accurately.

## Consequences

**Easier**

- The future execution app has a stable, safe, versioned contract to build against, and can be built independently.
- Reproducibility and audit come for free.
- Revision history and diff become straightforward UI features.
- The publish action is a natural attachment point for future review or approval workflows.

**Harder**

- One more concept for researchers to understand; the UI must make "working state vs. published revision" legible without clutter.
- Storage grows monotonically. Protocol files are small, so this is not a near-term concern, but there is no deletion path by design — a retention policy will eventually be needed.

**To revisit**

- Retention and archival policy for old revisions, once volume justifies it.
- Whether revisions need approval workflow (a second person signing off before a revision is runnable) — likely, once real hardware is in play, but that gate belongs in the execution app.
- The manifest will need extending as the execution app's requirements firm up. P5 is what makes that safe.

## Action Items

1. [ ] Add the `protocol_revisions` table and `(protocol_id, revision_number)` uniqueness constraint (P1).
2. [ ] Split storage into `working/` and `revisions/{n}/`; confirm the sandbox has no write access to `revisions/` (P2).
3. [ ] Implement `POST /protocols/{id}/revisions` with turn-in-progress rejection and role check (P3, P4).
4. [ ] Implement the four read endpoints of the export contract.
5. [ ] Emit `manifest_version: "1.0"` from the first revision (P5).
6. [ ] Capture `runtime.image_digest` and pinned library versions at publish time from the sandbox that produced the state.
7. [ ] Record simulation status honestly, including `"not_run"` (P6).
8. [ ] Add revision history to the protocol workspace UI; diff between revisions may be deferred.
9. [ ] Document the export contract as the interface for the future execution app; version it independently of the internal API.
