# Orchestration UI, Notifications & Human Interface: Technical Comparison

**Systems compared**

- **System A — “The Orchestrator” (external, user-built):** `/Users/bensmith/personal/orchestrator/` — human surface is OS notifications, shell scripts, terminal I/O, and markdown artifacts under `~/.orchestrator/`.
- **System B — Claude Code internal swarm:** `/Users/bensmith/Downloads/src/` — React/Ink terminal UI with inline status, teammate views, dialogs, and in-app notifications.

---

## 1. Status display — how each system shows what agents are doing

### System A (Orchestrator)

- **Manifest as truth:** Work is summarized in `~/.orchestrator/manifest.json` per ticket: `current_stage`, `status`, `blocking_decision`, `last_activity`, etc. (spec §7). The human does not get a live animated UI; visibility is **pull-based** (read manifest, run CLI) or **event-driven** (notifications when checkpoints hit).
- **Stages and status vocabulary:** Spec example shows `current_stage` (e.g. `BUILD`, `PLAN`) and `status` values such as `in_progress`, `blocked`, `review_ready`, `approved`, `done` (see manifest excerpt in `orchestrator-spec.md` §7).

### System B (Claude Code)

- **`CoordinatorTaskPanel` (`CoordinatorAgentStatus.tsx`):** Renders below the prompt footer for `local_agent` tasks. `getVisibleAgentTasks()` filters panel tasks where `isPanelAgentTask(t) && t.evictAfter !== 0`. Each row (`AgentLine`) shows optional agent name, truncated `task.progress?.summary || task.description`, play/pause icon (`PLAY_ICON` / `PAUSE_ICON`), **elapsed time** via `formatDuration`, **token count** when present, and **queued messages** count (`pendingMessages.length`) with warning color when `> 0`. A 1s interval evicts tasks past `evictAfter`.
- **`BackgroundTaskStatus` (`BackgroundTaskStatus.tsx`):** Two modes: (1) **pill strip** when all running tasks are in-process teammates — `@main` plus `@teammate` pills with `AgentPill` (theme colors via `getAgentThemeColor` / `AGENT_COLOR_TO_THEME_COLOR`); horizontal scroll via `calculateHorizontalScrollWindow`; hint `shift + ↓` to expand. (2) **summary pill** + “↓ to view” when not in full teammate mode — uses `getPillLabel(runningTasks)` and `pillNeedsCta`. Hides footer when `shouldHideTasksFooter` is true (spinner tree mode showing teammates in tree instead).
- **`TeammateSpinnerTree` / `TeammateSpinnerLine`:** Tree UI for in-process teammates: leader line shows `team-lead`, optional leader verb / idle text / token count; each teammate line uses box-drawing chars, colors from `toInkColor(teammate.identity.color)`, `describeTeammateActivity`-style semantics (via spinner verbs, idle timers). `TeammateSpinnerLine` can show **message previews** (`getMessagePreview`) from recent user/assistant content and tool-use lines.
- **`taskStatusUtils.tsx`:** Central semantics: `isTerminalStatus`, `getTaskStatusIcon`, `getTaskStatusColor`, `describeTeammateActivity` (maps shutdown → `stopping`, plan approval → `awaiting approval`, idle, else recent-activity summary or `working`).

### Contrast

| Aspect | Orchestrator | Claude Code |
|--------|--------------|-------------|
| **Live activity** | Not specified as streaming UI; checkpoint-based | Continuous: tokens, queued msgs, summaries, spinner verbs |
| **Multi-agent layout** | Per-ticket rows in brief / manifest | Pills, tree, coordinator panel, dialogs |
| **Identity** | Ticket IDs + project names | Colored `@names`, team-lead vs teammates |

---

## 2. Notification mechanisms — how each system alerts the human

### System A

- **`bin/notify`:** Shell entrypoint: `notify --title … --message … [--ticket TICKET-ID]`. Uses `terminal-notifier` when available with `-title "Orchestrator"`, `-subtitle` from `--title`, `-message`, `-sound Glass`, and **`-execute`** pointing to `"$ORCH_HOME/bin/open-review" $ticket` when ticket is set. Fallback: `osascript` `display notification` **without** click action; prints `Run: $open_review_cmd` to stderr if click unavailable.
- **Spec §15:** Documents the same pattern; **notification types table** maps events (SPEC/PLAN/BUILD/VERIFY ready, decision escalated, sub-agent failure) to titles and click actions (open Claude in worktree vs orchestrator session).
- **Morning brief:** Not a push notification in the spec — it is a **generated markdown** artifact (template-driven), consumed when the user runs or reads it.

### System B

