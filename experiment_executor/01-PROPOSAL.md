# Experiment Executor — Architecture Proposal (POC)

**Status:** Draft for review — revision 2 (user-identity architecture)
**Date:** 2026-08-19
**Scope:** Proof of concept. Explicitly not production-ready. Every deferred decision is listed in §10 with its upgrade path.

---

## 1. Problem

Lab operators need to run liquid-handling protocols on robots attached to a lab computer. Protocols live in Google Cloud Storage and are grouped by **workcell** (a workcell is a physical robot plus its deck configuration). A workcell has many protocols. A computer drives exactly one workcell.

Two properties drive the design:

1. **Workcell ↔ computer is 1:1.** A machine must only ever show and run protocols for its own workcell. Presenting a protocol built for a different deck layout is a physical hazard, not a UX bug.
2. **Lab computers change.** Machines get reimaged, replaced and moved. Binding must be re-establishable without a code change or a rebuild.

## 2. What changed in revision 2, and why

Revision 1 gave every workcell a service account, put its key on the lab machine, and derived the workcell from that credential. Revision 2 replaces this with **human Google login through IAP**.

| Rev 1 | Rev 2 | Why |
|---|---|---|
| Per-workcell service account key on each machine | **Operator signs in with their own Google account** | Removes key generation, distribution, rotation and the whole TPM upgrade path. Turns the weakest part of rev 1 — "typed email is identification, not authentication" — into real authentication. |
| Workcell derived from the credential | **Workcell from local config, authorised by the user's role** | Access control moves to the user. Workcell binding becomes a *safety* control rather than an *access* control (§4.4). |
| `machines` table keyed by SA email | **Collapsed into `workcells`** | With identity no longer coming from the machine, and the relationship 1:1, a separate table earned nothing. Nine tables become eight. |

This is a net **reduction** in build size. What it adds is one OAuth loopback flow.

Retained from revision 1 without change: the control-plane API boundary, subprocess execution with the full abort ladder, deck quarantine, protocol generation pinning, and the offline event spool. Those were never about identity.

### 2.1 Two alternatives considered and rejected

**Client connects directly to AlloyDB.** Rejected. Google's language connector "does not provide a network path to an AlloyDB instance if one is not already present" — it supplies mTLS and IAM, not connectivity. A private-IP instance is simply unreachable from a lab network, so this would require enabling **inbound public IP on an instance already shared with other experimental applications**, changing their exposure for this POC's benefit. Beyond that: workcell scoping would be lost entirely (any client that reaches the database reads every workcell, recoverable only via per-workcell Postgres roles and RLS — more work than the API it replaces), schema would couple to a client that cannot be force-upgraded, and there would be nothing for IAP to protect.

**Drop the API, keep only the desktop app.** Rejected for the same reason. The control plane is roughly eight endpoints of authorisation and validation with no business logic; the expensive components are the PySide6 app, the runner, and the abort machinery. Removing the API does not meaningfully reduce the build, and it removes the only place server-side enforcement can live.

## 3. System context

```
┌───────────────────────────────────────┐
│  Lab computer (Linux)                 │
│  ┌─────────────────────────────────┐  │
│  │  Executor app (PySide6)         │  │
│  │  ├─ OAuth loopback → browser    │  │
│  │  ├─ UI thread                   │  │
│  │  └─ Runner subprocess ──────────┼──┼──► Hamilton STAR
│  └─────────────┬───────────────────┘  │     (PyLabRobot)
│                │                      │
│  /etc/experiment-executor/config.toml │
│      workcell_id, oauth client        │
└────────────────┼──────────────────────┘
                 │ HTTPS, user ID token
                 │ (aud = OAuth client ID)
                 ▼
┌───────────────────────────────────────┐
│  External HTTPS LB + IAP              │
│  authenticates the human,             │
│  injects x-goog-iap-jwt-assertion     │
└────────────────┬──────────────────────┘
                 ▼
┌───────────────────────────────────────┐
│  Control plane (Cloud Run)            │
│  --no-allow-unauthenticated           │
│  ingress: LB only, no default URL     │
│  + Direct VPC egress                  │
└──────┬──────────────────────────┬─────┘
       │ private IP               │
       ▼                          ▼
┌─────────────────┐      ┌──────────────┐
│ AlloyDB         │      │ GCS          │
│ (shared inst.)  │      │ protocols/   │
│                 │      │ run-logs/    │
└─────────────────┘      └──────────────┘
```

