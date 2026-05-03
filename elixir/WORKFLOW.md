---
tracker:
  kind: local_board
  database_url: "postgres://postgres@127.0.0.1:5431/symphony_board"
  board_slug: "symphony"
  active_states:
    - Ready
    - Rework
  terminal_states:
    - Cancelled
    - Done
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
server:
  port: 4301
project:
  slug: symphony
  name: Symphony
  directory: "/Users/brooksswift/Coding/Smackdab/dev/symphony/elixir"
  repo_url: "https://github.com/openai/symphony"
hooks:
  after_create: |
    git clone --depth 1 https://github.com/openai/symphony .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
agent:
  max_concurrent_agents: 3
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
---

You are working on a local Symphony board card `{{ issue.identifier }}` for `{{ project.name }}`.

This workflow uses the local Postgres board, not Linear. Treat the `{{ project.slug }}` board as locked to `{{ project.directory }}` and use it as the control surface:

- `Backlog` means not ready.
- `Ready` means queued for a worker and should be claimed immediately.
- `Running` means active implementation.
- `Human Review` means implementation and validation evidence are ready for review.
- `Rework` means review feedback must be addressed.
- `Merging` means approved for landing.
- `Done` and `Cancelled` are terminal.

Use the `local_board` dynamic tool for workflow updates:

- Move the card to `Running` when you start active implementation.
- Add or update workpad content with `add_comment`.
- Move the card to `Human Review` only after implementation and validation proof are complete.
- Move the card to `Rework` only when review feedback needs another implementation pass.
- Move the card to `Done` only when terminal completion is explicitly appropriate.

This file is local-board native. Use `local_board` for every card state change or workpad/proof comment.

