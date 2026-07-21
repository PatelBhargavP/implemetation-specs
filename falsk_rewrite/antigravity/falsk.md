---
description: FALSK rewrite — binding guardrails for the coding agent. Always apply.
alwaysApply: true
---

# FALSK rewrite — agent rules

**Copy this file to `.agents/rules/falsk.md` in the code repo.** It is always-on.

Authoritative specs (read before acting; they are the single source of truth):
@docs/specs/README.md
@docs/specs/07-guardrails-for-coding-agent.md

The eight numbered docs (`docs/specs/00`–`08`) govern this rewrite. When a request and a
spec disagree, the spec wins. When a guardrail blocks you, **STOP and record it in
`docs/specs/08-open-questions.md`** — do not deviate or invent a workaround.

## Hard rules (never violate — full list + rationale in doc 07)

1. **Frozen assets are byte-identical.** Agent prompts and tool signatures/return shapes are
   copied verbatim from `legacy/`. No rewording, no "cleanup", no refactor of prompt text.
2. **Never import from `legacy/`.** It is read-only reference. Frozen assets are *copied out*
   (with a content hash recorded in `INVENTORY.md`), never imported or referenced. Do not edit
   anything under `legacy/`.
3. **Never write `session.state[...]` directly.** All ADK state changes go through `output_key`,
   `EventActions.state_delta`, or `ToolContext`/`CallbackContext` (doc 02).
4. **One ADK invocation per turn.** No multi-Runner / multi-session-per-turn orchestration; use
   ADK sub-agent composition inside one invocation (doc 02 P1, doc 03 §4).
5. **Build the agent tree once at startup.** No per-session agent init. Compose explicitly in
   `agents/factory.py`. Remove the old `AGENT_CONFIG` dispatch dict; keep `agent_config.yaml`
   only as the factory's declarative tuning input (doc 03 §1.1–§1.2).
6. **Background workers never touch ADK session state.** `session_service` is not a worker
   dependency; workers write only the `executions` table + GCS and broadcast via Redis (doc 02 §5).
7. **Additive Alembic only.** ADK-owned tables excluded from app autogenerate. Copy the existing
   migration history forward; do not start a fresh Alembic chain (doc 05 §5, doc 06 §0).
8. **No new tables beyond `executions`.** Reuse existing `chat_messages` (UI event stream) and
   `session_metadata` (session extras). No `execution_events`/`analysis_jobs`/outbox (doc 05 §3).
9. **All app endpoints under `/api/*`; FastAPI serves the compiled React build.** No second UI
   service, no client-side router added. Health/readiness stay at root (doc 04 §9–§10).
10. **IAP stays the authenticator.** No in-app login. No new infra beyond Postgres/AlloyDB, Redis,
    GCS (doc 00 NG4/NG5).
10b. **Use the API key manager service as-is.** All API keys come through the existing frozen key
    manager (rotation-aware). Never read keys from env/config in new code, never reimplement key
    loading/rotation, never alter the service (doc 03 §2.1, doc 07 #14).
11. **`uv` for packaging.** `pyproject.toml` + committed `uv.lock`; `uv sync --frozen`; `uv run`.
    No `requirements.txt`/Poetry/`pip install`. `legacy/` excluded from build/lint/tests/Docker.
12. **The monolith must not reappear.** Respect layering and the ~400-line module budget (doc 04 §1).

## Working style

- Work **one phase at a time** (doc 06). Do not cross a phase gate without explicit approval.
- Every file you add must be reachable and used. No unused scaffolds.
- Add the CI enforcement gates in doc 07 §5 during Phase 0 — they are not optional.