No service account key exists on the lab machine. No database credential exists on the lab machine. The only local state is a config file naming the workcell and the OAuth client.

## 4. Identity, authorisation and workcell binding

### 4.1 Sign-in

On launch — and whenever the cached token has expired — the app runs the **OAuth 2.0 loopback flow for desktop apps**:

1. App starts a local HTTP listener on `127.0.0.1:<port>` and opens the system browser.
2. Operator signs in with their Google Workspace account.
3. App exchanges the authorization code for an **ID token** and a refresh token, requesting `scope=openid email` and `access_type=offline`.
4. The ID token is sent to the control plane as `Authorization: Bearer <id_token>`.

The OAuth client is of type **Desktop app**, and the loopback redirect is the current supported pattern — the manual copy/paste (OOB) method is no longer supported, and the separate loopback deprecation applies only to iOS, Android and Chrome client types, not desktop.

ID tokens last about an hour and are renewed from the refresh token with no user prompt.

> **Provisioning trap, and it is project-stopping.** The OAuth client ID must be added to IAP's `programmatic_clients` allowlist. Google's documentation carries this instruction in the desktop *user-account* section, not only the service-account sections. Without it, every lab machine is rejected at the edge with no application log to inspect.

### 4.2 What the control plane trusts

IAP validates the token and injects `x-goog-iap-jwt-assertion` — a signed JWT the control plane verifies independently. For a Workspace user its `email` claim is the plain address with no namespace prefix, unlike the unsigned `x-goog-authenticated-user-email` header, which is prefixed and is not used anywhere in this design.

```
IAP assertion email  →  users.email  →  user_workcells(role) for the requested workcell
```

The service is deployed `--no-allow-unauthenticated` with `--ingress internal-and-cloud-load-balancing` and `--no-default-url`, satisfying the organisation's prohibition on unauthenticated ingress. Because IAP substitutes its own identity before Cloud Run's IAM check, `roles/run.invoker` is granted to **IAP's service agent**; human operators receive `roles/iap.httpsResourceAccessor`.

### 4.3 What each principal can actually reach — read this before granting anything

The most consequential property of this architecture is easy to accidentally undo with a well-meaning IAM grant. Stated explicitly:

| Principal | Can reach | Must **never** be granted |
|---|---|---|
| **Operator (human Google account)** | The control plane, through IAP. Nothing else. | `roles/alloydb.databaseUser`, `roles/alloydb.client`, `roles/storage.objectViewer`, or any direct data-plane role |
| **Control-plane service account** | AlloyDB (IAM auth) and GCS. Never leaves Cloud Run. | — |
| **IAP service agent** | Invokes Cloud Run (`roles/run.invoker`) | — |
| **The lab machine itself** | Nothing. It holds no identity of its own. | — |

**Operators do not have database access and do not have GCS access.** The desktop app ships no database driver and no GCS client. Every read and write goes through the control plane, which is the only component holding data-plane credentials, and which authorises each request against the operator's role before touching anything.

Protocol scripts are downloaded using **short-lived signed URLs** — five minutes, one object, pinned to a specific generation — minted by the control plane *after* the role check passes. The operator therefore gets time-boxed access to exactly the object they were authorised for, and never a standing GCS permission. Run logs work the same way in reverse (§6.8).

> Granting an operator `storage.objectViewer` on the protocol bucket, or adding them as an AlloyDB IAM user, would let the desktop app bypass every server-side check in this design — workcell scoping, role enforcement, deck quarantine and run recording all live in the control plane. If a future requirement seems to need direct access, that is a signal to add an endpoint, not a grant.

### 4.4 Users are created on first contact, but never granted anything

