# FALSK Rewrite — 10 · UI Test Suite Spec (React + TypeScript)

> **Goal.** The React UI currently has **no tests**. This spec instructs the coding agent to add a
> **functional** test suite — tests that exercise real user behavior and the app's wiring, not just
> lines-executed — and to enforce **≥ 85% coverage** as a floor in CI. Toolchain is all
> open-source, widely adopted, and CI/GitHub-friendly.
>
> **Relationship to the rest of the rewrite.** This is a **separate workstream** from the FastAPI
> backend rewrite and can run independently (before, during, or after it). The frontend is
> *consumed as-is* (doc 08 Q11) — adding tests, test tooling, and CI is **additive** and does not
> change runtime behavior or the wire contract, so it does not count as "rewriting the frontend."
> Tests live alongside the **UI source tree** (locate it — e.g. a `frontend/`/`web/` dir or the UI
> repo), **not** under the backend `legacy/` quarantine.

## 1. Toolchain (all OSS, strong community, CI-portable)

| Concern | Library | Why |
|---|---|---|
| Test runner | **Vitest** | Native to Vite (shares the app's transform/config — no separate Babel/ts-jest), ESM + TS first-class, Jest-compatible API, fast watch mode. Runs on any Node-based CI. |
| Component testing | **@testing-library/react** (RTL) | Behavior-first: queries the DOM the way a user/assistive-tech does; discourages testing implementation details. |
| User interaction | **@testing-library/user-event** | Simulates real user input (typing, clicking, tab order) more faithfully than `fireEvent`. |
| DOM matchers | **@testing-library/jest-dom** | Readable assertions (`toBeVisible`, `toBeDisabled`, `toHaveTextContent`). |
| Network + WebSocket mocking | **MSW (Mock Service Worker) v2** | Intercepts `fetch`/XHR **and WebSockets** at the network layer, so components are tested against realistic `/api/*` responses and streamed socket events without a live backend. Same handlers reusable in dev. |
| Coverage | **@vitest/coverage-v8** | Built into Vitest; V8 coverage, `lcov` + `text` + `json-summary` reporters for any coverage service. |
| Environment | **jsdom** (or `happy-dom`) | DOM in Node for component tests. |

All are MIT/OSS with large communities and no vendor lock-in. Nothing here ties to a specific CI —
Vitest emits standard `junit` XML and `lcov`, consumable by GitHub Actions, GitLab, Codecov, etc.

**Do not** introduce Jest (redundant with Vitest on a Vite app), Enzyme (unmaintained, implementation-coupled), or Cypress/Playwright *for this spec* — E2E is valuable but out of scope here (this doc is unit/component/integration testing). If the user later wants E2E, that's a separate spec.

## 2. Testing philosophy — functional first (not coverage-chasing)

The point is confidence that **user-facing behavior works**, with coverage as a *byproduct and floor*, not the target.

- **Test behavior, not implementation.** Assert what the user sees and can do (rendered text, roles, enabled/disabled controls, messages appearing), never component internals, state variable names, or private methods. A refactor that preserves behavior must not break tests.
- **Query by accessibility.** Prefer `getByRole` / `getByLabelText` / `getByText` over test-ids; use `data-testid` only as a last resort. This doubles as a light a11y check.
- **Drive with `user-event`.** Interactions go through `user-event` (await it), not synthetic `fireEvent`, so tests reflect real usage.
- **Mock at the network boundary with MSW**, not by stubbing modules. Components exercise their real data-fetching/socket code against MSW handlers. This is what makes the tests *functional* rather than shallow.
- **No coverage-gaming.** Snapshot tests are **not** a substitute for assertions — a giant snapshot inflates coverage while asserting nothing meaningful. Avoid blanket snapshots; if used at all, keep them small and intentional. Every test must assert an observable outcome.
- **Deterministic.** Fake timers for debounce/timeout logic; no reliance on real network, real time, or test ordering. Each test sets up and tears down its own MSW handlers.

## 3. What to test — FALSK UI functional priorities

Cover the real user journeys and the app's stateful wiring. At minimum:

1. **WebSocket session lifecycle (highest priority — it's the core interaction, doc 04 §7):**
   - New session: UI opens with `session_id = "create_new"`, user sends first prompt → assert the server's returned real `session_id` is adopted, the socket is re-established with it as a query param, and the URL updates.
   - Existing session load: socket opens with the `session_id` from the start; prior messages render.
   - One-turn-per-session: while a turn is in flight, the UI reflects the `SESSION_BUSY` rejection appropriately (input disabled / error surfaced).
2. **Streaming event rendering:** simulate a sequence of streamed events (via MSW WebSocket) — plan/DAG updates, incremental agent output, execution progress — and assert the UI renders them incrementally and in order.
3. **Prompt submission:** typing + submit sends the correct message shape on the socket; empty/whitespace input is handled; the input clears/locks as designed.
4. **Plan approval → execution:** approving a plan triggers the correct action and the UI transitions to the executing/streaming state; execution progress and terminal status (completed/failed) render.
5. **Error & resilience paths:** structured error envelopes (`400/422/500`, `SESSION_BUSY`) render user-visible messages (never raw stack traces); socket disconnect/reconnect behavior; loading and empty states.
6. **Session list & snapshot sharing (doc 04 §5.2):** listing only the user's own sessions; the share-snapshot flow and instantiating a new session from a shared snapshot (as far as the UI drives it).
7. **Routing/entry:** the app renders at the base path (no client-side router today — doc 04 §10), and key views mount without crashing given representative props/state.
8. **Pure logic:** any formatters, reducers, hooks, and utility functions get focused unit tests (these are cheap coverage *and* real correctness).

For each: assert the **happy path and at least one failure/edge path**. Functional coverage of error branches is explicitly required — it's where UI bugs hide.

## 4. Structure & conventions

- Co-locate tests as `*.test.tsx` / `*.test.ts` next to the unit under test (or a mirror `__tests__/` — match the app's chosen convention, be consistent).
- A single `src/test/setup.ts` registers `jest-dom`, starts/stops the MSW server (`beforeAll`/`afterEach reset`/`afterAll`), and any global mocks (e.g. `matchMedia`, `scrollTo`).
- MSW handlers live in `src/test/handlers/` (REST) and a WS handler module; export a default happy-path set, and let individual tests override per-case with `server.use(...)`.
- A small set of **render helpers** (a custom `render` that wraps components in the app's real providers/context) so tests mount components as they run in the app.
- Test data builders/factories for domain objects (plans, sessions, events) to keep tests readable.

## 5. Coverage policy — ≥ 85% floor, enforced

- Configure Vitest coverage (`provider: 'v8'`) with **thresholds ≥ 85%** on **all four**: `lines`, `functions`, `branches`, `statements`. CI **fails** below threshold.
- **Branches at ≥ 85% is the meaningful bar** — it forces error/edge paths to be tested, which is where "functional, not just coverage" actually bites. Do not hit 85% lines while leaving branches low.
- **Denominator honesty:** exclude only genuine non-logic from coverage — type-only files, generated code, config, story files, entrypoints like `main.tsx`. **Do not** exclude real components/hooks/utilities to inflate the number; the exclude list is reviewed.
- Coverage is a **floor, not a ceiling or a goal**. A PR that reaches 85% with meaningless tests fails review even if the number is green (see §2 anti-gaming).
- Emit `text` (console), `lcov` (for Codecov/pipeline upload), and `json-summary` (for a PR badge/gate) reporters.

## 6. Config & CI wiring

- **`vitest.config.ts`** (or `test` block in `vite.config.ts`): `environment: 'jsdom'`, `setupFiles: ['src/test/setup.ts']`, `globals: true`, coverage provider `v8` with the thresholds and reporters above, and a sensible `coverage.exclude`.
- **Scripts:** `test` (run once), `test:watch`, `test:coverage`. Also emit `junit` XML for CI test-report surfacing.
- **GitHub Actions** (portable, no lock-in): a `ui-tests` job that installs deps (respecting the repo's package manager), runs `test:coverage`, uploads the `lcov`/`junit` artifacts, and **fails the build on threshold miss or any failing test**. Run it on PRs and on the default branch. If the UI shares the repo with the backend, gate it as its own job so it can run independently of the Python suite.
- Keep it CI-agnostic: everything runs via `npm/pnpm/yarn` scripts, so GitLab CI / CircleCI / etc. can call the same scripts.

## 7. Guardrails for the coding agent

- **U1 — Functional over cosmetic.** Every test asserts observable behavior; no assertion-free snapshots to pad coverage (§2). Reviews reject coverage-gaming even at green thresholds.
- **U2 — Behavior, not internals.** No tests coupled to component internals/implementation; query by role/text; drive with `user-event`.
- **U3 — Network at the boundary.** Use MSW for `/api/*` and for WebSocket event streams; don't deep-stub the app's fetch/socket modules. If MSW's WS API can't model the app's socket usage, wrap the socket client behind a thin interface and inject a fake — document the choice.
- **U4 — ≥ 85% on lines/branches/functions/statements**, enforced in CI, with an honest exclude list (§5).
- **U5 — Additive only.** Adding tests must not change UI runtime behavior or the WS/REST wire contract (doc 08 Q11). If a component is genuinely untestable without a change, prefer a minimal, behavior-preserving refactor (e.g. extract a pure function) and note it; don't alter observable behavior.
- **U6 — Deterministic & isolated.** No real network/time; reset MSW handlers between tests; no inter-test state leakage.
- **U7 — Don't introduce E2E or a second runner.** Vitest + RTL + MSW only for this spec.

## 8. Definition of done (UI-testing gate)

- Vitest + RTL + `user-event` + `jest-dom` + MSW + V8 coverage installed and configured; `test` scripts present.
- All functional priorities in §3 covered with happy-path **and** failure/edge assertions.
- Coverage **≥ 85%** on lines/branches/functions/statements, thresholds enforced in `vitest.config`, CI job fails below.
- The suite runs green in CI (GitHub Actions) with `lcov` + `junit` artifacts published.
- No coverage-gaming (spot-checked in review); tests read as behavior specs a new dev can learn the UI from.
