# Execution isolation: “The Orchestrator” vs Claude Code internal swarm

Deep technical comparison focused on **git worktrees**, **process boundaries**, **context isolation** (config, env, AsyncLocalStorage), **filesystem boundaries**, and **lifecycle**. Sources: `/Users/bensmith/personal/orchestrator/` (external orchestrator spec + `spawn-agent`) and `/Users/bensmith/Downloads/src/` (Claude Code tools + utilities).

---

## 1. Git worktree model

### System A — The Orchestrator (external, user-built)

**Design intent:** Each **sub-agent** executes inside a **dedicated git worktree directory** tied to a ticket. The orchestrator’s global view is the manifest; isolation of concurrent edits is primarily **filesystem + git**, not shared in-process state.

From **§3 Layer 3 (Sub-agents)**:

> **Invocation**: `claude` CLI with `--print` mode or piped prompts for non-interactive execution. **Each sub-agent runs in its own worktree directory.**

The **manifest** (`~/.orchestrator/manifest.json`) records the canonical path per unit of work under `worktrees.<ticket>.worktree_path` (§7):

```json
"worktrees": {
  "WBPR-3582": {
    "project": "wavebid-a2o",
    "branch": "feature/WBPR-3582-bulk-photo-upload",
    "worktree_path": "~/development/wavebid-a2o-wt/WBPR-3582",
    ...
  }
}
```

**Important:** `bin/spawn-agent` does **not** run `git worktree add`. It **requires** an existing directory (`--worktree <path>`) and fails if missing:

```35:38:/Users/bensmith/personal/orchestrator/bin/spawn-agent
if [[ ! -d "$worktree" ]]; then
  echo "Worktree not found: $worktree" >&2
  exit 3
fi
```

Worktree **creation** and **removal** are orchestrator lifecycle concerns: §8 specifies `git worktree remove` when a ticket is done, after manifest/inbox/review cleanup.

**Summary:** System A treats worktrees as **pre-provisioned checkout roots** per ticket; the spawn script only **enters** them (`cd "$worktree"`) and runs Claude Code there.

---

### System B — Claude Code (internal)

**Two related mechanisms:**

1. **Interactive session worktrees** — `EnterWorktreeTool` calls `createWorktreeForSession(getSessionId(), slug)`, then `process.chdir(worktreeSession.worktreePath)` and updates session state (`saveWorktreeState`, cache clears):

```90:101:/Users/bensmith/Downloads/src/tools/EnterWorktreeTool/EnterWorktreeTool.ts
    const slug = input.name ?? getPlanSlug()

    const worktreeSession = await createWorktreeForSession(getSessionId(), slug)

    process.chdir(worktreeSession.worktreePath)
    setCwd(worktreeSession.worktreePath)
    setOriginalCwd(getCwd())
    saveWorktreeState(worktreeSession)
    // Clear cached system prompt sections so env_info_simple recomputes with worktree context
    clearSystemPromptSections()
    // Clear memoized caches that depend on CWD
    clearMemoryFileCaches()
```

`utils/worktree.ts` implements **git** worktrees under `<repoRoot>/.claude/worktrees/<flattened-slug>` via `git worktree add` (or **hook-based** `WorktreeCreate` / `WorktreeRemove` when not using git — see `createWorktreeForSession` branches). The user-facing prompt (`prompt.ts`) states:

- In a git repo: creates under `.claude/worktrees/` with a branch based on HEAD.
- Outside git: hooks provide VCS-agnostic isolation.

2. **Agent / swarm worktrees (no global session mutation)** — `createAgentWorktree(slug)` reuses `getOrCreateWorktree` + `performPostCreationSetup` but **does not** set `currentWorktreeSession` or `process.chdir` (documented at `worktree.ts` ~896–900). That keeps **parallel agent** trees off the interactive session’s cwd state while still using the same on-disk layout under the **canonical** repo root (`findCanonicalGitRoot` so nested session worktrees do not create `.claude/worktrees` inside another worktree incorrectly).