The first time an authenticated email is seen, a `users` row is created automatically. **No role is granted with it.** A brand-new user can authenticate and reach the API, and can do nothing at all until an administrator inserts a `user_workcells` row.

This distinction is the whole security model: IAP controls *who can reach the service*, and `user_workcells` controls *what they can do*. Auto-creating the user row is a convenience that saves pre-registering staff; auto-granting a role would collapse the two layers into one and make IAP the only gate.

### 4.5 Workcell binding is a physical check — accepted decision

`workcell_id` comes from `/etc/experiment-executor/config.toml`, written by an administrator at provisioning time. It is client-asserted, which revision 1 deliberately avoided.

**This has been reviewed and accepted.** The reasoning: no hardware identity is bound to a workcell — no instrument serial number, no USB device signature, nothing the software can independently observe. So even a cryptographic machine credential would only prove *which credential file is present*, not *which robot is plugged in*. Correctness of the mapping is a physical fact verified by a human at provisioning time, and adding a credential would move the check without eliminating it.

The server still authorises every request: it checks that *this user* holds an executing role on *the workcell being claimed*. A machine claiming the wrong workcell cannot reach data its operator was not already entitled to. **The residual risk is not disclosure — it is physical:** a machine wired to workcell A's robot but configured as workcell B offers B's protocols, and an operator may run a protocol built for a different deck layout on the wrong instrument.

Mitigations, proportionate to a POC:

- The config file is administrator-written and root-owned; operators never edit it.
- **The workcell name is displayed persistently in the title bar** and on the confirmation screen before any run starts. The likeliest error in this system is a correct protocol at the wrong instrument, and the interface should make that hard to miss.
- The workcell's `last_hostname` is recorded on every heartbeat, so a workcell suddenly reporting from a different machine is visible to administrators.

**Future hardening, if wanted:** bind an actual hardware identifier — instrument serial read over the backend connection at preflight, compared against a value stored on the workcell row. That closes the loop properly, because it observes the robot rather than the file. A per-machine credential does not, which is why it is not the recommended upgrade.

### 4.6 Re-provisioning a machine

The case that motivated the original design, now trivial: install the app, write `config.toml` with the workcell ID and OAuth client, done. No keys to generate, copy, or revoke. Operators sign in with credentials they already have, and an operator who leaves the organisation loses access through normal Workspace offboarding rather than through anything this system does.

## 5. Operators and roles

Roles are `viewer`, `operator`, `admin`, scoped per workcell in `user_workcells`. `operator` and `admin` may execute; `viewer` may not.

> Revision 1's `viewer / editor / executor` had both editor and executor able to run, and nothing in the app to edit.

**Operator identity is now genuinely authenticated.** The run record attributes work to a Google-verified identity rather than a typed string, which removes the largest piece of accepted debt in revision 1 and is a precondition for any future GxP conversation.

The token lifetime doubles as the session boundary that revision 1 lacked: the app holds the refresh token in memory only and does **not** persist it, so closing the app ends the session. On a shared lab machine this is the desired behaviour — the next operator signs in as themselves. An explicit **Sign out** control is available for shift handover.

## 6. Execution and abort — the safety-critical part

**Target backend: Hamilton STAR**, with a second backend expected later, so the design is adapter-based (§6.6).

### 6.1 What PyLabRobot actually gives you

PyLabRobot (0.2.2) is a fully `async`/`await` API. A protocol is a sequence of awaited atomic commands:

```python
await lh.setup()
await lh.pick_up_tips(tip_rack["A1"])
await lh.aspirate(plate["A1"], vols=100)
```

Source review of `STARBackend` and `HamiltonLiquidHandler` settles the abort question:

- **`stop()` transmits nothing to the instrument.** It stops the host-side USB reader thread and fails pending futures with `RuntimeError`. A firmware command the STAR has already accepted runs to completion regardless.
- **No abort, halt, cancel or e-stop method exists** on either class.
- **No interactive error recovery.** VENUS offers the operator resume/ignore/abort on a fault; PyLabRobot surfaces faults as raised Python exceptions (`STARFirmwareError`, `ChannelizedError`, ~49 `STARModuleError` subclasses) and nothing more.
- **The cover interlock is not pollable.** It appears after the fact as `CoverCloseError` on the *next* command.
- Raw firmware access does exist (`send_command(module, command, …, wait=False)`), so an abort could in principle be sent — but no such command is documented in PyLabRobot, and speculatively firing raw firmware at a live instrument is not an acceptable way to find out.

