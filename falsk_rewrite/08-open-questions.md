# FALSK Rewrite — 08 · Open Questions (mostly resolved)

> Most questions are now answered by Bhargav (marked **Resolved** with the decision and where it's applied). Only **Q4** and **Q8** remain genuinely open; both are low-risk and do not block Phases 0–1.

## A. State, concurrency & background work (highest impact)

1. ~~Concurrent turns on one session~~ **Resolved (Bhargav):** reject the second prompt with a structured `SESSION_BUSY` (409) error. No queuing. (Applied in doc 02 §4 and doc 04 §7.)
2. ~~Immediate in-session reflection~~ **Resolved (Bhargav): "UI needs stream of events displayed."** Interpretation: the requirement is the **live UI event stream**, which is fully covered by the Broadcaster path (workers publish execution/analysis events to Redis → WebSocket → UI) and does **not** require the outbox — workers stream to the UI without ever touching ADK session state (doc 02 §5 rule 3, doc 04 §8). The outbox (doc 02 §6) is only for injecting results into the *agent's conversational memory* before the user's next prompt; that is **not built** — agents pick up results via tools on the next turn (pull model). If a proactive *agent comment* (not just UI events) on job completion is ever needed, reopen this and build the outbox.
3. ~~Crash-recovery policy~~ **Resolved (Bhargav): retry up to 3 times.** On process crash/restart, an interrupted execution is automatically retried up to **3 attempts** (attempt counter on the `executions` row); after the third failure it is marked `failed` and requires explicit user re-trigger. Safety constraint added in doc 02 §7: retries resume from the **last completed DAG step boundary** (never blind-re-run completed liquid-handling steps), and any step that is not verifiably idempotent must require hardware-state confirmation before resuming.
4. ~~Confirm the OCC root cause~~ **Resolved (Bhargav): the session was NOT reloaded per sub-agent.** So the "each agent reloads a different snapshot" theory is disconfirmed. Delegation is via frozen `call_<agent_name>` tools (doc 09); agents shared one in-turn reference. The concurrency pain therefore came from **Problem B (background writes crossing the turn boundary)** and/or delegated results reaching the session via a separate write — not per-agent reloads. The rewrite is robust to both: one invocation + in-invocation `call_*` AgentTools (single serial writer intra-turn) and execution decoupling (doc 02 §5) for Problem B. **Action:** Phase 2 must reproduce the *actual* original OCC trigger and prove it's gone (doc 06 Gate 2/3, doc 09 §5). If you can point at the specific place OCC surfaced (background write vs a delegated persist), note it for that test.

## B. Latency (Goal G2)

5. ~~Numeric target~~ **Resolved (Bhargav): p50 ≈ 15 min.** "Good enough" is a typical turn around **15 minutes** (down from ~30). Set as the Phase 4 acceptance target: **p50 ≤ 15 min** (doc 03 §7, doc 06 Gate 4). p95 not separately specified — track it but gate on p50.
6. ~~Profiling~~ **Resolved (Bhargav): not formally profiled.** No existing breakdown, so the instrument-first step stands (doc 03 §7 step 1) — capture a real slow-turn trace before optimizing. Assumption A1 confirmed.
7. ~~Model tiering tolerance~~ **Resolved (Bhargav): yes.** A faster/cheaper model may be used for **mechanical** steps provided outputs stay equivalent. Tiering is greenlit for extraction/validation/mechanical agents; the hard-reasoning agents keep their stronger model. Prompts stay frozen; only `model=` changes (doc 03 §7 step 3). Any tiering that risks a behavior change still gets flagged before shipping.

## C. Preservation & scope

8. ~~Frozen-asset source~~ **Resolved:** the coding agent has full access to the old codebase (doc 00 A6); Phase 0 extracts frozen assets directly from it. **Still open (low-risk):** should parity golden outputs (doc 03 §8, doc 06 Gate 2) be captured from the **running old system** (preferred — true behavior) or reconstructed from logs/DB history? Recommendation stands: capture from the running system before decommissioning.
9. ~~Vertex AI~~ **Resolved (Bhargav): seam-only.** Keep it in mind so a future move is easy; **do not build it now** (doc 00 NG3, doc 01 §6). Confirms A4.
10. ~~DB schema freeze~~ **Resolved (Bhargav): additive-only, no table changes.** No existing table needs to change; preserve `sessions`/`users` and all domain tables as-is; only additive migrations (doc 05 §5).
11. ~~Frontend contract~~ **Resolved (Bhargav): frontend consumed as-is.** The React frontend is **not** rewritten; the new backend must match the current REST/WS contracts exactly (doc 04 §7/§9, doc 00 §4).

## D. Deployment & authz

12. ~~Authz rules~~ **Resolved (Bhargav): owner-only + snapshot sharing.** A user sees **only their own** sessions/artifacts. Session sharing works by **creating a snapshot** and sharing it; the recipient uses that snapshot to **create a new session** of their own (no shared live session). Applied: owner-scoped authz on every session/artifact endpoint (doc 04 §5/§9); the snapshot-share mechanism is existing behavior preserved via `session_metadata` (doc 05 §2), extracted in Phase 0.
13. ~~IAP JWT verification~~ **Resolved (Bhargav): trust headers.** Trusting IAP identity headers is sufficient; the backend does **not** cryptographically verify `X-Goog-IAP-JWT-Assertion`. (Kept as an easy future add-on, not built — doc 04 §5.)
14. ~~Cloud Run vs VM~~ **Resolved (Bhargav): VM.** No hard platform commitment, but staying on **VM** for the long-lived WebSocket advantage. This makes the **in-process asyncio background workers viable as specified** — a VM instance is long-lived, so execution workers survive across turns (doc 01 §5, doc 02 §5). Note retained for the future: if Cloud Run is ever adopted, long robot runs need a min-instance/always-on worker deployment (config only, no new broker).

## E. Data analysis specifics

15. ~~Analysis pipeline~~ **Resolved (Bhargav): analysis is a sub-agent, preserved.** Data analysis is performed by an **ADK sub-agent** (its prompt + tools are frozen assets), **not** a separate LLM-bypassing background worker. Applied: analysis runs inside the single-invocation turn model as a frozen sub-agent in the agent tree; the earlier `AnalysisWorker`/analysis-as-background-job modeling is removed (doc 01 §3.3, doc 02 §3, doc 05 §3, doc 03 §1). Standard curves / concentration / QC math stays byte-faithful (doc 00 §4). *If* analysis on very large datasets ever needs to run detached from a turn, raise it then — default is in-turn.

---

**Remaining open (low-risk, non-blocking):**
- **Q8 — parity golden source.** Prefer capturing goldens from the running old system before it's decommissioned.
- **Q4 follow-up (optional):** if you can pinpoint *where* OCC actually surfaced (a background write, or a delegated-agent persist), note it so Phase 2's regression test targets the real trigger (doc 09 §5). Not a blocker.

Everything else is resolved and reflected in the specs (delegation & shared-knowledge tools now covered by doc 09).
