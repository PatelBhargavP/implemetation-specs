# ADR-004: Single-Driver Concurrency Model

**Status:** Accepted
**Date:** 2026-08-19
**Deciders:** Bhargav
**Applies to:** `backend-api`, `frontend`

---

## Context

A workcell is shared. Two collaborators opening the same protocol at the same
time is the **normal case for a collaboration tool**, not an edge case.

But only one live session per protocol is permitted (ADR-002 R5): the Antigravity
harness writes directly to disk with no locking, so two concurrent sessions
corrupt the workspace. This is enforced in the database by a partial unique index
on `sandbox_sessions`.

The constraint is settled. The question this ADR answers is **what the second
user experiences**, which is a product decision, not a technical one.

Without an explicit decision the default behaviour is the worst available
outcome: the second user's action fails with an opaque error, they do not know
why, they do not know who has the protocol, and they retry.

## Decision

**One driver per protocol. Everyone else gets read-only observer mode.**

- The first user to start a session on a protocol becomes its **driver**.
- Additional users with workcell access open the protocol successfully in
  **observer mode**: file tree browsable, editor read-only, chat history visible
  and **streaming live**, with a banner naming the current driver.
- Observers cannot prompt, save files, start or stop the sandbox, or publish
  revisions.
- There is **no takeover** in this pass. The lock releases when the driver's
  session ends (see P3).

The distinction that matters: the second user is blocked from *working*, not
from *looking*. Read paths already work without a sandbox (ADR-002 R7), so
observer mode costs almost nothing to build.

## Options Considered

### Option A: Read-only observer mode — **CHOSEN**

| Dimension | Assessment |
|---|---|
| Complexity | Low — read paths already exist and already work sandbox-free |
| UX quality | Good — legible, no dead ends |
| Risk | None to workspace integrity |

**Pros**

- The second user always gets a working screen and an explanation.
- Live chat streaming makes observation genuinely useful — a colleague can watch
  the agent work, which is a real collaboration behaviour for protocol review.
- Reuses ADR-002 R7's sandbox-free read path; little new machinery.
- Naturally extends to takeover or handoff later without rework.

**Cons**

- Requires a distinct UI state (a third one, alongside idle/provisioning/running).
- A driver who walks away holds the protocol until their session ends (P3).

### Option B: Hard rejection

The second user's request returns an error; the protocol will not open.

**Pros:** Nothing to build.
**Cons:** Dead end with no information. The user cannot see who holds it, cannot
read the files they have legitimate access to, and has no signal about when it
will free up. Generates support questions and erodes trust in sharing — which is
the product's central feature.

**Rejected.**

### Option C: Real-time collaborative editing (CRDT / OT)

**Pros:** No lock at all; the ceiling for collaboration UX.
**Cons:** Does not solve the actual problem. The conflict is not user-vs-user on
text — it is **agent-vs-user on files**, and the agent is an out-of-band writer
that no CRDT arbitrates. Would require rearchitecting the harness's file access.
Enormous scope for a pilot.

**Rejected as out of scope**, and note it would not remove the need for the
agent turn lock (ADR-002 P1) regardless.

## Trade-off Analysis

The trade is **a small amount of UI work vs. a confusing failure on a core flow**.

Options A and B are technically identical underneath — the same lock, the same
database constraint. The only difference is what the frontend does when it is
told "someone else is driving." Option B throws that information away; Option A
renders it.

Given that the protocol workspace is the product's main screen and workcell
sharing is its main feature, spending a modest amount of UI effort so that
sharing does not produce dead ends is clearly worth it.

Option C is a different product.

## Provisions (binding on implementation)

### P1 — The driver is derived from the active session, not a separate lock

The driver is `sandbox_sessions.started_by` on the protocol's active session
(status in `provisioning`, `running`, `stopping`). No second lock table.

*Why:* Two sources of truth for "who holds this protocol" will drift, and the
drift is invisible until a user is wrongly locked out. The partial unique index
already guarantees at most one active session; reuse it.

When no active session exists, the protocol has no driver, and the first user to
start one acquires it. `turn_leases` (ADR-002 P1) guards that startup race.