Consequences:

- Cancellation lands **between** atomic commands. A 96-channel aspirate or a long gantry move finishes no matter what the software wants.
- Killing the Python process does not stop the robot.
- **Physically halting a moving STAR means the hardware e-stop or cover.** This belongs in operator training. Nothing in the UI may imply software can stop the instrument.

### 6.2 The failure mode this creates

`STARBackend.setup()` carries this verbatim comment in the source:

> `# After setup, STAR will have thrown out anything mounted on the pipetting channels, including the core grippers.`

Inside `setup()`, detected tips *trigger* the ejection sequence: `if not initialized or any(tip_presences): await self.initialize_pip()`. A maintainer reports CoRe grippers being discarded into waste bins "countless times." A separate report describes `initialize_pip()` hardcoding `tip_type=4` (high-volume) when planning its descent to the waste bin, bringing mounted grippers within ~1 cm of colliding with the trash edge — because grippers are far taller than the assumed tip.

**After an incomplete stop, the robot's physical state is unknown to the software, and the next `setup()` is the dangerous moment — not the abort itself.** Any design where "stop" means "kill the PID" and the next run starts normally is a hardware-damage path.

The mitigation is `request_tip_presence()`, which returns per-channel tip state. Used *before* `setup()`, it converts deck quarantine from an operator promise into a machine check — see §6.6.

### 6.3 The design

**Protocols run in a dedicated subprocess.** Not a `QThread` — Python threads cannot be killed, and a hung protocol would take the UI down with it. The runner is its own process, in its own process group, communicating with the UI over newline-delimited JSON on stdout/stdin.

The abort sequence, in order:

1. **Operator confirms.** The dialog states plainly that the run cannot be resumed and the deck will need manual inspection.
2. **Cooperative cancel.** The UI writes `{"t":"abort"}` to the runner's stdin. The runner sets an abort event; the protocol wrapper checks it before each atomic command and raises `ProtocolAborted`. The current command still finishes.
3. **Graceful teardown.** The runner catches `ProtocolAborted` and makes a best-effort `await lh.stop()` to close the connection cleanly, then reports `aborted` and exits 0.
4. **Escalation.** If the runner has not exited within 30 s, `SIGTERM` to the process group; after a further 10 s, `SIGKILL`. The run record captures which rung was reached — that is the "where it was interrupted" metadata.
5. **Quarantine.** The workcell transitions to `deck_state = NEEDS_ATTENTION`. **The app refuses to start any new run** until an operator explicitly acknowledges that the deck has been physically inspected and reset. That acknowledgement is itself an audited event.

Step 5 matters most and is the one most likely to be dropped as "we'll add it later." It is the only thing standing between an aborted run and the collision in §6.2.

### 6.4 Run integrity

Protocols are Python executed against hardware, so provenance is not optional even in a POC:

- Bucket has **object versioning** enabled.
- Reads are **pinned to a specific GCS generation**, never "latest". The generation and `crc32c` are recorded on the run row.
- The **input schema is versioned with the script** — same registration, same generation. Schema and code cannot drift apart.

This makes "what code actually ran on this plate?" answerable months later, which is the first question anyone asks when a result looks wrong.

### 6.5 Concurrency and crash recovery

- **One run at a time per workcell**, enforced twice: a local `flock` on a lockfile, and a partial unique index in Postgres permitting at most one non-terminal run per workcell. The hardware is 1:1, so a second concurrent run must be structurally impossible, not merely discouraged.
- **Heartbeats.** Active runs heartbeat every 30 s on a **dedicated endpoint**, not as a side effect of event traffic — a single long plate-level command can emit nothing for minutes, and liveness must not depend on chattiness. A sweep marks runs with no heartbeat for 5 minutes as `UNKNOWN`.
- **Startup reconciliation.** On launch the app asks for any non-terminal run for its workcell. If one exists it did not end cleanly: it is closed out as `UNKNOWN` and the workcell goes to `NEEDS_ATTENTION`.

