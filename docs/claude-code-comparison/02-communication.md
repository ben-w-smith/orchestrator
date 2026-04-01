# Agent Orchestration: Communication Layer Comparison

Deep technical comparison of **System A** — the external user-built **Orchestrator** (`~/personal/orchestrator/`) — and **System B** — Claude Code’s internal **swarm / teammate** stack (`teammateMailbox`, `SendMessage`, `useInboxPoller`) under `~/Downloads/src/`. Focus: **mailbox layout, message formats, delivery, concurrency, polling, lifecycle, routing, and recommendations**.

---

## 1. Message format and schema

### System A: Orchestrator

**Envelope (all typed messages):** Every message is a single JSON object with a fixed top-level shape: `id`, `timestamp` (ISO-8601), `from`, `to`, `type`, and `payload`. The spec documents three concrete types inline:

```177:241:/Users/bensmith/personal/orchestrator/docs/orchestrator-spec.md
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
    ...
  }
}
```
...
**Decision resolution:**

```json
{
  "id": "<ticket>-decision-<seq>-resolved",
  ...
  "type": "decision_resolved",
  "payload": {
    "decision_id": "<original decision id>",
    ...
  }
}
```
```

**JSON Schema (Draft 07):** The repo ships machine-readable schemas, e.g. `decision_needed` requires `from` matching `^sub-agent:.+`, `to` const `orchestrator`, `type` const `decision_needed`, and a rich `payload` (ticket, stage, blocking, question, context, options, recommendation, confidence, impact). `decision_resolved` reverses the `from`/`to` pattern (`from`: orchestrator, `to`: `sub-agent:...`). `stage_complete` ties completion to GSD stages and plan file paths.

**Physical encoding:** **One message = one `.json` file** in the target inbox directory. There is no shared mutable array; the filename is part of the addressing story (e.g. `WBPR-3582-spec-complete.json`).

### System B: Claude Code swarm (`teammateMailbox.ts`)

**Primary row type (`TeammateMessage`):**

```43:50:/Users/bensmith/Downloads/src/utils/teammateMailbox.ts
export type TeammateMessage = {
  from: string
  text: string
  timestamp: string
  read: boolean
  color?: string // Sender's assigned color (e.g., 'red', 'blue', 'green')
  summary?: string // 5-10 word summary shown as preview in the UI
}
```

**Physical encoding:** **One recipient = one JSON file** containing a **JSON array** of `TeammateMessage` objects (`readMailbox` parses the file as `TeammateMessage[]`). Structured protocols (permissions, shutdown, plan approval, sandbox, idle, etc.) serialize **inside `text`** as JSON strings; helpers like `isPermissionRequest`, `isShutdownRequest`, `PlanApprovalRequestMessageSchema` parse `message.text` after the fact.

**UI / model-facing wire format:** `formatTeammateMessages` and `useInboxPoller` wrap bodies in XML using `TEAMMATE_MESSAGE_TAG`:

```51:52:/Users/bensmith/Downloads/src/constants/xml.ts
// XML tag name for teammate messages (swarm inter-agent communication)
export const TEAMMATE_MESSAGE_TAG = 'teammate-message'
```

Example construction:

```373:388:/Users/bensmith/Downloads/src/utils/teammateMailbox.ts
export function formatTeammateMessages(
  messages: Array<{
    from: string
    text: string
    timestamp: string
    color?: string
    summary?: string
  }>,
): string {
  return messages
    .map(m => {
      const colorAttr = m.color ? ` color="${m.color}"` : ''
      const summaryAttr = m.summary ? ` summary="${m.summary}"` : ''
      return `<${TEAMMATE_MESSAGE_TAG} teammate_id="${m.from}"${colorAttr}${summaryAttr}>\n${m.text}\n</${TEAMMATE_MESSAGE_TAG}>`
    })
    .join('\n\n')
}
```

**SendMessage tool input:** `SendMessageTool.ts` validates `to`, optional `summary`, and `message` as either a string or a small discriminated union (`shutdown_request`, `shutdown_response`, `plan_approval_response`) — see `StructuredMessage` and `inputSchema` in `tools/SendMessageTool/SendMessageTool.ts`.

---

## 2. Delivery mechanism

### System A

- **Path:** `~/.orchestrator/inboxes/<target-inbox-name>/` (override with `ORCH_HOME`). Sub-agents use ticket-keyed inbox folders (e.g. `WBPR-3582/`); the orchestrator’s inbox is `orchestrator/`.
- **Write path:** `bin/mailbox-send` validates JSON with `jq`, ensures the inbox dir exists, copies the payload to a temp file, then **`mv`** into the inbox — atomic rename into place.

```40:47:/Users/bensmith/personal/orchestrator/bin/mailbox-send
inbox_dir="$ORCH_HOME/inboxes/$to"
mkdir -p "$inbox_dir"

