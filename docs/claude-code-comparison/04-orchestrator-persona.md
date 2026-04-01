# Orchestrator Persona & Decision Authority: Deep Technical Comparison

**Research focus:** How each system’s coordinator/orchestrator decides what to do, what instructions it receives, which tools it may use, and how it delegates versus acting directly.

**Sources:**  
- **System A (external):** `/Users/bensmith/personal/orchestrator/` — `docs/orchestrator-spec.md` (§2 Vision, §3 Architecture), `CLAUDE.md`, `config/soul.md`, `config/sub-agent-prompt.md`  
- **System B (Claude Code internal):** `/Users/bensmith/Downloads/src/` — `coordinator/coordinatorMode.ts`, `utils/systemPrompt.ts`, `utils/toolPool.ts`, `constants/tools.ts`, `tools/AgentTool/prompt.ts`, `tools/AgentTool/AgentTool.tsx`, `tools/AgentTool/builtInAgents.ts`

---

## 1. Orchestrator identity

### System A — “The Orchestrator” (Chief of Staff)

The product vision casts the orchestrator as the **only agent the user talks to**, with a **chief-of-staff** interaction style: the user assigns work, requests briefings, and gets filtered escalations.

```35:46:/Users/bensmith/personal/orchestrator/docs/orchestrator-spec.md
The user works with a single **orchestrator agent** (in Claude Code or similar). This is the only agent the user interacts with directly. The orchestrator:

- Understands the user's intent at a high level
- Spawns and manages sub-agents across multiple git worktrees
- Monitors sub-agent progress through structured workflow stages
- Makes routine decisions autonomously (or escalates when judgment is needed)
- Presents finalized worktrees for human review with:
  - Summary of what changed and why
  - Decisions that were made (and by whom)
  - Decisions that need human input
  - Manual testing steps
- Provides a "morning brief" — state of all active work when the user sits down
```

Layer 2 explicitly names **judgment + routing**: maintaining global state via manifest, evaluating escalations, auto-advancing when risk is low, generating review packages at BUILD.

```70:89:/Users/bensmith/personal/orchestrator/docs/orchestrator-spec.md
### Layer 2: Orchestrator (judgment + routing)

- **Runtime**: Persistent process or resumable session
- **Model tier**: Top-tier — same as Layer 1, or could be the same instance
- **Responsibilities**:
  - Maintain global state across all worktrees (via manifest)
  - Evaluate sub-agent escalations: "Can I resolve this, or does the human need to see it?"
  - Auto-advance sub-agents through workflow stages when risk is low
  - Track dependencies between worktrees (if any)
  - Generate review packages when worktrees hit BUILD checkpoint
- **Decision authority**: Can auto-resolve decisions where:
  - Existing codebase patterns provide clear precedent
  - The plan file's risk level is Low
  - The decision doesn't change public API contracts
  - `.cursor/rules/` provides explicit guidance
- **Must escalate to human when**:
  - Architectural decisions (new patterns, new dependencies)
  - Anything rated Medium+ risk
  - Conflicting guidance from plan vs. codebase
  - Sub-agent confidence is low
```

The **runtime `CLAUDE.md`** opens with the same role label and ties it to concrete artifacts (`manifest.json`, inboxes, scripts):

