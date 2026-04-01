# Agent Orchestration: Permission & Security Model Comparison

Deep technical comparison of **System A — external “Orchestrator”** (`~/personal/orchestrator/`) and **System B — Claude Code internal swarm** (code under `utils/swarm/`, `hooks/toolPermission/`). Focus: what agents may do, how constraints propagate to children, tool restrictions, escalation, and trust boundaries.

---

## 1. Permission model

### System A: Orchestrator (external)

**Runtime contract** is enforced by **how the orchestrator invokes** `claude -p`, not by a nested permission runtime inside Claude Code.

- **Non-interactive print mode** (`-p`): Sub-agents do not drive an interactive REPL; permission UX is bypassed for listed tools via CLI flags.
- **`--allowedTools`**: Documented as *auto-approve tools (no permission prompts)* for the fixed set used in sub-agent runs.

From the validated-capabilities table:

| Flag | Purpose in orchestrator |
|------|------------------------|
| `--allowedTools` | Auto-approve tools (no permission prompts) |

(Source: `docs/orchestrator-spec.md` §13, “Key Flags for This Architecture”.)

- **Safety rails** are largely **operational**: `--max-turns`, optional `--max-budget-usd`, `--no-session-persistence`, per-ticket `CLAUDE_CONFIG_DIR` isolation.
- **Policy for “what the agent may decide”** is partly **prompt-based**: `config/sub-agent-prompt.md` instructs sub-agents to escalate architecture, dependencies, and low-confidence cases via **mailbox messages** (`decision_needed`) rather than acting unilaterally.

**Note on `--dangerously-skip-permissions`:** Section 13 of `orchestrator-spec.md` documents `--allowedTools`, MCP, budgets, and session flags. It does **not** define `--dangerously-skip-permissions`. That flag appears in **System B** when propagating the leader’s permission mode to spawned teammate processes (see §3).

### System B: Claude Code swarm (internal)

**Two layers**:

1. **Static permission context** (`ToolPermissionContext`): allow/deny/ask rules, mode (`default`, `acceptEdits`, `bypassPermissions`, `plan`, `auto`, etc.), and session flags such as `awaitAutomatedChecksBeforeDialog` (used to route “coordinator” workers).
2. **Dynamic resolution** via `hasPermissionsToUseTool` in `utils/permissions/permissions.ts`, which returns `allow` | `deny` | `ask` (with suggestions, classifier hooks, etc.).

**Swarm-specific behavior** is layered in `hooks/useCanUseTool.tsx` when `behavior === 'ask'`:

1. If `toolPermissionContext.awaitAutomatedChecksBeforeDialog` is true → **`handleCoordinatorPermission`** (hooks, then classifier, **no** user dialog until those complete or fail through).
2. Else → **`handleSwarmWorkerPermission`** (classifier for Bash first, then **forward to leader** via mailbox).
3. If still unresolved → **`handleInteractivePermission`** (full UI queue, optional bridge/channel relay).

Workers are detected with `isSwarmWorker()` in `utils/swarm/permissionSync.ts` (requires `teamName`, `agentId`, and not team leader).

**Team-wide allow rules**: On teammate startup, `initializeTeammateHooks` in `utils/swarm/teammateInit.ts` may apply `teamFile.teamAllowedPaths` as **session-scoped allow rules** via `applyPermissionUpdate` (additive `addRules` to `destination: 'session'`).

---

## 2. Permission propagation

### System A

- **CLI inheritance**: Each sub-agent is spawned with `CLAUDE_CONFIG_DIR="$ORCH_HOME/agents/$ticket"` (`bin/spawn-agent`), isolating settings and credentials per ticket.
- **No live “parent → child” permission channel**: The orchestrator does not forward interactive approvals; it **re-spawns** `claude -p` with the same static flags unless the operator changes scripts or config.
- **Escalation path** is **application-level**: sub-agent → JSON in orchestrator inbox → human/orchestrator decision → `decision_resolved` message back to the ticket inbox (`config/sub-agent-prompt.md`).

### System B

- **Spawned OS processes (e.g. tmux teammates)**: `buildInheritedCliFlags` in `utils/swarm/spawnUtils.ts` propagates:
  - Leader `permissionMode === 'bypassPermissions'` **or** session bypass → `--dangerously-skip-permissions`
  - `acceptEdits` → `--permission-mode acceptEdits`
  - **Plan mode guard**: If `planModeRequired`, **bypass is not inherited** (“Plan mode takes precedence over bypass permissions for safety”).
  - Also propagates `--model`, `--settings`, `--plugin-dir`, `--teammate-mode`, chrome flags.

A parallel implementation in `tools/shared/spawnMultiAgent.ts` additionally propagates `--permission-mode auto` when the leader is in `auto` mode.

- **In-process teammates**: `leaderPermissionBridge.ts` exposes **`registerLeaderToolUseConfirmQueue`** and **`registerLeaderSetToolPermissionContext`** so the leader’s REPL can serve permission UI for workers.
- **Worker permission flow**: `sendPermissionRequestViaMailbox` / `sendPermissionResponseViaMailbox` in `permissionSync.ts` route requests using **`getLeaderName`** (from team file) and **`writeToMailbox`**.