**Exit scope:** `ExitWorktreeTool` only operates on worktrees created by **EnterWorktree in the current session** (`getCurrentWorktreeSession()` gate in `validateInput` and `call`). Manual `git worktree add` or prior-session trees are explicitly out of scope (`ExitWorktreeTool/prompt.ts`).

---

## 2. Process isolation

### System A

**Strong OS-level separation:** Each sub-agent is a **separate process** — typically `claude` invoked with `-p` (non-interactive). The spec §3 positions sub-agents as distinct CLI runs; §13 notes limitations (no daemon, terminal death kills the process unless `nohup`/tmux).

`spawn-agent` wraps execution in `nohup bash -c "claude -p ... &"` after `cd` into the worktree:

```64:77:/Users/bensmith/personal/orchestrator/bin/spawn-agent
(
  cd "$worktree"
  export ORCH_HOME
  export CLAUDE_CONFIG_DIR="$agent_config_dir"
  nohup bash -c "claude -p \
    --system-prompt-file \"$prompt_file\" \
    --allowedTools \"Read,Write,Edit,Bash,Grep,Glob\" \
    --max-turns 200 \
    --output-format json \
    --no-session-persistence \
    \"$prompt\" \
    >> \"$log_file\" 2>&1 &
  echo \$! > \"$pid_file\""
) >> \"$log_file\" 2>&1
```

The orchestrator can therefore run **N sub-agents concurrently** as **N processes**, subject to provider concurrency (§14 mentions queueing). There is **no** shared Node/V8 heap with the orchestrator.

**Sandboxing:** The spec does not describe containers, seccomp, or VM isolation — “isolation” here means **separate processes + separate working trees + separate config dirs**, not kernel-level sandboxing.

---

### System B

**Mixed model:**

- **Main Claude Code CLI / REPL:** One (or more) **Node/Bun** processes per invocation; user may use tmux (`execIntoTmuxWorktree` in `worktree.ts`) which still runs the **same** binary in a **new** process **per pane/session**, not a security sandbox.
- **In-process teammates (swarm):** `spawnInProcessTeammate` in `utils/swarm/spawnInProcess.ts` explicitly states they run in the **same Node.js process**:

```1:7:/Users/bensmith/Downloads/src/utils/swarm/spawnInProcess.ts
/**
 * In-process teammate spawning
 *
 * Creates and registers an in-process teammate task. Unlike process-based
 * teammates (tmux/iTerm2), in-process teammates run in the same Node.js
 * process using AsyncLocalStorage for context isolation.
```

So: **filesystem** may still use per-agent worktrees (`createAgentWorktree`), but **runtime identity and analytics** for concurrent in-process agents rely on **AsyncLocalStorage**, not fork/exec.

- **Process-based teammates:** `agentContext.ts` documents env-based identity for **tmux/iTerm2** (`CLAUDE_CODE_AGENT_ID`, `CLAUDE_CODE_PARENT_SESSION_ID`) — separate processes, env vars instead of ALS.

---

## 3. Context isolation — config dirs, environment, AsyncLocalStorage

### System A

**Per-ticket Claude config directory:** §13 “Multiple Instances”:

> Separate `CLAUDE_CONFIG_DIR` per instance to avoid credential conflicts … Each sub-agent gets its own config dir: `CLAUDE_CONFIG_DIR=~/.orchestrator/agents/<ticket> claude -p ...`

`spawn-agent` implements this literally:

```50:51:/Users/bensmith/personal/orchestrator/bin/spawn-agent
agent_config_dir="$ORCH_HOME/agents/$ticket"
mkdir -p "$agent_config_dir"
```

and:

```67:67:/Users/bensmith/personal/orchestrator/bin/spawn-agent
  export CLAUDE_CONFIG_DIR="$agent_config_dir"
```

