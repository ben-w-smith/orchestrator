# Task & Work Coordination: Deep Technical Comparison

**Research focus**: How work is assigned, tracked, and coordinated across agents; how stages and phases are modeled.

**System A**: “The Orchestrator” — external, user-built layer at `~/personal/orchestrator/` integrating with the GSD workflow.

**System B**: Claude Code’s internal swarm / task / team tooling — implementation under `/Users/bensmith/Downloads/src/` (Task* tools, `utils/tasks.ts`, coordinator mode).

**Naming disambiguation (System B)**: The codebase uses “task” in two senses:

1. **Swarm / session task list** — JSON files under `~/.claude/tasks/{team-name}/`, manipulated by `TaskCreate`, `TaskUpdate`, `TaskList`, `TaskGet`. This is the coordination substrate for multi-agent work.
2. **Background execution tasks** — in-memory `AppState.tasks` for async shells/agents; `TaskStop` and `TaskOutput` operate on these (`utils/task/framework.ts`, `TaskStopTool.ts`), not on the shared JSON todo list.

This document focuses on **(1)** for coordination, and notes **(2)** where it affects stopping or reading sub-agent output.

---

## 1. Task / work unit model

### System A (Orchestrator + GSD)

- **Primary work unit**: A **ticket** (e.g. `WBPR-3582`) with a **dedicated git worktree** and a **single plan file** `.cursor/plans/[TICKET-ID].md` that accumulates SPEC → PLAN → BUILD log → VERIFY → RETRO sections over time (`gsd/README.md`, `gsd/spec-gsd.md`, `gsd/plan-gsd.md`, etc.).
- **Orchestrator state**: The **manifest** is the authoritative record per ticket: project, branch, `worktree_path`, `plan_file`, `current_stage`, `stage_history`, `status`, `blocking_decision`, `risk_level`, `sub_agent_pid`, `last_activity` (`docs/orchestrator-spec.md` §7).

```291:326:/Users/bensmith/personal/orchestrator/docs/orchestrator-spec.md
{
  "last_updated": "ISO-8601",
  "worktrees": {
    "WBPR-3582": {
      "project": "wavebid-a2o",
      "branch": "feature/WBPR-3582-bulk-photo-upload",
      "worktree_path": "~/development/wavebid-a2o-wt/WBPR-3582",
      "plan_file": ".cursor/plans/WBPR-3582.md",
      "current_stage": "BUILD",
      "stage_history": [
        { "stage": "SPEC", "completed": "ISO-8601", "result": "success" },
        {
          "stage": "PLAN",
          "completed": "ISO-8601",
          "result": "success",
          "auto_advanced": true
        }
      ],
      "status": "in_progress|blocked|review_ready|approved|done",
      "blocking_decision": null,
      "risk_level": "low",
      "sub_agent_pid": 12345,
      "last_activity": "ISO-8601"
    },
    "SP2-4514": { "...": "..." }
  }
}
```

- **Messages**: Structured JSON in per-agent **inboxes** (`stage_complete`, `decision_needed`, `decision_resolved`) — separate from the plan file (`docs/orchestrator-spec.md` §§4–5).

### System B (Claude Code)

- **Primary work unit**: A **`Task`** object persisted as `{id}.json` in the team task list directory:

```76:88:/Users/bensmith/Downloads/src/utils/tasks.ts
export const TaskSchema = lazySchema(() =>
  z.object({
    id: z.string(),
    subject: z.string(),
    description: z.string(),
    activeForm: z.string().optional(), // present continuous form for spinner (e.g., "Running tests")
    owner: z.string().optional(), // agent ID
    status: TaskStatusSchema(),
    blocks: z.array(z.string()), // task IDs this task blocks
    blockedBy: z.array(z.string()), // task IDs that block this task
    metadata: z.record(z.string(), z.unknown()).optional(), // arbitrary metadata
  }),
)
```

- **IDs**: Monotonic string IDs via `createTask` → `findHighestTaskId` + `writeFile` under lock (`createTask` in `utils/tasks.ts`).
- **Team linkage**: `TeamCreate` documents that a team has a 1:1 mapping to a task list path `~/.claude/tasks/{team-name}/` (`tools/TeamCreateTool/prompt.ts`).

---

## 2. Assignment and claiming

### System A

- **Assignment model**: One **sub-agent per ticket/worktree**, orchestrated by a **single writer** of `manifest.json`; sub-agents **do not** share a mutable task board — they report via **mailbox JSON** to `inboxes/orchestrator/` (`docs/orchestrator-spec.md` §5).
- **Human assignment**: SPEC/PLAN/BUILD checkpoints are explicitly **human-gated** (review, approve, manual test) per the stage matrix (`docs/orchestrator-spec.md` §4).
- **Concurrency rule**: “Every shared file has exactly one writer” — atomic writes via temp file + `mv` (`docs/orchestrator-spec.md` §5).

