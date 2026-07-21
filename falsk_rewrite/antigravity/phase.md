# /phase — run one FALSK rewrite phase

**Copy to the code repo as a Workspace workflow** (Customizations panel → **+ Workspace**, name it
`phase`), then invoke as `/phase <n>` (e.g. `/phase 0`).

This workflow runs exactly one gated phase from `docs/specs/06-migration-plan.md`. It never crosses
a gate without the human approving.

## Steps

1. Read `docs/specs/README.md` and all of `docs/specs/00`–`08` if not already loaded this session.
   Then read the section of `docs/specs/06-migration-plan.md` for the requested phase `<n>`.
2. Restate, in 3–5 bullets: the phase's deliverables and its **exit gate** (verbatim from doc 06).
3. Produce an **implementation plan** artifact for this phase only. Do not touch later phases.
   Cross-check every planned change against the doc 07 hard rules; if any change would violate a
   guardrail, STOP and write the conflict into `docs/specs/08-open-questions.md` instead.
4. Wait for the human to review the plan and click **Run**.
5. Execute the plan. Keep each module within the doc 04 §1 size budget. Add/extend tests as you go.
6. Run the full check suite: `uv run ruff check`, type-check, `uv run pytest`, and the doc 07 §5
   CI gates (state-write grep, `google.adk` import scope, `legacy` import scope, prompt-hash,
   migration up/down). All must pass.
7. Produce a **walkthrough** artifact that maps what you built to the phase's gate criteria, and
   explicitly states whether the gate is met. List anything deferred or flagged to doc 08.
8. **STOP.** Do not begin the next phase. Tell the human the gate status and wait for approval.

## Phase gates (from doc 06 — the agent must demonstrate these)

- **Phase 0** — legacy quarantined; `INVENTORY.md` complete (hashes + `legacy/` paths); scaffold
  boots; `/healthz` green; CI + lint + type-check run; `legacy/` excluded from build.
- **Phase 1** — authenticated request round-trips (identity resolved + cached); all error paths
  return the structured envelope; auth bypass impossible in the cloud profile.
- **Phase 2** — golden-output parity on representative prompts; state written only via
  `append_event`; **zero OCC conflicts** under concurrent/rapid-fire turn tests.
- **Phase 3** — start an execution, end the turn immediately → execution completes, persists, and
  streams UI updates (nothing lost); kill/restart mid-run → resumes from last completed step,
  ≤3 retries, marks `failed` after the 3rd, never re-runs a completed step.
- **Phase 4** — before/after latency trace with the agreed numeric target; no regression vs the
  Phase 2 golden outputs.
- **Phase 5** — parity + latency + robustness all green in a production-like env; load test at
  4–10 concurrent users; rollback plan documented.
