# FALSK Rewrite — Specs & Implementation Plan

A spec suite for rewriting FALSK (lab-automation experiment planner) from the current Quart monolith to a modular **FastAPI** application using **Google ADK** in raw form. Written to be executed by a coding agent (Antigravity) that **has full access to the old codebase**: the old repo is the extraction source for frozen assets (prompts, tool contracts, schema, API/WS contracts) and a behavioral reference for parity — but its harness code is not to be ported. The specs are prescriptive and include binding guardrails (doc 07).

## The three problems this rewrite solves
1. **~30-min planning turns** → measure-first instrumentation, parallel sub-agent fan-out, model tiering (doc 03 §7).
2. **State/OCC fragility + lost background updates** → ADK single-invocation turns, per-session serialization, and a decoupled durable-execution store so background work never races or loses writes (doc 02).
3. **2k-line monolith** → layered FastAPI (routers→services→repos), ADK isolated behind one module (doc 04).

## Read order
- **00 — Overview, scope & preservation boundary.** What's frozen vs rewritten. Start here.
- **01 — Target architecture.** Components, flows, deployment, Vertex AI seam.
- **02 — State & concurrency.** ⭐ The centerpiece: OCC fix + background-write pattern.
- **03 — ADK integration.** Runner, session/artifact services, orchestration, latency plan.
- **04 — FastAPI backend.** Layout, IAP auth, structured errors, WebSocket lifecycle.
- **05 — Data model.** Preserved schema + additive execution/outbox tables, Alembic policy.
- **06 — Migration plan.** Phased, gated, parity-checked.
- **07 — Guardrails.** Binding rules + CI enforcement for the coding agent.
- **08 — Open questions.** Needs Bhargav's answers; assumptions are flagged.

## Key architectural decisions (rationale in the docs)
- **One `Runner.run_async` invocation per turn**, sub-agents composed inside it → ADK is the single serial state writer → intra-turn OCC is structurally impossible (doc 02 §1–4).
- **Execution/analysis state lives in dedicated tables, not ADK session state**; background workers never write ADK sessions → "turn ends before job finishes" stops being a failure mode (doc 02 §5).
- **Per-session cross-instance advisory lock** serializes turns (doc 02 §4).
- **Preserve** prompts, tool contracts, DB schema, and frontend contracts; **rewrite** only the harness (doc 00 §4).
- **Vertex AI + remote execution are seams, not built** (doc 00 NG3, doc 01 §6).

> Open assumptions (doc 00 §5) and questions (doc 08) should be resolved with Bhargav; none block starting Phase 0–1.