```1:13:/Users/bensmith/personal/orchestrator/CLAUDE.md
# Orchestrator — Claude Code Context

You are the **orchestrator**: the single agent the user talks to. You manage sub-agents across multiple git worktrees, process their messages, make routine decisions, escalate when needed, and present work for human review. Read this file and `~/.orchestrator/soul.md` (if present) at session start.

## Your responsibilities

- **Manifest**: Maintain global state in `~/.orchestrator/manifest.json`. Only you write it. It holds `projects`, `worktrees`, and per-worktree state (branch, worktree_path, plan_file, current_stage, status, blocking_decision, risk_level, sub_agent_pid, last_activity, stage_history).
- **Inbox**: Read and process messages in `~/.orchestrator/inboxes/orchestrator/`. Sub-agents send `stage_complete` and `decision_needed` messages. Process them, then **archive** each message (move to `~/.orchestrator/archive/<ticket>/`) using `bin/mailbox-archive`.
- **Decisions**: For `decision_needed` messages, either auto-resolve (write a `decision_resolved` message to the sub-agent’s inbox) or escalate to the human and notify.
- **Sub-agents**: Start them with `bin/spawn-agent --ticket <TICKET> --stage <SPEC|PLAN|BUILD|VERIFY> --worktree <path>`. Check status with `bin/check-agent --ticket <TICKET>`.
- **User alerts**: Use `bin/notify --title "<title>" --message "<message>" --ticket <TICKET>` so the user gets a macOS notification; on click, `bin/open-review <TICKET>` runs.
- **Review packages**: When a worktree hits the BUILD checkpoint, write `~/.orchestrator/reviews/<TICKET>-review.md` (summary: what changed, why, decisions made/deferred) and `~/.orchestrator/reviews/<TICKET>-test-steps.md` (manual testing steps). Use `templates/review-package.md` as a guide.
- **Cleanup**: When a worktree is done (VERIFY passed, etc.), run `bin/mailbox-cleanup --ticket <TICKET>` to remove inbox, archive, reviews, and the worktree entry from the manifest.
```

### System B — Claude Code “Coordinator Mode”

Identity is **Claude Code**, but with a **coordinator** hat: orchestrate engineering work, **not** execute file/shell operations on the main thread.

```116:126:/Users/bensmith/Downloads/src/coordinator/coordinatorMode.ts
  return `You are Claude Code, an AI assistant that orchestrates software engineering tasks across multiple workers.

## 1. Your Role

You are a **coordinator**. Your job is to:
- Help the user achieve their goal
- Direct workers to research, implement and verify code changes
- Synthesize results and communicate with the user
- Answer questions directly when possible — don't delegate work that you can handle without tools

Every message you send is to the user. Worker results and system notifications are internal signals, not conversation partners — never thank or acknowledge them. Summarize new information for the user as it arrives.
```

So B’s “orchestrator” is **always** Claude Code-branded; it emphasizes **synthesis and user-facing communication**, and explicitly allows **answering without tools** when no delegation is needed (contrast with A, where the orchestrator is expected to drive stateful scripts and mailboxes).

---

## 2. Tool access

### System A

The spec does **not** strip tools from the orchestrator’s session. The orchestrator runs in a **normal interactive Claude Code–class session** and uses **project/orchestrator scripts** (`bin/mailbox-read`, `bin/spawn-agent`, `bin/notify`, etc.) as its “tools” via the same Read/Bash/Edit surface the host environment provides. Responsibilities in `CLAUDE.md` assume the model can **read/write** `~/.orchestrator/manifest.json`, inboxes, and review files.

Sub-agents are **separate** CLI invocations with a **restricted** tool allowlist (example from spec):

```572:579:/Users/bensmith/personal/orchestrator/docs/orchestrator-spec.md
```bash
claude -p \
  --system-prompt-file ~/.orchestrator/sub-agent-prompt.md \
  --allowedTools "Read,Write,Edit,Bash,Grep,Glob" \
  --mcp-config ~/.orchestrator/mcp-config.json \
  --max-turns 200 \
  --output-format json \
  "Execute SPEC stage for WBPR-3582. Read .cursor/plans/WBPR-3582.md for context."
```
```

**Summary:** Orchestrator = full agent + orchestration scripts; workers = constrained CLI agents with mailbox + GSD rules.

### System B

Coordinator mode **restricts** the main thread to a small fixed set. `COORDINATOR_MODE_ALLOWED_TOOLS` is the allowlist:

```107:112:/Users/bensmith/Downloads/src/constants/tools.ts
export const COORDINATOR_MODE_ALLOWED_TOOLS = new Set([
  AGENT_TOOL_NAME,
  TASK_STOP_TOOL_NAME,
  SEND_MESSAGE_TOOL_NAME,
  SYNTHETIC_OUTPUT_TOOL_NAME,
])
```

`applyCoordinatorToolFilter` in `utils/toolPool.ts` keeps only those names (plus MCP tools whose names end with `subscribe_pr_activity` / `unsubscribe_pr_activity`):

```35:40:/Users/bensmith/Downloads/src/utils/toolPool.ts
export function applyCoordinatorToolFilter(tools: Tools): Tools {
  return tools.filter(
    t =>
      COORDINATOR_MODE_ALLOWED_TOOLS.has(t.name) ||
      isPrActivitySubscriptionTool(t.name),
  )
}
```

The coordinator prompt in `getCoordinatorSystemPrompt()` names the **Agent**, **SendMessage**, **TaskStop**, and PR subscription tools — not Read/Bash/Edit:

```128:133:/Users/bensmith/Downloads/src/coordinator/coordinatorMode.ts
## 2. Your Tools

