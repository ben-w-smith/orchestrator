# State Persistence & Recovery: Technical Comparison

**Research focus:** How two agent orchestration approaches persist state and recover from partial or total process failure.

- **System A — “The Orchestrator” (external, user-built):** specification and implementation plan under `~/personal/orchestrator/`.
- **System B — Claude Code internal swarm / session stack:** implementation under `~/Downloads/src/` (this repository).

---

## 1. State model — what each system persists and where

### System A: Orchestrator

Persistent state is **explicitly distributed** across a fixed runtime tree (`~/.orchestrator/`) and per-worktree repo files. The spec’s cold-boot table is the canonical inventory:

| State | Location | Notes |
| --- | --- | --- |
| Active worktrees, stages, PIDs, history | `manifest.json` | Single writer: orchestrator only (`docs/orchestrator-spec.md` §7) |
| Per-ticket GSD progress | `.cursor/plans/TICKET.md` in the worktree repo | Append-only “recovery journal” (§9) |
| Inbound messages | `inboxes/<name>/*.json` | Immutable once delivered |
| Processed mail | `archive/<ticket>/` | Audit + recovery |
| Human review artifacts | `reviews/` | BUILD handoff |
| Orchestrator personality | `soul.md` (symlinked into runtime dir per `PLAN.md`) | Long-lived preferences |
| Observations / logs | `observations.jsonl`, `logs/` | Operational telemetry |

The **manifest schema** (example in §7) ties each worktree to `project`, `branch`, `worktree_path`, `plan_file`, `current_stage`, `stage_history`, `status`, `blocking_decision`, `sub_agent_pid`, `last_activity`.

The **template** at `config/manifest-template.json` is minimal:

```json
{
  "last_updated": "",
  "projects": {},
  "worktrees": {}
}
```

`PLAN.md` frames the **plan file** as the execution contract for phased implementation; the **spec** elevates the same Markdown plan (`.cursor/plans/TICKET.md`) to the **recovery journal** — not merely a task list.

### System B: Claude Code (sessions + swarm)

State splits into **(1) per-session transcript logs**, **(2) team membership files**, and **(3) in-process bootstrap / AppState** that is **rehydrated from disk on resume** rather than treated as the source of truth.

**Transcript (JSONL)** is the primary durable record. `loadTranscriptFile` in `utils/sessionStorage.ts` aggregates messages plus typed metadata: summaries, custom titles, tags, agent names/colors/settings, PR links, **worktree state**, file-history snapshots, attribution snapshots, content replacements, context-collapse commits/snapshots, etc. (see the return type starting ~line 3472).

**Session metadata** is cached and rewritten via `restoreSessionMetadata` / `reAppendSessionMetadata` patterns documented in `restoreSessionMetadata`:

```2753:2785:/Users/bensmith/Downloads/src/utils/sessionStorage.ts
/**
 * Restore session metadata into in-memory cache on resume.
 * Populates the cache so metadata is available for display (e.g. the
 * agent banner) and re-appended on session exit via reAppendSessionMetadata.
 */
export function restoreSessionMetadata(meta: {
  customTitle?: string
  tag?: string
  agentName?: string
  agentColor?: string
  agentSetting?: string
  mode?: 'coordinator' | 'normal'
  worktreeSession?: PersistedWorktreeSession | null
  prNumber?: number
  prUrl?: string
  prRepository?: string
}): void {
```

**Swarm / team state** lives under `~/.claude/teams/<sanitized-name>/config.json` (via `getTeamFilePath` in `utils/swarm/teamHelpers.ts`). The `TeamFile` type includes `leadAgentId`, `leadSessionId`, `members[]` with `agentId`, `tmuxPaneId`, `cwd`, `worktreePath`, `sessionId`, etc.

**Bootstrap** (`bootstrap/state.ts`) holds **session-scratch** data (`sessionCreatedTeams`, `sessionPersistenceDisabled`, `invokedSkills`, etc.). Comments explicitly mark many flags as **not persisted** — the transcript + team files are what survive a restart.

---