### 6.6 Preflight, and why it lives in the app rather than the protocol

Before any run, the runner asks the instrument whether it is physically clean. On STAR that is `request_tip_presence()`; the result is `clean`, `dirty`, `unsupported` or `error`, and anything other than `clean` stops the run **before `setup()` is called** — nothing moves.

This check is deliberately **not** the protocol author's responsibility, and not a registration-time check:

- **Ordering forbids it.** Preflight must precede `setup()`. Protocol code runs after the handler exists — it is the thing being gated, so it cannot be the gate.
- **Safety invariants must not be delegable.** One author who forgets reintroduces the hazard for one protocol, which is the worst failure distribution because everything else still looks correct.
- **Registration cannot know runtime state.** Whether tips are mounted *right now* is a physical fact at run time.
- **Protocols must stay portable.** Backend-agnosticism is PyLabRobot's central value; STAR-specific calls in protocol code destroy it.

**Genericity across backends is preserved by an adapter, not by pushing work into protocols.** Instrument-specific knowledge is confined to a `BackendAdapter` — `connect`, `preflight`, `teardown`, plus capability flags. The app, the API and the schema know only the four-valued result. Adding the second backend is one new file and one registry line.

Backends that cannot introspect return `unsupported`, and the app falls back to a blocking operator confirmation recorded on the run. A check that *failed* is treated as `dirty`, never as a pass.

### 6.7 Network loss

Labs lose network. The protocol and its schema are fetched **in full before the run starts**, so a mid-run outage cannot stall the robot. Run events are appended to a local SQLite spool and flushed on a background task; a failed API write **never** aborts a run and never blocks the UI.

> **One consequence of user login worth planning for:** if the network drops and the ID token expires mid-run, the app cannot refresh it. The run must continue regardless — the spool absorbs this, and the app re-authenticates when connectivity returns. **Token expiry must never interrupt a run in progress.**

### 6.8 Run logs — local first, synced to GCS by run ID

Logs are the primary debugging artefact for a lab tool — more useful in practice than the database row, because they contain what the instrument actually said. The design is **local-first**, for one reason: the machine driving a robot must never depend on the network to record what it did.

Every run writes three files under `{work_dir}/runs/{run_id}/`:

| File | Content |
|---|---|
| `events.jsonl` | The structured event stream — the same records sent to the API |
| `stderr.log` | Raw runner stderr, including PyLabRobot's own logging and any traceback |
| `run.json` | Run metadata snapshot: protocol, version, generation, hash, resolved inputs, operator, outcome |

These are written **as the run proceeds**, flushed on every event, before anything is queued for upload. If the machine loses power mid-run, whatever reached disk is preserved.

**Sync to GCS is by run ID and happens after the run ends.** The app requests a short-lived signed *upload* URL from the control plane, uploads the bundle to `gs://<bucket>/run-logs/<run_id>/`, and the control plane records `log_uri` and `log_uploaded_at` on the run. Consistent with §4.3, the lab machine never holds a GCS credential — only a time-boxed URL for one prefix.

Upload failure is not a run failure. Unsynced runs are retried by a background worker on a backoff, and on every app launch, so a lab that was offline for a day catches up when it reconnects. **Local files are never deleted while unsynced**; once synced they are retained for a configurable period (default 30 days) so recent runs stay inspectable without a round trip.

**Logs stay lookable afterwards.** The run history view lists past runs and can open any of them: a synced run fetches a signed download URL from the control plane, an unsynced one reads from local disk. Either way the operator opens a run and sees what happened, which is the property that matters.

## 7. Input forms

Inputs are driven by **JSON Schema (draft 2020-12)** plus a small `x-ui` hints layer for widget selection, ordering and grouping. Using the standard rather than a bespoke format means validation is a library call and the schema is portable to a future web UI.

