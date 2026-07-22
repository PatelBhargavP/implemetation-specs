# FALSK Rewrite — 03 · Google ADK Integration Spec

> Goal: use ADK **in its raw form** wherever possible. Wrap it behind one module (`AdkRuntime`) so the rest of the app is ADK-agnostic and a future Vertex AI swap is a config change. Do not fork or monkey-patch ADK internals; if ADK lacks something, wrap it, don't reimplement it.

## 1. Package layout for agents (frozen assets live here)

```
app/agents/
  __init__.py
  factory.py             # build_root_agent(config) -> BaseAgent : composes the tree EXPLICITLY, once
  supervisor_agent.py    # root agent — the "Supervisor Agent" (a.k.a. orchestrator); its name is FROZEN
  planner/
    agent.py             # def build_planner(cfg) -> LlmAgent (model, instruction=FROZEN prompt, tools)
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

### 1.1 Agent lifecycle — build once, no per-session init, no name→directory dictionary

**Binding decisions (do not deviate — doc 07):**

1. **Agents are stateless, reusable definitions.** All per-turn/per-session state lives in the ADK `InvocationContext` and the session (via `session_service`) — **never** on an agent object. Do not store anything mutable and session-specific as agent instance state.
2. **Build the agent tree exactly once, at process startup** (FastAPI lifespan), and share the single tree across all sessions and all concurrent turns. The tree is held on `AdkRuntime` alongside the single `Runner` (§2). **Do NOT re-initialize or re-instantiate agents when a new session starts** — that is wasted allocation and a concurrency-bug vector under multi-user load. A new session is just a new `session_id` handed to the same `Runner` + same tree.
3. **Composition is explicit, not reflective.** `factory.py` exposes a single `build_root_agent(config) -> BaseAgent` that imports each leaf agent's `build_*` function and wires the tree with ADK-native constructs (`sub_agents=[...]`, `AgentTool`, `ParallelAgent`, `SequentialAgent` — §4). **Remove the old `{name → identifier/description → directory}` dictionary and any directory-autoload / reflection mechanism.** The tree itself is the single source of truth; ADK resolves delegation/transfer by `agent.name` within the reachable tree, so no external lookup dict is needed for wiring.
4. **Adding or changing an agent** = create/edit its module + `build_*` function and wire it into `factory.py`. This must be visible in one place and type-checked — no runtime name-string indirection.

### 1.2 `AGENT_CONFIG` object → removed. `agent_config.yaml` → retained as the factory's declarative tuning source

Two distinct things in the old code, with opposite fates:

- **`AGENT_CONFIG` (the in-code object): REMOVE.** This is the name→identifier→description→directory dispatcher (§1.1 rule 3). It is deleted along with any directory-autoload/reflection. The agent tree in `factory.py` is the single source of truth; ADK resolves delegation by `agent.name`, so no dispatch dict is needed.
- **`agent_config.yaml` (the tuning file): KEEP.** This is the legitimate declarative per-agent tuning table, and it becomes the factory's build-time input.

Rules for `agent_config.yaml`:

- **What it holds:** per-agent knobs only — model / model-tier, temperature, `max_tokens` / token limits, and *which* frozen tools attach to which agent (by frozen tool identifier). These are the harness-level settings the rewrite is allowed to tune (e.g. model tiering for latency, doc 03 §7).
- **What it must NOT hold:** prompt text or tool implementations. Those stay as frozen constants in each agent's `prompt.py` / `tools.py` (doc 07 #1) — the single source of truth. The YAML may *reference* a tool by its frozen identifier to attach it, but never redefine it, and must not carry directory/dispatch mappings (that's the removed `AGENT_CONFIG` concern).
- **How it's used:** loaded and **parsed into typed, validated specs once at startup** (e.g. pydantic models); `factory.build_root_agent()` consumes those specs and wires each `LlmAgent`/composite. No runtime name-string lookup, no reflection, no directory autoload. A malformed YAML fails fast at startup, not at first turn.
- **Enumeration:** if the UI/API must list agents with descriptions, **derive** it by walking the built tree, not from the YAML and not from a second dict.

**Sanctioned extension:** if the *set* of agents must additionally vary at runtime (e.g. experiment-type-specific expert panels), the factory may select a subset driven by this same YAML config — still no parallel dispatch dict. If you believe runtime-dynamic *selection* (beyond static tuning) is required, raise it in doc 08 before building it.

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
- The root agent tree from `factory.build_root_agent(config)`, **built once here at startup** and reused for every session/turn (§1.1).

**Rules:**
- Construct services **once** (startup/lifespan); never per request. `DatabaseSessionService` and its pool are shared.
- `run_turn` performs exactly one `runner.run_async(...)` and iterates its event stream, calling `on_event` for each. It does not open nested runners.
- No service outside this module imports `google.adk.*`.

### 2.1 API keys come from the existing key-manager service (frozen, rotation-aware)

- The model/LLM credentials ADK uses (e.g. Gemini API keys) are supplied **exclusively by the existing API key manager service** (doc 00 §4, frozen). The key manager is injected into `AdkRuntimeImpl`; agent/model construction obtains keys from it. Keys are **never** read from env vars or config files by new code, and the key manager is **not** reimplemented or modified.
- **Rotation safety:** the key manager performs rotation, so a key must not be snapshotted once at process start and cached forever. Obtain the current key at the point of use per the manager's contract (fetch-on-use, or subscribe to its refresh callback / short-TTL accessor) so a rotation takes effect without a restart. If model clients are built once at startup, they must pull the live key from the manager on each call (or be rebuilt on rotation) — confirm the manager's exact interface in Phase 0 inventory (doc 06 §0) and wire whichever pattern it supports.
- Construct the key manager **once** in lifespan (a shared singleton) and pass it through the DI container (doc 04 §3); do not instantiate it per request or per turn.

## 3. Session & state management via ADK

- **Session identity.** `(app_name, user_id, session_id)` is the ADK key. `user_id` comes from IAP identity (doc 04 §5). `session_id` is the app's session id (the same one in the WS query param / DB `sessions` table). On first message (`create_new` sentinel, doc 04 §7) call `get_or_create_session` to mint it, then return the real id to the UI.
- **State writes** follow doc 02 P2 exclusively: `output_key` for simple agent-output capture, `EventActions.state_delta` for structured/multi-key/scoped updates, `ToolContext`/`CallbackContext` mutations inside tools/callbacks. ADK persists these through `append_event`. **Never** assign to `session.state[...]` on a fetched session.
- **State scoping.** Use prefixes deliberately: unprefixed for session-scoped plan/turn data; `user:` for per-user prefs; `app:` for app-wide constants; `temp:` for values that must not persist beyond the invocation. Document each key the agents rely on in `shared/schemas.py`.
- **Reads outside a turn** (e.g. REST `GET /sessions/{id}`) use `read_session_state`, which returns a read-only view; never write from a read path.

## 4. Orchestration — single invocation, native ADK composition

> **Naming:** the root/orchestrator agent is called the **Supervisor Agent** in the codebase (legacy and new). Throughout these specs "orchestrator" is a **role label** for this same agent — not a second agent and not a rename. Its ADK `name` (and prompt) is a **frozen asset**: extract the exact identifier string from `legacy/` in Phase 0 and preserve it byte-identical, because ADK resolves sub-agent delegation/transfer by `agent.name` (doc 00 §4, doc 03 §1.1). Do **not** confuse it with the background-worker supervisor (`workers/worker_supervisor.py`, doc 04 §1) — different thing entirely.

The **Supervisor Agent (orchestrator)** is the **root agent** of the one invocation per turn (doc 02 P1). Compose sub-agents with ADK's native constructs — **do not** call one agent from another via a fresh `Runner`:

> **Delegation is tool-based (doc 09).** FALSK's frozen prompts delegate by calling **`call_<agent_name>` tools** (e.g. `call_planner`), not via implicit `transfer`. Implement each as an **`AgentTool`** (or in-invocation runner) under the **exact frozen tool name**, running the sub-agent inside the current invocation. See doc 09 for the full mechanism, the shared-knowledge tools, and the guardrails. The constructs below are the ADK building blocks those tools are built from.

- **`AgentTool`** — the primary mechanism: expose each specialist agent as a `call_<agent_name>` tool of the Supervisor, invoked like a function with its result folded back, **within the one invocation** (doc 09 §2).
- **`sub_agents`** composition wires the tree; ADK's implicit `transfer` is **not** the delegation path here (the `call_*` tools are).
- **`ParallelAgent`** for **independent** hardware-expert / validation steps that can run concurrently within the invocation (primary latency lever — §7).
- **`SequentialAgent`** for fixed ordered pipelines (e.g. parse → design → estimate → validate) where each stage feeds the next.

All of these execute inside the same `InvocationContext`, share one session, and let ADK serialize `state_delta` application. Preserve each agent's *identity and prompt*; only their **composition** is (re)designed here.

**Guardrail:** the number and identity of agents, and each agent's prompt/tools, must match the current system's behavior. Changing *how they're wired* (sequential→parallel where independent) is in-scope; changing *what each agent is or says* is not (doc 07).

## 5. Artifacts via `GcsArtifactService`

- Use ADK artifact APIs (`save_artifact` / `load_artifact`, versioned) for binary/large outputs: generated plots, analytical reports, raw plate-reader data.
- Filename scoping: session-scoped artifacts use plain names; cross-session/user artifacts use the `user:` filename prefix per ADK convention. Record artifact references (bucket path + version) in the domain/execution tables so REST endpoints can list/serve them without going through an agent.
- Large raw data from execution/analysis workers is written to GCS directly by the worker via the same artifact service (or a thin GCS client behind `ArtifactService`), and its reference stored in `executions.result_refs`.

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

**Acceptance for G2:** a documented before/after trace showing where time went and the effect of parallelization + tiering, meeting the target **p50 ≤ 15 min** per turn (confirmed — doc 08 Q5; down from ~30 min). Track p95 but gate on p50. Model tiering for mechanical steps is approved (doc 08 Q7); no formal profile exists yet (doc 08 Q6), so the instrument-first step is mandatory.

## 8. Testing the ADK layer

- Unit-test agent *wiring* with `InMemoryRunner` + `InMemorySessionService` + `InMemoryArtifactService`: assert that a turn is a single invocation, that state changes appear only via `append_event`, and that parallel experts run concurrently.
- Contract-test tools against `shared/schemas.py` to prove signatures/returns match the frozen contracts.
- A regression harness compares new-system plan outputs against captured golden outputs from the current system for a set of representative prompts (doc 06 parity).
