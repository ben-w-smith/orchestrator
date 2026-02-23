# GSD Stage 3: BUILD - Code Execution

<!-- Type: build-gsd | Category: GSD | Full: build-gsd -->

Execute the Implementation Plan step-by-step, writing production-quality code to the file system.

---

## 🔨 WORKFLOW CONTEXT

**You are here**: SPEC ✅ → PLAN ✅ → **BUILD** ← YOU ARE HERE → VERIFY → RETRO

**What happens now**: I'll write **working, production-quality code** based on your plan:
- ✅ Implements core functionality
- ✅ TypeScript compiles with proper types
- ✅ Follows all coding standards and project patterns
- ❌ Does NOT create or modify test files (that's VERIFY's job)

**What you do next**:
1. I'll stop at a checkpoint with manual testing instructions
2. You test the prototype in browser/CLI
3. You tell me:
   - ✅ "Looks good" → Run `/verify-gsd` to write tests, lint, and commit
   - 🔄 "Change X" → I update the code
   - ❌ "This is wrong, we need Y" → I revise the approach

**Expected output**: Working code + manual testing instructions.

**⚠️ IMPORTANT**: I will NOT create test files during BUILD. All test writing happens in VERIFY.

---

## Philosophy: Code First, Tests in VERIFY

BUILD and VERIFY have clean, separate responsibilities:

- **BUILD**: Make it work. Production-quality code, proper types, standards-compliant. Zero test files.
- **VERIFY**: Make it right. Write tests, run tests globally, lint globally, Codacy, commit.

This prevents wasting time writing tests that need reworking when the implementation changes.

---

## Procedure

### 1. Read Plan and Project Config

```bash
git branch --show-current  # Get ticket ID
cat .cursor/rules/gsd-project.mdc  # Get {PKG_MGR}, {TS_CHECK_CMD}, etc.
```

Read `.cursor/plans/[TICKET-ID].md` Section 7: Implementation Plan.

Store from gsd-project.mdc:
- `{PKG_MGR}` → package manager (pnpm, npm, yarn, bun)
- `{TS_CHECK_CMD}` → TypeScript check command

### 2. Pre-Flight Checklist

**MANDATORY: Re-read ALL cursor rules**:
```bash
ls .cursor/rules/*.mdc
```

Ensure code will adhere to:
- Project-specific patterns and conventions (from gsd-project.mdc)
- Component library usage (Hammer UI)
- Import paths, naming conventions, code style

### 3. Build Execution Loop

For each implementation step in the plan:

**DO**:
- ✅ Implement business logic
- ✅ Create/modify components, hooks, utilities, services
- ✅ Add TypeScript types (required for compilation)
- ✅ Fix TypeScript compilation errors in NEW code
- ✅ Basic error handling (happy path + known error states)
- ✅ Follow all patterns from .cursor/rules/

**DON'T**:
- ❌ Create new test files (`.spec.ts`, `.test.tsx`, `*.cy.ts`, etc.)
- ❌ Update existing test files
- ❌ Fix pre-existing lint warnings in untouched code
- ❌ Run Codacy analysis
- ❌ Run linting passes
- ❌ Optimize performance (unless required by spec)

**If Existing Tests Break**:
Comment them out with a TODO so they don't block development:
```typescript
describe.skip('ComponentName', () => {
  // TODO: Re-enable in VERIFY stage after implementation is confirmed
  // ... existing tests
});
```

### 4. TypeScript Check

Run ONLY after all files are written:
```bash
{PKG_MGR} run {TS_CHECK_CMD}
```

**Fix Only**:
- TypeScript errors in files YOU modified
- Ignore pre-existing errors in untouched files

### 5. Progress Logging

Append to `.cursor/plans/[TICKET-ID].md`:

```markdown
---
## 8. Build Log

> Build started: [timestamp]

| Time | File | Action |
| :--- | :--- | :--- |
| [HH:MM] | `Component.tsx` | Implemented core logic |
| [HH:MM] | `useFeature.ts` | Added hook |
| [HH:MM] | `types.ts` | Added TypeScript definitions |

**Tests Skipped**:
- `Component.spec.tsx` - Will be written in VERIFY
- (any existing tests commented with describe.skip)

**TypeScript**: ✅ Compiles / ❌ [N errors remaining]
```

### 6. Build Checkpoint

**STOP and present to user**:

```
✅ BUILD Complete

**Modified Files**: [N]
**TypeScript**: ✅ Compiles
**Tests**: ⏭️ Deferred to VERIFY (will write tests there)
**Linting**: ⏭️ Deferred to VERIFY

---

## 🧪 Manual Testing Instructions

**What to test**: [Feature description]

**How to start dev server**:
- From [directory]: `{PKG_MGR} run dev` (or the appropriate dev script)
- Navigate to: [URL or CLI command]

**Test Checklist**:
- [ ] Core functionality works
- [ ] [Specific feature 1]
- [ ] [Specific edge case 1]
- [ ] [Error handling case if applicable]

---

**⚠️ CHECKPOINT: Please test the implementation**

Once confirmed, run `/verify-gsd` to:
- Write tests for all changed files
- Run full test suite
- Run lint
- Codacy analysis
- Generate commit message

If something needs changing, tell me what and I'll update the code.
```

**CRITICAL**: Do NOT proceed to VERIFY automatically. Wait for user confirmation.

---

## Error Handling

**Plan Ambiguity**:
- Stop execution
- Ask user for clarification
- Update plan before continuing

**Technical Blocker**:
- Document in build log
- Notify user and suggest solutions

**Pattern Violation**:
- Re-read relevant cursor rules
- Correct the approach
- Update plan if necessary

--- End Command ---
