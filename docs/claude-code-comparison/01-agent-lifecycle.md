# Agent Lifecycle: Deep Technical Comparison

**Systems compared**

- **System A — “The Orchestrator” (external, user-built):** shell-script layer outside Claude Code, under `/Users/bensmith/personal/orchestrator/`.
- **System B — Claude Code internal swarm:** TypeScript implementation in `/Users/bensmith/Downloads/src/` (teammates, backends, in-process runner).

**Scope:** spawn, health, termination, recovery, process-model tradeoffs, and design takeaways.

---

## 1. Spawn mechanism

### System A (Orchestrator)

**Process model:** One OS subprocess per sub-agent: `claude` in **non-interactive print mode** (`-p`), launched under `nohup` from a subshell so it survives terminal hangup. Working directory is the ticket’s **git worktree** (`cd "$worktree"` before launch).

**Implementation (`bin/spawn-agent`):**

- Resolves `ORCH_HOME` (default `~/.orchestrator`), creates per-ticket dirs: `agents/$ticket`, `inboxes/$ticket`, logs.
- Sets `CLAUDE_CONFIG_DIR="$ORCH_HOME/agents/$ticket"` for isolated credentials/config per sub-agent (matches spec §13: separate config dir per instance).
- Default prompt if omitted: `Execute $stage stage for $ticket...` with plan path and worktree.
- Core invocation:

```bash
nohup bash -c "claude -p \
  --system-prompt-file \"$prompt_file\" \
  --allowedTools \"Read,Write,Edit,Bash,Grep,Glob\" \
  --max-turns 200 \
  --output-format json \
  --no-session-persistence \
  \"$prompt\" \
  >> \"$log_file\" 2>&1 &
echo \$! > \"$pid_file\""
```

- Captures the **inner** `claude` PID via a temp `pid_file`, polls up to ~2.5s, then **removes** `pid_file` and merges `sub_agent_pid` + `last_activity` into `manifest.json` with `jq` + atomic `mv` on a temp file.

**Isolation:**

- **Filesystem:** each ticket’s worktree + per-ticket `CLAUDE_CONFIG_DIR`.
- **No tmux/session multiplexing** in the script itself; persistence is explicitly **nohup + log file** (spec §13 recommends this pattern).

**Spec alignment:** Layer 3 describes sub-agents as Claude Code CLI with `--print`, GSD stages, mailbox writes; §13 documents the same flag set and `nohup` recommendation.

### System B (Claude Code swarm)

**Entry point:** `spawnTeammate()` → `handleSpawn()` in `tools/shared/spawnMultiAgent.ts`.

**Three execution paths:**

1. **In-process** (`handleSpawnInProcess`) when `isInProcessEnabled()` is true — e.g. `getIsNonInteractiveSession()` forces in-process because “tmux-based teammates don't make sense without a terminal UI” (`utils/swarm/backends/registry.ts`, `isInProcessEnabled`).
2. **Split-pane** (`handleSpawnSplitPane`) — `createTeammatePaneInSwarmView()` then `sendCommandToPane(paneId, spawnCommand, !insideTmux)`.
3. **Separate tmux window** (`handleSpawnSeparateWindow`) — `tmux new-window` + `send-keys` with the spawn command.

**Process model for pane backends:** A **new Claude Code process** is started in the pane by typing a shell command (not `nohup` in-app): `cd <cwd> && env <inherited> <binary> <teammateArgs><inheritedFlags>`. Binary from `getTeammateCommand()` — bundled `process.execPath` or `process.argv[1]`.

**Teammate identity CLI:** `--agent-id`, `--agent-name`, `--team-name`, `--agent-color`, `--parent-session-id`, optional `--plan-mode-required`, `--agent-type`.

**Initialization split:**

- **Pane teammates:** No prompt on the CLI; first work comes from **`writeToMailbox()`** — “The teammate's inbox poller will pick this up and submit it as their first turn” (`spawnMultiAgent.ts` comments).
- **In-process:** `spawnInProcessTeammate()` then `startInProcessTeammate()` with prompt in-process; **mailbox initial message is skipped** to avoid duplicates.