- **`useTeammateLifecycleNotification` (`hooks/notifs/useTeammateShutdownNotification.ts` path in research brief; actual export: `useTeammateLifecycleNotification`):** Subscribes to `tasks`; for `isInProcessTeammateTask`, on first transition to `running` → `addNotification(makeSpawnNotif(1))`; on first `completed` → `addNotification(makeShutdownNotif(1))`. Notifications use `key: 'teammate-spawn' | 'teammate-shutdown'`, **fold** functions to batch into `"N agents spawned"` / `"N agents shut down"`, `priority: 'low'`, `timeoutMs: 5000`. Skips when `getIsRemoteMode()`.
- **No macOS Notification Center integration** in these files — alerts are **in-terminal** via the app’s notification context.

### Contrast

- **Orchestrator:** OS-level, sound, optional **click-through to `open-review`**.
- **Claude Code:** In-session, batched toasts for teammate lifecycle; rich status elsewhere in the same TUI.

---

## 3. Review and handoff — how completed work is presented for human review

### System A

- **Spec §6:** At BUILD checkpoint: (1) **Review package** under `~/.orchestrator/reviews/` — summary MD + manual testing steps. (2) Notify: *“WBPR-3582 is ready for review.”* (3) User runs `orchestrator review <ticket>` which opens Claude Code in the worktree with review context. (4) User replies **Approve** → VERIFY; **Request changes** → revision to sub-agent; **Reject** → re-plan.
- **`templates/review-package.md`:** Sections: `What changed`, `Why`, `Decisions made`, `Decisions deferred to human`, `Manual testing steps`; footer points to `orchestrator review` / `open-review`.
- **`bin/open-review`:** Resolves `worktree_path` from `manifest.json` via `jq`, builds `review_file="$ORCH_HOME/reviews/$ticket-review.md"`, optionally adds `--append-system-prompt-file` for Claude, runs AppleScript to **iTerm2** (or **Terminal**) with `claude --resume $ticket-review …` in the worktree.

### System B

- Review is **in-conversation**: foreground transcript, `TeammateViewHeader` when viewing a teammate (`Viewing @name · esc to return` + dim prompt text), detail dialogs (`InProcessTeammateDetailDialog`, `AsyncAgentDetailDialog`, etc.) from `BackgroundTasksDialog` routing.
- **No separate markdown review package** in this layer — handoff is continuous UI + task detail views, not a filesystem template.

### Contrast

- **Orchestrator:** **Explicit artifact + session bootstrap** (`--resume`, appended system prompt file) optimized for **guided manual testing** and approval verbs outside the IDE.
- **Claude Code:** **Same-session** inspection; structured review package is not the primary metaphor in the cited components.

---

## 4. Cross-project visibility — morning briefs, dashboards, summaries

### System A

- **Spec §12:** Projects registered via `orchestrator add-project`; `related_projects` for cascade hints. **Morning Brief Across Projects** shows an example block: emoji header, **WORK** vs **PERSONAL** sections, per-worktree lines with stage and short note, blocked/ready counts, command `orchestrator review …`.
- **`templates/morning-brief.md`:** Placeholders: `{{DATE}}`, `{{PROJECT_GROUPINGS}}`, `{{BLOCKED_ITEMS}}`, `{{READY_FOR_REVIEW}}`, `{{RUN_REVIEW_COMMAND}}`; footer explains grouping from `manifest.projects` / worktree project fields.

### System B

- **No morning-brief template** in cited files. Cross-project awareness is **not modeled** in these components — `TeamStatus` / `BackgroundTaskStatus` reflect **current session** `teamContext` and `tasks` only.
- **`useSwarmBanner`:** Surfaces **context** (tmux attach hint, `@teammate`, standalone agent rename/color, `--agent` CLI) — not multi-repo aggregation.

### Contrast

- **Orchestrator:** First-class **cross-repo digest** (morning brief) tied to manifest projects.
- **Claude Code (this slice):** **Session-scoped** swarm/task UI; no equivalent “all repos” brief in these files.

---

## 5. Interactive controls — how humans intervene (pause, redirect, kill agents)

### System A

- Human loop in §6 is **verbal / orchestrator CLI**: Approve / Request changes / Reject after review; no low-level “kill PID” in the cited UX sections (manifest may store `sub_agent_pid` for lifecycle elsewhere).
- Notifications **redirect** via `open-review` / orchestrator session opens (spec table, §15).

### System B

