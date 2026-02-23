# GSD Stage 4: VERIFY - Tests, Quality & Commit

<!-- Type: verify-gsd | Category: GSD | Full: verify-gsd -->

Write tests, run all quality gates, and prepare the commit.

---

## ✅ WORKFLOW CONTEXT

**You are here**: SPEC ✅ → PLAN ✅ → BUILD ✅ → **VERIFY** ← YOU ARE HERE → RETRO

**What happens now**: I own ALL quality work from here:
1. Write/update tests for changed files
2. Run targeted tests → fix until passing
3. Run global test suite → fix until passing
4. Run global lint → fix until passing
5. Codacy analysis on changed files
6. Generate commit message

**What you do next**:
1. Review the quality results
2. Confirm the commit message
3. I commit with your approval

**Expected output**:
- All tests passing ✅
- Lint clean ✅
- Codacy clean ✅
- Git commit ready

---

## Goal

Transform the confirmed BUILD implementation into production-ready, fully-tested, committed code.

## Procedure

### 1. Read Context and Project Config

```bash
git branch --show-current  # Extract ticket ID
cat .cursor/rules/gsd-project.mdc  # Get all commands and config
```

**Store from gsd-project.mdc**:
- `{PKG_MGR}` → package manager
- `{TS_CHECK_CMD}` → TypeScript check
- `{LINT_CMD}` → lint command
- `{LINT_FIX_CMD}` → lint fix command
- `{TEST_CMD_TARGETED}` → test command with file path argument
- `{TEST_CMD_GLOBAL}` → global test command
- `{TEST_FRAMEWORK}` → vitest or jest

Read `.cursor/plans/[TICKET-ID].md` (all sections).

### 2. Pre-Flight Checklist

**MANDATORY: Re-read ALL cursor rules for verification standards**:
```bash
ls .cursor/rules/*.mdc
```

### 3. Identify Changed Files

```bash
git diff --name-only
git diff --cached --name-only
```

Combine into a unique list. If empty, exit: "No changes to verify."

### 4. Spec Verification

Compare implementation against the original spec:

**Acceptance Criteria Check** (from Jira in Section 1):
- [ ] AC #1: [Description] - ✅/❌
- [ ] AC #2: [Description] - ✅/❌

**Success Criteria Check** (Section 6):
- [ ] Criterion 1 - ✅/❌
- [ ] Criterion 2 - ✅/❌

**API Contract Verification** (Section 4 — skip if N/A):
- [ ] Frontend types match backend DTOs - ✅/❌
- [ ] Transformations implemented - ✅/❌
- [ ] Nullable fields handled - ✅/❌

**Plan Completion Check** (Section 7):
- Ensure ALL checkboxes are marked `[x]`
- Document any remaining `[ ]` items before proceeding

### 5. Write Tests

This is the primary new responsibility of VERIFY.

**Find files that need tests**:
- Every source file in the changed list that is NOT already a test file
- Map: `Component.tsx` → `Component.test.tsx` or `Component.spec.tsx`
- Map: `useHook.ts` → `useHook.test.ts` or `useHook.spec.ts`

**Re-enable any skipped tests from BUILD**:
```bash
# Find tests commented out during BUILD
rg "describe\.skip" --type ts
rg "TODO.*VERIFY" --type ts
```
Remove `.skip`, update assertions for changed behavior.

**For each changed source file, write/update tests covering**:
- Happy path (primary use case)
- Props/arguments variations
- User interactions (for components)
- Error states and edge cases
- Loading/async states (if applicable)

**Test quality standards**:
- Unit tests: cover new/changed code paths
- Component tests: render, props, user interactions
- Hook tests: state changes, return values
- DO NOT write tests for unchanged files unless they were already failing

### 6. Run Targeted Tests

Run tests only for changed files first (faster feedback):

| Framework | Command |
| --------- | ------- |
| Vitest | `{TEST_CMD_TARGETED} [test-files]` |
| Jest | `{PKG_MGR} test -- --testPathPattern=[test-files]` |

**Fix failures iteratively (up to 5 iterations)**:
- Read failure output carefully
- Fix either the test or the source (prefer fixing source if test logic is correct)
- Re-run the targeted tests
- If still failing after 5 iterations, document and continue

### 7. Run Global Test Suite

After targeted tests pass, run the full suite to catch regressions:

```bash
{TEST_CMD_GLOBAL}
```