- **${AGENT_TOOL_NAME}** - Spawn a new worker
- **${SEND_MESSAGE_TOOL_NAME}** - Continue an existing worker (send a follow-up to its \`to\` agent ID)
- **${TASK_STOP_TOOL_NAME}** - Stop a running worker
- **subscribe_pr_activity / unsubscribe_pr_activity** (if available) - Subscribe to GitHub PR events (review comments, CI results). Events arrive as user messages. Merge conflict transitions do NOT arrive — GitHub doesn't webhook \`mergeable_state\` changes, so poll \`gh pr view N --json mergeable\` if tracking conflict status. Call these directly — do not delegate subscription management to workers.
```

**Workers** (async agents) get the broader `ASYNC_AGENT_ALLOWED_TOOLS` set — Read, Edit, Write, Grep, Glob, shell tools, Skill, worktree enter/exit, etc.:

```55:71:/Users/bensmith/Downloads/src/constants/tools.ts
export const ASYNC_AGENT_ALLOWED_TOOLS = new Set([
  FILE_READ_TOOL_NAME,
  WEB_SEARCH_TOOL_NAME,
  TODO_WRITE_TOOL_NAME,
  GREP_TOOL_NAME,
  WEB_FETCH_TOOL_NAME,
  GLOB_TOOL_NAME,
  ...SHELL_TOOL_NAMES,
  FILE_EDIT_TOOL_NAME,
  FILE_WRITE_TOOL_NAME,
  NOTEBOOK_EDIT_TOOL_NAME,
  SKILL_TOOL_NAME,
  SYNTHETIC_OUTPUT_TOOL_NAME,
  TOOL_SEARCH_TOOL_NAME,
  ENTER_WORKTREE_TOOL_NAME,
  EXIT_WORKTREE_TOOL_NAME,
])
```

`getCoordinatorUserContext()` injects a **dynamic string** listing the worker tool names (for the prompt), excluding internal “worker-only” tools like team create/delete in that helper:

```88:108:/Users/bensmith/Downloads/src/coordinator/coordinatorMode.ts
  const workerTools = isEnvTruthy(process.env.CLAUDE_CODE_SIMPLE)
    ? [BASH_TOOL_NAME, FILE_READ_TOOL_NAME, FILE_EDIT_TOOL_NAME]
        .sort()
        .join(', ')
    : Array.from(ASYNC_AGENT_ALLOWED_TOOLS)
        .filter(name => !INTERNAL_WORKER_TOOLS.has(name))
        .sort()
        .join(', ')

  let content = `Workers spawned via the ${AGENT_TOOL_NAME} tool have access to these tools: ${workerTools}`
```

**Summary:** B’s coordinator **cannot** directly Read/Write/Bash; it only **coordinates** and **subscribes to PR activity** (MCP). All repo inspection and edits happen in **workers**.

---

## 3. Delegation model

### System A

- **Three layers:** Human ↔ Orchestrator ↔ Sub-agents (`orchestrator-spec.md` §3). Sub-agents **never** talk to the human; they use the **mailbox** (`stage_complete`, `decision_needed`, `decision_resolved`).
- **Delegation** = spawn `claude` CLI in a worktree with `sub-agent-prompt.md`, GSD stages (SPEC → PLAN → BUILD → VERIFY), and atomic JSON messages.
- **Orchestrator** processes inbox, updates manifest, may auto-resolve or escalate, and may **re-spawn** with next stage after human checkpoints (spec §4, §5).

Sub-agent instructions are explicit about **no direct user contact**:

```1:4:/Users/bensmith/personal/orchestrator/config/sub-agent-prompt.md
# Sub-agent system prompt — Mailbox protocol & GSD workflow

You are a sub-agent of the orchestrator. You work in a single git worktree on one ticket. You do not interact with the human directly. All communication goes through the mailbox system.
```

### System B

- **Delegation** = `Agent` tool with `subagent_type: "worker"` (see `getCoordinatorSystemPrompt()` §2–3, §4–5). **Parallelism** is encouraged: multiple `Agent` calls in **one** assistant message.
- **Continue vs spawn** is first-class: `SendMessage` to reuse context vs new `Agent` for clean context (coordinator prompt §5).
- **Fork** (when feature-gated) is a separate path in `getPrompt()` for **non-coordinator**; coordinator gets a **slim** Agent tool description (`prompt.ts` — `if (isCoordinator) return shared`).

```214:218:/Users/bensmith/Downloads/src/tools/AgentTool/prompt.ts
  // Coordinator mode gets the slim prompt -- the coordinator system prompt
  // already covers usage notes, examples, and when-not-to-use guidance.
  if (isCoordinator) {
    return shared
  }
```

`AgentTool.tsx` passes `isCoordinator` into `getPrompt()` and forces **async** behavior for coordinator runs (among other conditions):

```223:224:/Users/bensmith/Downloads/src/tools/AgentTool/AgentTool.tsx
    const isCoordinator = feature('COORDINATOR_MODE') ? isEnvTruthy(process.env.CLAUDE_CODE_COORDINATOR_MODE) : false;
    return await getPrompt(filteredAgents, isCoordinator, allowedAgentTypes);
```

```567:567:/Users/bensmith/Downloads/src/tools/AgentTool/AgentTool.tsx
    const shouldRunAsync = (run_in_background === true || selectedAgent.background === true || isCoordinator || forceAsync || assistantForceAsync || (proactiveModule?.isProactiveActive() ?? false)) && !isBackgroundTasksDisabled;
```

**Built-in agent list** in coordinator mode is swapped via `getBuiltInAgents()`:

```35:42:/Users/bensmith/Downloads/src/tools/AgentTool/builtInAgents.ts
  if (feature('COORDINATOR_MODE')) {
    if (isEnvTruthy(process.env.CLAUDE_CODE_COORDINATOR_MODE)) {
      /* eslint-disable @typescript-eslint/no-require-exports */
      const { getCoordinatorAgents } =
        require('../../coordinator/workerAgent.js') as typeof import('../../coordinator/workerAgent.js')
      /* eslint-enable @typescript-eslint/no-require-exports */
      return getCoordinatorAgents()
    }
  }
```

*(Note: This workspace snapshot under `/Users/bensmith/Downloads/src/` contains `coordinator/coordinatorMode.ts` but not `coordinator/workerAgent.js`; the runtime is expected to supply `getCoordinatorAgents()` for coordinator-specific worker definitions.)*

Default worker persona (when general-purpose is used) is defined in e.g. `generalPurposeAgent.ts`:

```3:16:/Users/bensmith/Downloads/src/tools/AgentTool/built-in/generalPurposeAgent.ts
const SHARED_PREFIX = `You are an agent for Claude Code, Anthropic's official CLI for Claude. Given the user's message, you should use the tools available to complete the task. Complete the task fully—don't gold-plate, but don't leave it half-done.`

const SHARED_GUIDELINES = `Your strengths:
- Searching for code, configurations, and patterns across large codebases
- Analyzing multiple files to understand system architecture
- Investigating complex questions that require exploring many files
- Performing multi-step research tasks

Guidelines:
- For file searches: search broadly when you don't know where something lives. Use Read when you know the specific file path.
- For analysis: Start broad and narrow down. Use multiple search strategies if the first doesn't yield results.
- Be thorough: Check multiple locations, consider different naming conventions, look for related files.
- NEVER create files unless they're absolutely necessary for achieving your goal. ALWAYS prefer editing an existing file to creating a new one.
- NEVER proactively create documentation files (*.md) or README files. Only create documentation files if explicitly requested.`
```

---

## 4. Decision authority

### System A

- **Hierarchical filtering:** Sub-agents may escalate freely; the orchestrator **filters** what reaches the human (`orchestrator-spec.md` §11 table: “Orchestrator filters and only surfaces to human what genuinely requires human judgment”).
- **Auto-resolve** vs **escalate** rules are duplicated in `CLAUDE.md` and align with Layer 2:

```24:28:/Users/bensmith/personal/orchestrator/CLAUDE.md
## Decision authority

**Auto-resolve** when: codebase patterns give clear precedent, plan risk is Low, no public API change, and `.cursor/rules/` or soul.md give explicit guidance.

**Escalate to human** when: architectural decisions, new dependencies, medium+ risk, conflicting plan vs. codebase, or sub-agent confidence is low. Use `bin/notify` and present the decision and options clearly. Follow preferences in `soul.md`.
```

- **Human checkpoints** are explicit in GSD integration (SPEC/PLAN/BUILD/VERIFY) — orchestrator **presents** specs/plans/reviews; user approves testing before VERIFY, etc. (`orchestrator-spec.md` §4).

### System B

- **No separate “escalation” schema** to human from workers in the coordinator doc; the coordinator **synthesizes** worker results and talks to the user. **Task-notification XML** is the structured handoff from worker to coordinator (not a mailbox JSON).

```142:164:/Users/bensmith/Downloads/src/coordinator/coordinatorMode.ts
### ${AGENT_TOOL_NAME} Results

Worker results arrive as **user-role messages** containing \`<task-notification>\` XML. They look like user messages but are not. Distinguish them by the \`<task-notification>\` opening tag.

Format:

\`\`\`xml
<task-notification>
<task-id>{agentId}</task-id>
<status>completed|failed|killed</status>
<summary>{human-readable status summary}</summary>
<result>{agent's final text response}</result>
<usage>
  <total_tokens>N</total_tokens>
  <tool_uses>N</tool_uses>
  <duration_ms>N</duration_ms>
</usage>
</task-notification>
\`\`\`
```

- **Judgment** is pushed into the **coordinator’s synthesis step** (e.g. “never delegate understanding,” write concrete specs — `getCoordinatorSystemPrompt()` §5). Risk tiers and manifest are **not** built into this codebase path; authority is **prompt-driven**, not file-schema-driven.

---

## 5. System prompt construction

### System A

- **Primary instructions:** Repo-root `CLAUDE.md` (orchestrator role, paths, scripts, decision rules, cold boot, morning brief, soul reference).
- **Cross-session personality:** `~/.orchestrator/soul.md` (read at session start per `CLAUDE.md`).
- **Sub-agents:** `config/sub-agent-prompt.md` (or packaged copy at `~/.orchestrator/`) passed via `--system-prompt-file` for CLI runs.
- **Design reference:** `docs/orchestrator-spec.md` — not necessarily injected into the model every turn but cited as authoritative in `CLAUDE.md`.

### System B

`buildEffectiveSystemPrompt()` in `utils/systemPrompt.ts` defines **priority order**:

```28:40:/Users/bensmith/Downloads/src/utils/systemPrompt.ts
/**
 * Builds the effective system prompt array based on priority:
 * 0. Override system prompt (if set, e.g., via loop mode - REPLACES all other prompts)
 * 1. Coordinator system prompt (if coordinator mode is active)
 * 2. Agent system prompt (if mainThreadAgentDefinition is set)
 *    - In proactive mode: agent prompt is APPENDED to default (agent adds domain
 *      instructions on top of the autonomous agent prompt, like teammates do)
 *    - Otherwise: agent prompt REPLACES default
 * 3. Custom system prompt (if specified via --system-prompt)
 * 4. Default system prompt (the standard Claude Code prompt)
 *
 * Plus appendSystemPrompt is always added at the end if specified (except when override is set).
 */
```

When `COORDINATOR_MODE` is on and `CLAUDE_CODE_COORDINATOR_MODE` is truthy and there is **no** `mainThreadAgentDefinition`, the **default Claude Code prompt is replaced** by `getCoordinatorSystemPrompt()` plus optional `appendSystemPrompt`:

```59:75:/Users/bensmith/Downloads/src/utils/systemPrompt.ts
  // Coordinator mode: use coordinator prompt instead of default
  // Use inline env check instead of coordinatorModule to avoid circular
  // dependency issues during test module loading.
  if (
    feature('COORDINATOR_MODE') &&
    isEnvTruthy(process.env.CLAUDE_CODE_COORDINATOR_MODE) &&
    !mainThreadAgentDefinition
  ) {
    // Lazy require to avoid circular dependency at module load time
    const { getCoordinatorSystemPrompt } =
      // eslint-disable-next-line @typescript-eslint/no-require-imports
      require('../coordinator/coordinatorMode.js') as typeof import('../coordinator/coordinatorMode.js')
    return asSystemPrompt([
      getCoordinatorSystemPrompt(),
      ...(appendSystemPrompt ? [appendSystemPrompt] : []),
    ])
  }
```

The **Agent tool** description for coordinators is the **short** `shared` block from `getPrompt()` (agent types list + fork/subagent_type behavior), not the long non-coordinator sections.

---

## 6. Learning and adaptation

### System A — `soul.md` and 4-layer progression

Live `config/soul.md` is a **manual seed** with sections for decision preferences, escalation preferences, communication style, project notes, and **pending observations**:

```1:32:/Users/bensmith/personal/orchestrator/config/soul.md
# Orchestrator Soul

> Last updated: 2026-02-23
> Auto-proposals below this line are pending review.

## Decision Preferences

- Prefer existing codebase patterns over new abstractions unless the new abstraction serves 3+ use cases
- When two approaches are technically equivalent, choose the one with less surface area for bugs
- Default to incremental changes over big-bang refactors

## Escalation Preferences

- ALWAYS escalate: new dependencies, public API changes, architectural decisions, anything touching auth
- NEVER escalate: naming choices, import ordering, test structure decisions, formatting
- ASK ME: when the risk level is medium+ or when the sub-agent's confidence is low

## Communication Style

- Be direct. Don't pad with caveats.
- Lead with what needs my attention, not what went well.
- When presenting decisions, give me the recommendation and the reasoning, not a menu of options.

## Project-Specific Notes

### (Add project names as they are registered)

---

## Pending Observations

> The orchestrator appends observations here. Review and promote to sections above, or delete.
```

The **spec** defines a **4-layer** progression (manual seed → passive `observations.jsonl` → propose at RETRO → future auto-add with notification):

```786:812:/Users/bensmith/personal/orchestrator/docs/orchestrator-spec.md
The orchestrator learns preferences through a 4-layer progression:

**Layer 1 — Manual Seed (launch)**
Soul.md starts with known preferences from this design conversation. Not empty on day one.

**Layer 2 — Passive Observation (always running)**
The orchestrator tracks patterns across interactions in a scratch file (`~/.orchestrator/observations.jsonl`):

```json
{"timestamp": "...", "type": "rejection_pattern", "observation": "User rejected PLAN that didn't include error handling for 3rd time", "confidence": "high", "occurrences": 3}
{"timestamp": "...", "type": "escalation_feedback", "observation": "User said 'don't ask me about this kind of thing' when presented with a naming decision", "confidence": "high", "occurrences": 1}
{"timestamp": "...", "type": "approval_pattern", "observation": "User consistently approves SPECs without changes when they include API contract analysis", "confidence": "medium", "occurrences": 5}
```

**Layer 3 — Propose at Natural Breakpoints (RETRO hook)**
After each completed GSD cycle (during RETRO), or after a batch of decisions, the orchestrator reviews observations and proposes additions:

> *"I've noticed you've rejected the last 3 plans that didn't account for error states. Add to soul.md: 'Plans must include explicit error handling for every new code path'?"*

User approves → added to soul.md. User rejects → observation is discarded.

**Layer 4 — Auto-Add (future, earned trust)**
Once the orchestrator has a track record of accurate proposals (e.g., 10+ approved, <2 rejected), it starts auto-adding with a notification:

> *"Added to soul.md: 'Prefer streaming over batch processing for real-time features.' (Based on 4 consistent decisions. Edit soul.md to remove.)"*

This mirrors how Cursor Memories evolved from "suggest" to "auto" as it built confidence.
```

### System B

- **No `soul.md` equivalent** in the coordinator path in this repository. Coordinator instructions are **fixed** in code (`getCoordinatorSystemPrompt()`).
- **Optional** `appendSystemPrompt` can still append after the coordinator prompt (`buildEffectiveSystemPrompt`), giving users a hook for persistent preferences without a dedicated “soul” file in this module.
- **Project memory** (e.g. `CLAUDE.md`, user memory files) applies to **workers** that load the normal project context; the coordinator **does not** use the default prompt that typically embeds that stack, so **cross-session orchestrator personality** is not first-class here unless injected via `appendSystemPrompt` or similar.

---

## 7. Key differences — summary table

| Dimension | System A (external orchestrator) | System B (Claude Code coordinator mode) |
|-----------|----------------------------------|-------------------------------------------|
| **Identity** | Chief of staff; single human-facing agent; manifest + mailbox “brain” | Claude Code coordinator; synthesis + user-facing channel |
| **Direct tools** | Full session + scripts (Read/Bash/Edit as host allows) | **Only** Agent, SendMessage, TaskStop, SyntheticOutput + PR subscription MCP tools |
| **Worker tools** | CLI `--allowedTools` + MCP (spec example) | `ASYNC_AGENT_ALLOWED_TOOLS` (Read, shell, edit, skills, worktrees, …) |
| **Delegation** | Spawn `claude -p` per worktree; JSON mailbox | `Agent` async + `SendMessage` / `TaskStop`; `<task-notification>` XML |
| **Escalation / authority** | Explicit auto-resolve vs human rules; risk levels; soul.md | Prompt-led synthesis; no mailbox schema for “decision_needed” |
| **System prompt** | `CLAUDE.md` + `soul.md` + sub-agent file | `getCoordinatorSystemPrompt()` **replaces** default prompt (`systemPrompt.ts`) |
| **Agent tool text** | N/A (external) | Slim `getPrompt(..., isCoordinator=true)` in `prompt.ts` |
| **Persistent learning** | `soul.md` + spec’d 4-layer + `observations.jsonl` | Not built into coordinator; optional `appendSystemPrompt` |
| **Human vs sub-agent** | Sub-agents never talk to human | Workers don’t “talk” to user; coordinator relays |

---

## 8. Recommendations — what an improved external orchestration system should adopt

1. **Hard separation of coordinator tools (from B).** Proven pattern: coordinators that **cannot** edit the repo directly avoid “split brain” and force a **single synthesis step** before implementation. External orchestrators can mirror this by running the orchestrator in a **restricted allowlist** profile (similar to `COORDINATOR_MODE_ALLOWED_TOOLS`) while workers retain Read/Write/Bash/MCP.

2. **Structured worker handoff (from B).** `<task-notification>`-style envelopes with **task-id, status, summary, result** make coordinator turns deterministic. External JSON mailboxes (A) are richer for **typed decisions**; combining **B’s envelope** for completion + **A’s `decision_needed` schema** for escalation keeps UX and auditability.

3. **Explicit “never delegate understanding” (from B).** `getCoordinatorSystemPrompt()` §5 is a strong guardrail for external prompts too: require **file paths, line numbers, and concrete specs** in follow-up prompts — already aligned with A’s emphasis on orchestrator judgment.

4. **Parallelism semantics (from B).** “Multiple Agent calls in one message” is a concrete UX/throughput pattern; external spawn scripts should **queue/batch** parallel sub-agents where the host model supports multi-tool turns.

5. **Soul-equivalent with appendable policy (from A).** Keep **cross-project** behavior and escalation rules in a **single editable file** (`soul.md`) plus the **4-layer** spec for **observability → propose → (future) auto-add**. B’s coordinator would benefit from this; an external system should implement **Layer 2–3** even if Layer 4 stays manual.

6. **Manifest + cold boot (from A).** Disk-first `manifest.json` + plan files + inbox replay is a **clear recovery story** B doesn’t encode in the coordinator prompt; external orchestration should keep this as the **source of truth** for multi-worktree state.

7. **PR orchestration hooks (from B).** First-class **subscribe_pr_activity** in the coordinator filter acknowledges that **some** tools must stay on the orchestrator. External systems should allow **narrow** direct tools (notifications, PR hooks, issue trackers) without opening full filesystem access.

---

*Document generated for research comparison. Paths and line references reflect the repositories as read on 2026-03-31.*
