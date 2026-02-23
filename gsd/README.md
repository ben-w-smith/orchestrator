# GSD — Get Sh\*t Done

A structured 5-stage development workflow for Cursor AI. Works with any TypeScript/React/Node.js project.

## Install / Update

Files land in `~/.cursor/commands/gsd/`. Re-run to update.

**macOS / Linux** — with [gh CLI](https://cli.github.com):
```bash
gh api repos/ben-smith-atg/cursor-gsd/contents/install.sh --jq '.content' \
  | base64 -d | bash
```

**Windows (PowerShell)** — with [gh CLI](https://cli.github.com):
```powershell
gh api repos/ben-smith-atg/cursor-gsd/contents/install.ps1 --jq '.content' `
  | % { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_)) } `
  | iex
```

**Any platform** — with git:
```bash
git clone https://github.com/ben-smith-atg/cursor-gsd.git /tmp/cursor-gsd \
  && mkdir -p ~/.cursor/commands/gsd \
  && cp /tmp/cursor-gsd/*.md /tmp/cursor-gsd/install.* ~/.cursor/commands/gsd/ \
  && rm -rf /tmp/cursor-gsd
```

Or just clone the repo, copy the `.md` files to `~/.cursor/commands/gsd/`, and you're done.

---

## Workflow

### First time in a project

```
/gsd/setup-gsd   →  creates .cursor/rules/gsd-project.mdc (run once per project)
```

### Every ticket

```
/gsd/spec-gsd    →  research + fetch Jira ticket + document requirements
/gsd/plan-gsd    →  create step-by-step implementation plan
/gsd/build-gsd   →  write production-quality code (no tests)
[manual test]
/gsd/verify-gsd  →  write tests → run suite → lint → Codacy → commit
/gsd/pr-draft    →  create draft PR (auto-detects template)
```

### Optional

```
/gsd/retro-gsd   →  capture learnings, improve your Cursor rules
```

---

## Commands

| Command           | Purpose                                                                        |
| ----------------- | ------------------------------------------------------------------------------ |
| `/gsd/setup-gsd`  | One-time project config — detects pkg manager, base branch, test/lint commands |
| `/gsd/spec-gsd`   | Research phase — Jira integration, API contract review, requirements doc       |
| `/gsd/plan-gsd`   | Planning phase — numbered implementation steps saved to `.cursor/plans/`       |
| `/gsd/build-gsd`  | Build phase — production code only, no tests, ends at manual test checkpoint   |
| `/gsd/verify-gsd` | Quality phase — writes tests, runs suite + lint + Codacy, generates commit     |
| `/gsd/retro-gsd`  | Retro phase — extracts learnings and updates project Cursor rules              |

---

## How it works

- **Project config** lives in `.cursor/rules/gsd-project.mdc` — created once by `@setup-gsd`, read by every subsequent stage
- **Context survives resets** — all work persisted to `.cursor/plans/TICKET-ID.md`
- **Jira-aware** — detects any `PREFIX-####` ticket key, fetches ticket + attachments automatically
- **Monorepo-ready** — works from package root or turbo root