**Fix failures iteratively (up to 5 iterations)**:
- Focus on tests broken by your changes (not pre-existing failures)
- If a pre-existing test was already failing before your changes, document it but don't fix it (out of scope)
- Re-run global suite after each fix

### 8. Run Global Lint

```bash
{LINT_CMD}
```

**Fix issues iteratively (up to 5 iterations)**:
1. Run `{LINT_FIX_CMD}` first to auto-fix what's possible
2. Manually fix remaining issues:
   - Remove unused imports
   - Fix naming conventions
   - Resolve type warnings
   - Remove console.logs/debuggers
3. Re-run `{LINT_CMD}` to confirm clean

### 9. Codacy Analysis

For EACH modified file, run Codacy MCP analysis:
- `rootPath`: workspace root path
- `file`: absolute path to changed file
- `tool`: leave empty

**Fix issues by priority**:
1. Security vulnerabilities (MUST fix)
2. Code smells (SHOULD fix)
3. Style issues (NICE to fix)

Re-run Codacy on each file after fixing (up to 5 iterations per file).

### 10. Root Cause Analysis & Logging

Append to `.cursor/plans/[TICKET-ID].md`:

```markdown
---

## 10. Verification Results

> Verification completed: [timestamp]

### Spec Verification
- [x] AC #1: [Description]
- [x] Success Criterion 1

### Tests Written
| File | Tests Added | Coverage |
| :--- | :---------- | :------- |
| `Component.test.tsx` | 5 new + 2 updated | happy path, error state, interactions |
| `useHook.test.ts` | 3 new | state changes, return values |

### Quality Checks

#### Targeted Tests
- ✅/❌ Status: [PASS/FAIL]
- Tests run: [count] | Passed: [count] | Failed: [count remaining]

#### Global Tests
- ✅/❌ Status: [PASS/FAIL]
- Tests run: [count] | Passed: [count] | Failed: [count remaining]

#### Lint
- ✅/❌ Status: [PASS/FAIL]
- Errors: [found] → [remaining] | Auto-fixed: [count]

#### Codacy
- ✅/❌ Status: [PASS/FAIL]
- Files checked: [count] | Issues found: [count] | Issues fixed: [count]

### Iterations Required
- Targeted tests: [count]
- Global tests: [count]
- Lint: [count]
- Codacy: [count]

### Overall Status: PASS / PARTIAL / FAIL
```

### 11. Generate Commit Message

Analyze what changed (`git diff --staged` or `git diff`) and generate:

```
<type>: <Description in imperative mood>
```

**Types**: `fix` | `feat` | `refactor` | `test` | `docs` | `chore`

**Rules**:
- 50-80 chars ideal, 160 max
- Imperative mood ("Add" not "Added")
- Capitalize first word after colon
- No trailing period
- Describes the *what* and *why*, not the *how*

**Examples**:
```
feat: Add bulk selection to lot photo manager
fix: Resolve results-per-page dropdown state after navigation
refactor: Extract pagination logic into usePaginationParams hook
```

### 12. Final Summary

```
## ✅ Verification Complete

### Tests Written: [count new] tests across [count] files
### Quality Gates:
- ✅/❌ Targeted Tests: [X passing]
- ✅/❌ Global Tests: [X passing]
- ✅/❌ Lint: Clean
- ✅/❌ Codacy: [X issues fixed, Y remaining]

### Overall Status: PASS / PARTIAL / FAIL

[If PARTIAL or FAIL — list remaining issues]

---

### 📝 Proposed Commit Message:

```
[Generated commit message]
```

---

**Shall I commit now?** (y/n)

**Next**: Run `/retro-gsd` to capture any patterns or gotchas from this session worth preserving.
```

---

## Important Notes

- **Tests in VERIFY, not BUILD**: BUILD confirmed the implementation works; VERIFY makes it trustworthy with tests.
- **Global before commit**: Always run the global suite — targeted tests alone can miss regressions.
- **Pre-existing failures**: Don't fix test failures that existed before your changes (document them instead).
- **Never auto-commit**: ALWAYS ask permission before committing.
- **Codacy workspace rule**: Must analyze after any file edit per workspace rules.
- **Max iterations**: 5 per check type to prevent infinite loops. Document anything that can't be resolved.

## Exit Conditions

- ✅ **Pass**: All checks pass, commit message ready
- ⚠️ **Partial**: Some issues fixed but some remain after 5 iterations — present to user
- ❌ **Fail**: Critical issues remain — present blocking issues to user before committing
