# ADR-005: Sandbox Runtime Profiles and Dependency Management

**Status:** Stage 1 Accepted · Stages 2–3 Proposed
**Date:** 2026-08-19
**Deciders:** Bhargav
**Applies to:** `sandbox-runtime`, `sandbox-controller`, `backend-api`

---

## Context

The sandbox has **no general internet egress** (ADR-002 P3, R4) and its
toolchain is baked into a fixed image. This is right for security: the sandbox
runs model-generated code, and its output eventually drives physical liquid
handling.

It also means a researcher who needs a library the image lacks is stuck until
the platform team rebuilds the image. Stated intent: *start with predefined
dependencies, but preserve researcher freedom to experiment long-term.*

### The reframe that makes this tractable

"Package freedom" conflates **two different needs with different right answers**:

| | Need | Nature | Frequency |
|---|---|---|---|
| **(a)** "I need a different PyLabRobot version, or a library not in the image" | **Platform** concern — affects everyone, and version drift threatens reproducibility | Rare |
| **(b)** "I need a custom deck resource, plate definition, or my own helper module" | **Content** concern — this is *code the researcher wrote*, not a third-party package | Common |

Researchers will describe both as "I need to install something," because
`pip install` is the tool they know. But (b) is not a packaging problem at all —
it is a file-sharing problem wearing a packaging costume.

**Most of the demand is (b).** Solving (b) properly shrinks (a) to a handful of
genuine cases per year, which a curated process handles comfortably. Building a
general package-installation system to serve demand that is mostly (b) would be
solving the wrong problem at the highest possible cost in security.

## Decision

Stage the capability. Ship Stage 1 now; the trigger for each later stage is
evidence, not a calendar.

### Stage 1 — Fixed image, pinned dependencies **(accepted, build now)**

- One image, exact pinned versions of PyLabRobot and all libraries. No egress.
- **`runtime_profile` is recorded on every protocol and in every revision
  manifest from day one**, even though exactly one profile exists.
- **Failed imports inside the sandbox are logged** as a structured telemetry
  event: the module name, the protocol, the timestamp.

The `runtime_profile` field is the important part. It costs one column and one
manifest key today. Without it, Stage 2 is a schema migration plus a manifest
version bump plus a backfill of revisions whose runtime is then unknowable.

The import telemetry is the second important part, and it is nearly free:
**it is the only way to answer "what do researchers actually need?" with data
instead of anecdote.** Without it, Stage 2 is designed by guesswork.

### Stage 2 — Named runtime profiles **(proposed)**

A small catalogue of curated, versioned images:

```
plr-2026.1          PyLabRobot pinned, core simulation stack
plr-2026.1-analysis adds pandas / numpy / plotting
plr-2026.2          next PyLabRobot line, published alongside 2026.1
```

- A protocol selects a profile. The profile ID is recorded in the revision
  manifest, so a published revision always names the exact environment that
  produced it.
- Adding a library means the platform team publishes a new profile version.
  Existing protocols are unaffected — old profiles remain available, which is
  what makes old revisions reproducible.
- Still zero egress. Still fully reproducible.

**Pair this with workcell-level shared modules**, which is what actually
resolves need (b):

```
gs://<bucket>/workcells/{workcell_id}/lib/
```

Mounted read-only into every sandbox in that workcell, on the Python path.
Researchers put custom deck resources, plate definitions, and helper modules
here and simply import them. No packaging involved.

Note this is **the same mechanism as the deferred cross-protocol reference
feature** — a read-only mount of a sibling prefix under the same workcell root.
Building it serves both, and the storage layout was already chosen to allow it
(ADR-002 P8). One feature, two requirements met.

**Trigger:** import telemetry from Stage 1 shows recurring demand for a specific
library set, or a PyLabRobot version split becomes necessary.

### Stage 3 — Per-protocol dependency manifest **(proposed; only if truly needed)**

A protocol declares dependencies in a manifest file. Resolution happens in a
**separate builder service outside the sandbox**, against a private Artifact
Registry remote repository that proxy-caches PyPI. The output is a locked layer
mounted read-only into the sandbox.

**The sandbox itself still has no egress.** This is the whole point of the design
and is non-negotiable.

**Trigger:** Stages 1–2 demonstrably fail to serve real, recurring needs. Do not
build this speculatively.

## Options Considered

### Option A: Staged profiles, resolution outside the sandbox — **CHOSEN**

**Pros:** Preserves zero-egress. Preserves reproducibility — every revision names
its exact runtime. Serves the common case (b) with a mechanism you were building
anyway. Each stage is justified by evidence from the previous one.
**Cons:** Adding a library at Stage 2 requires platform-team action, so there is
a turnaround time researchers will feel. Three stages means the long-term answer
is deliberately deferred.