**Additional paths:** Inboxes and logs are also per-ticket (`$ORCH_HOME/inboxes/$ticket`, `$ORCH_HOME/logs/$ticket-$stage.log`). The manifest is updated with `sub_agent_pid` and `last_activity` after spawn — process identity is tracked at the orchestration layer.

**Memory model for sub-agents:** `--no-session-persistence` in `spawn-agent` aligns with §13: sub-agents don’t rely on `.claude/` session history; the **plan file** in the repo is the durable memory.

---

### System B

**AsyncLocalStorage (ALS) — primary in-process isolation:**

| Module | Role |
|--------|------|
| `utils/teammateContext.ts` | `teammateContextStorage = new AsyncLocalStorage<TeammateContext>()` — `runWithTeammateContext`, `getTeammateContext` |
| `utils/agentContext.ts` | `agentContextStorage = new AsyncLocalStorage<AgentContext>()` — subagents vs teammates (`SubagentContext` / `TeammateAgentContext`) |

`agentContext.ts` explains **why** ALS instead of `AppState`:

```16:21:/Users/bensmith/Downloads/src/utils/agentContext.ts
 * WHY AsyncLocalStorage (not AppState):
 * When agents are backgrounded (ctrl+b), multiple agents can run concurrently
 * in the same process. AppState is a single shared state that would be
 * overwritten, causing Agent A's events to incorrectly use Agent B's context.
 * AsyncLocalStorage isolates each async execution chain, so concurrent agents
 * don't interfere with each other.
```

`teammateContext.ts` triangulates identity mechanisms:

```7:14:/Users/bensmith/Downloads/src/utils/teammateContext.ts
 * Relationship with other teammate identity mechanisms:
 * - Env vars (CLAUDE_CODE_AGENT_ID): Process-based teammates spawned via tmux
 * - dynamicTeamContext (teammate.ts): Process-based teammates joining at runtime
 * - TeammateContext (this file): In-process teammates via AsyncLocalStorage
 *
 * The helper functions in teammate.ts check AsyncLocalStorage first, then
 * dynamicTeamContext, then env vars.
```

**Worktree session state (module-level):** `utils/worktree.ts` uses `let currentWorktreeSession: WorktreeSession | null = null` — not ALS — for **EnterWorktree**’s linked session; concurrent **interactive** worktree sessions in one process are not the model here (EnterWorktree throws if already in a worktree session: `EnterWorktreeTool.ts` lines 78–81).

**Feature gating:** `worktreeModeEnabled.ts` returns `true` unconditionally (worktree mode always on).

---

## 4. Filesystem boundaries

### System A

- **Sub-agent cwd:** Exactly the ticket’s worktree path passed to `spawn-agent`.
- **Repo visibility:** Typically one checkout per ticket; the spec does not enforce chroot — the sub-agent can still access absolute paths the OS allows (e.g. `/tmp`, user home) unless constrained by Claude Code’s own rules or tool allowlists. `--allowedTools` in `spawn-agent` limits **tool surface**, not POSIX permissions.
- **Shared orchestration data:** `ORCH_HOME` (`~/.orchestrator`) holds manifest, inboxes, logs — **outside** the git worktree; agents write to **their** inbox via the mailbox protocol (single-writer design in §5).
- **Plan file:** Lives under the project (e.g. `.cursor/plans/TICKET.md`) — shared **conceptually** with humans and orchestrator, but **written** by one agent role at a time per spec discipline.

**Net:** Isolation is **“this ticket’s tree vs other tickets’ trees”** plus **mailbox invariants**, not a hardened sandbox.

---

### System B

