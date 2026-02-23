# SPEC: AI Orchestration Layer — "The Chief of Staff"

> Conversation started: 2026-02-23
> Status: Active research & conceptual design

---

## 1. Problem Statement

### The Core Bottleneck

AI coding tools (Cursor, Claude Code) have dramatically accelerated the _solitary production_ part of software engineering — code generation, debugging, refactoring. But this speed-up has exposed and amplified two persistent bottlenecks:

1. **Cognitive load of parallel work.** Managing 2-8 active branches/worktrees across projects requires holding each worktree's state in working memory: where you left off, what decisions were made, what's blocking, PR feedback, CI status. This scales as `N × context_per_worktree` and exceeds human working memory (~7±2 items) quickly. The user describes this as an "asynchronous game of Simon Says" that eventually collapses.

2. **Human coordination overhead.** Discussions with PMs, QA, boss, coworkers on PRs — these interactions can't be automated because AI lacks organizational standing, trust, and political awareness. These interactions haven't gotten faster, but they now represent a proportionally larger fraction of the workday because the coding portion compressed.

### What Exists Today

| Tool                     | What it does                                                            | What's missing                                                |
| ------------------------ | ----------------------------------------------------------------------- | ------------------------------------------------------------- |
| Cursor Background Agents | Spawn cloud agents that clone repo, create branches, open PRs           | Task-scoped, no cross-worktree awareness, no persistent state |
| Conductor (Melty Labs)   | Dashboard of parallel Claude Code agents, each in isolated git worktree | Still requires manual task definition and kickoff per agent   |
| Claude Squad             | Multiplexes Claude Code instances in tmux panes                         | Parallelism without coordination — agents don't communicate   |
| Claude Code sub-agents   | Orchestrator can spawn sub-agents for delegated work                    | No persistence across sessions, no worktree-level management  |

**Gap:** No tool provides a persistent orchestration layer that understands the state of all active worktrees, manages sub-agents through a structured workflow, makes routine decisions autonomously, and presents completed work for human review with judgment filtering.

---

## 2. Vision

### Interaction Model

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

### What This Is NOT

- Not a replacement for human judgment on architectural/strategic decisions
- Not a way to remove the human from the loop — it's a way to move the human to the _right_ place in the loop
- Not autonomous in the "let it run for days" sense — it operates within a structured workflow (GSD) with defined checkpoints

---

## 3. Architecture — Three Layers

### Layer 1: Human ↔ Orchestrator (interactive)

- **Interface**: Claude Code session (or similar conversational AI)
- **Model tier**: Top-tier (GLM5, Opus 4.6 class) — needs strong judgment
- **Responsibilities**:
  - Accept new work assignments from the user (Jira tickets, feature descriptions)
  - Brief the user on current state of all worktrees
  - Present completed worktrees for review
  - Escalate decisions that require human judgment
  - Accept human decisions and route them back to sub-agents
- **Interaction style**: The user talks to the orchestrator like a chief of staff. "Here are the three tickets I need done. Brief me when WBPR-3582 is ready for testing."

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

### Layer 3: Sub-agents (execution)

- **Runtime**: Claude Code CLI instances (primary — uses Z.ai max plan token quota, ~90M tokens per 5 hours)
- **Model tier**: Can be cheaper/faster models (Sonnet-class) — they follow instructions, they don't need to make judgment calls
- **Invocation**: `claude` CLI with `--print` mode or piped prompts for non-interactive execution. Each sub-agent runs in its own worktree directory.
- **Responsibilities**:
  - Execute GSD workflow stages (SPEC → PLAN → BUILD → VERIFY) within a single worktree
  - Follow the existing GSD command protocols (spec-gsd, plan-gsd, build-gsd, verify-gsd)
  - Write status updates and escalations to the mailbox system
  - Pause and wait when blocked on a decision
- **Key advantage of Claude Code CLI**: Sub-agents inherit MCP access (Jira, Hammer UI, Context7) and can read `.cursor/rules/` natively — both critical for the GSD workflow.
- **Key constraint**: Sub-agents have the ability to escalate decisions to the orchestrator. They do NOT interact with the human directly.

---

## 4. GSD Workflow Integration

The existing GSD pipeline (SPEC → PLAN → BUILD → VERIFY → RETRO) maps directly onto the orchestration model. Each stage has a natural automation profile:

### Stage Automation Matrix

