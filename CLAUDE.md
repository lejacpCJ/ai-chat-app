# Claude Code — Project Instructions

## Custom Commands & Skills

Each workflow is available both as a **slash command** (user-invocable) and as a **skill** (Claude-invocable via the Skill tool). Files are mirrored in `.claude/commands/` and `.claude/skills/`.

| Command / Skill | Description |
|---|---|
| `/code-review` | Reviews uncommitted (staged + unstaged) changes using two parallel subagents (a11y + code quality). Produces a unified report and action plan before making any edits. |
| `/commit-message` | Analyzes staged changes and generates a conventional commit message with emoji prefix. Asks for approval before running `git commit`. |
| `/spec <description>` | Turns a short feature description into a detailed markdown spec file under `_specs/` and switches to a new `claude/feature/` branch. |