## 2. Persistence mechanisms — files, formats, atomicity

### System A

- **Mailbox messages:** JSON files, **immutable after write**. Writers use **write-temp-then-`mv`** so readers never see partial files (`docs/orchestrator-spec.md` §5 “Atomic Write Protocol”).
- **Manifest:** JSON, **single writer** (orchestrator), reducing lock contention and corruption risk.
- **Plan file:** Markdown with **append-only sections**; section *presence* encodes stage completion (§9 “Plan File as Recovery Journal”).
- **No reliance on in-memory agent state** for recovery (“Why This Works: State Is On Disk, Not In Memory”, §9).

Sub-agents spawned per `PLAN.md` are started with **`--no-session-persistence`** (`PLAN.md` Phase 3.2), pushing durability to the plan file + mailbox rather than Claude Code’s session store.

### System B

- **Transcript:** Append-oriented **JSONL** with parent/UUID chaining, compaction boundaries, and optional optimizations (e.g. pre-compact skip for large files in `loadTranscriptFile`). `recordTranscript` delegates to `getProject().insertMessageChain` (`utils/sessionStorage.ts` ~1408).
- **Flush:** `flushSessionStorage` awaits `getProject().flush()` — explicit durability boundary for buffered project state.
- **Metadata tail:** Comments on `reAppendSessionMetadata` (see `sessionStorage.ts` ~2807) note a **16KB tail window** for lite metadata reads — operational constraint for how titles/tags survive compaction.
- **Worktree persistence:** `saveWorktreeState` appends a `worktree-state` entry when `project.sessionFile` exists (`utils/sessionStorage.ts` ~2883–2919).
- **Team files:** JSON written with `writeFile` / `writeFileSync` after `mkdir` (`teamHelpers.ts`); not described as atomic rename — **last writer wins** semantics typical for this pattern.

---

## 3. Single agent recovery

### System A

The spec defines a **deterministic orchestrator-driven** path:

1. Detect death: **PID no longer running** or **inbox silence past timeout** (`docs/orchestrator-spec.md` §9 “Single Agent Death”).
2. Read **`.cursor/plans/TICKET.md`** for last completed step.
3. Check the **ticket inbox** for unprocessed messages.
4. **Respawn** a new sub-agent with a **recovery prompt** that cites ticket ID, plan path, last stage, and partial BUILD progress if applicable.

There is **no assumption** that the old process’s memory is recoverable; the new agent is a clean process guided by disk.

### System B

There is **no global “orchestrator PID table”** analogous to the manifest. Recovery is **per Claude Code session / teammate**:

- **Transcript resume:** `loadConversationForResume` rebuilds messages and detects **mid-turn interruption** via `deserializeMessagesWithInterruptDetection` → `detectTurnInterruption` (`utils/conversationRecovery.ts`). Interrupted turns can receive a synthetic **“Continue from where you left off.”** user message (meta) so the API sees a valid continuation.
- **Swarm teammate:** On `--resume` / `/resume`, `useSwarmInitialization` reads `teamName` / `agentName` from the **first message** of the loaded conversation and calls `initializeTeammateContextFromSession` (`hooks/useSwarmInitialization.ts`). That function re-reads `readTeamFile(teamName)` and repopulates `AppState.teamContext` (`utils/swarm/reconnection.ts`).
- **Fresh CLI spawn:** `computeInitialTeamContext` uses **`getDynamicTeamContext()`** from CLI args and **`readTeamFile`** for `leadAgentId` — **not** from the transcript (`utils/swarm/reconnection.ts`).

If a **teammate process dies** but the leader and team file remain, recovery is effectively **“start a new process and resume or rejoin”** via the same transcript + team file — not the mailbox-driven respawn contract of System A.

---

## 4. Full system recovery — cold boot and full restart

### System A

**Cold boot** (`docs/orchestrator-spec.md` §9):

1. User starts the orchestrator.
2. Load **`manifest.json`** → enumerate worktrees.
3. For **each** worktree, **reconcile** against reality:
   - Worktree directory still exists (`git worktree list`).
   - **Plan file sections** → infer last completed stage.
   - **Git diff** → BUILD mid-flight.
   - **Inbox messages** → pending work.
   - **Pending decisions**.