- **EnterWorktree:** Session cwd moves to `worktreeSession.worktreePath`; `ExitWorktreeTool` restores `originalCwd` and clears cwd-dependent caches via `restoreSessionToOriginalCwd` (mirrors Enter mutations — see `ExitWorktreeTool.ts` ~115–146).
- **Canonical placement:** Agent worktrees use `findCanonicalGitRoot` in `createAgentWorktree` so paths stay under the main repo’s `.claude/worktrees/` even when spawning from inside another worktree (`worktree.ts` comments ~921–925).
- **Symlinks / sparse / includes:** `performPostCreationSetup` can symlink dirs (e.g. `node_modules`), copy `settings.local.json`, set hooks paths, and copy `.worktreeinclude` patterns — **intentional sharing** across main and worktree to save disk and preserve local secrets.
- **Safety on remove:** `ExitWorktreeTool` uses `countWorktreeChanges` and refuses destructive remove without `discard_changes` when there are uncommitted files or commits after baseline (`validateInput`).

**Net:** Filesystem isolation is **git worktree semantics + session bookkeeping**; ALS does not isolate disk — concurrent in-process agents must still rely on **separate worktree paths** when true file separation is required (`createAgentWorktree`).

---

## 5. Worktree lifecycle

### System A

| Phase | Behavior (spec + script) |
|-------|---------------------------|
| **Create** | Out of band (human/CI/orchestrator script) — `spawn-agent` only checks directory exists. |
| **Use** | `cd` worktree, run `claude -p`, log to `$ORCH_HOME/logs/`, PID written then merged into manifest. |
| **Track** | `manifest.json` — `worktree_path`, `branch`, `current_stage`, `sub_agent_pid`, `last_activity`. |
| **Done** | §8: remove manifest entry, delete inbox/archive/reviews, **`git worktree remove`**, keep plan file in main repo. |
| **Recovery** | §9: state on disk (manifest, plan, inboxes); respawn sub-agent with recovery prompt; PIDs may be stale after reboot. |

---

### System B

| Phase | Behavior |
|-------|----------|
| **Create (session)** | `getOrCreateWorktree` — fast resume if worktree already exists (read `readWorktreeHeadSha`); else `git worktree add` + optional sparse checkout + `performPostCreationSetup`. |
| **Create (agent)** | `createAgentWorktree` — same disk ops, **no** `currentWorktreeSession` / global chdir. |
| **Exit (session)** | `keepWorktree` vs `cleanupWorktree` — git `worktree remove` or hook; optional branch `-D`; `saveCurrentProjectConfig` clears `activeWorktreeSession`. |
| **Stale cleanup** | `cleanupStaleAgentWorktrees` — only **ephemeral** slug patterns (`agent-a…`, `wf_…`, `bridge-…`, etc.), fail-closed on dirty/unpushed state. |
| **Resume** | `restoreWorktreeSession` for `--resume`; EnterWorktree refuses double entry. |

---

## 6. Key differences — summary table

| Dimension | System A (Orchestrator) | System B (Claude Code) |
|-----------|-------------------------|-------------------------|
| **Worktree creation** | External to `spawn-agent`; manifest holds path | `createWorktreeForSession` / `createAgentWorktree` / hooks; under `.claude/worktrees/` (git) |
| **Process model** | **One OS process per sub-agent** (`claude -p`) | One main CLI process; **in-process teammates** share process; optional tmux = more processes |
| **Config / credentials** | **`CLAUDE_CONFIG_DIR=$ORCH_HOME/agents/<ticket>`** per sub-agent | Default project `.claude/`; ALS for identity; process teammates use **env vars** |
| **Concurrency context** | Separate processes + separate config dirs | **AsyncLocalStorage** for subagents/teammates in-process; AppState insufficient per comments |
| **Cwd / session** | Sub-agent starts **in** worktree directory | EnterWorktree **chdir** + `WorktreeSession`; Exit restores; agent worktrees may avoid global session |
| **Tool-level confinement** | `--allowedTools` whitelist in spawn script | Full product toolset unless policy restricts (not compared in depth here) |
| **Persistence** | `--no-session-persistence`; plan file + manifest | Session persistence optional; worktree state in project config + `saveWorktreeState` |
| **Sandbox** | None beyond OS + git + orchestrator conventions | None beyond git/worktree + ALS correctness; not a security boundary |

---

