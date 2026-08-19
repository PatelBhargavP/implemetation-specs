# UI Wireframe Prompt — Experiment Executor Desktop App

**How to use this file:** paste everything below the line into a fresh session with an AI that can produce HTML/SVG wireframes. It is self-contained — it does not assume the model has seen the proposal or build spec.

---

## PROMPT BEGINS

You are designing wireframes for a **Linux desktop application** built with **PySide6 (Qt)**. It lets laboratory operators run automated liquid-handling protocols on a **Hamilton STAR** robot.

Produce **low-to-mid fidelity wireframes** — layout, hierarchy, state and copy. Not visual design: greyscale, no brand colours, no imagery. Colour is used only where it carries meaning (status, danger).

### Deliverable

A **single self-contained HTML file** containing all screens laid out vertically, each with a heading and a one-line note on when it appears. Inline all CSS. No external requests. Use plain HTML/CSS boxes — no canvas, no JS frameworks. Target a **1280×800** window (typical lab PC), and note where a layout must survive down to 1024×768.

---

## What this application does

An operator sits at a computer physically wired to **one** robot. They sign in with their Google account, pick a protocol, fill in a parameter form, start the run, and watch it execute. They can abort. Runs cannot be resumed — an aborted run must be restarted from the beginning.

### The domain, in the words the UI should use

- **Workcell** — one physical robot plus its deck layout. This computer is bound to exactly one, permanently.
- **Protocol** — a versioned script that runs on that workcell.
- **Run** — one execution of a protocol, with recorded parameters and outcome.
- **Deck** — the physical surface holding tips, plates and labware.
- **Operator** — the signed-in human, responsible for the run.

### Three safety facts that must shape the design

These are not decoration. They are why several screens exist.

1. **Software cannot stop the robot.** Aborting stops the *next* command; the one already in flight completes. Physically halting the machine means the hardware emergency stop. **The interface must never imply software can stop the instrument.**
2. **After any abnormal end, the instrument's physical state is unknown.** Tips or grippers may still be mounted, and the next startup routine can collide with them. So the app blocks all new runs until a human confirms they physically inspected and cleared the deck.
3. **The likeliest serious error is a correct protocol run at the wrong instrument.** The workcell name must be permanently and unmissably visible.

---

## Screens to produce

### 1. Sign in
First screen on launch. The app opens the system browser for Google sign-in and waits.

Show: application name; the **workcell name prominently** (read from local config, known before sign-in); a "Sign in with Google" button; a waiting state ("Waiting for browser sign-in…") with a cancel option; and a compact footer with app version and hostname.

### 2. Sign-in error — no access to this workcell
The person authenticated successfully but has no role on the workcell this computer is bound to. **This must be diagnostic, not a dead end** — it is the most common setup failure and the operator needs to know who to ask.

Show: their signed-in email; the workcell this machine is configured for; the workcells they *do* have access to (possibly none); and a plain-language next step ("Ask an administrator to grant you access to this workcell"). Offer sign out / retry.

### 3. Deck requires inspection — blocking modal
Appears at launch, or immediately after any run that did not complete normally. **Nothing else is reachable until it is cleared.**

Show: an unmissable warning header; which run caused it and how it ended; this copy, near-verbatim —

> The previous run did not complete normally, so the software does not know the physical state of the instrument. Tips or grippers may still be mounted. Starting a new run now can cause the initialisation routine to collide with mounted hardware. Physically inspect and clear the deck before continuing.

— then an explicit checkbox ("I have physically inspected the deck and it is clear"), an optional note field, and a **Confirm deck is clear** button that stays disabled until the checkbox is ticked. Include a link to view that run's log.

### 4. Protocol list
The main screen after sign-in.

Show: a persistent header carrying **workcell name**, signed-in operator email, connection status, and a sign-out control. Then a searchable list of protocols — name, description, version, last-run timestamp. A **Run history** entry point. Empty state for a workcell with no protocols yet.

Design the header once; it appears on every screen from here on.

### 5. Parameter form — generated from a schema
The form is **generated at runtime from JSON Schema**, so the layout must accommodate arbitrary field sets, not a fixed design. Supported types are exactly:

- boolean → checkbox
- integer → spin box, with min/max
- number → decimal spin box, with min/max
- string → single-line text
- string with a fixed set of choices → dropdown
- string marked as long-form → multi-line text
- object → a titled group box, **nested one level only**

Every field can have a title, a help hint, and a default value. No arrays.

Show: the protocol name and version; a form with **at least one nested group** and a mix of field types; per-field validation errors, at least one visible; a **Review** panel listing final resolved values (including defaults the operator did not touch); and a **Start run** button.

Also show a **second variant** with roughly fifteen fields across three groups, to prove the layout scrolls sensibly and the Start button stays reachable.

### 6. Pre-run confirmation
Between pressing Start and anything moving.

Show: workcell name **large**; protocol name and version; a compact summary of key parameters; a reminder that the run cannot be paused or resumed; and Cancel / Start. Cancel is the default.

### 7. Instrument check failed
The app queried the robot before starting and found tips or tools still mounted on the channels. **Nothing has moved.**

Show: which channels are dirty; a clear statement that the run did not start and nothing moved; and a route to the deck-inspection flow.

### 8. Run in progress
The screen operators watch for minutes or hours. Design it to be readable **from a couple of metres away** — a lab worker glancing over from the bench.

Show: run status prominently; current step name and index ("Step 7 of 24"); elapsed time; a progress indication where total steps are known; a live scrolling log pane; the protocol and operator; and an **Abort run** button, clearly available but not adjacent to anything routine.

Produce **three states**: starting up / checking instrument; running normally; and aborting-in-progress (abort requested, waiting for the current command to finish — with copy explaining precisely that).

### 9. Abort confirmation dialog
Show this copy near-verbatim:

> **Abort this run?** The run cannot be resumed — it must be restarted from the beginning. The current instrument command will finish before the run stops. Afterwards the deck must be physically inspected before another run can start.

Buttons: `Keep running` (default, focused) and `Abort run`. Make the destructive action deliberately the harder one to hit.

### 10. Run finished
Four variants, visually distinguishable at a glance:

- **Completed** — normal end
- **Aborted** — operator stopped it, showing which step it reached
- **Failed** — the protocol raised an error, with the message and expandable detail
- **Unknown** — the app or machine crashed and the outcome could not be determined

Each shows duration, step reached, a **View log** action, and a route onward. The three abnormal outcomes must lead into the deck-inspection flow.

### 11. Run history
A list of past runs: date, protocol, version, operator, outcome, duration, and a **log sync indicator** (synced to cloud / local only / unavailable). Include a detail view showing full parameters, provenance (protocol version and content hash) and the log viewer.

### 12. Log viewer
Opened from a run. Shows the structured event stream with timestamps, a filter by level, and a toggle for raw instrument output. Show both a synced-from-cloud state and a local-only state.

### 13. Connection lost banner
A non-blocking indicator for when the network drops. **A run in progress must visibly continue** — this is the point. Show it as a persistent strip, with a count of runs pending upload, never as a modal.

---

## Design constraints

**Density.** A working lab tool, not a consumer app. Operators may wear gloves and may be standing. Comfortable hit targets, but do not waste vertical space.

**Colour.** Greyscale except where meaning demands it: red for destructive and for the deck warning, amber for degraded or pending, green for success. Never colour alone — always pair with an icon or text label.

**Typography.** Two sizes plus a heading size. Run status and workcell name are the largest text on their screens.

**Motion.** None, beyond an indeterminate progress indicator.

**Modality.** Only two things block: the deck-inspection modal and the abort confirmation. Everything else is inline.

---

## What to get right

The judgement I most want to see:

1. **The header.** It carries workcell and operator on every screen. Getting its weight right — impossible to miss, never in the way — is the highest-leverage decision here.
2. **The abort control.** Reachable in an emergency without being reachable by accident.
3. **The generated form.** It must look deliberate despite being assembled at runtime from an unknown schema.
4. **The deck-inspection modal.** This is a physical-safety interlock. It should feel like one, without being so alarming that people learn to click through it.

## Also produce

After the wireframes, add a short section listing:

- Any screen or state you think is missing
- Anywhere the specified copy is unclear or could be misread by a hurried operator
- Any place the design might encourage a dangerous habit

Be direct. If something here is a bad idea, say so.

## PROMPT ENDS
