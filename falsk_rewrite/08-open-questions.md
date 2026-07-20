# FALSK Rewrite — 08 · Open Questions (need Bhargav's answers)

> The interactive clarification did not complete, so the specs proceed on the assumptions in doc 00 §5. Each question below either confirms an assumption or resolves a genuine fork. Answers refine the specs; none block Phase 0–1 from starting.

## A. State, concurrency & background work (highest impact)

1. ~~Concurrent turns on one session~~ **Resolved (Bhargav):** reject the second prompt with a structured `SESSION_BUSY` (409) error. No queuing. (Applied in doc 02 §4 and doc 04 §7.)
2. ~~Immediate in-session reflection~~ **Resolved (Bhargav): "UI needs stream of events displayed."** Interpretation: the requirement is the **live UI event stream**, which is fully covered by the Broadcaster path (workers publish execution/analysis events to Redis → WebSocket → UI) and does **not** require the outbox — workers stream to the UI without ever touching ADK session state (doc 02 §5 rule 3, doc 04 §8). The outbox (doc 02 §6) is only for injecting results into the *agent's conversational memory* before the user's next prompt; that is **not built** — agents pick up results via tools on the next turn (pull model). If a proactive *agent comment* (not just UI events) on job completion is ever needed, reopen this and build the outbox.
3. ~~Crash-recovery policy~~ **Resolved (Bhargav): retry up to 3 times.** On process crash/restart, an interrupted execution is automatically retried up to **3 attempts** (attempt counter on the `executions` row); after the third failure it is marked `failed` and requires explicit user re-trigger. Safety constraint added in doc 02 §7: retries resume from the **last completed DAG step boundary** (never blind-re-run completed liquid-handling steps), and any step that is not verifiably idempotent must require hardware-state confirmation before resuming.
4. **Confirm the OCC root cause.** Is it true that today's orchestration runs sub-agents as **separate `Runner` invocations** (or otherwise reloads the session per agent)? If your current code already runs one invocation and you *still* get OCC, there's a different cause and I need a stack trace / the relevant orchestration code.

## B. Latency (Goal G2)

5. **Numeric target** (doc 03 §7, doc 06 Gate 4): what p50/p95 turn time is "good enough"? (e.g. < 5 min p50.) Needed to define done.
6. **Have you profiled at all?** If you have *any* signal on where the 30 min goes (LLM calls vs tool calls vs DB vs sequential waits), share it — it lets us skip straight to the real bottleneck instead of instrumenting from scratch.
7. **Model tiering tolerance** (doc 03 §7): are you OK with using a faster/cheaper model for mechanical steps if outputs stay equivalent, or must every agent keep its exact current model?

## C. Preservation & scope

8. ~~Frozen-asset source~~ **Resolved:** the coding agent has full access to the old codebase (doc 00 A6); Phase 0 extracts frozen assets directly from it. Remaining sub-question: should the golden outputs for parity testing (doc 03 §8, doc 06 Gate 2) be captured from the **running old system** (preferred — captures true behavior) or reconstructed from logs/DB history?
9. **Vertex AI** (doc 00 A4, doc 01 §6): confirm it's future-seam-only for this rewrite (default), not to be built now.
10. **DB schema freeze** (doc 05): confirm additive-only is acceptable and the existing `sessions`/`users` and other domain tables must be preserved as-is. Any table you *do* want changed?
11. **Frontend contract** (doc 04 §7/§9): is the React frontend also being rewritten, or must the new backend match the **current** frontend's REST/WS contracts exactly? (Specs assume: match current contracts.)

## D. Deployment & authz

12. **Authz rules** (doc 06 §5): can a user see only their own sessions/artifacts, or are sessions shared within a team/org? Affects every session/artifact endpoint.
13. **IAP JWT verification** (doc 04 §5): do you want the backend to cryptographically verify the `X-Goog-IAP-JWT-Assertion` (defense-in-depth), or is trusting the identity headers sufficient (your current approach)?
14. **Cloud Run vs VM** (doc 01 §5): which is the actual target? It affects background-worker lifetime — Cloud Run can suspend/scale instances between requests, which can kill in-process background workers. **If Cloud Run is the target, in-process asyncio workers for long robot runs are risky** and we should discuss a min-instance / always-on worker deployment (still no new broker — just deployment config). This is the one place the "in-process workers" design has a real caveat.

## E. Data analysis specifics

15. Confirm the analysis pipeline scope for parity (doc 06 §6): standard curves, concentration calc, QC — anything else (e.g. specific plate-reader formats, report templates) that must match exactly?

---

**My recommendation on ordering:** answer A1–A4 first — they unblock the highest-risk phases (2 & 3). B5/B7 can wait until Phase 4. D14 matters before you finalize the deployment target.