---

## 3. Tool whitelisting

### System A

`bin/spawn-agent` passes a **fixed** allowlist:

```bash
--allowedTools "Read,Write,Edit,Bash,Grep,Glob"
```

The spec’s example also shows `--mcp-config` for MCP-enabled sub-agents; the checked `spawn-agent` script does **not** pass `--mcp-config` (only `--system-prompt-file`, `--allowedTools`, `--max-turns`, `--output-format json`, `--no-session-persistence`). Actual deployments may wrap or extend this.

**Effect**: Only those tools are auto-approved at the Claude Code CLI layer; anything else would require prompts or would be unavailable depending on CLI behavior—so the **shell script is the tool whitelist**.

### System B

- **Global tool gating** still goes through `hasPermissionsToUseTool` and rule sets in `ToolPermissionContext`.
- **Sub-agents / agents** use `filterToolsForAgent` and `resolveAgentTools` in `tools/AgentTool/agentToolUtils.ts`:
  - MCP tools (`mcp__*`) are allowed through the filter.
  - `ALL_AGENT_DISALLOWED_TOOLS` / `CUSTOM_AGENT_DISALLOWED_TOOLS` remove dangerous or inappropriate tools from agent pools.
  - Async agents get a stricter set; **in-process swarm teammates** get explicit exceptions for `AGENT_TOOL_NAME` and `IN_PROCESS_TEAMMATE_ALLOWED_TOOLS` when `isAgentSwarmsEnabled() && isInProcessTeammate()`.

- **Teammate spawn config** (`utils/swarm/backends/types.ts`): `TeammateSpawnConfig` includes optional **`permissions?: string[]`** and **`allowPermissionPrompts?: boolean`** (“When false (default), unlisted tools are auto-denied”).

- **In-process runner** (`utils/swarm/inProcessRunner.ts`): Resolved agent definitions inject **team-essential tools** (message, task list, team create/delete) and set `permissionMode: 'default'` on the custom agent definition so teammates get **full tool access subject to normal permission checks**, not a stripped-down mode.

---

## 4. Permission escalation

### System A

- **Escalation = out-of-band messaging**, not elevated CLI flags mid-run:
  - Sub-agent writes `decision_needed` to `$ORCH_HOME/inboxes/orchestrator/` with structured payload.
  - Human/orchestrator responds with `decision_resolved` in the ticket inbox.
- **No automatic elevation** of `--allowedTools` inside a running `claude -p` session; changing capability requires a **new invocation** with different flags or prompt.

### System B

- **Workers → leader**: `handleSwarmWorkerPermission` (`hooks/toolPermission/handlers/swarmWorkerHandler.ts`):
  1. Optional Bash **classifier** auto-approval (`ctx.tryClassifier`).
  2. **`createPermissionRequest`** then **`registerPermissionCallback`** (before send to avoid races).
  3. **`sendPermissionRequestViaMailbox(request)`** to the leader.
  4. Leader approval triggers **`ctx.handleUserAllow`** with merged input and **`permissionUpdates`** (e.g. “always allow” rules).
  5. On failure to send, handler returns `null` and flow can fall through (see below).

- **Sandbox network**: `sendSandboxPermissionRequestViaMailbox` / `sendSandboxPermissionResponseViaMailbox` in `permissionSync.ts` for host-level approvals.

- **Coordinator path**: `handleCoordinatorPermission` runs **`ctx.runHooks`** then **`ctx.tryClassifier`** sequentially; if neither resolves, returns `null` and the pipeline may reach interactive handling—appropriate for background workers that should not pop dialogs until automated checks finish.

- **Interactive path**: `handleInteractivePermission` supports local dialog, **REPL bridge** (`bridgeCallbacks`), and **channel** relay (`channelCallbacks`).

---

## 5. Trust boundaries

### System A

| Boundary | Role |
|----------|------|
| **Orchestrator + operator** | Chooses projects, stages, and **spawn command** (tools, budgets, MCP config). |
| **`bin/spawn-agent`** | Hardcoded `--allowedTools`; enforces non-interactive contract. |
| **`~/.orchestrator/` (ORCH_HOME)** | Mailbox and manifests; human reads escalations here. |
| **Claude Code CLI** | Enforces `-p` + allowedTools as configured; sub-agent does not talk to the user directly (prompt constraint). |

The **trust model** is: *anything the orchestrator puts on the command line is trusted to run unsupervised* for that invocation.

### System B

| Boundary | Role |
|----------|------|
| **Leader session** | Owns `ToolPermissionContext`, confirm queue (via `leaderPermissionBridge`), and user approvals for forwarded worker requests. |
| **Team file + mailboxes** | `~/.claude/teams/{team}/...` (e.g. `getPermissionDir`, mailbox routing in `permissionSync.ts`). |
| **Plan mode** | Blocks inheriting `--dangerously-skip-permissions` in `buildInheritedCliFlags`. |
| **Worker identity** | `isSwarmWorker()` ensures worker-specific path; leaders identified via `isTeamLeader()` (no agent id or `team-lead`). |

