# ADR-002: Sandbox Topology

**Status:** Accepted
**Date:** 2026-08-19
**Deciders:** Bhargav
**Applies to:** `sandbox-controller`, `sandbox-runtime`, `backend-api`

---

## Context

A **protocol** is the isolation unit: one protocol = one sandbox = one storage prefix. Inside the sandbox, the Antigravity SDK runs as an autonomous agent that generates and edits liquid-handling protocol files from natural-language prompts, and simulates them via PyLabRobot.

Requirements that constrain the topology:

| # | Requirement | Source |
|---|---|---|
| R1 | Sandbox must be **individually addressable** — `backend-api` proxies file and chat requests to *this protocol's* sandbox | Backend spec |
| R2 | Sandbox is **stateful across turns** within a session — the agent's working directory and conversation persist | Antigravity harness writes directly to disk |
| R3 | **Hard isolation** — gVisor, non-root, all capabilities dropped, no host networking, no hostPath | Agent executes model-generated code |
| R4 | **No general internet egress** — allowlist the model API endpoint only | Security requirement |
| R5 | **Single active session per protocol** — the harness has no file locking | Backend spec |
| R6 | **No compute cost while idle** — most protocols are idle most of the time | Non-functional requirement |
| R7 | **File browsing works with no sandbox running** | Backend spec, hard requirement |
| R8 | Provisioning latency should be **seconds, not tens of seconds** | UI spec: "provisioning" is a transient state |

Execution against physical instruments is **out of scope for this platform** (see ADR-003). The sandbox simulates only.

The original build prompt proposed "Cloud Run Sandbox pattern as a standalone Cloud Run service" as the default, with GKE Agent Sandbox as the alternative. Investigation showed this inverted: **Cloud Run sandboxes are nested inside your own container** — launched via a `sandbox` CLI made available by the `--sandbox-launcher` flag — and are not independently addressable network endpoints. Satisfying R1 and R2 on Cloud Run therefore requires solving instance routing, which Cloud Run does not reliably support.

## Decision

**Use GKE Agent Sandbox as the per-protocol execution unit.**

- `sandbox-controller` becomes a Kubernetes-facing controller running **in-cluster**, not a Cloud Run service reaching into GCP.
- A **`SandboxTemplate`** defines the protocol runtime image, resource limits, and egress policy.
- A **`SandboxClaim`** is created per protocol session and reclaimed on idle.
- A **`SandboxWarmPool`** keeps pre-warmed pods available to satisfy R8.
- The **Sandbox Router** is the ingress `backend-api` uses to reach a specific sandbox by claim identity.

## Options Considered

### Option A: GKE Agent Sandbox — **CHOSEN**

| Dimension | Assessment |
|---|---|
| Complexity | Medium-High — a cluster to operate |
| Cost | Cluster control plane + node floor, always on |
| Scalability | High; warm pools give sub-second claim satisfaction |
| Team familiarity | To be confirmed — see Consequences |
| Requirements met | R1–R5, R7, R8 natively. R6 partially (pods scale to zero; nodes do not) |

**Pros**

- Purpose-built for exactly this shape: addressable, long-lived, stateful, gVisor-isolated per-agent sandboxes.
- `SandboxClaim`/`SandboxTemplate` express the lifecycle declaratively; the controller becomes thin.
- Warm pools deliver sub-second start, which turns "provisioning" from a several-second UI state into a near-instant one.
- Pod snapshots offer a future path to suspend/resume rather than flush/hydrate.
- Network policy for R4 is a first-class Kubernetes concept, not a workaround.

**Cons**

- A GKE cluster is a standing operational commitment and a standing cost floor. R6 is met at the pod level, not the infrastructure level.
- More moving parts than the rest of the stack; the only component not serverless.
- Requires Kubernetes competence to operate and debug.

### Option B: Cloud Run nested sandboxes

| Dimension | Assessment |
|---|---|
| Complexity | High — instance routing is unsolved |
| Cost | Low when idle |
| Scalability | Poor for this access pattern |
| Requirements met | R3, R4, R6, R7. **R1 and R2 not reliably satisfiable** |

**Pros:** Genuinely scales to zero; consistent with the rest of the stack; no cluster to run.
**Cons:** Sandboxes live *inside* a Cloud Run container instance. With autoscaling, nothing guarantees that a request for protocol X reaches the instance holding X's sandbox. Session affinity on Cloud Run is best-effort and breaks precisely on scale events. Working around this means building a routing layer plus a shared session store — reimplementing, badly, what Option A provides.

**Rejected because** the core requirement (R1, addressability) is fought rather than supported.