POC scope is deliberately narrow: `boolean`, `integer`, `number`, `string` (incl. `enum` → combo box), and `object` nested **one** level. **No arrays.** Arbitrary nesting and dynamic array widgets in Qt is a real widget-tree project and is not where POC time should go.

Inputs are validated in the UI *and* re-validated server-side at run creation. What gets stored is the **resolved** input document with defaults materialised, so the record is complete without needing the schema to interpret it.

## 8. Data model

Eight tables:

- `users` — id, email *(auto-created on first authenticated request; no roles implied)*
- `workcells` — id, slug, header, description, **plus deck state and last-seen telemetry**
- `user_workcells` — user ↔ workcell ↔ role
- `protocols` — workcell-scoped protocol registry
- `protocol_versions` — GCS generation, crc32c, entrypoint, cached input schema
- `runs` — the audit record
- `run_events` — state transitions and milestones
- `deck_acknowledgements` — who cleared a `NEEDS_ATTENTION` and when

The `runs` table is much wider than "inputs + operator_id". It carries `protocol_version_id`, `protocol_generation`, `protocol_crc32c`, `resolved_inputs`, `input_schema_snapshot`, `status`, `termination_reason`, `aborted_by_user_id`, `abort_escalation`, `preflight_status`, `exit_code`, `app_version`, `hostname` and `log_uri`. Every column exists because someone will eventually ask a question that cannot be answered without it.

## 9. Technology choices

| Choice | Rationale |
|---|---|
| **PySide6**, not PyQt6 | PyQt6 is GPL-or-commercial. If this ships to labs as a product, GPL is a licensing problem. PySide6 is LGPL with a near-identical API — free now, expensive later. |
| **FastAPI on Cloud Run** | Small, scales to zero, and works unchanged whether fronted by IAP or not. |
| **IAP + user login** | Satisfies the organisation's prohibition on unauthenticated ingress, gives real operator authentication, and removes all credential management from lab machines. |
| **AlloyDB for PostgreSQL** | An instance is already in use by other experimental applications; this adds a database to it. Standard PostgreSQL only — no AlloyDB-specific features — so local development and CI run against stock `postgres:16`. |
| **SQLAlchemy 2.0 + Alembic** | Migrations from day one — schema *will* change during a POC. |
| **asyncio subprocess runner** | Matches PyLabRobot's async model; gives real process isolation and a real kill path. |

## 10. Explicitly deferred

| Deferred | Risk accepted | Upgrade path |
|---|---|---|
| **Hardware↔workcell binding** | `workcell_id` is administrator-written local config, verified physically at provisioning (§4.5). Misconfiguration means protocols offered for the wrong instrument. **Reviewed and accepted.** | Read an instrument serial over the backend connection at preflight and compare against the workcell row — observes the robot, not the config file. |
| **Protocol code signing** | A GCS write grants code execution on lab hardware. Mitigated by generation pinning and hash recording, so tampering is *detectable* after the fact. | Sign artefacts at registration; verify before execution. |
| **Fine-grained protocol permissions** | Roles are per-workcell, not per-protocol. Any operator on a workcell may run any of its protocols. | Add a protocol-level ACL. |
| **21 CFR Part 11 / GxP** | Not addressed. Operator identity is now genuinely authenticated, which is a precondition but not sufficient. | Requires e-signature semantics and a tamper-evident audit trail; the append-only `run_events` table is the right shape to build on. |
| **Multi-workcell machines** | Not supported by design. | Would require rethinking §4 from scratch; do not add casually. |

> Revision 1's **TPM-backed credentials** entry is deleted rather than deferred. With no service account key on the machine there is no key for a TPM to protect.

## 11. Recommended build order

