# Implementation Plan — Orchestrator

> For a weaker model to execute. Each phase is independent and verifiable.
> Full spec: `docs/orchestrator-spec.md`

---

## Phase 1: Foundation — Directory Structure & State Files

**Goal**: Set up `~/.orchestrator/` runtime directory and the manifest schema.

### Tasks

- [x] 1.1 Create the `~/.orchestrator/` runtime directory structure:
  ```
  ~/.orchestrator/
  ├── manifest.json
  ├── soul.md → symlink to ~/personal/orchestrator/config/soul.md
  ├── inboxes/
  │   └── orchestrator/
  ├── archive/
  ├── reviews/
  ├── logs/
  └── observations.jsonl
  ```

- [x] 1.2 Write `config/soul.md` with the initial manually-seeded content from spec section 16. This is the orchestrator's persistent personality file.

- [x] 1.3 Write `config/message-schemas/stage-complete.json` — JSON schema for the stage completion message (spec section 5, "Stage completion" schema).

- [x] 1.4 Write `config/message-schemas/decision-needed.json` — JSON schema for the decision escalation message (spec section 5, "Decision escalation" schema).

- [x] 1.5 Write `config/message-schemas/decision-resolved.json` — JSON schema for the decision resolution message (spec section 5, "Decision resolution" schema).

- [x] 1.6 Write an initial `manifest.json` with empty `projects` and `worktrees` objects. Include the schema structure from spec section 7 and section 12 (cross-project).

- [x] 1.7 Write a setup script `bin/setup` that creates the `~/.orchestrator/` directory structure and symlinks `soul.md`. Should be idempotent (safe to run multiple times).

### Verification
- Run `bin/setup` twice — second run should be a no-op.
- `~/.orchestrator/manifest.json` exists and is valid JSON.
- `~/.orchestrator/soul.md` is a symlink pointing to `config/soul.md`.

---

## Phase 2: Mailbox System — Atomic Write Helpers

**Goal**: Shell functions for the atomic write protocol. These are the building blocks for all agent communication.

### Tasks

- [x] 2.1 Write `bin/mailbox-send` — a shell script that:
  - Takes arguments: `--to <inbox-name>` `--file <message.json>`
  - Validates the JSON is well-formed
  - Writes to a temp file first
  - Atomically moves (`mv`) to `~/.orchestrator/inboxes/<inbox-name>/<filename>.json`
  - Exits with clear error codes

- [x] 2.2 Write `bin/mailbox-read` — a shell script that:
  - Takes argument: `--inbox <inbox-name>`
  - Lists all messages in the inbox, sorted by timestamp
  - Optionally: `--type <message-type>` to filter by type
  - Outputs to stdout

- [x] 2.3 Write `bin/mailbox-archive` — a shell script that:
  - Takes argument: `--inbox <inbox-name>` `--file <filename>`
  - Atomically moves the message from inbox to `~/.orchestrator/archive/`
  - Creates archive subdirectory if needed

- [x] 2.4 Write `bin/mailbox-cleanup` — a shell script that:
  - Takes argument: `--ticket <TICKET-ID>`
  - Removes all inbox, archive, and review files for that ticket
  - Removes the inbox directory for that ticket
  - Updates manifest to remove the worktree entry (use `jq`)

### Verification
- Send a test message to `orchestrator` inbox → verify it appears.
- Read from the inbox → verify the message content is correct.
- Archive the message → verify it moved to archive.
- Cleanup a ticket → verify all traces are removed.

---

## Phase 3: Sub-agent Prompt & Spawner

**Goal**: The system prompt that makes sub-agents follow the mailbox protocol, and the script to spawn them.

### Tasks

- [x] 3.1 Write `config/sub-agent-prompt.md` — the system prompt injected into every sub-agent via `--system-prompt-file`. Must include:
  - Explanation of the mailbox protocol (how to send messages, where inboxes are)
  - The atomic write protocol (write to /tmp first, then mv)
  - When and how to escalate decisions (write a `decision_needed` message)
  - How to report stage completion (write a `stage_complete` message)
  - How to read the plan file for context
  - How to read decision responses from its inbox
  - Reference to the GSD stage commands (spec-gsd, plan-gsd, build-gsd, verify-gsd)