### System B

- **Creation**: `TaskCreateTool.call` invokes `createTask(getTaskListId(), { subject, description, activeForm, status: 'pending', owner: undefined, blocks: [], blockedBy: [], metadata })` (`tools/TaskCreateTool/TaskCreateTool.ts`).
- **Task list resolution** (`getTaskListId` in `utils/tasks.ts`): `CLAUDE_CODE_TASK_LIST_ID` → in-process teammate context → `CLAUDE_CODE_TEAM_NAME` → leader `setLeaderTeamName` → session ID.
- **Claiming**:
  - **Soft claim**: Prompts tell agents to set `owner` via `TaskUpdate` (`tools/TaskCreateTool/prompt.ts`, `tools/TaskListTool/prompt.ts`).
  - **Hard claim**: `claimTask(taskListId, taskId, claimantAgentId, options)` acquires a **per-task file lock**, rejects if another `owner`, task `completed`, or unresolved `blockedBy`; optional `checkAgentBusy` uses a **list-level lock** and `claimTaskWithBusyCheck` to enforce one open task per agent (`utils/tasks.ts`).
- **Auto-owner on swarm**: When agent swarms are enabled, setting `status: 'in_progress'` without `owner` auto-fills `owner` from `getAgentName()` (`TaskUpdateTool.ts`).

```185:198:/Users/bensmith/Downloads/src/tools/TaskUpdateTool/TaskUpdateTool.ts
    if (
      isAgentSwarmsEnabled() &&
      status === 'in_progress' &&
      owner === undefined &&
      !existingTask.owner
    ) {
      const agentName = getAgentName()
      if (agentName) {
        updates.owner = agentName
        updatedFields.push('owner')
      }
    }
```

- **Mailbox on assign**: When `owner` changes and swarms are enabled, `writeToMailbox` sends a JSON `task_assignment` message to the assignee (`TaskUpdateTool.ts`).

---

## 3. Progress tracking

### System A

- **Manifest**: `current_stage`, `stage_history`, `status` (`in_progress|blocked|review_ready|approved|done`), `blocking_decision`, `last_activity` (`docs/orchestrator-spec.md` §7).
- **Plan file**: Append-only sections (e.g. §8 Build Log, §10 Verification) in `.cursor/plans/[TICKET].md` (`gsd/build-gsd.md`, `gsd/verify-gsd.md`).
- **Reviews folder**: `~/.orchestrator/reviews/` holds human-facing BUILD packages (`docs/orchestrator-spec.md` §6).

### System B

- **File-backed tasks**: Each update rewrites the task JSON; `notifyTasksUpdated()` signals in-process subscribers (`utils/tasks.ts`).
- **TaskList output**: Filters `metadata._internal`, strips `blockedBy` entries that point to **completed** tasks for display (`tools/TaskListTool/TaskListTool.ts`).
- **Agent busyness**: `getAgentStatuses(teamName)` derives `idle|busy` from non-completed tasks with `owner` (`utils/tasks.ts`).
- **Teammate exit**: `unassignTeammateTasks` clears `owner` and resets `status` to `pending` for unresolved tasks when a teammate terminates (`utils/tasks.ts`).

---

## 4. Stage / phase model

### System A — GSD pipeline (ticket-scoped)

Linear pipeline: **SPEC → PLAN → BUILD → VERIFY → RETRO**, documented in `gsd/README.md` and each `gsd/*-gsd.md` file.

Orchestrator **maps** this to automation vs. human checkpoints:

| Stage   | Orchestrated behavior (summary) |
| ------- | -------------------------------- |
| SPEC    | Sub-agent research; **human validates** |
| PLAN    | Sub-agent plan; **human approves** |
| BUILD   | Sub-agent executes; **human tests** at checkpoint |
| VERIFY  | Mostly automated after BUILD approval |
| RETRO   | Auto-generated; **batch** rule review |

