# GSD Stage 1: SPEC - Research & Requirements

<!-- Type: spec-gsd | Category: GSD | Full: spec-gsd -->

Research and document requirements in a persistent context file.

---

## 🎯 WORKFLOW CONTEXT

**You are here**: **SPEC** ← START → PLAN → BUILD → VERIFY → RETRO

**What happens now**: I'll research the requirements, analyze the codebase, and create a comprehensive context file at `.cursor/plans/[TICKET-ID].md` with:
- Jira ticket details (if applicable)
- Relevant files and current behavior
- API contract analysis (frontend/backend alignment)
- Constraints and risks
- Success criteria

**What you do next**: Review the spec file. If it looks good, run `/plan` to create the implementation strategy.

**Expected output**: `.cursor/plans/[TICKET-ID].md` with complete research findings.

---

## CRITICAL: IMMEDIATE FIRST ACTION

**When given a Jira URL or ticket key, IMMEDIATELY fetch the ticket as your FIRST action.**

### Step 1: Fetch Jira Ticket (if applicable)

**Jira Detection**:

A Jira ticket ID is an uppercase project prefix (2-5 letters) followed by a hyphen and a number.
Examples: `WBPR-3582`, `SP2-4514`, `HUI-100`, `WAVE-42`

Find it from (in order):
1. A URL the user provides (e.g., `.../browse/SP2-4514`)
2. Text the user typed (e.g., "SP2-4514" or "working on WBPR-3582")
3. The current branch name: `git branch --show-current` (look for the pattern above)

If none found, ask: "What's the Jira ticket ID for this work?"

**IMMEDIATELY call MCP Atlassian**:
```json
{
  "server": "user-mcp-atlassian",
  "toolName": "jira_get_issue",
  "arguments": {
    "issue_key": "WBPR-####",
    "fields": "*all",
    "expand": "changelog,renderedFields",
    "comment_limit": 10
  }
}
```

**Download Attachments**:
- Download IMAGES (png, jpg, gif, webp)
- Download TEXT-READABLE files (txt, md, json, xml, csv)
- SKIP: videos, PDFs, binaries
- Use `jira_download_attachments` to `/tmp/jira-attachments`
- READ the downloaded files to understand context

**ABSOLUTE PROHIBITIONS**:
- NEVER use web search for Jira URLs
- NEVER skip fetching the ticket
- NEVER guess at ticket contents

## Goal

Create comprehensive context file: `.cursor/plans/[TICKET-ID].md`

## Procedure

### 1. Parse Ticket ID

**Branch Detection**:
```bash
git branch --show-current
```

Extract ticket ID from:
- Branch name: `WBPR-3582`, `feature/WBPR-1234-description`
- User's prompt if not in branch
- Jira URL if provided

**Confirm with user**: "I detected Ticket ID `WBPR-3582`. Is this correct?"

**Action**: Create (or overwrite) `.cursor/plans/[TICKET-ID].md`

### 2. Pre-Flight Checklist

**MANDATORY: Read project config and ALL cursor rules before proceeding**:
```bash
# Read GSD project config first
cat .cursor/rules/gsd-project.mdc

# Then read all other rules
ls .cursor/rules/*.mdc
```

This ensures you understand:
- Project-specific tooling (package manager, commands, base branch)
- API contract paths (if applicable — see gsd-project.mdc)
- Component library usage (e.g., Hammer UI)
- Domain-specific constraints

### 3. Research Phase

Use parallel tool calls for efficiency:

**Codebase Search**:
- `SemanticSearch` for conceptual searches ("Where is marketplace filter implemented?")
- `Grep` for exact symbol/text searches (component names, function names)
- `Glob` to find files by pattern (`**/MarketplaceFilter*`)
- `Read` to examine specific files

**MCP Resources**:
- **Hammer UI**: Call `user-hammer-ui.getResource` for component details
  - NEVER guess component props - always verify
  - Example: `{ "name": "Button" }`
- **Context7**: For external library docs if needed

**API Contract Verification** (if applicable):

Check `.cursor/rules/gsd-project.mdc` → **API Contract** section.

- **If it says `N/A`**: Skip API contract verification entirely. Note "N/A" in the plan file.
- **If paths are defined**: Use those paths to check alignment between frontend types and backend DTOs.

Verify:
- Frontend types match backend DTOs
- Transformations between API response and UI state
- Missing or outdated types
- Nullable fields properly handled

**Nuance Check**:
- Identify legacy behaviors not covered by standard rules
- Check for "weird" patterns in the code
- Review test files to understand expected behavior

### 4. Write Context File

Create `.cursor/plans/[TICKET-ID].md` with this structure:

```markdown
# SPEC: [TICKET-ID] - [Brief Description]

> Generated on [Date]

## 1. Jira Ticket Summary (if applicable)

**Status**: [status] | **Priority**: [priority] | **Assignee**: [name]

### Description
[Ticket requirements from Jira]

### Acceptance Criteria
1. [AC #1]
2. [AC #2]

### Attachments Reviewed
- [List images/files analyzed, or "None"]

## 2. Context & Intent

[Summary of what needs to change and WHY]

## 3. Research Findings

### Relevant Files
- `path/to/file.tsx` - [Brief description]
- `path/to/file.ts` - [Brief description]

### Current Behavior
[How it works now]

### Similar Implementations
[Examples to reference]

### Architecture Context
[Patterns discovered]

### Constraints
- Tech stack constraints
- Monorepo boundaries
- Legacy considerations

### Rule References
- `.cursor/rules/[file].mdc` - [What applies]

## 4. API Contract (if applicable)

> Paths sourced from `.cursor/rules/gsd-project.mdc`. If N/A, write "N/A" here and skip.

### Endpoint(s)
- `[METHOD] /api/v[version]/[resource]`

### Frontend Types
- Location: `[from gsd-project.mdc]`
- Interface: `[TypeName]`

### Frontend Hook/Data
- Location: `[from gsd-project.mdc]`
- Hook: `[useHookName]`

### Backend DTO
- Location: `[from gsd-project.mdc]`
- Class: `[ClassName]`

### Contract Analysis
- **Frontend Assumptions**: [What the UI expects]
- **Backend Reality**: [What the API returns]
- **Data Transformations**: [Any mapping needed]
- **Gaps/Concerns**: [Missing types, nullable fields not handled]

## 5. Nuance & Risks

[Critical context NOT in rules: potential regressions, edge cases, legacy quirks]

## 6. Success Criteria

- [ ] [Criterion 1]
- [ ] [Criterion 2]
- [ ] [Criterion 3]
```

### 5. Clarifying Questions

**ONLY ASK IF TRULY UNCLEAR after thorough research:**
- Specific, targeted questions about requirements
- Clarification on edge cases
- Confirmation of acceptance criteria
- Missing information needed for implementation

**DO NOT ask questions that can be answered by:**
- Reading the code
- Checking existing patterns
- Reviewing similar features
- Looking at test files

### 6. Completion

Output: "✅ Spec created at `.cursor/plans/[TICKET-ID].md`. Review it, then run `/plan-gsd` to proceed."

## Important Notes

- **Thoroughness**: Be comprehensive - don't skip investigation
- **Parallel Reads**: Use parallel tool calls to read multiple files efficiently
- **Pattern Following**: Review existing similar code first
- **Cite Specifics**: Reference specific files and line numbers
- **MCP-First**: Always use MCP for Jira/Hammer UI - never guess
- **API Verification**: Explicitly check frontend/backend alignment
- **Context Persistence**: Everything goes into the plan file for future stages
