# Running the FALSK rewrite in Antigravity — runbook

This is the operator's guide for executing the `falsk_rewrite` specs with Google Antigravity.
The eight numbered docs (`00`–`08`) are the source of truth; this file is just *how to drive them*.

---

## 0. One-time setup

Antigravity works on a **single workspace folder**, and the agent needs the specs, the old code,
and the new code all visible at once. Do the consolidation in your **FALSK code repo**:

1. **Quarantine the old code.** Move all current code into a top-level `legacy/` folder, in one
   commit, unchanged. (Doc 06 §0, guardrail doc 07 #13.)
2. **Bring the specs in.** Copy the `falsk_rewrite/` docs into the code repo at `docs/specs/`.
   The separate `implemetation-specs` repo stays their canonical home; this is the working copy
   the agent reads.
3. **Install the rule.** Copy `antigravity/falsk.md` → `.agents/rules/falsk.md`. It's always-on and
   pins the hard guardrails (it points at the full docs via `@`-references).
4. **Install the workflow.** In Antigravity's Customizations panel, add a **Workspace** workflow
   named `phase` with the contents of `antigravity/phase.md`. You'll invoke it as `/phase <n>`.
5. **Open the code repo as the Antigravity workspace** and open the Agent pane.

> Alembic note (easy to get wrong): copy the existing `migrations/versions/` history into the new
> app's Alembic dir so new revisions append to the current head. Do **not** start a fresh history —
> autogenerate would try to recreate tables that already exist. (Doc 05 §5, doc 06 §0.)

---

## 1. The loop

Run **one phase at a time**. For each phase:

1. In the Agent pane, type `/phase <n>` (or paste the kickoff prompt below for Phase 0).
2. Antigravity shows an **implementation plan** artifact. **Read it.** Confirm it stays within the
   phase and doesn't trip a guardrail.
3. Click **Run**. The agent works across editor/terminal/browser.
4. Review the **walkthrough** artifact it produces and the gate status.
5. Only when the phase's gate is green do you approve moving on. **Do not "Accept All" across a
   gate.**

---

## 2. Phase 0 kickoff prompt (paste verbatim the first time)

> Read `docs/specs/` docs 00–08 in order. Do **not** write app code yet. Execute Phase 0
> (doc 06 §0): (1) confirm all old code is in `legacy/`; (2) produce `INVENTORY.md` of every frozen
> asset — agent prompts (and any prompt-composition logic), tool signatures/returns, DB schema +
> Alembic history, REST `/api/*` paths, and the WebSocket path/message shapes — each with its
> `legacy/`-relative source path and a content hash; (3) scaffold the doc 04 §1 layout with `uv`,
> empty routers, health endpoints, structured-error envelope stub, logging/tracing, and CI wired
> with the doc 07 §5 gates (state-write, adk-import scope, legacy-import scope, prompt-hash,
> migration up/down); (4) exclude `legacy/` from the package, lint, type-check, tests, and Docker
> build context. Copy the existing Alembic history forward — do not start a fresh chain. Stop at
> Gate 0 and show me `INVENTORY.md` before proceeding.

Then for later phases: `/phase 1`, `/phase 2`, … Each phase's deliverables and gate are in doc 06.

---

## 3. Gating checklist (you enforce these — the agent will try to keep going)

- **Phase 0:** `INVENTORY.md` is complete and hashes look right; CI gates actually fail on
  violations (test one deliberately); `legacy/` is excluded from the build.
- **Phase 1:** an authenticated request round-trips; every error path returns the envelope; the
  local auth bypass is impossible in the cloud profile.
- **Phase 2 (the big one):** golden-output parity on representative prompts; **zero OCC conflicts**
  under concurrent/rapid-fire turns. This is the proof the original OCC problem is fixed — don't
  wave it through on a single happy-path turn.
- **Phase 3:** start an execution, end the turn immediately, confirm nothing is lost; kill/restart
  mid-run and confirm safe resume (≤3 retries, no re-run of completed steps).
- **Phase 4:** a real before/after latency trace against the target you set in doc 08; no regression
  vs Phase 2 goldens.
- **Phase 5:** parity + latency + robustness green in a prod-like env; rollback plan written.

---

## 4. Things that make or break it

- **Wire the CI gates in Phase 0, not later.** The doc 07 §5 grep/AST gates are what hold the line
  when the agent generates many files at once. Prose guardrails alone won't.
- **Answer doc 08 before the phases that depend on it.** In particular Q4 (OCC root cause) before
  Phase 2, and the latency target before Phase 4. Open questions left unanswered become the agent's
  guesses.
- **Keep prompts referencing docs by `@path`,** not pasted — the rule file's 12k-char cap means it
  should point at the docs, not contain them.
- **When the agent says a guardrail is in its way,** it should have stopped and written to doc 08.
  If it "worked around" one instead, reject the change.
