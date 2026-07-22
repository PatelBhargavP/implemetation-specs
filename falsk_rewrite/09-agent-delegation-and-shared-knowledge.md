# FALSK Rewrite — 09 · Agent Delegation & Shared Knowledge (frozen custom tools ↔ raw ADK)

> **Why this doc exists.** The legacy agent prompts reference custom tools — `call_<agent_name>` (e.g. `call_planner`) for delegation, and `clear_shared_knowledge` (and, almost certainly, companion read/write operations) for a shared-state blob. Because **prompts are frozen** (doc 00 §4), any tool a prompt names is *also* frozen — the new harness **must** provide a tool of that exact name and equivalent behavior, or the frozen prompt breaks. This doc derives what those tools mean, specifies how to implement them on **raw ADK without a separate `Runner` per call** (preserving the OCC fix), and corrects the delegation model in doc 03 §4.
>
> **Derivation caveat:** the interpretations below are inferred from the prompt fragments Bhargav reported; the coding agent has the legacy code and **must verify exact names, signatures, arguments, return shapes, and lifetimes in Phase 0** (doc 06 §0) and preserve them byte-faithfully. Where this doc and the legacy code disagree, the legacy code wins for *contracts*; this doc governs *how they are re-hosted on ADK*.

## 1. What the discovery changes

Two corrections to earlier assumptions:

1. **Delegation is tool-based, not native transfer.** The Supervisor Agent (orchestrator, doc 03 §4) delegates by **calling `call_<agent_name>` tools**, not via ADK's implicit `transfer_to_agent` / `sub_agents` auto-routing. doc 03 §4's "use `sub_agents`/transfer" is superseded by this doc for the delegation mechanism.
2. **There is a first-class "shared knowledge" state blob.** Agents read/write a shared store during a turn (the old `SharedContext`), and can **clear** it via `clear_shared_knowledge`. The *harness class* `SharedContext` is removed (doc 02 §8), but the *state concept* it exposed is preserved as ADK session state (see §3).

Neither changes the core invariants: **one invocation per turn**, **ADK is the single serial writer**, **background work is decoupled** (doc 02). This doc shows how to honor the frozen tools *within* those invariants.

## 2. `call_<agent_name>` — delegation tools

**Derived meaning:** a tool named `call_<agent_name>` invokes the named specialist agent, passes it the relevant task/context, runs it, and returns its result to the caller (the Supervisor Agent). It is the explicit, prompt-driven delegation primitive.

**How to implement on raw ADK (binding):**

- Implement each `call_<agent_name>` as an **ADK `AgentTool`** wrapping the corresponding sub-agent (or an equivalent thin `FunctionTool` that runs the sub-agent **inside the current `InvocationContext`**). The sub-agent therefore executes **within the same single invocation** as the Supervisor Agent.
- **Never implement `call_<agent_name>` as a fresh `Runner.run_async` or a new session.** That is precisely the multi-writer pattern that risks OCC and violates doc 02 P1 / doc 07 #3. AgentTool runs the sub-agent in-invocation, so ADK remains the single serial writer and applies each `state_delta` through one `append_event` stream.
- **Tool names must match the frozen prompt exactly.** Expose the tool under the literal string the prompt uses (e.g. `call_planner`), not ADK's default AgentTool auto-name. If ADK's default naming differs, set the tool name explicitly so the frozen prompt resolves it.
- **Enumerate every `call_*` tool in Phase 0** and record each one's target agent, arguments, and return shape in `INVENTORY.md`. The set of delegation tools is part of the frozen surface.
- Delegation is still **explicit composition** in `agents/factory.py` (doc 03 §1.1): the factory builds each sub-agent once and attaches the `call_*` AgentTools to the Supervisor Agent. No runtime name→agent dictionary (doc 03 §1.1 still holds).

**Result:** the frozen prompts keep working verbatim ("use tool `call_planner` …"), while the mechanism underneath is single-invocation ADK — parallelism where independent (doc 03 §7) is still available by having the Supervisor issue independent `call_*` tools that ADK can run concurrently, or by composing a `ParallelAgent` behind a single delegation tool.

## 3. "Shared knowledge" — state, not a harness class

**Derived meaning:** a shared store that agents within a turn write to and read from to pass intermediate findings (the old `SharedContext`). `clear_shared_knowledge` empties it; there are very likely companion operations (e.g. `get_shared_knowledge` / `update_shared_knowledge` / `add_to_shared_knowledge`) — **inventory the full set in Phase 0.**

**How to implement on raw ADK (binding):**