```112:118:/Users/bensmith/personal/orchestrator/docs/orchestrator-spec.md
| Stage      | Current (manual)                        | Orchestrated                                                                                                                          | Human checkpoint?                                                                                                     |
| ---------- | --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| **SPEC**   | User runs `/spec-gsd`, reviews          | Sub-agent does the research legwork. Orchestrator presents spec to human for review.                                                  | **YES — human validates the research direction.** Poor spec → everything downstream is garbage.                       |
| **PLAN**   | User reviews plan, approves             | Sub-agent generates plan. Orchestrator presents plan to human for approval.                                                           | **YES — human approves the architectural approach.** This is where bad design gets caught, not after code is written. |
| **BUILD**  | User manually tests at checkpoint       | Sub-agent executes the approved plan. Mostly autonomous — the plan is blessed, just build it. Orchestrator packages review when done. | **YES — human tests the output.** Theory meets reality.                                                               |
| **VERIFY** | User confirms, agent runs quality gates | Sub-agent runs tests/lint/Codacy autonomously after BUILD approval.                                                                   | Only if quality gates fail after max iterations                                                                       |
| **RETRO**  | User runs manually                      | Orchestrator generates automatically, queues proposed rule changes for batch review.                                                  | Batch review (not blocking)                                                                                           |
```

Visual “attention” model:

```
SPEC ──── PLAN ──── BUILD ──── POST-BUILD ──── VERIFY ──── RETRO
 👁️         👁️       🤖          👁️             🤖          📋
```

(`docs/orchestrator-spec.md` §4)

### System B — Coordinator mode (session-scoped)

When `COORDINATOR_MODE` is enabled, `getCoordinatorSystemPrompt()` defines **four phases** for breaking down work:

```198:209:/Users/bensmith/Downloads/src/coordinator/coordinatorMode.ts
### Phases

| Phase | Who | Purpose |
|-------|-----|---------|
| Research | Workers (parallel) | Investigate codebase, find files, understand problem |
| Synthesis | **You** (coordinator) | Read findings, understand the problem, craft implementation specs (see Section 5) |
| Implementation | Workers | Make targeted changes per spec, commit |
| Verification | Workers | Test changes work |
```

This is **orthogonal** to the GSD stage names: it describes how the **lead session** fans out **Agent** workers, not the content of `.cursor/plans/*.md`.

### System B — Swarm task list (coordination convention)

Prompts encourage **ID-order** work and explicit status transitions `pending → in_progress → completed` (`tools/TaskUpdateTool/prompt.ts`).

---

## 5. Dependencies and blocking

### System A

- **Plan-level**: GSD PLAN stage asks for dependencies between implementation steps inside section 7 (`gsd/plan-gsd.md`).
- **Runtime blocking**: Manifest `blocking_decision` references pending human/orchestrator decisions; inbox schema includes `decision_needed` with `blocking: true|false` (`docs/orchestrator-spec.md` §§5–7).
- **No shared multi-agent task graph**: coordination is **per ticket**, not a global DAG between agents.

### System B

- **Graph**: `blocks` / `blockedBy` arrays on each `Task`; `blockTask` updates both endpoints (`utils/tasks.ts`).
- **Claim gating**: `claimTask` builds `unresolvedTaskIds` from tasks where `status !== 'completed'` and treats any `blockedBy` still in that set as blocking (`utils/tasks.ts`).
- **TaskUpdate**: `addBlocks` / `addBlockedBy` call `blockTask` in a loop (`tools/TaskUpdateTool/TaskUpdateTool.ts`).

---

## 6. Human checkpoints

### System A

| Checkpoint | Mechanism |
| ---------- | --------- |
| SPEC review | Human validates research before PLAN |
| PLAN approval | Human approves architecture before BUILD |
| Post-BUILD test | `orchestrator review <ticket>` seeds Claude Code with review + test steps; user approves → VERIFY, changes → message sub-agent, reject → re-plan (`docs/orchestrator-spec.md` §6) |
| VERIFY failure | Human if quality gates fail after max iterations (stage matrix) |
| RETRO | Batch review of proposed rule updates |

### System B

- **Task completion**: Prompts require honest completion criteria; `TaskUpdate` runs `executeTaskCompletedHooks` before allowing `completed` (`TaskUpdateTool.ts`).
- **Verification nudge**: Optional `verificationNudgeNeeded` when closing many tasks without a “verif” subject (`TaskUpdateTool.ts` — feature-gated).
- **Coordinator**: The **coordinator** is the human-facing role; workers are internal — prompt says every message to the user is from the coordinator (`coordinator/coordinatorMode.ts`).
- **Commits**: GSD VERIFY explicitly asks permission to commit (`gsd/verify-gsd.md`); swarm tools do not encode git commit approval — that’s left to session rules.

---

## 7. Key differences — summary table