**Backend selection:** `detectAndGetBackend()` in `registry.ts` — priority: inside tmux → `TmuxBackend`; else iTerm2 + it2 → `ITermBackend`; else tmux external session; else error with install instructions. `buildInheritedEnvVars()` / `buildInheritedCliFlags()` (also duplicated in `spawnMultiAgent.ts` for the tool) propagate permission mode, model, plugins, API env vars (`spawnUtils.ts` lists `TEAMMATE_ENV_VARS` for tmux-spawned shells).

**Related files (not swarm lifecycle):** `utils/forkedAgent.ts` implements **in-process forked query loops** with cache-aligned params for skills/hooks — OS process spawn is not the model there. `utils/standaloneAgent.ts` only resolves **standalone vs swarm naming** in `AppState`, not spawn/kill.

---

## 2. Health monitoring

### System A

**Primary signal:** `manifest.json` field `sub_agent_pid` checked with **`kill -0`** in `bin/check-agent`:

```bash
pid="$(jq -r --arg t "$ticket" '.worktrees[$t].sub_agent_pid // empty' "$manifest")"
if kill -0 "$pid" 2>/dev/null; then
  echo "status: running"
else
  echo "status: not running (process exited or invalid)"
fi
```

**Secondary signal:** inbox file count under `$ORCH_HOME/inboxes/$ticket` (lists `.json` files).

**Limits:** Spec §9 states PIDs are **stale after restart** and must be revalidated. No heartbeat protocol in the scripts reviewed — “periodic health check, or inbox goes silent” is described in the spec as orchestrator behavior, not implemented in `check-agent` itself.

### System B

**Pane backends:** Health is implicit: **tmux pane id** / **iTerm session id** stored in `AppState.teamContext.teammates` and team file; user-visible **background task** via `registerOutOfProcessTeammateTask` (`registerTask`). No `kill -0` on a tracked PID in the snippets reviewed — liveness is **terminal UI + task state**.

**In-process:** `InProcessBackend.isActive()` checks `findTeammateTaskByAgentId`, `task.status === 'running'`, and `!task.abortController.signal.aborted` (`InProcessBackend.ts`).

**Reconnection:** `utils/swarm/reconnection.ts` — `computeInitialTeamContext()` / `initializeTeammateContextFromSession()` restore **team context from CLI or transcript**, not process health. “Heartbeat” is mentioned in comments as depending on restored `teamContext` after resume.

---

## 3. Termination

### System A

Scripts reviewed do **not** define `kill-agent` or graceful shutdown. Operational termination would be **OS signals** to the PID from manifest (not shown in `spawn-agent` / `check-agent`). Sub-agents use `--no-session-persistence`; each run is a bounded `claude -p` task (exits when done or hits `--max-turns`).

### System B

**Out-of-process teammates:** `registerOutOfProcessTeammateTask` attaches `AbortController.signal` to:

```typescript
abortController.signal.addEventListener('abort', () => {
  if (isPaneBackend(backendType)) {
    void getBackendByType(backendType).killPane(paneId, !insideTmux)
  }
}, { once: true })
```

(`spawnMultiAgent.ts`)

- **`TmuxBackend.killPane`:** `tmux kill-pane -t <paneId>` via `runTmuxInSwarm` or `runTmuxInUserSession` (`TmuxBackend.ts`).
- **`ITermBackend.killPane`:** `it2 session close -f -s <paneId>` — comment notes **`-f`** required to bypass iTerm2 “confirm before closing” (`ITermBackend.ts`). Clears `teammateSessionIds` state after close.

**In-process:** `InProcessBackend.terminate()` sends a **shutdown request** via `writeToMailbox` + `requestTeammateShutdown`. `kill()` calls `killInProcessTeammate(task.id, ...)` — immediate abort path. Spec in `types.ts`: pane teammates use `kill()`; in-process uses `abortController`.

---

## 4. Failure recovery

### System A

**Design (spec §9 — Cold Boot Recovery):**

