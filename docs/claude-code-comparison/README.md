# Claude Code Orchestration System Comparison

A deep technical comparison between this external orchestrator and Claude Code's internal swarm/coordinator system, produced March 2026 from analysis of Claude Code's source.

## Files

| File | Subsystem | Key Finding |
|------|-----------|-------------|
| [01-agent-lifecycle.md](01-agent-lifecycle.md) | Spawn, Health, Kill, Recovery | This system lacks graceful shutdown; Claude Code has 3 backend modes (tmux, iTerm2, in-process) |
| [02-communication.md](02-communication.md) | Mailbox, Messages, Delivery | Different concurrency models: one-file-per-message vs shared JSON array with lockfile |
| [03-task-coordination.md](03-task-coordination.md) | Task Assignment, Phases | GSD stages and coordinator phases are complementary, not competing |
| [04-orchestrator-persona.md](04-orchestrator-persona.md) | Decision Authority, Persona | Coordinator tool restriction forces a synthesis step — the single most important design insight |
| [05-execution-isolation.md](05-execution-isolation.md) | Worktrees, Contexts | Both use worktrees; AsyncLocalStorage is integration-only and can't be replicated externally |
| [06-permissions.md](06-permissions.md) | Security, Propagation | Live permission bridge is the biggest gap an external system can't easily close |
| [07-state-recovery.md](07-state-recovery.md) | Persistence, Cold Boot | Manifest model is better for cross-project visibility; transcript model is better for session continuity |
| [08-ui-notifications.md](08-ui-notifications.md) | UI, Notifications, Review | Review packages are this system's strength; live status is Claude Code's |
| [09-synthesis.md](09-synthesis.md) | **Cross-cutting analysis** | Top 10 differences, validated decisions, gaps, and 13 prioritized recommendations |

## How this research was produced

8 focused subagents each read the relevant source files from both systems and produced a subsystem comparison. The synthesis was written by a higher-capability model after reading all 8 research files.

Source locations at time of analysis:
- **This orchestrator**: `~/personal/orchestrator/`
- **Claude Code source**: a `src/` directory snapshot from Claude Code's codebase

## Key takeaways

1. **Tool restriction forces synthesis.** Claude Code's coordinator cannot Read/Write/Bash — it can only delegate. This prevents shallow delegation.
2. **soul.md is ahead of Claude Code.** Their coordinator has no learning mechanism. The 4-layer learning progression is genuinely novel.
3. **The manifest model is better for cross-project work.** Claude Code's session-centric recovery doesn't provide fleet-level visibility.
4. **Graceful shutdown, task DAGs, and polling intervals are the critical missing infrastructure** in this system.
5. **Most of the swarm system is already available** via `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` — coordinator mode is the main piece that requires a build-time flag.
