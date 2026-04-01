# Orchestrator — AI Coding Swarm Manager

A centralized orchestration layer for managing parallel AI coding agents across multiple git worktrees and projects. Built on Claude Code CLI.

## What This Does

- Manages multiple AI sub-agents working on different feature branches in parallel
- Routes your intent through a structured GSD workflow (SPEC → PLAN → BUILD → VERIFY → RETRO)
- Handles routine decisions autonomously, escalates to you when judgment is needed
- Presents finalized worktrees for your review with native macOS notifications
- Recovers gracefully from crashes (single agent or full machine restart)

## Architecture

```
You ↔ Orchestrator (GLM-5, interactive Claude Code session)
         ↕
    Sub-agents (GLM-5, claude -p, one per worktree)
         ↕
    Git Worktrees (isolated branches, each running GSD stages)
```

## Prerequisites

- macOS
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code/overview) (`npm install -g @anthropic-ai/claude-code`)
- [Z.ai GLM Coding Plan](https://z.ai) (Max tier recommended)
- Git with worktree support
- iTerm2
- `terminal-notifier` (`brew install terminal-notifier`)

## Project Structure

```
orchestrator/
├── bin/                    # CLI scripts (open-review, spawn-agent, etc.)
├── config/                 # Default configs and schemas
│   ├── soul.md             # Orchestrator personality & preferences
│   ├── sub-agent-prompt.md # System prompt for sub-agents
│   ├── coordinator-claude.md # Coordinator-mode CLAUDE.md template (see below)
│   └── message-schemas/    # JSON schemas for mailbox messages
├── docs/                   # Design docs
│   ├── orchestrator-spec.md
│   ├── coordinator-quickstart.md  # Quick start for coordinator mode
│   └── claude-code-comparison/    # Deep comparison with Claude Code's internal system
├── templates/              # Templates for review packages, notifications
└── CLAUDE.md               # Orchestrator's own Claude Code context
```

## Runtime State (not committed)

When running, the orchestrator creates state at `~/.orchestrator/`:

```
~/.orchestrator/
├── manifest.json           # All active worktrees and their stages
├── soul.md                 # Symlinked from config/soul.md
├── inboxes/                # Mailbox system for agent communication
├── archive/                # Processed messages
├── reviews/                # BUILD review packages for human review
├── logs/                   # Sub-agent output logs
└── observations.jsonl      # Pattern observations for soul.md learning
```

## Getting started

1. Clone this repo and from its root run: **`./bin/setup`**
   - Creates `~/.orchestrator/` with inboxes, archive, reviews, logs
   - Symlinks `soul.md` and `sub-agent-prompt.md` from `config/`
   - Symlinks all `bin/` scripts to `~/.orchestrator/bin/` (for notifications)
2. Install [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code/overview) and (optional) **`brew install terminal-notifier`** for clickable macOS notifications.
3. Start the orchestrator by running **`claude`** in this directory; it will read `CLAUDE.md` and act as the orchestrator.

## Coordinator Mode (Alternative Approach)

Instead of the full custom orchestration layer, you can use Claude Code's built-in agent teams feature with a coordinator-style CLAUDE.md that constrains the lead agent to synthesis and delegation only.

```bash
# Quick test — no project changes needed
claude --system-prompt-file ~/personal/orchestrator/config/coordinator-claude.md
```

Requires `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`. See [docs/coordinator-quickstart.md](docs/coordinator-quickstart.md) for full setup.

This approach was informed by a [deep comparison](docs/claude-code-comparison/) between this project and Claude Code's internal swarm/coordinator system.

## Status

**Phases 1–5 implemented.** Foundation, mailbox system, sub-agent prompt & spawner, notifications, and `CLAUDE.md` + templates are in place. Phase 6 (single worktree end-to-end integration test) is next. See `PLAN.md` and `docs/orchestrator-spec.md`.