- **Disk-first:** manifest, plan files, inboxes, git working tree — “no agent holds essential state only in memory.”
- **Single agent death:** detect PID gone → read plan → check inbox → respawn with **recovery prompt** (resume stage/steps).
- **Full restart:** reconcile manifest vs `git worktree list`, plan sections, diff, inbox messages, pending decisions → user-facing summary (“Resume all?”).
- **Guarantees:** no work lost (git + plan append-only); no duplicate work (plan as journal); orphaned state caught in reconciliation.

**Error/retry (spec §17):** Categories (transient, stuck, crash, logic, unrecoverable). Protocol: **two retries then escalate**; retry 1 from checkpoint; retry 2 with orchestrator reading **log file** and injecting diagnosis; then human options. `--max-turns 200` treats “stuck” as failure.

**CLI limitations (spec §13):** “No true daemon mode,” “terminal death kills the process” — mitigated by **nohup** for sub-agents; orchestrator session uses `--resume`.

### System B

**Swarm:** Recovery is **session/transcript-oriented**, not a global manifest:

- `reconnection.ts` rebuilds **teamContext** when resuming a session that stored `teamName` / `agentName`.
- **`ITermBackend`** has **at-fault recovery** when splitting a pane: if split fails targeting a teammate session, `it2 session list` can confirm dead session → prune ID and retry (`ITermBackend.ts` loop with `teammateSessionIds`).

**In-process:** `inProcessRunner.ts` implements a **poll loop** after turns: wait for mailbox messages or shutdown; **idle** state keeps teammate alive between turns (`while (!abortController.signal.aborted)`). On abort, typed outcomes include `'aborted'` / shutdown handling (grep shows `idleReason`, `shutdown_request`).

**Non-interactive:** `isInProcessEnabled()` true for `-p` sessions → teammates run **in-process**, avoiding tmux pane death for headless runs.

There is **no** equivalent to the orchestrator’s **cross-worktree cold boot** in the swarm code reviewed; recovery is per Claude Code process and team file + transcript.

---

## 5. Process model tradeoffs

| Aspect | Orchestrator (nohup + PID + worktree) | Swarm (tmux / iTerm2 / in-process) |
|--------|----------------------------------------|-------------------------------------|
| **Isolation** | Separate OS process + separate `CLAUDE_CONFIG_DIR` + git worktree | Separate OS process per pane *or* shared Node process (in-process) |
| **Visibility** | Log files under `~/.orchestrator/logs`; no built-in terminal UI | Panes with colored borders, `send-keys`, optional external tmux session `SWARM_SESSION_NAME` |
| **Headless / CI** | Natural fit: `claude -p` + nohup | Registry forces **in-process** when non-interactive; pane backends skipped |
| **Persistence** | Manifest + plan + mailbox; PID stale on reboot | Team file on disk; pane IDs can go stale if user closes pane (iTerm recovery path) |
| **Cost / sharing** | N full Claude processes, N config dirs | In-process shares API/MCP with leader (`InProcessBackend` docstring) |
| **Kill semantics** | External `kill` to PID (not wrapped in repo scripts here) | `tmux kill-pane` / `it2 session close -f` / `AbortController` |

**nohup + PID:** Enables orchestration **outside** the leader process and survives closing the spawning terminal. Tradeoff: PID bookkeeping drifts on crash/reboot until reconciled.

**tmux/iTerm2:** Visual multiplexing, attach/detach culture, but **depends on terminal infrastructure**; iTerm needs **force** close to avoid confirmation dialogs.

**In-process:** No separate OS process; **AsyncLocalStorage** isolation (`inProcessRunner.ts` / `InProcessBackend`); best for **non-interactive** and dense co-location; leader crash kills all teammates.

---

## 6. Key differences (summary table)

| Dimension | Orchestrator | Claude Code swarm |
|-----------|--------------|-------------------|
| **Spawn API** | `bin/spawn-agent` bash | `spawnTeammate()` → `handleSpawn*` / `createTeammatePaneInSwarmView` |
| **Sub-agent identity** | Ticket + stage + worktree path | `formatAgentId()` / `--agent-id` / team file |
| **Health check** | `check-agent` + `kill -0` + inbox count | Task state + `isActive()` / pane existence (implicit) |
| **Stop / kill** | Not in reviewed scripts; OS-level | `abort` → `killPane` or `killInProcessTeammate` |
| **Recovery anchor** | `manifest.json` + `.cursor/plans/TICKET.md` + inboxes | Team file + transcript + `reconnection.ts`; iTerm pane list for splits |
| **Retry policy** | Spec: 2 retries + escalate + log diagnosis | App-level (not duplicated in these files as a policy) |
| **Bounded execution** | `--max-turns 200` in spawn | Teammate model config + main loop behaviors |
| **Scope** | Multi-worktree, cross-ticket orchestration | Single leader session + team + optional panes |