---

## 6. Key differences (summary table)

| Dimension | System A — Orchestrator | System B — Claude Code swarm |
|-----------|---------------------------|------------------------------|
| **Primary enforcement** | CLI flags (`--allowedTools`, `-p`) + isolated `CLAUDE_CONFIG_DIR` | In-app `ToolPermissionContext` + `hasPermissionsToUseTool` + handlers |
| **Sub-agent tool scope** | Fixed string in `spawn-agent` | Spawn `permissions` + filters in `agentToolUtils`; in-process teammate may use `'*'` with injections |
| **Interactive prompts** | Effectively disabled for listed tools via auto-approve | Workers defer to **leader UI** or automated hooks/classifier; main agent uses full interactive handler |
| **Propagation** | Re-spawn with same/different flags; no live sync | CLI flags from `buildInheritedCliFlags`; mailbox + optional leader bridge |
| **Bypass / dangerous mode** | Not used in orchestrator spec/script; relies on explicit allowlist | `--dangerously-skip-permissions` propagated when leader uses bypass (unless plan mode) |
| **Escalation** | Mailbox JSON protocols | Mailbox permission messages + file-based pending/resolved + `PermissionUpdate` persistence |
| **Team-wide policy** | Project rules + soul.md (behavioral) | `teamAllowedPaths` → session allow rules in `teammateInit.ts` |

---

## 7. Recommendations for an improved external orchestration system

1. **Adopt explicit capability tiers per stage**  
   Mirror System B’s separation: *static allowlist* (like `--allowedTools`) for mechanical stages, optional *narrower* lists for SPEC vs BUILD, instead of one global string for all stages.

2. **Add a real escalation channel for “ask” tools**  
   System A’s mailbox is strong for **decisions**; System B shows value in **forwarding tool permission requests** to a supervising process. An external orchestrator could poll a **permission inbox** or use a small sidecar to approve/deny tool classes without restarting `claude -p`.

3. **Propagate parent policy deliberately**  
   Use System B’s pattern: **plan/safety gates** that block inheriting bypass (`planModeRequired` in `buildInheritedCliFlags`), and document when `--dangerously-skip-permissions`-equivalent behavior is unacceptable for sub-agents.

4. **Persist “always allow” style rules**  
   System B’s `permissionUpdates` + `persistPermissions` in `PermissionContext.ts` allows approvals to narrow future prompts. External orchestrators could mirror this in **per-ticket or per-repo JSON** consumed on each spawn.

5. **Separate coordinator vs interactive semantics**  
   `awaitAutomatedChecksBeforeDialog` + `handleCoordinatorPermission` model **headless workers** that run hooks/classifiers but avoid user dialogs until necessary—useful for CI-like VERIFY stages in an external system.

6. **Keep the trust boundary explicit**  
   System A is correct that **the spawn command is the security perimeter**. Any addition of MCP or extra tools should be **reviewed as tightly** as changing `--allowedTools`, matching how System B treats spawn `permissions` and `allowPermissionPrompts`.

---

## Code references (quick index)

| Artifact | Path |
|----------|------|
| Orchestrator CLI table §13 | `~/personal/orchestrator/docs/orchestrator-spec.md` |
| Sub-agent behavioral constraints | `~/personal/orchestrator/config/sub-agent-prompt.md` |
| Spawn invocation | `~/personal/orchestrator/bin/spawn-agent` |
| Swarm permission sync | `utils/swarm/permissionSync.ts` (`createPermissionRequest`, `sendPermissionRequestViaMailbox`, `isSwarmWorker`, `isTeamLeader`) |
| Leader REPL bridge | `utils/swarm/leaderPermissionBridge.ts` (`registerLeaderToolUseConfirmQueue`, `registerLeaderSetToolPermissionContext`) |
| Worker handler | `hooks/toolPermission/handlers/swarmWorkerHandler.ts` (`handleSwarmWorkerPermission`) |
| Coordinator handler | `hooks/toolPermission/handlers/coordinatorHandler.ts` (`handleCoordinatorPermission`) |
| Interactive handler | `hooks/toolPermission/handlers/interactiveHandler.ts` (`handleInteractivePermission`) |
| Permission context | `hooks/toolPermission/PermissionContext.ts` (`createPermissionContext`, `persistPermissions`, `tryClassifier`, `runHooks`) |
| Permission pipeline | `hooks/useCanUseTool.tsx` |
| CLI flag propagation | `utils/swarm/spawnUtils.ts` (`buildInheritedCliFlags`) |
| Teammate session rules | `utils/swarm/teammateInit.ts` (`initializeTeammateHooks`) |
| Agent tool filtering | `tools/AgentTool/agentToolUtils.ts` (`filterToolsForAgent`) |

---

*Generated for research: permission models and propagation in external orchestrator vs Claude Code swarm.*
