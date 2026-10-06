# AI Workflow Log

This repo was built by a team of role-scoped Claude Code subagents, directed by a human. Each phase is one PR, and each PR goes through the same pipeline:

```
PRODUCT_BRIEF.md (human)
      │
      ▼
product-analyst ──► acceptance criteria (Cucumber), open questions
      │                                   │
      │                    human answers ◄┘
      ▼
developer ──────► implementation + unit tests
      │
      ▼
qa-engineer ────► runs every relevant layer; PASS / FAIL with evidence
      │  FAIL → back to developer
      ▼
code-reviewer ──► APPROVE / REQUEST CHANGES
      │
      ▼
human merges
```

Agent definitions: [`.claude/agents/`](../.claude/agents/). Each role has a restricted toolset. For example, the reviewer is read-only and QA reports defects instead of fixing production code, so no single agent can write code and also sign off on it.

Below, each phase records what each agent produced and, most importantly, **what the later agents caught**.

---