- [x] 3.2 Write `bin/spawn-agent` — a shell script that:
  - Takes arguments: `--ticket <TICKET-ID>` `--stage <SPEC|PLAN|BUILD|VERIFY>` `--worktree <path>`
  - Creates a `CLAUDE_CONFIG_DIR` for the agent at `~/.orchestrator/agents/<TICKET-ID>/`
  - Spawns `claude -p` with:
    - `--system-prompt-file config/sub-agent-prompt.md`
    - `--allowedTools "Read,Write,Edit,Bash,Grep,Glob"`
    - `--max-turns 200`
    - `--output-format json`
    - `--no-session-persistence`
  - Uses `nohup` to survive terminal closure
  - Redirects output to `~/.orchestrator/logs/<TICKET-ID>-<stage>.log`
  - Records PID in manifest via `jq`
  - Creates the agent's inbox directory at `~/.orchestrator/inboxes/<TICKET-ID>/`

- [x] 3.3 Write `bin/check-agent` — a shell script that:
  - Takes argument: `--ticket <TICKET-ID>`
  - Checks if the agent's PID is still running
  - Checks the agent's inbox for unprocessed messages
  - Reports status to stdout

### Verification
- `spawn-agent` creates the correct directory structure and log file.
- PID appears in manifest.
- `check-agent` correctly reports running/stopped status.

---

## Phase 4: Notification System

**Goal**: macOS notifications that click-to-open Claude Code in a worktree.

### Tasks

- [x] 4.1 Write `bin/notify` — a shell script that:
  - Takes arguments: `--title <text>` `--message <text>` `--ticket <TICKET-ID>`
  - Uses `terminal-notifier` if installed, falls back to `osascript`
  - Click action calls `bin/open-review` with the ticket ID

- [x] 4.2 Write `bin/open-review` — a shell script that:
  - Takes argument: ticket ID
  - Reads worktree path from manifest via `jq`
  - Reads review file path from `~/.orchestrator/reviews/<TICKET-ID>-review.md`
  - Opens iTerm2 with a new window
  - `cd`s to the worktree directory
  - Starts `claude --resume <TICKET-ID>-review --append-system-prompt-file <review-file>`

### Verification
- `notify` shows a macOS notification.
- Clicking the notification opens iTerm2 in the correct directory.
- Claude Code starts with the review context loaded.

---

## Phase 5: Orchestrator CLAUDE.md

**Goal**: The orchestrator's own Claude Code context file that tells it how to manage everything.

### Tasks

- [x] 5.1 Write `CLAUDE.md` at the project root. This is what Claude Code reads when starting an orchestrator session. It must include:
  - What the orchestrator is and its responsibilities
  - How to read the manifest (`~/.orchestrator/manifest.json`)
  - How to check inboxes (`~/.orchestrator/inboxes/orchestrator/`)
  - How to process messages (read, decide, route, archive)
  - Decision authority boundaries (what to auto-resolve, what to escalate)
  - How to use `bin/spawn-agent` to start sub-agents
  - How to use `bin/notify` to alert the user
  - How to use `bin/mailbox-*` for communication
  - Cold boot recovery procedure (spec section 9)
  - Reference to `soul.md` for preferences
  - The morning brief format (spec section 12)

- [x] 5.2 Write `templates/review-package.md` — template for the review summary generated when a worktree hits BUILD checkpoint. Include placeholders for: ticket ID, what changed, why, decisions made, decisions deferred, manual testing steps.

- [x] 5.3 Write `templates/morning-brief.md` — template for the morning brief format. Include placeholders for: project groupings, worktree statuses, blocked items, items ready for review.

### Verification
- Start `claude` in the orchestrator project directory.
- Verify it reads CLAUDE.md and understands its role.
- Ask it to read the manifest and give a brief — it should be able to.

---

## Phase 6: Integration Test — Single Worktree End-to-End

**Goal**: Test the full flow with one worktree in one project.

### Tasks

- [ ] 6.1 Register a test project: create a simple test repo, run `bin/setup`, manually add it to the manifest.

- [ ] 6.2 Create a test worktree from the test project.

- [ ] 6.3 Spawn a sub-agent for the SPEC stage in the test worktree.

- [ ] 6.4 Verify the sub-agent sends a `stage_complete` message to the orchestrator inbox.

- [ ] 6.5 Process the message (manually or via orchestrator) and advance to PLAN.

- [ ] 6.6 Continue through BUILD → review → VERIFY.

- [ ] 6.7 Verify cleanup removes all state when the worktree is done.

### Verification
- Full SPEC → PLAN → BUILD → VERIFY cycle completes.
- Messages flow correctly through the mailbox system.
- Notification fires when BUILD is ready for review.
- Cleanup leaves no orphaned state.

---

## Implementation Notes

- All scripts should use `#!/bin/bash` with `set -euo pipefail`.
- Use `jq` for all JSON manipulation (installed via Homebrew).
- All paths should expand `~` properly (use `$HOME` in scripts, not `~`).
- Test each phase independently before moving to the next.
- The full spec with all schemas, message formats, and architectural decisions is at `docs/orchestrator-spec.md` — reference it heavily.