| Dimension | System A (Orchestrator + GSD) | System B (Claude Code swarm + tasks) |
| --------- | ------------------------------- | ------------------------------------- |
| **Work atom** | Ticket + worktree + monolithic plan file | Many small `Task` JSON files keyed by ID |
| **Global state writer** | Single orchestrator → `manifest.json` | Concurrent agents → file locks on task files / list |
| **Stage semantics** | Fixed GSD pipeline (SPEC…RETRO) | Coordinator phases (Research…Verification) + optional GSD in workers |
| **Parallelism** | Multiple tickets/worktrees; one pipeline per ticket | Parallel workers + parallel **Research**; write-heavy impl serialized per coordinator prompt |
| **Dependencies** | Plan sections + decision IDs in manifest | Explicit task DAG (`blocks` / `blockedBy`) |
| **Assignment** | Orchestrator schedules sub-agents per stage | Agents claim via `owner` / `claimTask`; leader can assign |
| **Inter-agent IPC** | Mailbox JSON (single reader/writer per inbox) | Task files + `writeToMailbox` + `SendMessage` (team prompts) |
| **Stopping work** | Orchestrator lifecycle / PID in manifest | `TaskStop` stops **background** worker task by `task_id` (`TaskStopTool.ts`) — different ID space than JSON todos |

---

## 8. Recommendations for an improved external orchestrator

1. **Adopt explicit dependency edges** like `Task.blocks` / `Task.blockedBy` and atomic **claim** semantics (`claimTask`, `claimTaskWithBusyCheck`) so multiple automations can share a work queue safely without corrupting a single markdown file.
2. **Keep a single authoritative state document** (your manifest) for **cross-ticket** view, but store **fine-grained items** in separate files or rows to avoid the “one writer per file” constraint biting a unified todo — System B’s per-task JSON + locks is a proven pattern (`createTask`, `updateTask`, `lockfile.lock`).
3. **Mirror the coordinator phase split**: parallel **read-only** exploration, then a **synthesis** gate before concurrent writes — aligns with `getCoordinatorSystemPrompt()` concurrency rules (`coordinator/coordinatorMode.ts`).
4. **Auto-unassign on worker death**: Port `unassignTeammateTasks`-style behavior so stuck `owner` fields do not block the queue after a crashed sub-agent.
5. **Separate “session task IDs”** (background Agent/bash) from **coordination todo IDs** to avoid the ambiguity between `TaskStop` / `TaskOutput` vs `TaskList` (`TaskStopTool` uses `appState.tasks`; swarm tasks use `~/.claude/tasks/`).
6. **Structured completion payloads**: Combine GSD-style **stage_complete** JSON (`docs/orchestrator-spec.md`) with richer **task** records (subject, description, metadata) for machine-checkable handoffs.
7. **Human checkpoint UX**: Keep System A’s **review package** + explicit approve/change/reject transitions; add System B-style **staleness** reminders (“read latest with TaskGet”) before updates (`tools/TaskGetTool/prompt.ts`).

---

## References (files read)

**System A**

- `/Users/bensmith/personal/orchestrator/docs/orchestrator-spec.md` (§§4, 5–7)
- `/Users/bensmith/personal/orchestrator/gsd/README.md`
- `/Users/bensmith/personal/orchestrator/gsd/spec-gsd.md`, `plan-gsd.md`, `build-gsd.md`, `verify-gsd.md`, `retro-gsd.md`

**System B**

- `/Users/bensmith/Downloads/src/utils/tasks.ts` — `Task`, `createTask`, `claimTask`, `blockTask`, `getTaskListId`, `getAgentStatuses`, `unassignTeammateTasks`
- `/Users/bensmith/Downloads/src/tools/TaskCreateTool/TaskCreateTool.ts`, `prompt.ts`
- `/Users/bensmith/Downloads/src/tools/TaskUpdateTool/TaskUpdateTool.ts`, `prompt.ts`
- `/Users/bensmith/Downloads/src/tools/TaskListTool/TaskListTool.ts`, `prompt.ts`
- `/Users/bensmith/Downloads/src/tools/TaskGetTool/TaskGetTool.ts`, `prompt.ts`
- `/Users/bensmith/Downloads/src/tools/TaskStopTool/TaskStopTool.ts`, `prompt.ts`
- `/Users/bensmith/Downloads/src/tools/TaskOutputTool/TaskOutputTool.tsx`
- `/Users/bensmith/Downloads/src/utils/task/framework.ts` — in-app task state / polling (distinct from swarm todos)
- `/Users/bensmith/Downloads/src/tools/TeamCreateTool/prompt.ts`
- `/Users/bensmith/Downloads/src/coordinator/coordinatorMode.ts` — `getCoordinatorSystemPrompt`, phase table