| Stage      | Current (manual)                        | Orchestrated                                                                                                                          | Human checkpoint?                                                                                                     |
| ---------- | --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| **SPEC**   | User runs `/spec-gsd`, reviews          | Sub-agent does the research legwork. Orchestrator presents spec to human for review.                                                  | **YES — human validates the research direction.** Poor spec → everything downstream is garbage.                       |
| **PLAN**   | User reviews plan, approves             | Sub-agent generates plan. Orchestrator presents plan to human for approval.                                                           | **YES — human approves the architectural approach.** This is where bad design gets caught, not after code is written. |
| **BUILD**  | User manually tests at checkpoint       | Sub-agent executes the approved plan. Mostly autonomous — the plan is blessed, just build it. Orchestrator packages review when done. | **YES — human tests the output.** Theory meets reality.                                                               |
| **VERIFY** | User confirms, agent runs quality gates | Sub-agent runs tests/lint/Codacy autonomously after BUILD approval.                                                                   | Only if quality gates fail after max iterations                                                                       |
| **RETRO**  | User runs manually                      | Orchestrator generates automatically, queues proposed rule changes for batch review.                                                  | Batch review (not blocking)                                                                                           |

### Key Insight: Human Bookends, Automated Middle

Humans have the most impact in SPEC and PLAN — this is where direction is set, and bad direction leads to wasted execution. The human is **front-loaded** (validate research, approve architecture) and **back-loaded** (test the output against reality). The execution middle (BUILD) and mechanical validation (VERIFY) are where automation earns its keep.

The flow of human attention through the pipeline:

```
SPEC ──── PLAN ──── BUILD ──── POST-BUILD ──── VERIFY ──── RETRO
 👁️         👁️       🤖          👁️             🤖          📋
review    approve   execute     test          auto        batch
```

---

## 5. Communication Protocol — Mailbox Pattern

### Why Not Shared Mutable Files

File-based communication between agents has a critical concurrency problem:

- Two agents writing to the same file simultaneously → data corruption
- An agent reading mid-write → dirty read (partial/truncated data)
- Agent crashes while holding a lock → deadlock

### Design Principles

1. **Every shared file has exactly one writer.** No file is written by more than one agent.
2. **All writes are atomic.** Write to temp file, then `mv` to final path. POSIX `mv` is atomic — readers see either complete old file or complete new file, never partial.
3. **Messages are immutable once delivered.** A file in an inbox is never modified. Responses are new files in the sender's inbox.
4. **Each inbox has exactly one reader.** No contention by design.

### Directory Structure

```
~/.orchestrator/
  manifest.json                        # ONLY orchestrator writes this. Global state.

  inboxes/
    orchestrator/                      # Messages TO the orchestrator
      WBPR-3582-spec-complete.json     # Sub-agent reporting stage completion
      SP2-4514-decision-needed.json    # Sub-agent requesting a decision
      HUI-100-build-ready.json         # Worktree ready for human review

    WBPR-3582/                         # Messages TO this sub-agent
      decision-001-resolved.json       # Orchestrator's answer to a decision
      advance-to-build.json            # Orchestrator approving stage advance

    SP2-4514/                          # Messages TO this sub-agent
      decision-002-resolved.json

  archive/                             # Processed messages (moved here after handling)

  reviews/                             # Completed BUILD packages for human review
    WBPR-3582-review.md                # What changed, why, decisions made
    WBPR-3582-test-steps.md            # Manual testing checklist
```

### Message Schema

**Stage completion:**

```json
{
  "id": "<ticket>-<stage>-complete-<timestamp>",
  "timestamp": "ISO-8601",
  "from": "sub-agent:<ticket>",
  "to": "orchestrator",
  "type": "stage_complete",
  "payload": {
    "ticket": "<ticket-id>",
    "stage": "SPEC|PLAN|BUILD|VERIFY",
    "plan_file": "<path to .cursor/plans/TICKET.md>",
    "result": "success|partial|failure",
    "decisions_made": ["<description>", ...],
    "decisions_needing_review": [],
    "next_stage": "PLAN|BUILD|VERIFY|RETRO",
    "auto_advance_recommendation": true|false,
    "risk_level": "low|medium|high"
  }
}
```

**Decision escalation:**

```json
{
  "id": "<ticket>-decision-<seq>-<timestamp>",
  "timestamp": "ISO-8601",
  "from": "sub-agent:<ticket>",
  "to": "orchestrator",
  "type": "decision_needed",
  "payload": {
    "ticket": "<ticket-id>",
    "stage": "SPEC|PLAN|BUILD|VERIFY",
    "blocking": true|false,
    "question": "<what needs to be decided>",
    "context": "<reference to plan file section or codebase location>",
    "options": ["A: <description>", "B: <description>", ...],
    "recommendation": "A|B|...",
    "confidence": "high|medium|low",
    "impact": "<what changes depending on the decision>"
  }
}
```

**Decision resolution:**

```json
{
  "id": "<ticket>-decision-<seq>-resolved",
  "timestamp": "ISO-8601",
  "from": "orchestrator",
  "to": "sub-agent:<ticket>",
  "type": "decision_resolved",
  "payload": {
    "decision_id": "<original decision id>",
    "resolution": "A|B|...",
    "rationale": "<why this was chosen>",
    "resolved_by": "orchestrator|human"
  }
}
```

### Atomic Write Protocol

All agents MUST follow this write pattern:

```bash
# 1. Write to temp file (outside the inbox)
echo '<json>' > /tmp/orchestrator-msg-<uuid>.tmp

# 2. Atomic move to inbox
mv /tmp/orchestrator-msg-<uuid>.tmp ~/.orchestrator/inboxes/<target>/<filename>.json
```

The `mv` ensures no reader ever sees a partial file.

---

## 6. Review & Handoff UX

When a worktree reaches the BUILD checkpoint, the orchestrator:

1. Generates a review package in `~/.orchestrator/reviews/`:
   - **Review summary** (MD): What changed, why, architectural decisions made, decisions deferred to human
   - **Manual testing steps** (MD): Concrete steps to verify the implementation

2. Notifies the user: _"WBPR-3582 is ready for review."_

3. Provides a command the user can run from their home directory:

   ```bash
   orchestrator review WBPR-3582
   ```

   This command:
   - Opens a Claude Code instance in the worktree directory
   - Seeds the Claude Code session with the review summary + testing steps as context
   - The agent in this session has knowledge of the feature and can walk the user through testing

4. After testing, the user tells the orchestrator:
   - **Approve** → Orchestrator triggers VERIFY stage automatically
   - **Request changes** → Orchestrator sends revision instructions to sub-agent
   - **Reject** → Orchestrator marks worktree as needing re-plan

---

## 7. Manifest — The Orchestrator's Brain

The manifest is the single source of truth for all active work. Only the orchestrator writes to it.

```json
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
    "SP2-4514": {
      "project": "wavebid-a2o",
      "branch": "fix/SP2-4514-payment-rounding",
      "worktree_path": "~/development/wavebid-a2o-wt/SP2-4514",
      "current_stage": "PLAN",
      "status": "blocked",
      "blocking_decision": "SP2-4514-decision-001",
      "risk_level": "medium"
    }
  }
}
```

---

## 8. Lifecycle Management — Cleanup & Disk Hygiene

### Message Lifecycle

Messages are tiny (1-5KB JSON each), but unbounded growth is still bad practice. Every message has a clear lifecycle:

```
Created → Delivered (in inbox) → Processed → Archived → Purged
```

1. **Delivered**: Message lands in target inbox via atomic write.
2. **Processed**: Reader processes the message, then atomically moves it to `~/.orchestrator/archive/<ticket>/`.
3. **Archived**: Message sits in archive for auditability. Useful for debugging ("why did the orchestrator make that decision?") and for cold boot recovery.
4. **Purged**: When a worktree is fully **done** (VERIFY passes, PR merged, worktree removed), the orchestrator bulk-deletes all archived messages for that ticket and removes the worktree entry from the manifest.

### Worktree Lifecycle

```
Created → SPEC → PLAN → BUILD → Review → VERIFY → Done → Cleaned up
```

When a worktree reaches "done":

1. Orchestrator removes it from `manifest.json`
2. All inbox and archive messages for that ticket are deleted
3. The review package in `reviews/` is deleted
4. The git worktree itself is removed (`git worktree remove`)
5. The plan file (`.cursor/plans/TICKET.md`) stays in the main repo as permanent history

### Periodic Cleanup (safety net)

As a defensive measure, a cleanup routine can run periodically:

- Archive messages older than 14 days with no matching active worktree → delete
- Orphaned inbox directories (no matching manifest entry) → warn and offer to delete
- Stale worktrees (no activity in N days) → orchestrator flags for human review

### Disk Impact

Realistic estimate for active work:

- 8 active worktrees × ~20 messages each × 3KB average = **~480KB**
- Manifest: **<10KB**
- Review packages: 8 × 2 files × ~5KB = **~80KB**
- **Total active footprint: <1MB**

The git worktrees themselves are the real disk cost (shared objects, but separate working trees with `node_modules`), not the orchestration layer.

---

## 9. Cold Boot Recovery — Full Swarm Restart

### The Problem

Agents die. Sometimes one terminal closes accidentally. Sometimes the whole machine restarts and every agent dies simultaneously. The system must recover gracefully from both cases.

### Why This Works: State Is On Disk, Not In Memory

The critical design decision is that **no agent holds essential state only in memory**. Everything is persisted:

| State                                     | Where it lives                                               | Survives crash?                    |
| ----------------------------------------- | ------------------------------------------------------------ | ---------------------------------- |
| Which worktrees exist and their stages    | `manifest.json`                                              | Yes                                |
| What work has been completed per worktree | `.cursor/plans/TICKET.md` (each GSD stage appends a section) | Yes                                |
| Pending decisions and messages            | Inbox files                                                  | Yes                                |
| Actual code changes                       | Git working tree + staged changes                            | Yes                                |
| Sub-agent process IDs                     | `manifest.json` (but PIDs are stale after restart)           | Partially — PIDs need revalidation |

### Single Agent Death (accidental terminal close)

