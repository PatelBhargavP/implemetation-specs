# FALSK Rewrite — 03 · Google ADK Integration Spec

> Goal: use ADK **in its raw form** wherever possible. Wrap it behind one module (`AdkRuntime`) so the rest of the app is ADK-agnostic and a future Vertex AI swap is a config change. Do not fork or monkey-patch ADK internals; if ADK lacks something, wrap it, don't reimplement it.

## 1. Package layout for agents (frozen assets live here)

```
app/agents/
  __init__.py
  registry.py            # builds & returns configured agent objects; single source of truth
  orchestrator.py        # root agent definition + composition of sub-agents
  planner/
    agent.py             # LlmAgent config (model, instruction=FROZEN prompt, tools)
    prompt.py            # FROZEN instruction text, verbatim
    tools.py             # FROZEN tool contracts (signatures/return shapes preserved)
  hardware/
    agent.py             # hardware-compiling / device-expert agents
    prompt.py            # FROZEN
    tools.py             # FROZEN
  analysis/
    ...
  shared/
    schemas.py           # pydantic/JSON schemas for tool I/O (must match current contracts)
    callbacks.py         # before/after agent & tool callbacks (telemetry, broadcast hooks)
```

- **Prompts** live in `prompt.py` files as verbatim constants, extracted directly from the old codebase (doc 00 A6). If the current system composes prompts dynamically, port the composition so the rendered string is byte-identical (doc 00 §4). Record the old-repo source path of each prompt in `INVENTORY.md` (doc 06 §0).
- **Tools** keep their exact names, parameters, and return shapes. Re-home implementation code, but do not alter observable behavior. Tools that mutate state do so via `ToolContext` (never direct `session.state` writes).

## 2. The `AdkRuntime` interface (the only ADK boundary)

Every ADK interaction goes through one injected object. Services depend on this interface, not on ADK classes.

```python
class AdkRuntime(Protocol):
    async def run_turn(
        self,
        *,
        app_name: str,
        user_id: str,
        session_id: str,
        new_message: types.Content,   # ADK content built from the user prompt
        on_event: Callable[[Event], Awaitable[None]],  # broadcast hook
        run_config: RunConfig | None = None,
    ) -> TurnResult: ...

    async def get_or_create_session(self, *, app_name, user_id, session_id) -> Session: ...
    async def read_session_state(self, *, app_name, user_id, session_id) -> Mapping: ...  # read-only
```

Implementation `AdkRuntimeImpl` holds a **single process-wide `Runner`** (or a small registry of runners keyed by app) constructed once at startup with:

- `session_service = DatabaseSessionService(db_url=<AlloyDB async URL>)` — bound via config; the interface allows swapping to `VertexAiSessionService` later (doc 01 §6). Reuse one instance for the process; it manages its own connection pool.
- `artifact_service = GcsArtifactService(bucket_name=<cfg>)` — for plots/reports/raw data. `InMemoryArtifactService` in tests, `FileArtifactService`/`InMemory` for local dev by config.
- `memory_service` — only if the current app uses long-term memory; otherwise omit (do not add capability that doesn't exist today).
- Agents from `registry.py`.

**Rules:**
- Construct services **once** (startup/lifespan); never per request. `DatabaseSessionService` and its pool are shared.
- `run_turn` performs exactly one `runner.run_async(...)` and iterates its event stream, calling `on_event` for each. It does not open nested runners.
- No service outside this module imports `google.adk.*`.

## 3. Session & state management via ADK

- **Session identity.** `(app_name, user_id, session_id)` is the ADK key. `user_id` comes from IAP identity (doc 04 §5). `session_id` is the app's session id (the same one in the WS query param / DB `sessions` table). On first message (`create_new` sentinel, doc 04 §7) call `get_or_create_session` to mint it, then return the real id to the UI.
- **State writes** follow doc 02 P2 exclusively: `output_key` for simple agent-output capture, `EventActions.state_delta` for structured/multi-key/scoped updates, `ToolContext`/`CallbackContext` mutations inside tools/callbacks. ADK persists these through `append_event`. **Never** assign to `session.state[...]` on a fetched session.
- **State scoping.** Use prefixes deliberately: unprefixed for session-scoped plan/turn data; `user:` for per-user prefs; `app:` for app-wide constants; `temp:` for values that must not persist beyond the invocation. Document each key the agents rely on in `shared/schemas.py`.
- **Reads outside a turn** (e.g. REST `GET /sessions/{id}`) use `read_session_state`, which returns a read-only view; never write from a read path.

## 4. Orchestration — single invocation, native ADK composition

The orchestrator is the **root agent** of the one invocation per turn (doc 02 P1). Compose sub-agents with ADK's native constructs — **do not** call one agent from another via a fresh `Runner`:

- **`sub_agents` / transfer** for delegation where the orchestrator hands control to a specialist and back.
- **`AgentTool`** to expose a specialist agent as a callable tool of the orchestrator when it should be invoked like a function and its result folded back.
- **`ParallelAgent`** for **independent** hardware-expert / validation steps that can run concurrently within the invocation (primary latency lever — §7).
- **`SequentialAgent`** for fixed ordered pipelines (e.g. parse → design → estimate → validate) where each stage feeds the next.

All of these execute inside the same `InvocationContext`, share one session, and let ADK serialize `state_delta` application. Preserve each agent's *identity and prompt*; only their **composition** is (re)designed here.

**Guardrail:** the number and identity of agents, and each agent's prompt/tools, must match the current system's behavior. Changing *how they're wired* (sequential→parallel where independent) is in-scope; changing *what each agent is or says* is not (doc 07).

## 5. Artifacts via `GcsArtifactService`

- Use ADK artifact APIs (`save_artifact` / `load_artifact`, versioned) for binary/large outputs: generated plots, analytical reports, raw plate-reader data.
- Filename scoping: session-scoped artifacts use plain names; cross-session/user artifacts use the `user:` filename prefix per ADK convention. Record artifact references (bucket path + version) in the domain/execution tables so REST endpoints can list/serve them without going through an agent.
- Large raw data from execution/analysis workers is written to GCS directly by the worker via the same artifact service (or a thin GCS client behind `ArtifactService`), and its reference stored in `execution_events`/`analysis_jobs`.

## 6. RunConfig & safety limits

- Set `max_llm_calls` to a sane ceiling (well below the 500 default if the workflow is bounded) to prevent runaway loops; surface `LlmCallsLimitExceededError` as a structured `409`/`422`.
- `streaming_mode = SSE` for incremental event delivery to the UI (partial events are broadcast but **not** persisted by ADK; only non-partial events carry committed state). Do not treat partial events as state.
- Do not enable experimental features (BIDI, CFC) unless the current app uses them.

## 7. Latency plan (Goal G2) — measure, then parallelize, then tier

**Do not optimize blind (A1).** Order of operations:

1. **Instrument first.** Enable ADK/OpenTelemetry tracing and structured timing around every agent, tool call, LLM call, and `append_event`. Emit per-turn a breakdown: wall-clock per agent, per tool, per LLM call, and DB time. Capture a real 30-min turn trace and attach it to the migration record. **This is a required deliverable before latency work is called done.**
2. **Parallelize independent work.** Convert independent hardware-expert / validation sub-agents from sequential to `ParallelAgent` within the single invocation. This is expected to be the biggest win if experts currently run serially.
3. **Model tiering.** Use a faster/cheaper model (e.g. a Flash-class Gemini) for mechanical/extraction/validation steps and reserve the stronger model for hard design reasoning. Model choice is per-agent config; **prompts stay frozen** — only the `model=` binding changes, and only where it does not alter output contracts. Flag any tiering that risks behavior change in doc 08.
4. **Trim context.** Avoid re-sending unbounded history/state each call; rely on `temp:` for scratch and keep only necessary keys in persisted state. Ensure tools return compact, structured results rather than large blobs (store blobs as artifacts, pass references).
5. **Stream early.** Broadcast the DAG/plan incrementally as events arrive so perceived latency drops even before total time does.

**Acceptance for G2:** a documented before/after trace showing where time went and the effect of parallelization + tiering. A specific numeric target (e.g. "< 5 min p50") should be set with the user (doc 08) rather than assumed.

## 8. Testing the ADK layer

- Unit-test agent *wiring* with `InMemoryRunner` + `InMemorySessionService` + `InMemoryArtifactService`: assert that a turn is a single invocation, that state changes appear only via `append_event`, and that parallel experts run concurrently.
- Contract-test tools against `shared/schemas.py` to prove signatures/returns match the frozen contracts.
- A regression harness compares new-system plan outputs against captured golden outputs from the current system for a set of representative prompts (doc 06 parity).