tmp=$(mktemp -t "orchestrator-msg-XXXXXX.tmp")
trap 'rm -f "$tmp"' EXIT
cp "$file" "$tmp"

mv "$tmp" "$inbox_dir/$filename"
```

- **Read path:** Consumers use `mailbox-read`, which loads all `*.json` in the inbox, optionally filters by `.type`, and **sorts by `.timestamp`** — one JSON object per line on stdout.

- **Semantics:** The spec states that **responses are new files in the sender’s inbox** (not edits to the original), preserving immutability of delivered messages.

### System B

- **Path:** `getInboxPath` resolves `~/.claude/teams/{team_name}/inboxes/{agent_name}.json` (via `getTeamsDir()`, `sanitizePathComponent`, optional `CLAUDE_CODE_TEAM_NAME`).

```52:65:/Users/bensmith/Downloads/src/utils/teammateMailbox.ts
 * Structure: ~/.claude/teams/{team_name}/inboxes/{agent_name}.json
 */
export function getInboxPath(agentName: string, teamName?: string): string {
  const team = teamName || getTeamName() || 'default'
  ...
  const fullPath = join(inboxDir, `${safeAgentName}.json`)
```

- **Write path:** `writeToMailbox` creates the file with `wx` if missing, then acquires a **file lock** (`lockfile.lock` with `lockFilePath` beside the inbox), **re-reads** the array, **appends** the new message, writes the whole file, releases the lock.

- **Delivery to the model:** Not filesystem-only — `useInboxPoller` turns unread rows into **conversation turns** by calling `onSubmitMessage` with XML-wrapped content, or queues into `AppState.inbox` when busy. So “delivery” is **file → poller → LLM attachment / new user turn**.

- **Other channels:** `SendMessageTool.call` can route plain strings to **in-process** agents (`queuePendingMessage`), **resume** stopped agents (`resumeAgentBackground`), **UDS** (`sendToUdsSocket`), or **Remote Control bridge** (`postInterClaudeMessage`) when `UDS_INBOX` feature flags apply — these bypass the shared JSON inbox for those targets.

---

## 3. Concurrency and atomicity

### System A

**Design rule: single writer per file; many files per inbox.**

```144:149:/Users/bensmith/personal/orchestrator/docs/orchestrator-spec.md
### Design Principles

1. **Every shared file has exactly one writer.** No file is written by more than one agent.
2. **All writes are atomic.** Write to temp file, then `mv` to final path. POSIX `mv` is atomic — readers see either complete old file or complete new file, never partial.
3. **Messages are immutable once delivered.** A file in an inbox is never modified. Responses are new files in the sender's inbox.
4. **Each inbox has exactly one reader.** No contention by design.
```

**Implication:** Multiple sub-agents can all post to `inboxes/orchestrator/` **concurrently** as long as each uses a **distinct filename** — there is no lock on the directory; atomicity is per-file via `mv`. No multi-writer mutation of one JSON blob.

**Contrast:** `mailbox-archive` moves a file out of the inbox (`mv` to `archive/<ticket>/`) — another atomic filesystem operation.

### System B

**Explicit multi-writer support on one file:** The same `{agent}.json` is read and rewritten by any sender; **proper-lockfile** serializes writers.

```31:41:/Users/bensmith/Downloads/src/utils/teammateMailbox.ts
// Lock options: retry with backoff so concurrent callers (multiple Claudes
// in a swarm) wait for the lock instead of failing immediately. The sync
// lockSync API blocked the event loop; the async API needs explicit retries
// to achieve the same serialization semantics.
const LOCK_OPTIONS = {
  retries: {
    retries: 10,
    minTimeout: 5,
    maxTimeout: 100,
  },
}
```

`writeToMailbox`, `markMessageAsRead`, `markMessageAsReadByIndex`, and `markMessagesAsReadByPredicate` all follow: `lock` → read → mutate → write → `release`. **`readMailbox` itself is not locked** — concurrent reads can still interleave with writers; the lock protects writers and readers who mutate (mark read). Unsynchronized `readFile` could theoretically read mid-write from another process without the lock; in practice the locked write replaces the whole file atomically from the OS perspective once `writeFile` completes, and readers are encouraged to go through the same lock for consistency when extending the codebase (reads for display often use `readMailbox` without locking — a documented tradeoff).

**Summary:** Orchestrator avoids shared mutable files by construction; Claude swarm **uses lock + full-file rewrite** for a shared inbox array.

---

## 4. Polling and notification

### System A

The spec’s §5 does not define a daemon; **notification is largely external** (see spec §15 “Notification System” — macOS notifications, `open-review`, etc.). Inbox consumption is **pull-based** via `mailbox-read` (scripts/CI/human/orchestrator process). **No built-in sub-second poll** in the snippets reviewed — operational latency depends on how often the orchestrator process runs `mailbox-read`.

### System B

**`useInboxPoller`** runs on a **1 second** interval when enabled and an agent name is resolved:

```107:107:/Users/bensmith/Downloads/src/hooks/useInboxPoller.ts
const INBOX_POLL_INTERVAL_MS = 1000
```

```952:954:/Users/bensmith/Downloads/src/hooks/useInboxPoller.ts
  const shouldPoll = enabled && !!getAgentNameToPoll(store.getState())
  useInterval(() => void poll(), shouldPoll ? INBOX_POLL_INTERVAL_MS : null)
```

- **`getAgentNameToPoll`:** Returns `undefined` for **in-process teammates** (they use `waitForNextPromptOrShutdown` instead), otherwise the teammate’s name or team-lead display name.

- **Behavior:** `readUnreadMessages` → classify `text` into protocol buckets vs `regularMessages` → either route to permission queues / `setAppState` handlers, or format XML and **`onSubmitMessage`** (new turn). Desktop **`sendNotification`** is used for permission prompts when appropriate.

**Prompt guidance** (`tools/SendMessageTool/prompt.ts`) states teammates do not manually check an inbox — delivery is automatic — which matches the poller-driven UX:

```36:36:/Users/bensmith/Downloads/src/tools/SendMessageTool/prompt.ts
Your plain text output is NOT visible to other agents — to communicate, you MUST call this tool. Messages from teammates are delivered automatically; you don't check an inbox.
```

---

## 5. Message lifecycle

### System A

Explicit state machine in the spec:

```333:344:/Users/bensmith/personal/orchestrator/docs/orchestrator-spec.md
### Message Lifecycle

Messages are tiny (1-5KB JSON each), but unbounded growth is still bad practice. Every message has a clear lifecycle:

```
Created → Delivered (in inbox) → Processed → Archived → Purged
```

1. **Delivered**: Message lands in target inbox via atomic write.
2. **Processed**: Reader processes the message, then atomically moves it to `~/.orchestrator/archive/<ticket>/`.
3. **Archived**: Message sits in archive for auditability...
4. **Purged**: When a worktree is fully **done**...
```

**Tools:** `mailbox-archive` moves from inbox to `archive/$ticket/`; `mailbox-cleanup --ticket` removes `inboxes/$ticket`, `archive/$ticket`, review artifacts, and updates `manifest.json` via temp+jq+`mv`.

### System B

- **Append:** New messages arrive with `read: false`.
- **Read handling:** `useInboxPoller` calls `markMessagesAsRead` after successful submit to the model or after queuing to `AppState.inbox` (to avoid loss on crash mid-busy).

```860:863:/Users/bensmith/Downloads/src/hooks/useInboxPoller.ts
    // Mark messages as read only after they have been successfully delivered
    // or reliably queued in AppState. This prevents permanent message loss
    // when the session is busy — if we crash before this point, the messages
    // will be re-read on the next poll cycle instead of being silently dropped.
    markRead()
```

- **Clear:** `clearMailbox` overwrites with `[]` using flag `r+` (only if file exists — avoids creating empty inboxes accidentally).

- **No separate archive directory** in `teammateMailbox` — history stays in the JSON array until cleared or overwritten; protocol messages may be consumed by side-effect handlers without surfacing as “regular” chat.

**Idle / stop hook:** `initializeTeammateHooks` registers a **Stop** hook that `writeToMailbox`’s an `idle_notification` JSON to the leader (`createIdleNotification`, `getLastPeerDmSummary`).

---

## 6. Broadcast and routing

### System A

- **One-to-one per file:** Routing is by **inbox directory name** (`--to orchestrator` vs `--to WBPR-3582`). The spec shows **multiple ticket subdirectories**, not a broadcast primitive.
- **Fan-out:** If multiple sub-agents must receive the same logical message, the sender (or orchestrator) issues **multiple `mailbox-send` invocations** with distinct target inboxes / filenames — not a single shared “topic” file.

### System B

- **Broadcast:** `handleBroadcast` in `SendMessageTool.ts` loads `readTeamFileAsync(teamName)`, skips the sender, and **`writeToMailbox` for each member** — O(team size) file writes.

```218:249:/Users/bensmith/Downloads/src/tools/SendMessageTool/SendMessageTool.ts
  const recipients: string[] = []
  for (const member of teamFile.members) {
    if (member.name.toLowerCase() === senderName.toLowerCase()) {
      continue
    }
    recipients.push(member.name)
  }
  ...
  for (const recipientName of recipients) {
    await writeToMailbox(
      recipientName,
      {
        from: senderName,
        text: content,
        ...
      },
      teamName,
    )
  }
```

- **`to: "*"`** is rejected for structured messages (`validateInput`); plain text only.

- **Leader vs worker:** Many flows hard-code `TEAM_LEAD_NAME` (e.g. shutdown responses to leader). **Cross-session** addressing uses `uds:` / `bridge:` when enabled (`parseAddress`, `feature('UDS_INBOX')`).

---

## 7. Key differences — summary table

| Dimension | System A (Orchestrator) | System B (Claude swarm) |
|-----------|-------------------------|-------------------------|
| **Storage model** | One **file** per message | One **file** per agent = **array** of messages |
| **Top-level schema** | `id`, `timestamp`, `from`, `to`, `type`, `payload` + JSON Schema | `TeammateMessage` + optional JSON-in-`text` for protocols |
| **Immutability** | Message files never edited; reply = new file | Rows toggled `read`; array rewritten |
| **Concurrency** | Single writer **per file**; many writers to same inbox **different files** | **Lockfile** + read-modify-write one shared file |
| **Atomicity** | `mv` after temp write (`mailbox-send`, spec) | Lock + full `writeFile` of array |
| **Ordering** | `mailbox-read` sorts by `.timestamp` | Array order = append order; poller processes **unread** batch |
| **Delivery to agent** | External process reads files | **Poll 1s** + inject as XML / `AppState` queue |
| **Broadcast** | Manual multi-send | `to: "*"` iterates team members |
| **Validation** | `jq` + JSON Schema files in repo | Zod in tool; ad-hoc `is*` parsers on `text` |
| **Lifecycle** | inbox → archive → purge by ticket | read flags; `clearMailbox`; no first-class archive dir |

---

## 8. Recommendations — what an improved external orchestrator should adopt

1. **Keep Orchestrator’s immutability + one-file-per-message** for audit trails and crash safety; it maps cleanly to object-store or git-backed logs later. When borrowing Claude’s patterns, **do not** merge unrelated message streams into one mutable JSON file without locks — or adopt the same **lock + RMW** discipline.

2. **Adopt explicit protocol typing:** Combine A’s JSON Schema envelopes with B’s lesson that **machine routing** (permissions, shutdown) benefits from **discriminated `type`** fields and dedicated handlers — optionally split “control plane” messages into a parallel directory or prefix scheme so they are not mixed with human-visible stage reports.

3. **Polling vs push:** For CLI agents, a **1s poll** (B) is simple but chatty; Orchestrator’s pull model is cheaper at rest. A hybrid **filesystem watch** (`fswatch` / `notify`) on `inboxes/orchestrator/` could reduce latency without full React polling.

4. **Delivery guarantees:** B explicitly **defers marking read** until after queueing or submit — prevents silent loss under load. External orchestrators should **mirror that**: only ack/archive after the consumer has persisted downstream state.

5. **Broadcast:** If the external system needs team-wide announcements, implement B-style **fan-out with idempotency keys** (message `id` in A already supports dedup) and cap blast radius — B’s prompt warns broadcast is expensive.

6. **Cross-session:** B’s UDS/bridge paths are a reminder that **filesystem inbox is one transport**; an external orchestrator might standardize a **pluggable transport** (file, HTTP, socket) behind the same envelope schema.

7. **XML vs JSON in the model:** B wraps teammate content in `<teammate-message>` for LLM parsing. An external stack using Claude or similar should define a **single stable delimiter** (XML tag or fenced JSON) for multi-agent context — aligns with `TEAMMATE_MESSAGE_TAG` and `formatTeammateMessages`.

---

## References (files)

| System | Path |
|--------|------|
| A | `/Users/bensmith/personal/orchestrator/docs/orchestrator-spec.md` (§5, §8) |
| A | `/Users/bensmith/personal/orchestrator/config/message-schemas/*.json` |
| A | `/Users/bensmith/personal/orchestrator/bin/mailbox-send`, `mailbox-read`, `mailbox-archive`, `mailbox-cleanup` |
| B | `/Users/bensmith/Downloads/src/utils/teammateMailbox.ts` |
| B | `/Users/bensmith/Downloads/src/tools/SendMessageTool/SendMessageTool.ts`, `prompt.ts` |
| B | `/Users/bensmith/Downloads/src/hooks/useInboxPoller.ts` |
| B | `/Users/bensmith/Downloads/src/utils/swarm/teammateInit.ts`, `teammatePromptAddendum.ts` |
| B | `/Users/bensmith/Downloads/src/constants/xml.ts` (`TEAMMATE_MESSAGE_TAG`) |
| B | `/Users/bensmith/Downloads/src/utils/lockfile.ts` (wrapper around `proper-lockfile`) |