## 7. Recommendations — what an improved external orchestration system should adopt

1. **Explicit worktree creation API:** System A’s `spawn-agent` assumes the tree exists. A robust orchestrator should either invoke **`git worktree add`** (with naming, base branch, and cleanup parity to System B’s `getOrCreateWorktree`) or delegate to **hooks** for non-git VCS — matching Claude Code’s `hasWorktreeCreateHook()` / `executeWorktreeCreateHook` pattern.

2. **Per-agent `CLAUDE_CONFIG_DIR`:** Keep System A’s approach (§13 + `spawn-agent` lines 50–51, 67) to avoid credential/session collisions when many CLI instances share a host.

3. **Separate “interactive session worktree” vs “background agent worktree” state:** System B separates **`createWorktreeForSession`** (mutates session + cwd) from **`createAgentWorktree`** (disk only). External orchestrators spawning parallel sub-agents should adopt the **agent** pattern: do not conflate orchestrator cwd with every sub-agent’s tree.

4. **Ephemeral worktree GC:** Adopt patterns from `cleanupStaleAgentWorktrees` — **pattern-scoped** deletion, fail-closed on git uncertainty, and **mtime** bump on resume to avoid accidental removal.

5. **Destructive exit semantics:** Mirror `ExitWorktreeTool`’s `countWorktreeChanges` + `discard_changes` **explicit confirmation** before removing trees with local commits or dirty files.

6. **In-process vs out-of-process clarity:** If an external tool ever runs multiple agents **inside one runtime** (e.g. embedded SDK), **AsyncLocalStorage-style** per-async-chain context (as in `agentContext.ts` / `teammateContext.ts`) is preferable to global singletons — but for **strong** isolation, **System A’s multi-process model** remains strictly stronger for memory and failure domains.

7. **Observability:** Persist **PID + last_activity** (as `spawn-agent` jq merge into `manifest.json`) for health checks; combine with §9 cold-boot reconciliation so stale PIDs are not trusted blindly.

---

## References (file paths)

**System A**

- `/Users/bensmith/personal/orchestrator/docs/orchestrator-spec.md` — §3 (layers / worktree per sub-agent), §7 (`worktree_path`), §8 (lifecycle), §9 (recovery), §13 (`CLAUDE_CONFIG_DIR`, `nohup`, limitations)
- `/Users/bensmith/personal/orchestrator/bin/spawn-agent` — worktree `cd`, `CLAUDE_CONFIG_DIR`, `nohup`, manifest PID update

**System B**

- `/Users/bensmith/Downloads/src/tools/EnterWorktreeTool/EnterWorktreeTool.ts` — `createWorktreeForSession`, `chdir`, caches
- `/Users/bensmith/Downloads/src/tools/EnterWorktreeTool/prompt.ts` — user-facing worktree behavior
- `/Users/bensmith/Downloads/src/tools/ExitWorktreeTool/ExitWorktreeTool.ts` — `restoreSessionToOriginalCwd`, `countWorktreeChanges`, `keepWorktree` / `cleanupWorktree`
- `/Users/bensmith/Downloads/src/tools/ExitWorktreeTool/prompt.ts` — scope limits (session-only)
- `/Users/bensmith/Downloads/src/utils/worktree.ts` — `getOrCreateWorktree`, `createWorktreeForSession`, `createAgentWorktree`, `removeAgentWorktree`, `cleanupStaleAgentWorktrees`, `execIntoTmuxWorktree`
- `/Users/bensmith/Downloads/src/utils/worktreeModeEnabled.ts` — always-on worktree mode
- `/Users/bensmith/Downloads/src/utils/swarm/spawnInProcess.ts` — `spawnInProcessTeammate`
- `/Users/bensmith/Downloads/src/utils/teammateContext.ts` — `AsyncLocalStorage` teammate context
- `/Users/bensmith/Downloads/src/utils/agentContext.ts` — `AsyncLocalStorage` agent context; env vs ALS documentation