4. Present a **human-readable summary** (“Cold Boot Recovery — N worktrees found”) with per-ticket status; user may resume all, selectively, or review.

**Guarantees** stated in spec: no work lost (git + plan + messages), no duplicate work (append-only plan), no orphaned state if reconciliation runs, graceful degradation per worktree.

### System B

**Full restart** of the IDE/CLI means **reloading sessions from disk**:

- `loadConversationForResume` with `source === undefined` picks the **most recent** session log, optionally **skipping live background sessions** when `BG_SESSIONS` + UDS list reports active non-interactive writers (`conversationRecovery.ts` ~487–512).
- `processResumedConversation` (`utils/sessionRestore.ts`) wires **session ID**, **fork** semantics, **metadata**, **worktree cd** via `restoreWorktreeForResume`, **agent** restoration via `restoreAgentFromSession`, and **coordinator mode** via `saveMode` / `matchSessionMode`.
- **Worktree after crash:** `restoreWorktreeForResume` uses `process.chdir` as an existence check; on failure it **`saveWorktreeState(null)`** so the next metadata write records “exited” instead of a stale path (`sessionRestore.ts` ~332–349).

There is **no** single **global manifest** that lists all active tickets across repos; recovery is **session-centric** (and **team file**-centric for swarm metadata).

---

## 5. Recovery journal — plan-file-as-journal vs transcript-based recovery

### System A: plan file as append-only journal

The spec treats **`.cursor/plans/TICKET.md`** as a **write-ahead style log**:

| Sections present | Inference |
| --- | --- |
| 1–6 only | SPEC complete → PLAN |
| 1–7 | PLAN complete → BUILD |
| 1–7 + partial 8 | BUILD in progress |
| 1–8 | BUILD complete → review |
| 1–10 | VERIFY complete |
| 1–11 | RETRO complete |

This is **domain-specific** (GSD stages) and **human-readable**.

### System B: transcript as the journal

The **JSONL transcript** is the journal: messages, tool calls, compaction summaries, and auxiliary entry types. **Stage completion** is **not** modeled as Markdown sections; progress is inferred from **message/tool history** and auxiliary entries (e.g. `turn_duration` checkpoints for consistency monitoring in `checkResumeConsistency`).

**Todos:** For non–todo-v2 paths, `extractTodosFromTranscript` scans for the last `TodoWrite` tool block (`sessionRestore.ts` ~72–93). Interactive todo v2 uses file-backed tasks separately.

**Skills:** `restoreSkillStateFromMessages` replays `invoked_skills` attachments into bootstrap state (`conversationRecovery.ts` ~382–403).

---

## 6. State reconciliation — detecting and resolving inconsistencies

### System A

Reconciliation is **first-class and procedural** (§9): manifest vs filesystem, plan sections vs `current_stage`, inbox vs decisions. **Stale PIDs** after restart are expected; the spec calls out **revalidation** rather than trusting `sub_agent_pid`.

**Orphan handling** is part of lifecycle §8: orphaned inbox directories without manifest entries → **warn and offer delete**; periodic cleanup for old archives.

### System B

- **`checkResumeConsistency`:** Compares `turn_duration` checkpoint `messageCount` to reconstructed chain index; logs `tengu_resume_consistency_delta` for monitoring (`sessionStorage.ts` ~2208–2242).
- **`deserializeMessages*`:**
  - Strips invalid `permissionMode` values from deserialized user messages (`conversationRecovery.ts` ~173–184).
  - `filterUnresolvedToolUses` removes dangling tool pairs.
  - Special cases like **brief mode** terminal tool results avoid false “interrupted” detection (`isTerminalToolResult`, `conversationRecovery.ts` ~348–372).
