# Synthesis: External vs. Integrated Agent Orchestration

A cross-cutting analysis of eight subsystem comparisons between **System A** (an external, shell-script-based orchestrator built on top of Claude Code CLI) and **System B** (Claude Code's internal "swarm" orchestration system). The goal: extract actionable design principles for building an effective external orchestration system.

---

## 1. Architectural Philosophy Comparison

The two systems represent fundamentally different answers to the same question: *"Where does the orchestration brain live?"*

### System A: Orchestration as an External Layer

The orchestrator is a **separate concern** that wraps Claude Code. It uses the CLI as a black box (`claude -p`), communicates through the filesystem (mailbox JSON, manifest), and treats each sub-agent as a disposable worker with no shared runtime state. The orchestrator itself runs in a Claude Code interactive session, but its sub-agents are headless processes.

**When this wins:**
- **Portability.** The orchestration layer could wrap any AI CLI, not just Claude Code. Nothing in the shell scripts is Claude-specific except the `claude` binary name.
- **Auditability.** Every message is a file. Every state transition is a manifest update. Everything is `cat`-able and `grep`-able by a human. The plan file is a readable Markdown document that doubles as a recovery journal.
- **Separation of failure domains.** A sub-agent crash cannot corrupt the orchestrator's state. The orchestrator's death doesn't take sub-agents with it (they're `nohup`'d).
- **Cross-project scope.** The manifest naturally spans repos, worktrees, and projects. Morning briefs aggregate across everything.

### System B: Orchestration as an Integrated Runtime

The swarm is **inside** Claude Code. Teammates share the process (in-process mode), the API connection, the permission system, and the UI. The coordinator replaces Claude Code's own system prompt and operates through Claude Code's tool system.

**When this wins:**
- **Latency.** In-process teammates don't need to spawn a new OS process, authenticate, or bootstrap. Message delivery is function calls, not filesystem polling.
- **UI fidelity.** The coordinator panel, teammate spinners, colored names, token counts, and message previews are deeply integrated. You see what every agent is doing in real time.
- **Permission coherence.** Workers can forward permission requests to the leader's UI. The leader can approve once and propagate rules to all teammates. This is impossible with separate processes that don't share a permission context.
- **Resource sharing.** In-process teammates share API connections and MCP channels, which matters for rate-limited contexts.

### The Fundamental Tradeoff

External orchestration trades **latency and UI richness** for **failure isolation, auditability, and cross-project scope**. Integrated orchestration trades **portability and separation of concerns** for **tight feedback loops and resource efficiency**.

Neither is categorically better. But the failure modes are different: external orchestration fails by being too slow and too invisible; integrated orchestration fails by coupling everything together so tightly that one bad state corrupts the whole session.

---

## 2. The 10 Most Important Differences (Ranked by Impact)

### 1. Coordinator Tool Restriction (Impact: Critical)

System B's coordinator **cannot** Read, Write, Edit, or Bash. It can only spawn workers, send messages, and stop tasks. System A's orchestrator has **full tool access** and uses shell scripts to manage state.

**Why this matters:** Stripping the coordinator of direct action forces a **synthesis step**. The coordinator must understand worker findings before delegating implementation, because it literally cannot do implementation itself. This prevents the most common orchestration failure: the coordinator doing shallow delegation ("go look at this") without understanding what it's asking for. System A's orchestrator *can* do everything itself, which means it can also *skip* the synthesis step and make uninformed delegation decisions.

### 2. Recovery Model: Manifest vs. Transcript (Impact: Critical)

System A persists everything in a **manifest + plan file + mailbox** that the orchestrator explicitly manages. System B recovers from **session transcripts** — the JSONL conversation log is the recovery journal.

**Why this matters:** System A's model is **human-debuggable** and **cross-project**. You can `cat manifest.json` and know the state of every ticket. System B's model is **automatic** but **opaque** — recovery is built into the resume path, but there's no single file a human can read to understand fleet status. For an external orchestration system, the manifest model is strictly better for the "morning brief" use case and for cold boot after a full system crash.

### 3. Communication Concurrency Model (Impact: High)

System A enforces **one file per message, one reader per inbox, one writer per file** — concurrency by design avoidance. System B uses **one JSON array per inbox with lockfile** — concurrency by explicit serialization.

**Why this matters:** System A's design is simpler and corruption-proof but limits throughput and creates more filesystem objects. System B's design handles the reality that multiple teammates message the same agent. For an external system with 3-5 concurrent agents (a realistic ceiling given API rate limits), System A's approach is sufficient and less error-prone. At 10+ agents, you'd need System B's approach or something like it.

### 4. GSD Pipeline vs. Coordinator Phases (Impact: High)

System A has a **fixed, domain-specific** pipeline (SPEC → PLAN → BUILD → VERIFY → RETRO) with human gates at defined points. System B has **flexible, session-scoped** phases (Research → Synthesis → Implementation → Verification) without enforced stage transitions.

**Why this matters:** GSD stages encode **when humans must pay attention**. The coordinator phases encode **how work fans out and converges**. These are complementary, not competing. An improved system should use GSD-style gates for the macro workflow and coordinator-style phases within each stage. Specifically: SPEC and PLAN stages should use Research → Synthesis → Human Review. BUILD should use Implementation → Verification → Human Review.

### 5. Permission Propagation Depth (Impact: High)

System A propagates permissions via **static CLI flags** at spawn time. System B has a **live permission bridge** where workers can forward permission requests to the leader's UI, get real-time approvals, and persist "always allow" rules.

**Why this matters:** System A's model means sub-agents either have blanket approval or they block on something the orchestrator can't help with mid-run. System B's model lets the human approve a novel filesystem operation once and have it propagate to all teammates. For an external system, the practical implication is: if you use `--allowedTools` with a tight list, agents will hit walls you can't unblock without restarting them. If you use `--dangerously-skip-permissions`, you lose all safety rails. System B found a middle path.

### 6. Process Model Flexibility (Impact: Medium-High)

System A has **one model**: separate OS processes via `nohup`. System B has **three backends** (tmux, iTerm2, in-process) with auto-detection and fallback.

**Why this matters:** The in-process backend is what makes System B practical for headless/CI use — it forces `isInProcessEnabled()` when there's no TTY. System A's `nohup` model is fine for interactive use but has no equivalent optimization for environments where process spawning is expensive or terminal infrastructure is absent (Docker containers, CI runners, cloud environments).

### 7. Task Dependency Graph (Impact: Medium)

System A tracks dependencies **implicitly** through GSD stage ordering and `blocking_decision` in the manifest. System B has **explicit `blocks`/`blockedBy` arrays** per task with claim semantics.

**Why this matters:** When you have 3+ concurrent tasks with real dependencies (e.g., "shared types must be defined before feature A and feature B can implement"), implicit ordering breaks. System B's DAG model with `claimTask` preventing work on blocked items is a materially better primitive for concurrent work.

### 8. Learning and Adaptation: soul.md (Impact: Medium)

System A has a **4-layer learning progression** (manual seed → observations → propose at RETRO → auto-add). System B has **no equivalent** — the coordinator prompt is fixed in code.

**Why this matters:** This is the one area where System A is unambiguously ahead. Over time, an orchestrator that learns from human corrections becomes dramatically more useful. System B's coordinator behaves identically on day 1 and day 100. The soul.md pattern is genuinely novel for external orchestration and should be preserved and expanded.

### 9. Cross-Project Orchestration (Impact: Medium)

System A's manifest spans **multiple projects and repos**. System B is scoped to **one session, one team**.

**Why this matters:** Real development work involves related changes across repos (API server + client library + documentation, for example). System A's `related_projects` and cascade model addresses this. System B doesn't try.

### 10. UI and Observability Gap (Impact: Medium)

System A provides **checkpoint-based** visibility (notifications at stage gates, morning briefs, review packages). System B provides **continuous** visibility (token counts, queued messages, activity spinners, colored teammate names).

**Why this matters:** Between checkpoints, System A is a black box. The human has no idea if a sub-agent is stuck, making progress, or burning tokens on a dead end. System B's observability lets the human intervene early. An external system can partially close this gap with periodic log tailing or a lightweight dashboard, but it'll never match in-process observability.

---

## 3. What System A Got Right That System B Validates

These are design decisions in System A that Claude Code's team independently arrived at the same conclusion on:

1. **File-based messaging.** Both systems use the filesystem as the message bus. Neither uses HTTP, sockets, or a message queue for the primary inter-agent communication path. (System B adds UDS/bridge as *optional* transports behind feature flags, but the default is file-based.)

2. **Agents don't talk to the human.** Both systems enforce that sub-agents/workers communicate through the orchestrator/coordinator, never directly to the user. System A does this via prompt instruction. System B does this by architecture (coordinator is the only agent that renders to the conversation).

3. **Bounded execution.** System A uses `--max-turns 200`. System B uses model config and teammate loop behaviors. Both recognize that agents need a ceiling to prevent infinite loops.

4. **Worktree isolation for concurrent work.** Both systems use git worktrees as the primary mechanism for giving agents isolated working directories. The details differ, but the instinct is the same.

5. **Distinct orchestrator vs. worker identities.** Both systems give the orchestrator/coordinator a fundamentally different prompt and role than the workers. Neither treats them as peers.

6. **Immutable message delivery.** System A makes this explicit ("messages are immutable once delivered"). System B implements it differently (array with `read` flags) but the poller explicitly defers marking read until after successful delivery to avoid loss.

---

## 4. What System A Missed That System B Reveals

These are gaps in System A's design that would cause real operational failures:

1. **No graceful shutdown protocol.** System A has no `kill-agent` script and no way to tell a running sub-agent to stop gracefully. System B has both `terminate()` (mailbox shutdown request) and `kill()` (immediate abort). In practice, a sub-agent that's heading down a wrong path needs to be stopped *without* losing the work it's already done. `SIGKILL` via PID doesn't allow for any cleanup.

2. **No mid-run permission escalation.** When a System A sub-agent encounters something outside its `--allowedTools` list, it's stuck. It can send a `decision_needed` message, but the orchestrator can't inject new permissions into a running `claude -p` process. The agent has to fail, and then be re-spawned with different flags. System B's permission bridge solves this cleanly.

3. **No task unassignment on death.** System B's `unassignTeammateTasks` automatically frees tasks when a teammate dies, preventing deadlocks where work is claimed but no agent is working on it. System A's manifest has no equivalent — a crashed agent's work stays "in_progress" until the orchestrator notices during reconciliation.

4. **No broadcast primitive.** System A requires the orchestrator to explicitly send the same message to N inboxes. System B has `to: "*"` broadcast that iterates team members. This matters for "stop everything" or "the spec changed" scenarios.

5. **No structured task dependencies.** System A relies on sequential GSD stages and `blocking_decision` for a single human decision. System B's `blocks`/`blockedBy` arrays model arbitrary dependency graphs between concurrent tasks. When the BUILD stage has 5 parallel work items with 2 shared dependencies, System A has no way to express "task 3 can't start until tasks 1 and 2 are both done."

6. **Polling interval not defined.** System A's spec describes pull-based inbox consumption but doesn't specify how often. System B polls every 1 second. In practice, if the orchestrator checks inboxes every 30 seconds, agent-to-orchestrator latency is 15 seconds on average, which makes the system feel broken for any interactive workflow.

7. **No "continue existing agent" path.** System A always spawns a new `claude -p` process. System B has `SendMessage` to continue an existing agent's context. When you want an agent to do a follow-up task in the same codebase, System A loses all context from the prior run. System B preserves it.

---

## 5. What System B Does That's Only Possible Because It's Integrated

These capabilities fundamentally require being inside the runtime and cannot be replicated by an external orchestrator:

1. **In-process AsyncLocalStorage isolation.** Running multiple agents in the same Node.js process with per-async-chain context isolation is a runtime capability. An external system can only achieve process-level isolation.

2. **Live permission bridge.** Workers forwarding permission requests to the leader's UI for real-time approval requires shared memory or IPC within a single application. An external system could approximate this with a sidecar process, but the latency and complexity would be much higher.

3. **Shared API connections and MCP channels.** In-process teammates share the leader's authenticated API connection and MCP server connections. External processes must each establish their own, which means N× authentication, N× connection overhead, and N× rate limit consumption for connection setup.

4. **Coordinator tool stripping at the framework level.** System B enforces that the coordinator cannot use `Read` or `Bash` because the tool pool is filtered before the model sees them. An external system can only enforce this via prompt instructions ("don't use Read directly"), which the model might ignore.

5. **Real-time UI integration.** Token counts, queued message indicators, spinner trees, and colored teammate pills require hooks into the rendering loop. An external system can show logs, but not sub-second activity indicators.

---

## 6. Recommendations for System A v2: Prioritized Changes

Ordered by impact-to-effort ratio. Each recommendation cites the specific subsystem research that supports it.

### Tier 1: Critical Path (Do These First)

**R1. Add graceful shutdown.** Create `bin/stop-agent` that writes a shutdown message to the agent's inbox before falling back to `SIGTERM` → `SIGKILL` escalation. This mirrors System B's `terminate()` → `kill()` distinction.
*(Source: 01-agent-lifecycle.md §3, §7 recommendation 5)*

**R2. Define a polling interval.** The orchestrator should check inboxes on a fixed cadence (1-5 seconds for interactive use, configurable for CI). Consider `fswatch`/`inotifywait` as a lower-latency alternative to polling.
*(Source: 02-communication.md §4, §8 recommendation 3)*

**R3. Add `unassign-on-death`.** When `check-agent` detects a dead PID, automatically clear the agent's ownership claims in the manifest and any task tracking. Don't wait for cold boot reconciliation.
*(Source: 03-task-coordination.md §8 recommendation 4)*

**R4. Add explicit task dependencies.** Extend the manifest or a parallel task file with `blocks`/`blockedBy` arrays so concurrent BUILD tasks can express ordering constraints.
*(Source: 03-task-coordination.md §5, §8 recommendation 1)*

### Tier 2: High Value (Do These Next)

**R5. Strip orchestrator tools (prompt-enforced).** Even without framework-level enforcement, rewrite the orchestrator's CLAUDE.md to instruct it to **never** directly edit repo files or run `Bash` in worktrees. All repo changes go through sub-agents. The orchestrator only reads manifest, inboxes, and reviews. This forces the synthesis step that makes System B's coordinator effective.
*(Source: 04-orchestrator-persona.md §2, §8 recommendation 1)*

**R6. Implement worktree creation in `spawn-agent`.** Don't require pre-provisioned worktrees. Add `git worktree add` with naming conventions and base branch selection, matching System B's `createWorktreeForSession`. Add `bin/cleanup-worktree` with dirty-state protection matching `ExitWorktreeTool`'s `countWorktreeChanges`.
*(Source: 05-execution-isolation.md §5, §7 recommendation 1)*

**R7. Add per-stage capability tiers.** SPEC agents only need `Read, Grep, Glob, WebSearch`. BUILD agents need `Read, Write, Edit, Bash, Grep, Glob`. VERIFY agents need `Read, Bash, Grep`. Don't give every stage the same blanket `--allowedTools`.
*(Source: 06-permissions.md §3, §7 recommendation 1)*

**R8. Add structured `task-notification` envelopes.** When sub-agents complete, send a structured message (not just `stage_complete`) with: task ID, status, summary, key file paths changed, token usage, duration. This gives the orchestrator machine-parseable completion data.
*(Source: 04-orchestrator-persona.md §4, §8 recommendation 2)*

### Tier 3: Valuable Enhancements

**R9. Implement the "continue agent" pattern.** After a sub-agent completes SPEC, instead of spawning a new `claude -p` for PLAN, consider using `--resume` with the same session to preserve context. This saves tokens (no re-reading of the codebase) and improves plan quality (the agent remembers what it learned during SPEC).
*(Source: 01-agent-lifecycle.md §7 recommendation 7; 04-orchestrator-persona.md §3)*

**R10. Add a lightweight status dashboard.** A simple script that tails the last 5 lines of each agent's log file, plus manifest status, refreshing every 2 seconds. Even a `watch`-based approach would close the observability gap with System B's spinner tree.
*(Source: 08-ui-notifications.md §1, §7 recommendation 1)*

**R11. Add stale worktree GC.** Periodic cleanup of worktrees where the manifest entry says `done` and the worktree has been inactive for >24 hours. Fail-closed on dirty/unpushed state.
*(Source: 05-execution-isolation.md §5, §7 recommendation 4)*

**R12. Implement soul.md Layer 2-3.** The observation JSONL + RETRO proposal loop is the most unique and valuable feature in System A's design. Prioritize implementing Layers 2 and 3 before attempting Layer 4 (auto-add).
*(Source: 04-orchestrator-persona.md §6, §8 recommendation 5)*

**R13. Persist "always allow" rules per project.** When the human approves a decision type (e.g., "always use existing error handling patterns for this project"), write it to a per-project rules file that sub-agents can load. This approximates System B's `permissionUpdates` for behavioral (not tool-level) permissions.
*(Source: 06-permissions.md §4, §7 recommendation 4)*

---

## 7. Open Questions

These require human judgment or real-world testing to resolve:

1. **Should the orchestrator use `--resume` or `--no-session-persistence` for sub-agents?** The spec currently says `--no-session-persistence`, pushing durability to the plan file. But if agents need to continue across stages (R9), session persistence becomes valuable. The tradeoff is: session persistence gives context continuity but couples recovery to Claude Code's transcript format. Plan-file-as-journal gives portability but loses conversation context.

2. **How many concurrent agents are practically viable?** System A's spec mentions a 3-concurrent-request limit for the API. System B's in-process model lets it run more teammates without hitting OS-level limits. What's the real ceiling for `nohup` + `claude -p` processes hitting the same API account? At what point does the orchestrator's inbox polling become the bottleneck?

3. **Is coordinator tool stripping worth the enforcement cost?** R5 proposes prompt-level enforcement. But System B's experience suggests that the model *will* sometimes try to use tools it shouldn't have. Is it worth building a wrapper script that intercepts and blocks tool calls from the orchestrator session, or is prompt discipline sufficient?

4. **What's the right granularity for tasks in the BUILD stage?** System A uses one-agent-per-ticket. System B allows many small tasks per team. If a BUILD stage involves 8 files across 3 modules, should that be 1 agent with 1 plan, 3 agents by module, or 8 agents by file? The answer likely depends on how tightly coupled the changes are, but there's no heuristic in either system.

5. **How should the morning brief handle stale state?** If a sub-agent died overnight and the orchestrator wasn't running, the manifest will show `in_progress` for work that's actually stalled. Should the morning brief run reconciliation before generating the report? That adds latency but prevents misleading status.

6. **When is "external orchestration" no longer the right model?** If Claude Code's swarm system ships publicly with full coordinator mode, is there still value in an external orchestrator? The answer is probably "yes, for cross-project scope and soul.md-style learning," but the boundary of what each layer should own needs to be drawn carefully.

---

## Appendix: Files Produced by This Research

| File | Subsystem | Key Finding |
|------|-----------|-------------|
| `01-agent-lifecycle.md` | Spawn, Health, Kill, Recovery | System A lacks graceful shutdown; System B has 3 backend modes |
| `02-communication.md` | Mailbox, Messages, Delivery | Fundamentally different concurrency models; both file-based |
| `03-task-coordination.md` | Task Assignment, Phases | GSD stages + coordinator phases are complementary |
| `04-orchestrator-persona.md` | Decision Authority, Persona | Coordinator tool restriction forces synthesis — the key insight |
| `05-execution-isolation.md` | Worktrees, Contexts | Both use worktrees; AsyncLocalStorage is integration-only |
| `06-permissions.md` | Security, Propagation | Live permission bridge is the biggest external-system gap |
| `07-state-recovery.md` | Persistence, Cold Boot | Manifest model is better for cross-project; transcript model is better for session continuity |
| `08-ui-notifications.md` | UI, Notifications, Review | Review packages are System A's strength; live status is System B's |
| `09-synthesis.md` | This document | Cross-cutting analysis and prioritized recommendations |