### Option C: Stateless per-turn execution on Cloud Run

Each agent turn hydrates from storage, runs to completion, flushes, and exits. No sandbox persists between turns.

| Dimension | Assessment |
|---|---|
| Complexity | **Low** — the whole class of session problems disappears |
| Cost | Lowest; true scale-to-zero |
| Scalability | High |
| Requirements met | R3, R4, R6, R7 fully. R1, R2, R5 become moot |

**Pros:** No addressability problem, no session affinity, no turn-lock coordination, no idle reaper. The single-active-session constraint (R5) collapses into a database row lock. Operationally the simplest option by a wide margin.
**Cons:** Every turn pays hydrate + agent cold start. Conversation state must be reconstructed from persisted history each turn rather than living in the harness's memory — which may fight the Antigravity SDK's session model.

**Rejected because** per-turn cold start plus conversation reconstruction degrades the interactive feel the UI spec calls for, and the SDK's session handling is a poor fit for a process that dies between turns.

**Worth revisiting if** GKE operational burden proves higher than expected, or if measured turn latency shows hydration is cheap relative to model latency — in which case Option C's simplicity is very attractive.

## Trade-off Analysis

The real trade is **operational burden vs. session fidelity**.

Option C is the simplest system by a large margin. Everything difficult about this design — turn locking, idle reaping, WebSocket affinity, single-session enforcement — exists *only because* the sandbox is long-lived. Deleting long-lived sandboxes deletes all of it.

Option A is chosen because the interaction model is a live, conversational coding agent, and that model wants a warm process holding conversation state and a working directory. Reconstructing that per turn is possible but works against the SDK's grain.

We accept a standing GKE cost floor and a Kubernetes operational surface in exchange for the interactive experience. The cost floor is a genuine concession against R6: **R6 is satisfied for protocol compute, not for platform infrastructure.** This should be stated plainly to stakeholders rather than discovered on the first bill.

## Provisions (binding on implementation)

### P1 — The turn lock lives in the sandbox, not in `backend-api`

The sandbox is already the single writer to a protocol's files. It is therefore the authoritative holder of turn state.

- `sandbox-runtime` tracks turn-in-progress in process and **rejects `PUT /files/{path}` with `409 Conflict`** while a turn is active.
- `backend-api` forwards the write and relays the `409`. It does **not** maintain its own copy of turn state for correctness purposes.
- `backend-api` may cache `turn_start`/`turn_end` events for **UI relay only** — driving the editor lock — but must never treat that cache as authoritative.

*Why:* The original spec proposed either instance affinity or a shared low-latency store. Both are unnecessary. Placing the lock where the single writer already is eliminates the distributed-state problem entirely, along with the Redis dependency.

For the sandbox-idle case only, a `turn_lease(protocol_id, sandbox_ref, expires_at)` row in Postgres guards session startup races. It carries a TTL so a crashed sandbox cannot deadlock a protocol.

### P2 — An agent turn must not exist only inside the WebSocket

Per ADR-001 P8, no WebSocket survives beyond ~60 minutes, and clients disconnect routinely.

- Turn output is appended to a **durable log with a monotonic per-turn sequence number**, written as the turn streams.
- Clients reconnect with `?since=<seq>` and receive everything they missed.
- A turn continues running in the sandbox when its socket drops. It is never cancelled by disconnection.

*Why:* Without this, a laptop lid closing loses an in-flight agent turn's output irrecoverably. Retrofitting resumability into a socket-only stream is substantially harder than building it in.

### P3 — Egress is default-deny, with a curated package path

Kubernetes `NetworkPolicy` denies all egress except:

1. The model API endpoint required by the Antigravity SDK.
2. An **internal Artifact Registry Python remote repository**, if the package provision below is adopted.

Nothing else. No general internet, no public PyPI.

**On packages: resolved — see [ADR-005](ADR-005-runtime-profiles-and-dependencies.md).** Stage 1 is a fixed image with exact pinned versions and no egress, plus a `runtime_profile` field recorded from day one and structured failed-import telemetry. Later stages introduce named runtime profiles and a workcell-level `lib/` mount. **Item 2 above is therefore not part of Stage 1** — the allowlist contains the model API endpoint only, for now.

Binding regardless of stage: the agent never installs packages, and dependency resolution never happens inside the sandbox (ADR-005 P3, P4).

### P4 — Hydrate and flush must be crash-safe

The sandbox hydrates its working directory from the protocol's storage prefix on start and flushes back on stop.