1. **IAP bootstrap.** Custom OAuth client, `programmatic_clients` allowlist, and a throwaway debug route confirming the assertion `email` is the operator's address. **Blocks everything** — the identity design rests on it.
2. **Control plane + schema + authorisation.** The boundary, and the hardest thing to add later. Prove Cloud Run → AlloyDB connectivity first; it stalls silently as a connection timeout.
3. **Runner with backend adapter, preflight gate, abort ladder and deck quarantine.** The safety core. Build against the chatterbox backend — no hardware needed.
4. **Protocol registration with generation pinning.** Cheap now, invasive later.
5. **PySide6 shell:** sign-in → protocol list → form → run monitor.
6. **Schema-driven form generation.**
7. **Crash recovery, heartbeats, offline spool.**

Steps 1, 2, 3, 4 and 7 are painful to retrofit. Steps 5 and 6 are ordinary UI work, cheaply rebuilt if the POC changes what the UI should be.

## 12. Open questions

**Resolved since revision 1:**

1. ~~Which backend?~~ **Hamilton STAR**, second backend later — hence the adapter layer.
2. ~~Firmware e-stop?~~ **None exists.** The §6.3 ladder is the complete software stop; physical halt is the hardware e-stop.
3. ~~Org policy conflict?~~ **None.** The prohibition is on unauthenticated invokers; this design is `--no-allow-unauthenticated` with IAP.

**Still open:**

4. **Does `cred_ref=true` matter?** Google's IAP desktop-flow example includes this undocumented authorization-URL parameter. Its effect is unknown and `google-auth-oauthlib` may not forward it cleanly. Spike this before committing to `InstalledAppFlow` rather than a hand-rolled flow.
5. **Can `request_tip_presence()` be called before the full `setup()` sequence on real hardware?** The preflight design depends on it. If not, `StarAdapter` must return `unsupported` and fall back to operator confirmation — an automated check that silently runs too late is worse than none.
6. **Confirm the PyLabRobot import path** for the pinned version. `backends/hamilton/__init__.py` on `main` is now a deprecation shim pointing at `pylabrobot.legacy.…`, while `backends/__init__.py` still imports from the old path.
7. **Who registers protocols?** The POC assumes an admin CLI. If lab scientists self-publish, that becomes a review-and-approval workflow — much bigger than it sounds.
8. **Is there an existing LIMS/ELN** owning sample or run identity? If so, `runs` needs a correlation ID, and adding it later means backfilling.

---

## Sources

- [PyLabRobot on PyPI](https://pypi.org/project/PyLabRobot/) — version 0.2.2, backends, OS support
- [`STAR_backend.py`](https://raw.githubusercontent.com/PyLabRobot/pylabrobot/main/pylabrobot/liquid_handling/backends/hamilton/STAR_backend.py) — `setup()` ejection behaviour, `request_tip_presence()`, error classes
- [`hamilton/base.py`](https://raw.githubusercontent.com/PyLabRobot/pylabrobot/main/pylabrobot/legacy/liquid_handling/backends/hamilton/base.py) — `stop()` is host-side teardown; `send_command()` raw firmware access
- [Discard of CoRe Grip tools after an incomplete stop](https://discuss.pylabrobot.org/t/discard-of-core-grip-tools-after-an-incomplete-stop/531) — the incomplete-stop collision hazard
- [IAP programmatic authentication](https://docs.cloud.google.com/iap/docs/authentication-howto) — desktop user flow, refresh, allowlist requirement
- [IAP signed headers](https://docs.cloud.google.com/iap/docs/signed-headers-howto) — assertion `email` claim has no namespace prefix
- [OAuth 2.0 for iOS and Desktop Apps](https://developers.google.com/identity/protocols/oauth2/native-app) — loopback flow, OOB deprecation
- [Loopback migration guide](https://developers.google.com/identity/protocols/oauth2/resources/loopback-migration) — desktop loopback remains supported
- [AlloyDB Language Connectors overview](https://docs.cloud.google.com/alloydb/docs/language-connectors-overview) — "don't provide a network path if one is not already present"
- [Choose how to connect to AlloyDB](https://docs.cloud.google.com/alloydb/docs/choose-alloydb-connectivity)
- [Restrict network ingress for Cloud Run](https://docs.cloud.google.com/run/docs/securing/ingress)
- [Enable IAP for Cloud Run](https://docs.cloud.google.com/iap/docs/enabling-cloud-run)