### P2 — Observer mode is a server-side authorization state, not a UI mode

`backend-api` independently rejects prompt submission, file writes, sandbox
control, and revision publication from any user who is not the current driver —
returning `409 Conflict` with a typed body:

```jsonc
{
  "error": "not_driver",
  "driver": { "user_id": "…", "display_name": "…", "email": "…" },
  "since": "2026-08-19T09:02:00Z"
}
```

*Why:* The UI disabling controls is a convenience, not a guarantee. A stale
client, a duplicated tab, or a race can otherwise slip a write past it — the same
reasoning that makes the turn lock server-side in ADR-002 P1. The response body
carries the driver's identity so the client can render the banner from the error
alone, without a second round trip.

### P3 — The lock releases on session end, and on driver absence

The driver lock is released when:

1. The driver explicitly stops the sandbox; **or**
2. The session is reaped for idleness (ADR-002 P5); **or**
3. The driver's WebSocket has been disconnected for longer than a grace period
   (suggest 5 minutes) **and** no agent turn is in progress.

*Why:* Condition 3 exists because conditions 1 and 2 alone produce a real and
predictable annoyance: a driver closes their laptop and holds the protocol until
the full idle timeout expires, blocking a colleague who is present and waiting.
The grace period must be long enough to survive a network blip or a page reload —
brief disconnects are routine (ADR-001 P8).

The "no agent turn in progress" condition is essential: a turn continues running
in the sandbox after its socket drops (ADR-002 P2). Releasing the lock mid-turn
would let a second user start writing files while the agent is still writing them,
which is precisely what the lock exists to prevent.

### P4 — Observers see live chat, not a frozen snapshot

Observers subscribe to the same turn event stream as the driver (ADR-002 P2),
replaying from `?since=` and then streaming. They receive all event kinds but
may not submit any.

*Why:* A frozen transcript makes observer mode feel broken. Live streaming makes
it useful, and it costs nothing extra — the durable event log already exists for
reconnection.

### P5 — Presence is visible before it is relevant

The protocol list on the workcell detail screen shows the current driver on any
protocol that has one. A user should learn a protocol is occupied **before**
opening it and being demoted, not after.

## Consequences

**Easier**

- No dead-end states. Every user with workcell access can always open every
  protocol in it.
- Observation is a genuine feature — a colleague can watch a protocol being
  developed, useful for review and for training.
- The lock has exactly one source of truth, so it cannot drift.

**Harder**

- The protocol workspace has a fourth state to design and test
  (idle / provisioning / running-as-driver / running-as-observer), interacting
  with the existing agent-turn editor lock. **The UI must distinguish "locked
  because the agent is working" from "locked because you are not the driver" —
  these have different causes, different durations, and different remedies.**
- The disconnect grace period (P3) is a timing behaviour, which means it needs
  deliberate integration tests rather than manual checking.

**To revisit**

- **Takeover / request-control.** Deliberately excluded here. Expect demand once
  the pilot has real users — the natural next step is an observer requesting
  control and the driver approving, or a forced takeover after a long idle
  period. P1's single-source lock makes either straightforward to add.
- **Multiple observers at scale.** Fine at pilot volume. If a protocol ever has
  many simultaneous observers, streaming every event to every one of them merits
  a fan-out review.

## Action Items

1. [ ] Derive driver identity from the active session's `started_by`; add no lock
       table (P1).
2. [ ] Enforce driver-only on prompt submit, file write, sandbox start/stop, and
       revision publish, returning typed `409 not_driver` with driver identity (P2).
3. [ ] Implement lock release on stop, on idle reap, and on driver disconnect
       beyond the grace period with no turn in progress (P3).
4. [ ] Subscribe observers to the turn event stream, read-only (P4).
5. [ ] Show the current driver on protocol cards in the workcell detail screen (P5).
6. [ ] Design the observer banner distinctly from the agent-working banner; the
       two must not be confusable.
7. [ ] Integration tests: second user gets observer mode not an error; observer
       write attempts rejected server-side with the UI bypassed; lock releases
       after driver disconnect; lock does **not** release mid-turn.
