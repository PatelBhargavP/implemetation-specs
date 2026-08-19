# UI Build Request: Protocol Workspace Frontend

Design a React web UI, similar in spirit to Google AI Studio or v0, for a system with two levels of hierarchy:

- **Workcell** — a shared space containing multiple protocols. Users are invited to a workcell, not to individual protocols within it.
- **Protocol** — an isolated workspace within a workcell, where a user prompts a coding agent to generate and edit files. This is where the actual file browser + chat experience lives.

Navigation: **Workcell list → Workcell detail (protocol list + sharing) → Protocol workspace (file browser + chat)**.

---

## Screen 1: Workcell list (landing page)

- Grid or list of workcells the user has access to. Visually distinguish workcells the user owns from ones shared with them.
- Primary action: create a new workcell (name only, minimal friction).
- Empty state: no workcells yet — prompt to create the first one.

## Screen 2: Workcell detail

Two things live on this screen:

**Protocol list**
- Cards or rows, one per protocol in this workcell.
- Each shows a status indicator with at least three states: **idle** (no sandbox running, files browsable but agent not active), **provisioning** (sandbox starting — show a spinner/progress state, this can take a few seconds), **running** (sandbox active).
- Primary action: create a new protocol within this workcell.
- Empty state: no protocols yet in this workcell.

**Sharing panel**
- List of current collaborators with their role.
- Invite-by-identifier control (email or username) plus a role selector.
- This is the only place sharing happens — there is no per-protocol sharing UI, by design.

## Screen 3: Protocol workspace (the main view)

This is the AI-Studio-style split view. Three regions:

1. **File tree panel** (left) — the protocol's files. Must render and be browsable even when the protocol's sandbox is idle (no active session) — this is a hard requirement, not just a nice-to-have, so don't design the tree as dependent on an active chat session.
2. **Chat panel** (right) — prompt input plus streamed agent responses. If no sandbox is running yet, sending the first prompt should visibly transition the panel through provisioning → active states rather than appearing to hang.
3. **File editor area** (center/main) — content of whichever file is selected in the tree, and it's a real editor, not just a preview: users can edit files directly, independent of the agent. Use an explicit save action (a Save button and/or a keyboard shortcut like Cmd/Ctrl+S) rather than silent autosave — saving is the discrete moment the agent gets notified of the change, so it should feel like a deliberate action, not something that happens invisibly as the user types.

**The editor locks while the agent has an active turn in progress** — not simply whenever the sandbox is running. A running sandbox waiting on the next prompt still allows editing; the moment the agent starts working on a response (streaming, editing files, running commands), the editor should go read-only until that turn finishes, with a clear visual reason shown (e.g. a banner: "Agent is working — editing paused"). This avoids the user and agent racing to edit the same files at once.

### Manual save → agent awareness
When a user saves a manual edit, the agent needs to visibly register it — design this so the connection is obvious, not hidden. A good pattern: a small system-style entry in the chat panel's timeline, e.g. "— you edited protocol.py —", so there's one shared record of the change sitting right where the conversation lives. Pair this with a brief save confirmation near the editor itself (e.g. a transient "Saved" state on the Save button).

The confirmation reads differently depending on what's happening when the save occurs:
- **Sandbox running, agent between turns** — something like "Saved — agent notified," since the change reaches the live conversation immediately.
- **No sandbox running** — something like "Saved — the agent will see this next time it works on this protocol," since there's no live conversation to notify yet.
- **Agent mid-turn** — saving isn't possible in this state at all (editor is locked); no confirmation copy needed here.

### States to design for
- Empty protocol (just created, no files yet — likely first-run guidance to just start prompting).
- Sandbox idle vs. provisioning vs. running — should be visually distinct at a glance, not just a text label.
- **Agent actively working on a turn** — a state distinct from "sandbox running": editor locked/read-only, with the locked reason visible, not just a disabled control with no explanation.
- Streaming response in the chat panel (agent "typing"/working indicator) — this should visually correlate with the editor-locked state above, since they're triggered by the same underlying event.
- Unsaved changes in the editor (dirty-state indicator, e.g. a dot on the file's tab) vs. saved.
- Error states: sandbox failed to start, file failed to load, save failed.

### Reserve space, don't build yet
Leave a natural extension point in the chat input or file panel for referencing another protocol's files from within the same workcell (e.g., an "@" or "reference from..." affordance). This is a planned future feature, not part of this pass — just avoid a layout that would need to be reworked to fit it in later.

---

## Out of scope for this wireframe pass
- Exact copy/microcopy.
- Any settings/account-management screens beyond the collaborator list on Screen 2.