1. Orchestrator notices the sub-agent's PID is no longer running (periodic health check, or inbox goes silent past expected timeout)
2. Orchestrator reads the plan file for that worktree to determine last completed step
3. Orchestrator checks the inbox for any unprocessed messages from that sub-agent
4. Orchestrator respawns a new Claude Code sub-agent in the worktree with a recovery prompt:

```
Resume GSD workflow for TICKET-ID.
Read .cursor/plans/TICKET.md for full context.
Last completed stage: PLAN (sections 1-7 present).
BUILD was in progress — section 8 shows 3 of 7 files completed.
Pick up from step 4 of the implementation plan.
Check ~/.orchestrator/inboxes/TICKET/ for any pending decisions.
```

### Full Machine Restart (all agents die)

1. User starts the orchestrator (manually or via a startup script)
2. Orchestrator reads `manifest.json` — discovers N worktrees
3. For each worktree, orchestrator **reconciles** the manifest against reality:

```
For each worktree in manifest:
  a. Does the worktree directory still exist? (git worktree list)
  b. What sections exist in the plan file? (determines last completed stage)
  c. Is there a git diff? (determines if BUILD was mid-execution)
  d. Are there unprocessed messages in the inbox?
  e. Are there pending decisions awaiting resolution?
```

4. Orchestrator rebuilds an accurate picture and presents it to the user:

```
🔄 Cold Boot Recovery — 4 worktrees found

WBPR-3582: Was in BUILD (3/7 files done). Ready to resume.
SP2-4514:  Was blocked on decision-001. Decision still pending — needs your input.
HUI-100:   VERIFY was running, tests were passing. Ready to resume VERIFY.
WAVE-42:   SPEC complete, PLAN complete. Was about to start BUILD.

Resume all? Or review individually?
```

5. User can resume all, resume selectively, or review any worktree before resuming.

### Recovery Guarantees