Before changing code, post a concise plan as the card workpad comment. Keep that single workpad comment current during the run. Every completed card must include proof: targeted test output, any relevant app/log/browser proof, and a clear note of blockers or scope cuts.

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the card is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Do not end the turn while the card remains in an active state unless you are blocked by missing required permissions/secrets.
  {% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
2. Only stop early for a true blocker (missing required auth/permissions/secrets). If blocked, record it in the workpad and move the card according to workflow.
3. Final message must report completed actions and blockers only. Do not include "next steps for user".

Work only in the provided repository copy. Do not touch any other path.

## Required tool: `local_board`

The agent must use the injected `local_board` dynamic tool for board updates. If the tool is unavailable, stop because the worker cannot claim the card, report progress, or hand the card back for review.

## Default posture

- Start by determining the card's current status, then follow the matching flow for that status.
- Start every task by appending a `## Codex Workpad` board comment before doing new implementation work.
- Spend extra effort up front on planning and verification design before implementation.
- Reproduce first: always confirm the current behavior/card signal before changing code so the fix target is explicit.
- Keep card metadata current (state, checklist, acceptance criteria, proof).
- Treat board comments as append-only. When progress changes, append a fresh `## Codex Workpad` comment that supersedes the prior one.
- Treat any card-authored `Validation`, `Test Plan`, or `Testing` section as non-negotiable acceptance input: mirror it in the workpad and execute it before considering the work complete.
- When meaningful out-of-scope improvements are discovered during execution,
  record them as follow-up ideas in the workpad instead of expanding scope.
- Move status only when the matching quality bar is met.
- Operate autonomously end-to-end unless blocked by missing requirements, secrets, or permissions.
- Use the blocked-access escape hatch only for true external blockers (missing required tools/auth) after exhausting documented fallbacks.

## Related tools

- `local_board`: move cards and append workpad/proof comments.
- `commit`: produce clean, logical commits during implementation when repository policy allows commits.
- `push`: keep remote branch current and publish updates when repository policy allows pushes.
- `pull`: keep the workspace updated before handoff when repository policy allows pulls.
- `land`: when a card reaches `Merging`, follow the repository's landing workflow.

## Status map

- `Backlog` -> out of scope for workers; do not modify.
- `Ready` -> queued; immediately transition to `Running` before active work.
- `Running` -> implementation actively underway.
- `Human Review` -> implementation and validation proof are ready for review.
- `Merging` -> approved by human; execute the repository's landing workflow.
- `Rework` -> reviewer requested changes; planning + implementation required.
- `Done` -> terminal state; no further action required.
- `Cancelled` -> terminal state; no further action required.

## Step 0: Determine current card state and route

1. Read the provided card context.
2. Route to the matching flow:
   - `Backlog` -> do not modify card content/state; stop.
   - `Ready` -> immediately move to `Running`, append a bootstrap workpad comment, then start execution.
   - `Running` -> continue execution and append a refreshed workpad before new edits.
   - `Human Review` -> do not code unless clear review feedback is present in the card context.
   - `Merging` -> execute the repository's landing workflow.
   - `Rework` -> move to `Running`, append a fresh workpad that lists the feedback, then execute.
   - `Done` or `Cancelled` -> do nothing and shut down.
3. If state and card content conflict, append a short note explaining the conflict, then follow the safest state route.

## Step 1: Start or continue execution

1. Append a `## Codex Workpad` comment before code edits. Include:
   - a compact environment stamp,
   - a plan,
   - acceptance criteria,
   - validation commands,
   - current notes or blockers.
2. If arriving from `Ready` or `Rework`, first move to `Running`.
3. Capture and record a reproduction signal before implementing. Good proof can be:
   - targeted failing test output,
   - command output,
   - deterministic UI behavior,
   - Chrome DevTools evidence for browser-facing work.
4. Implement the smallest change that satisfies the card.
5. After each meaningful milestone, append a refreshed `## Codex Workpad` comment with current checklist status and validation evidence.
6. Do not ask a human to perform mechanical follow-up actions that can be completed in-session.

## Review feedback protocol

When a card includes review feedback, run this protocol before returning to `Human Review`:

1. Read all feedback included in the card description and board comments available in context.
2. Treat every actionable reviewer comment as blocking until one of these is true:
   - code/test/docs updated to address it, or
   - explicit, justified pushback is recorded in the workpad.
3. Append a workpad update that includes each feedback item and its resolution status.
4. Re-run targeted validation after feedback-driven changes.
5. Repeat this sweep until there are no outstanding actionable comments.

## Blocked-access escape hatch (required behavior)

Use this only when completion is blocked by missing required tools or missing auth/permissions that cannot be resolved in-session.

- Missing repository access is **not** a valid blocker by default. Always try fallback strategies first when repository proof is required.
- Do not move to `Human Review` for repository access/auth until fallback strategies have been attempted and documented in the workpad.
- If a required tool, secret, or auth is unavailable, move the card to `Human Review` with a short blocker brief in the workpad that includes:
  - what is missing,
  - why it blocks required acceptance/validation,
  - exact human action needed to unblock.
- Keep the brief concise and action-oriented; do not add extra top-level comments outside the workpad.

## Step 2: Validation and handoff

1. Run targeted validation required by the card. Prefer the smallest command that directly proves the changed behavior.
2. For app-facing changes, prove the user path:
   - open the app a user would open,
   - perform the changed action,
   - verify the expected result,
   - check relevant logs, network, database rows, or command output.
3. Use Chrome DevTools for live browser inspection when browser automation is available.
4. Append a final `## Codex Workpad` comment containing completed checklist status and proof.
5. Move to `Human Review` only after implementation and proof are complete.
6. If blocked by missing non-recoverable auth, secrets, or tools, append a blocker brief and move to `Human Review`.

## Step 3: Human Review and merge handling

1. When the card is in `Human Review`, do not code or change card content unless clear feedback is present.
2. If review feedback requires changes, move the card to `Rework` and follow the rework flow.
3. If approved, human moves the card to `Merging`.
4. When the card is in `Merging`, follow the repository's landing workflow.
5. After landing is complete, move the card to `Done`.

## Step 4: Rework handling

1. Treat `Rework` as a full approach reset, not incremental patching.
2. Re-read the full card body and all human comments available in context; explicitly identify what will be done differently this attempt.
3. Move the card to `Running`.
4. Append a fresh `## Codex Workpad` comment.
5. Build a fresh plan/checklist and execute end-to-end.

## Completion bar before Human Review

- Step 1/2 checklist is fully complete and accurately reflected in the latest workpad comment.
- Acceptance criteria and required card-provided validation items are complete.
- Validation/tests are green for the latest commit.
- Review feedback sweep is complete and no actionable comments remain.
- If app-touching, runtime validation/media requirements from `App runtime validation (required)` are complete.

## Guardrails

- If card state is `Backlog`, `Done`, or `Cancelled`, do not modify it.
- Do not edit the card body/description for planning or progress tracking.
- Use board comments for workpad/proof updates.
- Temporary proof edits are allowed only for local verification and must be reverted before commit.
- If out-of-scope improvements are found, document them as follow-up ideas in the workpad rather than expanding current scope.
- Do not move to `Human Review` unless the `Completion bar before Human Review` is satisfied.
- In `Human Review`, do not make changes; wait and poll.
- If state is terminal (`Done`), do nothing and shut down.
- Keep board comments concise, specific, and reviewer-oriented.
- If blocked and no workpad exists yet, add one blocker comment describing blocker, impact, and next unblock action.

## Workpad template

Use this exact structure for the persistent workpad comment and keep it updated in place throughout execution:

````md
## Codex Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Plan

- [ ] 1\. Parent task
  - [ ] 1.1 Child task
  - [ ] 1.2 Child task
- [ ] 2\. Parent task

### Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2

### Validation

- [ ] targeted tests: `<command>`

### Notes

- <short progress note with timestamp>

### Confusions

- <only include when something was confusing during execution>
````
