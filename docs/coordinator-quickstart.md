# Coordinator Mode Quick Start

Use Claude Code's built-in agent teams with a coordinator-style lead agent that delegates instead of implementing directly.

## Prerequisites

- Claude Code v2.1.32+
- `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` in your environment or `~/.claude.json` settings

Add to settings.json:
```json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  }
}
```

## Option A: Quick test (no file changes)

```bash
claude --system-prompt-file ~/personal/orchestrator/config/coordinator-claude.md
```

## Option B: Per-project (copy CLAUDE.md)

```bash
cp ~/personal/orchestrator/config/coordinator-claude.md ~/development/your-project/CLAUDE.md
```

## Option C: Symlink (all projects, one source of truth)

```bash
ln -s ~/personal/orchestrator/config/coordinator-claude.md ~/development/your-project/CLAUDE.md
```

## What to expect

**Works well:**
- Research tasks: "investigate why auth is slow" → 3 teammates each look at a different layer
- Independent modules: "add feature X to frontend, API, and DB" → 3 teammates, no file conflicts
- Review: "review this PR from security, perf, and testing angles" → 3 focused reviewers

**Gets janky:**
- The lead will occasionally edit a file itself despite the prompt. Call it out and it corrects.
- Iterative corrections (teammate 2 broke something teammate 1 depends on) burn tokens fast.
- Teams of 6+ get hard to coordinate — stick to 3-5 teammates.

**When NOT to use coordinator mode:**
- Simple questions (just answer them)
- Single-file changes (no parallelism benefit)
- Sequential work (use one agent, not a team)

## Tips

- **Require plan approval** for risky work: "Spawn a teammate to refactor auth. Require plan approval."
- **Use Shift+Down** to cycle through teammates and message them directly
- **Use Sonnet for teammates** to save tokens: "Create a team with 3 teammates. Use Sonnet for each."
- **Always let the lead clean up**: tell it "clean up the team" when done