- Represent shared knowledge as a **dedicated key (or key namespace) in ADK session state**, e.g. `shared_knowledge` (match the legacy key name if one exists). It is read/written **only** through the sanctioned state paths — `ToolContext` mutations inside these tools, applied via `state_delta` / `append_event` (doc 02 P2). **No direct `session.state[...]` writes**, and **no revived `SharedContext` class** (doc 02 §8, doc 07 #2).
- **`clear_shared_knowledge`** → a tool whose effect is a `state_delta` that clears/resets that key (set to empty). **`get_*`** → reads the key from the current session snapshot. **`update_/add_*`** → a `state_delta` merge. Behavior (merge semantics, whether clear is full or scoped) must match legacy — verify in Phase 0.
- **Lifetime / scope (Phase 0 decision):** determine from the legacy code whether shared knowledge is **turn-scoped** (discarded after the invocation → use the ADK `temp:` prefix) or **persists across turns** (→ unprefixed session state, persisted by `DatabaseSessionService`). Pick the ADK scope that reproduces current behavior; document the choice. If `clear_shared_knowledge` is routinely called at end/'start of a turn, that is a strong signal it is turn-scoped working memory.
- These shared-knowledge tools are **frozen contracts** (named by frozen prompts) — preserve names/signatures; only their *implementation* moves onto ADK state.

## 4. Reconciliation with earlier docs

- **doc 03 §4 (orchestration):** the delegation mechanism is the `call_<agent_name>` **AgentTools**, not implicit transfer. `AgentTool`/`sub_agents`/`ParallelAgent` remain the ADK building blocks, but delegation is driven by the frozen tools. (This doc supersedes the "sub_agents / transfer for delegation" wording there.)
- **doc 02 §8 (Turn-Aware removed):** still correct — the diff-aggregation harness and the `SharedContext` *class* are removed. What survives is the **shared-knowledge state key**, now a normal ADK-state construct with a single serial writer. "Shared knowledge" is *data*; "Turn-Aware" was *machinery* — we keep the data, drop the machinery.
- **doc 02 P1 / P2:** unchanged and reinforced — one invocation, ADK-mediated writes only.
- **doc 03 §1.1–§1.2 (build once, explicit factory, `agent_config.yaml`):** unchanged. The `call_*` tools are wired in the factory alongside each agent.
- **doc 00 §4 / doc 07 #1 (frozen assets):** the `call_<agent_name>` and shared-knowledge tools are explicitly part of the frozen tool surface.

## 5. Implication for the OCC diagnosis (doc 08 Q4)

Bhargav confirmed **the session was *not* reloaded per sub-agent.** So the intra-turn "each agent loads a different snapshot" theory (old background doc) is **disconfirmed** — the agents shared one in-turn reference (consistent with the old Turn-Aware single-reference and with tool-based delegation running in one process context). The concurrency pain therefore came not from per-agent reloads but from:

- **Background writes crossing the turn boundary** (Problem B — the explicitly reported failure), and/or
- any path where a delegated agent's results were persisted to the session through a **separate write** rather than one serialized stream.

The rewrite is robust to both regardless: **one invocation + `call_*` AgentTools in-invocation** makes ADK the single serial writer intra-turn (no separate writes), and **execution/background work is decoupled to the `executions` store** (doc 02 §5), which is the actual fix for Problem B. Net: the single-invocation model is *belt-and-suspenders* even though the original per-reload hypothesis didn't hold. **Action:** in Phase 2, add a test that reproduces the old OCC scenario (whatever concretely triggered it — background write during/after a turn, or a delegated-agent persist) and prove it no longer conflicts (doc 06 Gate 2/3).

## 6. Guardrails (add to doc 07)

- **G-D1** Every tool named by a frozen prompt (all `call_*`, all shared-knowledge tools) **must exist under its exact legacy name** with equivalent behavior. A frozen prompt referencing a missing/renamed tool is a build-blocking error.
- **G-D2** `call_<agent_name>` tools run their target sub-agent **in the current invocation** (AgentTool / in-invocation runner). **Never** a new `Runner`/session (doc 07 #3).
- **G-D3** Shared knowledge lives in **ADK session state** and is mutated **only** via `ToolContext`/`state_delta` (doc 07 #2). No `SharedContext` class, no direct `session.state` writes.
- **G-D4** Phase 0 must inventory the **complete** set of delegation and shared-knowledge tools (names, args, returns, and shared-knowledge scope/lifetime) before any agent code is written.

## 7. Coding-agent checklist

1. Phase 0: enumerate all `call_*` and shared-knowledge tools from `legacy/`; record names/signatures/returns and the shared-knowledge key name + lifetime in `INVENTORY.md`.
2. Build sub-agents in `agents/factory.py`; attach `call_<agent_name>` AgentTools (exact names) to the Supervisor Agent.
3. Implement shared-knowledge tools over an ADK-state key (`temp:` or session-scoped per Phase 0 finding), via `ToolContext`.
4. Contract-test each frozen tool (name/args/return) and assert no `call_*` opens a new Runner (CI grep gate — doc 07 §5).
5. Phase 2: reproduce and refute the original OCC trigger (doc 06 Gate 2).