---

## 7. Recommendations for an improved external orchestration system

1. **Keep disk-first state** from the orchestrator: manifest + append-only plan + atomic mailbox writes — enables cold boot without trusting PIDs.

2. **Treat PIDs as hints** — align with spec §9: always reconcile against filesystem + git + plan sections after restart; `check-agent`-style `kill -0` is useful but insufficient alone.

3. **Adopt swarm’s backend abstraction** where useful: `PaneBackend` with `killPane`, `sendCommandToPane`, and explicit **force** semantics for macOS terminals (iTerm’s `-f` lesson).

4. **For headless / automation**, mirror `isInProcessEnabled()` behavior conceptually: when no TTY multiplexing exists, avoid spawning pane-dependent processes; prefer **one-shot `claude -p`** or a single supervisor process.

5. **Separate graceful vs hard kill:** swarm’s `terminate()` (mailbox shutdown) vs `kill()` (abort) maps cleanly to external design: SIGTERM vs SIGKILL, or “request stop” message before `kill -0` fails.

6. **Propagate environment deliberately** — `buildInheritedEnvVars()` shows tmux/iTerm lose parent env; external orchestrators should document required env for API routing (`ANTHROPIC_BASE_URL`, etc.).

7. **Do not conflate** `forkedAgent` patterns with long-running teammates — forked agents optimize **cache-aligned short query loops** inside one session; orchestrator sub-agents are **separate lifetimes** per worktree.

8. **Encode retry policy as code** next to spawn (spec §17): same structured hooks the spec describes (checkpoint → log-assisted retry → escalate) beat ad-hoc reruns.

---

## File reference index

**Orchestrator**

- `/Users/bensmith/personal/orchestrator/docs/orchestrator-spec.md` — §3 Architecture, §9 Cold Boot, §13 CLI, §17 Error & Retry
- `/Users/bensmith/personal/orchestrator/bin/spawn-agent`
- `/Users/bensmith/personal/orchestrator/bin/check-agent`

**Claude Code (src)**

- `/Users/bensmith/Downloads/src/tools/shared/spawnMultiAgent.ts` — `spawnTeammate`, `handleSpawn`, `registerOutOfProcessTeammateTask`, `handleSpawnInProcess`
- `/Users/bensmith/Downloads/src/utils/swarm/backends/registry.ts` — `detectAndGetBackend`, `isInProcessEnabled`
- `/Users/bensmith/Downloads/src/utils/swarm/backends/types.ts` — `PaneBackend`, `TeammateExecutor`
- `/Users/bensmith/Downloads/src/utils/swarm/backends/TmuxBackend.ts` — `killPane`, `sendCommandToPane`
- `/Users/bensmith/Downloads/src/utils/swarm/backends/ITermBackend.ts` — `killPane`, split-pane recovery loop
- `/Users/bensmith/Downloads/src/utils/swarm/backends/InProcessBackend.ts` — `spawn`, `terminate`, `kill`, `isActive`
- `/Users/bensmith/Downloads/src/utils/swarm/inProcessRunner.ts` — in-process teammate loop, idle/shutdown
- `/Users/bensmith/Downloads/src/utils/swarm/spawnUtils.ts` — `buildInheritedEnvVars`, `buildInheritedCliFlags`
- `/Users/bensmith/Downloads/src/utils/swarm/reconnection.ts` — `computeInitialTeamContext`, `initializeTeammateContextFromSession`
- `/Users/bensmith/Downloads/src/utils/forkedAgent.ts` — forked query loops (distinct from swarm)
- `/Users/bensmith/Downloads/src/utils/standaloneAgent.ts` — standalone naming helper
