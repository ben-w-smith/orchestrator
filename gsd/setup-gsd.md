# GSD Project Setup

<!-- Type: setup-gsd | Category: GSD | Full: setup-gsd -->

Run **once per project** to detect configuration and write `.cursor/rules/gsd-project.mdc`.

---

## WORKFLOW CONTEXT

**When to run**: First time you use the GSD workflow in a project, or when the project config changes (new package manager, new test framework, etc.).

**What happens**: I'll auto-detect everything I can, ask you to confirm or fill in any gaps, then write a project config file that all GSD commands read instead of guessing.

**Expected output**: `.cursor/rules/gsd-project.mdc` — the single source of truth for this project's GSD config.

---

## Procedure

### 1. Get Project Name

```bash
basename $(git rev-parse --show-toplevel 2>/dev/null || pwd)
```

### 2. Detect Package Manager

Check for lockfiles (in order of priority):

```bash
ls pnpm-lock.yaml 2>/dev/null && echo "pnpm"
ls yarn.lock 2>/dev/null && echo "yarn"
ls package-lock.json 2>/dev/null && echo "npm"
ls bun.lockb 2>/dev/null && echo "bun"
```

### 3. Detect Monorepo Structure

```bash
ls turbo.json 2>/dev/null && echo "turbo"
cat package.json | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('workspaces','none'))" 2>/dev/null
cat pnpm-workspace.yaml 2>/dev/null
```

### 4. Detect Base Branch

```bash
git show-ref --verify --quiet refs/heads/main && echo "main" || \
git show-ref --verify --quiet refs/heads/master && echo "master" || \
echo "main"
```

### 5. Detect Available Scripts

```bash
cat package.json | python3 -c "import json,sys; d=json.load(sys.stdin); [print(k) for k in d.get('scripts',{}).keys()]" 2>/dev/null
```

Map detected scripts to GSD variables:

| GSD Variable | Look for scripts named |
|:---|:---|
| `{TS_CHECK_CMD}` | `ts-check`, `typecheck`, `type-check` |
| `{LINT_CMD}` | `lint` |
| `{LINT_FIX_CMD}` | `lint-fix`, `lint:fix` |
| `{TEST_CMD}` | `test`, check for `cross-env TZ=UTC` prefix |
| `{TEST_CHANGED_CMD}` | `test:changed`, `test-changed` |

### 6. Detect Test Framework

```bash
cat package.json | python3 -c "
import json,sys
d=json.load(sys.stdin)
deps={**d.get('devDependencies',{}), **d.get('dependencies',{})}
if 'vitest' in deps: print('vitest')
elif 'jest' in deps or '@types/jest' in deps: print('jest')
else: print('unknown')
" 2>/dev/null
```

If this is a monorepo root and the test framework lives in a subpackage, check one of the workspace packages.

### 7. Detect API Contract (Frontend ↔ Backend)

Check for signs of a co-located backend:

```bash
ls -d *-service 2>/dev/null
ls -d backend 2>/dev/null
ls -d server 2>/dev/null
ls -d api 2>/dev/null
```

Also check for frontend type/hook directories:

```bash
ls -d */types 2>/dev/null
ls -d */data 2>/dev/null
ls -d */hooks 2>/dev/null
```

**If a backend directory is found**: Ask the user to confirm the paths for:
- Frontend types directory
- Frontend data/hooks directory
- Backend API controllers directory
- Backend DTO/model directory

**If no backend found** (component library, standalone frontend, MCP server): Set API Contract to `N/A`.

### 8. Detect PR Template

```bash
ls .github/PULL_REQUEST_TEMPLATE.md 2>/dev/null || \
ls .github/pull_request_template.md 2>/dev/null || \
echo "none"
```

### 9. Get Codacy Config

Read from existing `.cursor/rules/codacy.mdc` if present:

```bash
cat .cursor/rules/codacy.mdc 2>/dev/null | grep -E "organization:|repository:"
```

### 10. Get Jira Domain

Default: `auctiontechnologygroup.atlassian.net`

If the project uses a different Jira domain, ask the user.

### 11. Confirm & Fill Gaps

Present a summary of detected values and ask:
- "Does this look correct? Any changes?"
- Fill in any `unknown` values with user input

### 12. Write gsd-project.mdc

Create or overwrite `.cursor/rules/gsd-project.mdc`:

```markdown
---
description: GSD project configuration — run /setup-gsd to regenerate
globs: ["**/*"]
alwaysApply: false
---

## GSD Project Config: [PROJECT-NAME]

> Generated: [DATE] — re-run `/setup-gsd` to update

### Tooling
- Package manager: [pnpm|yarn|npm|bun]
- Monorepo: [turbo (workspaces: X) | pnpm workspaces | single package]
- Node version: [version from .nvmrc or .node-version or package.json engines]

### Git
- Base branch: [main|master]

### Commands
- TypeScript check: [PKG_MGR] run [ts-check|typecheck|type-check]
- Lint: [PKG_MGR] run lint
- Lint fix: [PKG_MGR] run [lint-fix|lint:fix]
- Test (targeted): [full test command including cross-env/TZ if needed] [test-file-path]
- Test (global): [PKG_MGR] run test
- Test framework: [vitest|jest]

### API Contract
[N/A - [project type, e.g., component library, MCP server]]

OR

- Frontend types: [relative path]
- Frontend hooks/data: [relative path]
- Backend API: [relative path]
- Backend DTOs: [relative path]

### PR Template
- Location: [.github/PULL_REQUEST_TEMPLATE.md | none]

### Jira
- Domain: [domain]

### Codacy
- Provider: gh
- Organization: [org]
- Repository: [repo]
```

### 13. Completion

Output:
```
✅ GSD project config written to `.cursor/rules/gsd-project.mdc`

All GSD commands will now use this config. No more auto-detection on every run.

**Review the file** and adjust any values that look wrong.

To regenerate: run `/setup-gsd` again (it overwrites the existing file).
```

---

## Important Notes

- **Non-destructive to other rules**: Only creates/updates `gsd-project.mdc` — never touches `codacy.mdc` or any other rule file.
- **Safe to re-run**: Overwrites the previous config, asks for confirmation before writing.
- **Monorepo tip**: Run from the monorepo root. The config covers the whole repo; individual subpackage commands are specified in the Commands section.
- **The `alwaysApply: false` flag**: Cursor will only read this file when a GSD command explicitly loads it (via the Pre-Flight step), keeping it out of every other conversation's context.