### Option B: Open egress to PyPI from the sandbox

**Pros:** Maximum researcher freedom, immediately. Zero platform effort.
**Cons:** Defeats the isolation model entirely. A model-generated or
prompt-injected `pip install` becomes arbitrary code execution with network
access, in an environment producing code that will drive physical hardware. It
also destroys reproducibility: a protocol that worked in March silently behaves
differently in June. **Rejected outright** — this is the failure mode the whole
sandbox design exists to prevent.

### Option C: Per-user persistent virtual environments

**Pros:** Familiar, feels like a laptop.
**Cons:** Environments drift per user, so "works for me" becomes unresolvable
across a shared workcell. Published revisions are no longer reproducible by a
colleague. Directly undermines ADR-003's export contract, which exists so a
separate application can safely run a protocol later. **Rejected.**

## Trade-off Analysis

The tension is **researcher autonomy vs. reproducibility**, and reproducibility
has to win — not for security reasons alone, but because of ADR-003. A published
revision is consumed by a *separate application that drives physical hardware*.
That application must be able to determine what environment a protocol was
authored and simulated against. An environment a researcher mutated ad hoc cannot
answer that question.

Option A concedes turnaround time on new libraries in exchange for keeping that
guarantee. The concession is smaller than it appears, because the workcell `lib/`
mechanism gives researchers unmediated freedom over the thing they most often
actually want: **their own code**.

### On timing

Deferring the long-run answer is correct here, and not merely expedient. The
right Stage 3 design depends on demand you cannot yet observe — whether
researchers need many libraries or a few, the same ones or divergent ones,
occasionally or constantly. Stage 1's import telemetry is what converts that
guess into a measurement. **Committing now to a general package system would be
designing against imagined requirements.**

## Provisions (binding on implementation)

### P1 — `runtime_profile` exists from the first commit

Recorded on `protocols`, and in every revision manifest. Stage 1 sets it to a
single constant.

*Why:* One column now versus a migration, a manifest version bump, and revisions
with permanently unknowable runtimes later.

### P2 — Failed imports are logged as structured telemetry

Module name, protocol ID, timestamp. Reviewed before Stage 2 is designed.

*Why:* This is the entire evidence base for the next decision. It cannot be
reconstructed retroactively.

### P3 — The agent never installs packages, at any stage

Not at Stage 1, not at Stage 3. Dependency changes are always a human action
through an explicit interface.

*Why:* An agent that can add dependencies to a protocol destined to drive a
liquid handler is a supply-chain attack surface with physical consequences. A
prompt-injected agent pulling an attacker-controlled package into that
environment is the single worst outcome this architecture can produce. Human in
the loop, permanently.

### P4 — Dependency resolution never happens inside the sandbox

If Stage 3 is built, resolution runs in a separate builder service with network
access and **no agent control**. The sandbox receives a pre-built, locked,
read-only layer.

*Why:* Keeping resolution outside is what allows gating it — allowlists,
approval, vulnerability scanning, lockfile review. Resolution inside the sandbox
would make every one of those impossible.

### P5 — Old profiles are never deleted while revisions reference them

Retiring a profile that a published revision names makes that revision
irreproducible, silently breaking ADR-003's contract. Mark profiles deprecated;
do not remove them.

## Consequences

**Easier**

- Zero-egress isolation holds without blocking researchers on their own code.
- Every published revision names its exact runtime, so the future execution app
  can validate compatibility before running anything physical.
- The workcell `lib/` mount serves both custom resources and the deferred
  cross-protocol reference feature.

**Harder**

- New third-party libraries require platform-team turnaround. Set this
  expectation with researchers explicitly at pilot start rather than letting them
  discover it.
- Profiles accumulate and must be maintained; P5 forbids cleaning them up freely.

**To revisit**

- Stage 2, once import telemetry justifies it.
- Stage 3, only if Stages 1–2 demonstrably fail.
- Whether workcell `lib/` should be versioned alongside protocol revisions — it
  probably should, since a revision that imports from `lib/` is not fully
  reproducible unless `lib/` is pinned too. **Resolve this when Stage 2 is
  designed; it is a genuine gap in the export contract.**

## Action Items

1. [ ] Add `runtime_profile` to `protocols` and to the revision manifest; set a
       single constant for Stage 1 (P1).
2. [ ] Pin exact PyLabRobot and library versions in the sandbox image; record the
       image digest at publish time.
3. [ ] Implement structured failed-import telemetry in `sandbox-runtime` (P2).
4. [ ] Document for researchers, at pilot start, that dependencies are fixed and
       how to request additions.
5. [ ] Review import telemetry before designing Stage 2.
6. [ ] When Stage 2 is designed, resolve `lib/` versioning against the export
       contract (see *To revisit*).