- **`CoordinatorTaskPanel`:** Docstring: *“Enter to view/steer, x to dismiss.”* `AgentLine` shows `· x to stop` or `· x to clear` when selected and not viewing (`hintPart`).
- **`BackgroundTasksDialog`:** `killAgentsShortcut` from `useShortcutDisplay('chat:killAgents', 'Chat', 'ctrl+x ctrl+k')`. Kill routing: `LocalShellTask.kill`, `LocalAgentTask.kill`, `InProcessTeammateTask.kill`, `DreamTask.kill`, `RemoteAgentTask.kill`, workflow/monitor MCP kills, `stopUltraplan` for ultraplan remote sessions. Detail dialogs receive `onKill`, `onForeground` (e.g. `InProcessTeammateDetailDialog`).
- **`TeamsDialog`:** `cycleTeammateMode` / `cycleAllTeammateModes`, `sendShutdownRequestToMailbox`, `removeMemberFromTeam`, etc. — permission modes and team management.

### Contrast

- **Orchestrator:** **Workflow-level** decisions (approve/changes/reject); tooling opens the right Claude session.
- **Claude Code:** **Fine-grained** kill/stop/foreground, teammate modes, keyboard shortcuts within the running TUI.

---

## 6. Key differences — summary table

| Dimension | System A: Orchestrator | System B: Claude Code swarm UI |
|-----------|-------------------------|--------------------------------|
| **Primary surface** | macOS notifications + Terminal/iTerm + markdown on disk | Ink/React terminal UI |
| **Status fidelity** | Checkpoint + manifest fields | Live tokens, queues, activity strings, spinners |
| **Alert transport** | `terminal-notifier` / `osascript` | `addNotification` (in-app), batched spawn/shutdown |
| **Review artifact** | `reviews/<ticket>-review.md` + template | Transcript + dialogs |
| **Cross-project** | Morning brief template + manifest projects | Not in cited code |
| **Intervention** | Approve/changes/reject; `open-review` | Kill/stop/foreground; mode cycling; overlays |
| **Dependency** | Homebrew `terminal-notifier` for click actions | Same process as chat |

---

## 7. Recommendations — what an improved external orchestration system should adopt

1. **Adopt Claude Code–style density for “what is it doing right now”**  
   External orchestrators rarely match token counts and queued-message indicators; even a **periodic digest** (last tool summary + elapsed time) pushed to notification body or a small **TUI dashboard** would narrow the gap with `AgentLine` / `describeTeammateActivity`.

2. **Keep Orchestrator’s review package + click-through**  
   The pairing of **durable markdown** (`review-package.md`) + **`open-review` seeding Claude** is strong for async review; replicate the pattern with clear sections: changes, decisions, deferred items, manual steps.

3. **Unify notification tiers**  
   Map Orchestrator’s event table (SPEC/PLAN/BUILD/VERIFY/decision/failure) to **priority + sound + optional batching** like `useTeammateLifecycleNotification`’s `fold` pattern to avoid notification storms when many sub-agents finish together.

4. **Morning brief as the external “multi-session dashboard”**  
   The template + manifest grouping is the right **cross-project** primitive; consider **machine-readable JSON** alongside markdown for scripting, and optional **RSS or email** for users who miss macOS notifications.

5. **Intervention hooks**  
   Expose **workflow-level** controls (approve, request changes) *and*, where sub-agents run as processes, **operational** controls analogous to `killTeammateTask` / shutdown mailbox messages, with audit trail in the manifest.

6. **Fallback parity**  
   Orchestrator already documents `terminal-notifier` vs `osascript` fallback; ensure **every** alert path includes a **non-interactive fallback** (log line + copy-paste command) matching `notify`’s stderr hint when click actions are unavailable.

---

## Reference index (files cited)

**System A**

- `docs/orchestrator-spec.md` — §6 Review & Handoff UX, §12 Cross-Project Orchestration (Morning Brief), §15 Notification System
- `bin/notify`, `bin/open-review`
- `templates/review-package.md`, `templates/morning-brief.md`

**System B**

- `components/CoordinatorAgentStatus.tsx` — `CoordinatorTaskPanel`, `getVisibleAgentTasks`, `AgentLine`
- `components/tasks/BackgroundTasksDialog.tsx` — `BackgroundTasksDialog`, kill helpers
- `components/tasks/BackgroundTaskStatus.tsx` — `BackgroundTaskStatus`, `AgentPill`, `SummaryPill`
- `components/tasks/taskStatusUtils.tsx` — `isTerminalStatus`, `getTaskStatusIcon`, `describeTeammateActivity`, `shouldHideTasksFooter`
- `components/PromptInput/useSwarmBanner.ts` — `useSwarmBanner`
- `components/teams/TeamsDialog.tsx` — `TeamsDialog`
- `components/teams/TeamStatus.tsx` — `TeamStatus`
- `components/Spinner/TeammateSpinnerTree.tsx`, `components/Spinner/TeammateSpinnerLine.tsx`
- `hooks/notifs/useTeammateShutdownNotification.ts` — **Note:** file implements `useTeammateLifecycleNotification` (spawn + shutdown batching)
- `components/TeammateViewHeader.tsx` — `TeammateViewHeader`