- **Parallel tool-result recovery:** `sessionStorage.ts` includes logic to **reinsert orphaned siblings/tool_results** when reconstructing chains (see comments ~2180–2205 in the read portion).
- **Team vs transcript:** `initializeTeammateContextFromSession` logs if **`member` not found** in team file (“may have been removed”) — **best-effort** alignment (`reconnection.ts` ~91–96).

---

## 7. Key differences — summary table

| Dimension | System A (Orchestrator) | System B (Claude Code + swarm) |
| --- | --- | --- |
| **Primary registry** | `manifest.json` (multi-worktree, cross-project) | Per-project session JSONL + optional `~/.claude/teams/.../config.json` |
| **Progress journal** | Append-only **plan Markdown** with section semantics | **Transcript** (messages + typed metadata entries) |
| **Atomicity** | Mailbox **`mv`**, single-writer manifest | Project flush + append patterns; team JSON overwrite |
| **Single agent death** | Orchestrator **detects PID**, reads plan + inbox, **respawns** with recovery prompt | **Resume** same session from transcript; swarm rehydrates **teamContext** from transcript + team file |
| **Full restart** | **Reconcile all manifest worktrees** to disk/git/inbox | **Resume/continue** chosen session(s); skip live BG sessions; **no** global ticket manifest |
| **Sub-agent persistence** | Explicitly **`--no-session-persistence`** in spawn plan | Session persistence **optional** at app level (`sessionPersistenceDisabled` in bootstrap state) |
| **Inconsistency handling** | Operational **reconciliation** + human prompt | **Automated transcript repair** + telemetry (`checkResumeConsistency`) |
| **Cross-cutting “swarm” state** | Mailboxes + manifest | **Team file** + transcript fields (`teamName`/`agentName` on messages) |

---

## 8. Recommendations — what an improved external orchestration system should adopt

1. **Keep a durable global index** (like **manifest.json**) for multi-ticket, multi-repo work — System B’s session-centric model does not replace this for **fleet-level** visibility.

2. **Retain an append-only, human-auditable journal** — the **plan file** pattern (System A) is excellent for **stage gates** and **legal/audit** clarity; pair it with machine-readable events if needed.

3. **Borrow transcript lessons from System B:**
   - **Interrupt detection** and **unresolved tool-use filtering** (`deserializeMessagesWithInterruptDetection`) avoid corrupted API turns after crash.
   - **Explicit consistency telemetry** (`checkResumeConsistency`) helps catch compaction/chain bugs early.
   - **Worktree state** persisted with **TOCTOU-safe** directory checks (`restoreWorktreeForResume`) avoids silently operating in deleted trees.

4. **Use atomic delivery** for inter-agent mail (System A’s **temp + `mv`**) wherever multiple writers exist; avoid shared mutable JSON without merge semantics.

5. **Treat orchestrator PIDs as hints** — always **reconcile** against plan + inbox + filesystem on boot (System A).

6. **For swarm-like topologies**, persist **membership and roles** in a small **team config** (System B’s `config.json` pattern) **plus** point-in-time references in the **journal** so removal/rename edge cases are diagnosable.

7. **Avoid duplicating state** — if using Claude Code subprocesses, decide explicitly whether they use **`--no-session-persistence`** (delegate durability to your layer, per `PLAN.md`) or full resume (delegate durability to CC’s transcript).

---

## References (files)

| System | Path |
| --- | --- |
| A | `~/personal/orchestrator/docs/orchestrator-spec.md` (§§5–9, 7) |
| A | `~/personal/orchestrator/PLAN.md` |
| A | `~/personal/orchestrator/config/manifest-template.json` |
| B | `~/Downloads/src/utils/sessionRestore.ts` |
| B | `~/Downloads/src/utils/conversationRecovery.ts` |
| B | `~/Downloads/src/utils/sessionStorage.ts` |
| B | `~/Downloads/src/utils/swarm/reconnection.ts` |
| B | `~/Downloads/src/utils/swarm/teamHelpers.ts` |
| B | `~/Downloads/src/hooks/useSwarmInitialization.ts` |
| B | `~/Downloads/src/bootstrap/state.ts` |
| B | `~/Downloads/src/state/AppStateStore.ts` |