- **Flush on every `turn_end`**, not only on stop signal. Pods are evictable; a sandbox that only flushes on graceful shutdown loses work on eviction.
- A flush writes a **manifest object last**, listing every file and its generation. The manifest is the commit point: a partial flush leaves the previous manifest intact and is therefore invisible.
- Hydration reads the manifest, then the files it names. Objects not in the manifest are ignored.
- Enable **object versioning** on the bucket.

*Why:* Object storage offers no atomic multi-object commit. Without a manifest commit point, a sandbox killed mid-flush leaves a half-written protocol that hydrates into an inconsistent state, and deletes become indistinguishable from failed writes.

> **Decided:** protocol file content lives in Cloud Storage, not Postgres. This provision is therefore **mandatory, not conditional** — the manifest commit point is the only thing standing between a mid-flush pod eviction and a silently corrupted protocol.

### P5 — Idle reaping is externally triggered and lease-based

`sandbox-controller` exposes `POST /reconcile`, invoked by Cloud Scheduler, which sweeps `sandbox_sessions` for entries past the idle threshold and releases their claims.

Reaping is driven by `last_activity_at` with a **lease** semantic: the sandbox heartbeats, and absence of a heartbeat — not merely absence of user activity — is what makes a session reapable. A sandbox actively running a long agent turn with no user interaction must not be reaped.

### P6 — File reads must not require a sandbox

`GET /protocols/{id}/files` and `GET /protocols/{id}/files/{path}` read from storage directly when no sandbox is running (R7). This path must be independently tested with **no sandbox infrastructure available at all**, so that a broken cluster degrades browsing to read-only rather than taking it down.

### P7 — The controller is abstracted behind an interface

`backend-api` depends on a `SandboxController` interface, never on Kubernetes types. A `FakeSandboxController` is a required deliverable, not a testing nicety.

*Why:* Two reasons. First, the entire sandbox lifecycle is otherwise untestable in CI. Second, Option C remains a live fallback — the interface is what keeps that door open at reasonable cost.

### P8 — Sandbox pod hardening

Per R3, enforced via `SandboxTemplate` and admission policy: gVisor runtime class, `runAsNonRoot`, all Linux capabilities dropped, no host networking, no `hostPath` mounts, read-only root filesystem with a writable working-directory volume, fixed minimal base image, explicit CPU and memory limits.

**The default mount scope is exactly one protocol's storage prefix.** Cross-protocol references (a deferred feature) must later be an explicit per-request read-only grant of a sibling prefix under the same workcell root — never a default, never a wildcard.

## Consequences

**Easier**

- Addressability, statefulness, and isolation are provided rather than engineered around.
- Warm pools make provisioning fast enough that the UI's "provisioning" state is barely perceptible.
- Network policy expresses the egress allowlist directly.
- Pod snapshots offer a future suspend/resume path, improving on flush/hydrate.

**Harder**

- A GKE cluster must be operated, monitored, upgraded, and paid for continuously.
- The stack is no longer uniformly serverless; debugging spans Cloud Run and Kubernetes.
- **R6 is only partially met.** Protocol compute scales to zero; cluster infrastructure does not.

**To revisit**

- If GKE operational load exceeds appetite, or if measured hydrate cost proves small relative to model latency, **Option C becomes attractive**. P7's interface is what makes that switch affordable.
- Package installation (P3) is unresolved.
- Pod snapshots as a replacement for flush/hydrate, once the base system is stable.

## Action Items

1. [ ] Provision a GKE cluster with Agent Sandbox enabled; confirm gVisor runtime class availability.
2. [ ] Author `SandboxTemplate` with the runtime image, resource limits, and hardening from P8.
3. [ ] Configure `SandboxWarmPool`; measure claim-satisfaction latency against R8.
4. [ ] Deploy the Sandbox Router; confirm `backend-api` can address a specific claim.
5. [ ] Apply default-deny `NetworkPolicy` with the model API allowlist (P3).
6. [ ] Implement `SandboxController` interface + `FakeSandboxController` (P7).
7. [ ] Implement manifest-commit flush and hydrate; test kill-mid-flush recovery (P4).
8. [ ] Implement the durable turn log with sequence numbers and `?since=` replay (P2).
9. [ ] Implement `POST /reconcile` with heartbeat-lease semantics; wire Cloud Scheduler (P5).
10. [ ] Test the no-sandbox file browsing path with sandbox infrastructure fully unavailable (P6).
11. [ ] Implement Stage 1 of ADR-005: pinned image, `runtime_profile` field, failed-import telemetry.
12. [ ] Enable object versioning on the bucket; verify the sandbox service account has no write access to `revisions/` (ADR-003 P2).