- **No work is lost.** Code changes are in git (even uncommitted, they're in the working tree). Plan files are on disk. Messages are on disk.
- **No duplicate work.** The plan file's append-only structure means we know exactly what's done. A resumed sub-agent reads the plan file and skips completed steps.
- **No orphaned state.** The reconciliation step catches mismatches between manifest and reality (e.g., manifest says a worktree exists but the directory was deleted).
- **Graceful degradation.** If one worktree can't be recovered (corrupted plan file, deleted worktree), the rest still resume fine.

### The Plan File as Recovery Journal

The GSD plan file (`.cursor/plans/TICKET.md`) is the single most important artifact for recovery. Its append-only structure makes it a natural write-ahead log:

| Sections present                | Recovery inference                                              |
| ------------------------------- | --------------------------------------------------------------- |
| Sections 1-6 only               | SPEC complete. Ready for PLAN.                                  |
| Sections 1-7                    | PLAN complete. Ready for BUILD.                                 |
| Sections 1-7, partial section 8 | BUILD was in progress. Check build log for last completed step. |
| Sections 1-8                    | BUILD complete. Ready for human review (or already approved).   |
| Sections 1-10                   | VERIFY complete. Worktree is done.                              |
| Sections 1-11                   | RETRO complete. Full cycle done.                                |

---

## 10. Human Coordination Overhead — Mitigation Strategies

While the orchestrator can't automate human-to-human interactions (PM meetings, PR disagreements, QA discussions), it can compress the cognitive overhead surrounding them:

| Strategy                         | How it helps                                                                                                                                                                                                                        |
| -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Pre-conversation briefing**    | Orchestrator generates a context brief before meetings: "Here's where feature X stands, here are the 3 open design questions, here's what was decided." User walks in loaded instead of spending 10 minutes reconstructing context. |
| **Post-conversation capture**    | User tells orchestrator what was decided ("PM wants streaming instead of batch, ship by Thursday"). Orchestrator translates into updated task definitions and routes to sub-agents.                                                 |
| **Disagreement preparation**     | For PR disagreements, orchestrator surfaces codebase precedents and helps articulate the technical position before engagement.                                                                                                      |
| **Async communication drafting** | Orchestrator drafts PR descriptions, responses to review comments, standup updates based on worktree state. User reviews, edits, sends.                                                                                             |

---

## 11. Resolved Decisions

| Decision | Resolution | Rationale |
|----------|-----------|-----------|
| Sub-agent runtime | **Claude Code CLI via `claude -p`** | Uses Z.ai max plan token quota (~90M tokens). Non-interactive print mode. Gets MCP access with `--mcp-config`. Auto-approve tools with `--allowedTools`. Safety rails via `--max-turns` / `--max-budget-usd`. |
| Orchestrator runtime | **Interactive Claude Code session with `--resume`** | Session persistence via `--resume`. Context reload via `soul.md` + manifest. Terminal death recoverable. Familiar conversational interface. |
| Human checkpoints | **SPEC + PLAN + post-BUILD** | Poor research and planning lead to poor execution. Human validates direction (SPEC/PLAN) and output (post-BUILD). Middle execution and mechanical validation are automated. |
| Communication | **Mailbox pattern with atomic writes** | Single-writer per file, immutable messages, POSIX atomic `mv`. No locks, no race conditions, crash-resilient. |
| Recovery model | **Disk-first state, plan file as recovery journal** | All state on disk. Manifest + plan file + inbox = full recovery from any crash. No essential state in agent memory. |
| Inbox cleanup | **Archive on process → purge on worktree completion** | Messages archived after processing, bulk-deleted when ticket is done. Safety-net periodic cleanup for orphans. |
| Scope | **Cross-project, centralized orchestrator** | One orchestrator at `~/.orchestrator/`, projects register with it. Enables cross-project awareness and cascading change management. Morning brief covers all active work. |
| Orchestrator personality | **`~/.orchestrator/soul.md`** | Persistent file capturing preferences, escalation tendencies, learned patterns. Read on every session start. Inspired by OpenClaw's soul.md pattern. |
| Decision escalation | **Hierarchical filtering** | Sub-agents freely escalate to orchestrator (high volume OK). Orchestrator filters and only surfaces to human what genuinely requires human judgment. Human never interacts with sub-agents directly. |
| Model allocation | **GLM-5 everywhere** | One model, zero selection logic. Concurrency limit (3) queues excess requests rather than rejecting. Slight latency at peak load accepted in exchange for simplicity and best quality. |
| Worktree creation | **Orchestrator owns it** | Orchestrator creates worktrees as part of `assign`. Knows project path, creates worktree, sets up branch, runs dependency install, spawns sub-agent. |
| Notification | **Native macOS notification via `terminal-notifier`** | Click action opens iTerm2 with Claude Code in the worktree, pre-loaded with review context. Falls back to `osascript` if `terminal-notifier` not installed. |
| Soul.md | **Manual seed + auto-population via 4-layer progression** | Starts with known preferences. Orchestrator observes patterns, proposes additions at RETRO, eventually auto-adds as trust builds. Mirrors Cursor Memories evolution. |
| Error/retry | **Two retries then escalate** | Retry 1: restart from checkpoint. Retry 2: orchestrator reads log and injects diagnosis. After 2 failures: escalate to human with full context and options. |

## 12. Cross-Project Orchestration

### Project Registration

The orchestrator manages multiple projects. Projects are registered (not discovered automatically):

```bash
orchestrator add-project ~/development/wavebid-a2o
orchestrator add-project ~/personal/sts-simulator
orchestrator add-project ~/personal/sts-training-framework
```

Registration stores project metadata in the manifest:

```json
{
  "projects": {
    "wavebid-a2o": {
      "path": "~/development/wavebid-a2o",
      "type": "work",
      "gsd_config": ".cursor/rules/gsd-project.mdc",
      "related_projects": []
    },
    "sts-simulator": {
      "path": "~/personal/sts-simulator",
      "type": "personal",
      "gsd_config": ".cursor/rules/gsd-project.mdc",
      "related_projects": ["sts-training-framework"]
    },
    "sts-training-framework": {
      "path": "~/personal/sts-training-framework",
      "type": "personal",
      "gsd_config": ".cursor/rules/gsd-project.mdc",
      "related_projects": ["sts-simulator"]
    }
  }
}
```

### Cascading Changes Between Related Projects

When projects declare a `related_projects` relationship, the orchestrator understands that changes may cascade:

- If a worktree in `sts-simulator` changes the simulator's public API, the orchestrator flags: "This change may require updates in `sts-training-framework`."
- The orchestrator can spawn a follow-up worktree in the downstream project to handle the cascade.
- The manifest tracks these as linked worktrees so the orchestrator knows not to merge the upstream change until the downstream adaptation is also ready (or the user explicitly approves).

### Morning Brief Across Projects

```
🌅 Morning Brief — 2026-02-24

WORK — wavebid-a2o (3 active worktrees)
  WBPR-3582: BUILD complete, ready for your review
  SP2-4514:  PLAN needs your approval (medium risk)
  HUI-100:   VERIFY running, tests passing so far

PERSONAL — sts-simulator (1 active worktree)
  STS-42: BUILD in progress (step 5/8). Includes API change
           that will cascade to sts-training-framework.

No blocked decisions. 1 worktree ready for review.
Run `orchestrator review WBPR-3582` to start.
```

---

## 13. Claude Code CLI — Validated Capabilities

Research confirmed the following capabilities (critical for sub-agent implementation):

### Sub-agent Invocation Pattern

```bash
claude -p \
  --system-prompt-file ~/.orchestrator/sub-agent-prompt.md \
  --allowedTools "Read,Write,Edit,Bash,Grep,Glob" \
  --mcp-config ~/.orchestrator/mcp-config.json \
  --max-turns 200 \
  --output-format json \
  "Execute SPEC stage for WBPR-3582. Read .cursor/plans/WBPR-3582.md for context."
```

### Key Flags for This Architecture

| Flag | Purpose in orchestrator |
|------|------------------------|
| `-p` / `--print` | Non-interactive execution for sub-agents |
| `--system-prompt-file` | Inject mailbox protocol + GSD stage instructions |
| `--allowedTools` | Auto-approve tools (no permission prompts) |
| `--mcp-config` | Enable Jira, Hammer UI, Context7 in non-interactive mode |
| `--max-turns` | Safety rail — prevent runaway sub-agents |
| `--max-budget-usd` | Cost safety rail per sub-agent invocation |
| `--output-format json` | Structured output for orchestrator to parse |
| `--resume` / `-r` | Orchestrator session recovery after terminal death |
| `--continue` / `-c` | Continue most recent orchestrator session |
| `--model` | GLM-5 for orchestrator, GLM-4.7 for sub-agents (see Model Strategy) |
| `--append-system-prompt-file` | Layer additional context without replacing base prompt |

### Session Persistence

- Sessions stored in `.claude/` directory per project
- `--resume <session-id>` recovers a specific session
- `--continue` picks up the most recent session in the current directory
- `--no-session-persistence` available for sub-agents (they don't need session history — the plan file IS their memory)

### Multiple Instances

- Separate `CLAUDE_CONFIG_DIR` per instance to avoid credential conflicts
- Can run N simultaneous instances on the same machine
- Each sub-agent gets its own config dir: `CLAUDE_CONFIG_DIR=~/.orchestrator/agents/<ticket> claude -p ...`

### Limitations

- **No true daemon mode.** `claude -p` runs a task and exits. Interactive sessions die with the terminal. Recovery is via `--resume`.
- **No external message injection.** Can't send a message to a running interactive session from outside. Must use `--continue -p` pattern to append to a session after it ends.
- **Terminal death kills the process.** Sub-agents spawned in background will die if the parent shell dies. Mitigation: use `nohup` or `tmux`/`screen` to persist sub-agent processes.

### Recommended Sub-agent Process Management

```bash
# Spawn sub-agent in background, resilient to terminal death
nohup claude -p \
  --system-prompt-file ~/.orchestrator/sub-agent-prompt.md \
  --allowedTools "Read,Write,Edit,Bash,Grep,Glob" \
  --max-turns 200 \
  --output-format json \
  --no-session-persistence \
  "Execute BUILD stage for WBPR-3582..." \
  > ~/.orchestrator/logs/WBPR-3582-build.log 2>&1 &

# Store PID in manifest
echo $! → manifest.json sub_agent_pid
```

`nohup` ensures the sub-agent survives terminal closure. Output goes to a log file the orchestrator can tail. PID is tracked in the manifest for health checks.

---

## 14. Model Strategy

### Z.ai GLM Coding Plan (Max tier)

Provider: [Z.ai](https://z.ai) — routes through Claude Code CLI via `ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic`. Quota is prompt-based (~1,600 prompts per 5-hour window, ~8,000 per week on Max).

### Model Allocation: GLM-5 Everywhere

**One model, no selection logic, strongest reasoning at every stage.**

| Role | Model | Notes |
|------|-------|-------|
| **Orchestrator** | GLM-5 | Judgment, escalation, review packaging |
| **Sub-agents** (all stages) | GLM-5 | SPEC research, PLAN architecture, BUILD execution, VERIFY validation |

### Concurrency: Queue, Don't Reject

GLM-5 has a 3-concurrent-request limit. Requests beyond 3 are **queued, not rejected**. This means:

- Typical case (2-3 worktrees): No queuing. Everything runs immediately.
- Peak case (4-8 worktrees): Some sub-agents queue. Latency increases but work still completes.
- The orchestrator is interactive (human-paced), so it rarely competes with sub-agents for slots in practice.

**Trade-off accepted**: Slightly slower parallel execution at peak load in exchange for zero model-selection complexity and best quality everywhere.

### Fallback Models (available but not needed yet)

If queuing ever becomes a real bottleneck:
- GLM-4.7 (5 concurrent) for BUILD/VERIFY stages (mechanical execution)
- GLM-4.5 (10 concurrent) for burst parallelism
- These can be switched per-agent via `CLAUDE_CONFIG_DIR` with different `settings.json` model mappings

This is a future optimization, not a launch requirement.

---

## 15. Notification System

### Native macOS Notification → Claude Code Launch

When a worktree reaches a human checkpoint (SPEC review, PLAN approval, post-BUILD review), the orchestrator:

1. **Triggers a macOS notification** via `terminal-notifier` (Homebrew package) or `osascript`:

```bash
# Using terminal-notifier (preferred — supports click actions)
terminal-notifier \
  -title "Orchestrator" \
  -subtitle "WBPR-3582 ready for review" \
  -message "BUILD complete. Click to open review session." \
  -sound Glass \
  -execute "~/.orchestrator/bin/open-review WBPR-3582"
```

2. **On click**, the notification runs `open-review`, a shell script that:

```bash
#!/bin/bash
# ~/.orchestrator/bin/open-review
TICKET=$1
WORKTREE_PATH=$(jq -r ".worktrees.\"$TICKET\".worktree_path" ~/.orchestrator/manifest.json)
REVIEW_FILE="$HOME/.orchestrator/reviews/$TICKET-review.md"

# Open iTerm2 in the worktree directory and start Claude Code with review context
osascript -e "
  tell application \"iTerm2\"
    create window with default profile
    tell current session of current window
      write text \"cd $WORKTREE_PATH && claude --resume $TICKET-review --append-system-prompt-file $REVIEW_FILE\"
    end tell
  end tell
"
```

3. **The Claude Code session starts with**:
   - Working directory: the worktree
   - System prompt appended: the review summary (what changed, why, decisions made)
   - The agent is ready to walk the user through manual testing steps

### Notification Types

| Event | Notification title | Action on click |
|-------|-------------------|-----------------|
| SPEC ready for review | "SPEC complete: WBPR-3582" | Opens Claude Code in worktree with spec context |
| PLAN ready for approval | "PLAN ready: WBPR-3582" | Opens Claude Code in worktree with plan context |
| BUILD ready for testing | "BUILD ready: WBPR-3582" | Opens Claude Code in worktree with review + test steps |
| VERIFY complete | "VERIFY passed: WBPR-3582" | Opens Claude Code for final commit review |
| Decision escalated to human | "Decision needed: SP2-4514" | Opens orchestrator session with decision context |
| Sub-agent failure | "Agent failed: HUI-100 (BUILD)" | Opens orchestrator session with error context |

### Fallback

If `terminal-notifier` isn't installed, fall back to basic `osascript` notification (no click action) + echo to orchestrator terminal.

---

## 16. Soul.md — Orchestrator Personality & Learning

### What It Is

`~/.orchestrator/soul.md` is the orchestrator's persistent memory of the user's preferences, conventions, and decision patterns. It's read on every session start and shapes how the orchestrator makes autonomous decisions, what it escalates, and how it communicates.

**Distinction from `.cursor/rules/`**: Cursor rules are per-project, technical, and prescriptive ("use this import pattern," "test files go here"). Soul.md is cross-project, personal, and behavioral ("I prefer X over Y," "always escalate dependency additions," "don't bother me with naming bikesheds").

### Initial Structure (manually seeded)

```markdown
# Orchestrator Soul

> Last updated: [date]
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

### wavebid-a2o
- [Conventions learned over time will accumulate here]

### sts-simulator
- [Conventions learned over time will accumulate here]

---

## Pending Observations

> The orchestrator appends observations here. Review and promote to sections above, or delete.

```

### Auto-Population Mechanism

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

---

## 17. Error & Retry Policy

### Failure Categories

| Category | Example | Response |
|----------|---------|----------|
| **Transient** | API timeout, network blip, model hiccup, 500 error | Auto-retry |
| **Stuck** | Sub-agent exceeds max turns without completing the stage, infinite loop | Retry with more context |
| **Crash** | Terminal dies, process killed, OOM | Resume from last checkpoint |
| **Logic failure** | Sub-agent produces code that doesn't compile, misinterprets the plan | Retry with orchestrator guidance |
| **Unrecoverable** | Fundamental misunderstanding of requirements, blocked by external dependency, needs human decision | Escalate |

### Retry Protocol: Two Retries Then Escalate

```
Attempt 1 (initial run)
    ↓ failure
Retry 1: Restart from failure point, same context
    ↓ failure
Retry 2: Orchestrator reads log, injects diagnosis + adjusted prompt
    ↓ failure
Escalate to human with full context
```

**Retry 1 — Turn it off and on again.**
Resume from the last completed step (plan file tells us exactly where). Most failures are transient. The sub-agent gets the same prompt but starts from where it left off, not from scratch.

```bash
# Sub-agent retry — resume from checkpoint
claude -p \
  --system-prompt-file ~/.orchestrator/sub-agent-prompt.md \
  --allowedTools "Read,Write,Edit,Bash,Grep,Glob" \
  --max-turns 200 \
  "Resume BUILD for WBPR-3582 from step 4. Previous attempt failed. Read .cursor/plans/WBPR-3582.md section 8 for build log."
```

**Retry 2 — Orchestrator-assisted retry.**
The orchestrator reads the sub-agent's log file (`~/.orchestrator/logs/TICKET-stage.log`), identifies the likely failure point, and generates a more specific prompt:

```
"Previous attempt failed at step 4 (implementing PaymentService).
The error was: TypeScript compilation error — 'PaymentMethod' type not exported from shared types.
The shared types file is at packages/shared/types/payment.ts.
Fix the import and continue from step 4."
```

This gives the sub-agent targeted guidance instead of just "try again."

**After 2 retries — Escalate to human.**
The orchestrator presents:

```
⚠️ WBPR-3582 BUILD failed after 2 retries.

Stage: BUILD (step 4 of 7)
Failure: TypeScript compilation — PaymentMethod type mismatch
Retry 1: Same error persisted
Retry 2: Sub-agent attempted to fix shared types but introduced a breaking change in 3 other files

Options:
(a) I'll take over manually — open me into the worktree
(b) Try again with different instructions (tell me what to change)
(c) Skip this worktree for now
```

Triggers a macOS notification: *"Agent failed: WBPR-3582 (BUILD). Click to review."*

### Partial Success Handling

If a sub-agent completes 5 of 7 steps before crashing, that's not a full failure — it's a partial success. The plan file has steps 1-5 logged. On retry, the sub-agent starts from step 6. No work is lost.

### Max Turns as a Safety Rail

`--max-turns 200` prevents runaway agents. If a sub-agent hits 200 turns without completing the stage, it's treated as a "stuck" failure and enters the retry protocol. The 200 limit is adjustable per stage if needed (VERIFY might need fewer turns than BUILD).

---

## 15. Research Context

### Anthropic Internal Findings (Dec 2025)

Anthropic surveyed 132 engineers and studied 200K Claude Code transcripts. Key findings relevant to this design:

- **50% of engineers can only fully delegate 0-20% of work.** The orchestrator should increase this by handling stage transitions and routine decisions.
- **More AI collaboration → less human collaboration.** The orchestrator should preserve human touchpoints where they matter (BUILD review) while removing them where they don't.
- **Cognitive overhead of reviewing AI code is significant.** The review package (summary + decisions + testing steps) is designed to compress this overhead.
- **Experienced developers develop "AI delegation intuitions" over time.** The auto-advance threshold should be tunable as trust builds.

### METR Study (2025)

Experienced developers were 19% slower with AI on familiar codebases. Contributing factors align with what the orchestrator addresses:

- Large, complex environments → orchestrator breaks work into isolated worktrees
- Tacit knowledge not available to AI → orchestrator inherits `.cursor/rules/` and GSD plan files
- Context switching between verification and generation → orchestrator separates these into distinct stages

### Addy Osmani: Conductors to Orchestrators (2026)

Describes the shift from single-agent "conductor" workflows to multi-agent "orchestrator" systems. Key alignment with this design:

- Orchestrators enable parallel execution across isolated git worktrees
- Human effort is front-loaded (intent/spec) and back-loaded (review/testing)
- The developer role shifts from "How do I code this?" to "How do I get the right code built?"

---

## 16. Next Steps

### Resolved
- [x] Sub-agent runtime → Claude Code CLI via `claude -p`
- [x] Orchestrator runtime → Interactive Claude Code session with `--resume`
- [x] Scope → Cross-project, centralized at `~/.orchestrator/`
- [x] Claude Code CLI validation → Print mode, MCP, multi-instance all confirmed
- [x] Orchestrator personality → `soul.md`
- [x] Model allocation → GLM-5 everywhere (queuing at >3 concurrent accepted)
- [x] Worktree creation → Orchestrator owns it (`assign` command)
- [x] Notification → macOS native via `terminal-notifier` → click opens iTerm2 + Claude Code

### Remaining Open Questions
- None. All design questions resolved. Spec is implementation-ready.

### Implementation
- [ ] Install `terminal-notifier` via Homebrew (`brew install terminal-notifier`)
- [ ] Design the `orchestrator` CLI/skill (commands: `brief`, `assign`, `review`, `status`, `decide`, `add-project`, `recover`)
- [ ] Write `~/.orchestrator/soul.md` initial version
- [ ] Write `~/.orchestrator/sub-agent-prompt.md` (mailbox protocol, escalation behavior, GSD stage execution)
- [ ] Write the orchestrator's own CLAUDE.md (decision evaluation, escalation criteria, recovery procedure, manifest management)
- [ ] Write `~/.orchestrator/bin/open-review` shell script (iTerm2 + Claude Code launcher)
- [ ] Prototype the mailbox system (directory structure, atomic writes, message schemas)
- [ ] Build the review package generator (summary MD + testing steps MD)
- [ ] Build cold boot recovery routine (manifest reconciliation against reality)
- [ ] Build sub-agent spawner (nohup + claude -p + PID tracking + log capture)
- [ ] Configure Z.ai model mapping in `~/.claude/settings.json` for orchestrator vs sub-agent config dirs
- [ ] Integration with git worktree setup (from separate worktree-setup conversation)
- [ ] Test with a single worktree in one project end-to-end
- [ ] Expand to multi-worktree in one project
- [ ] Expand to cross-project orchestration (Slay the Spire test case)
