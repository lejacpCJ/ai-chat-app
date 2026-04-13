---
description: Analyze staged git diffs and generate a conventional commit message
allowed-tools:
  - Bash(git status:*), Bash(git diff --staged), Bash(git commit:*)
  - Read
---

**Step 1 — Gather context:**
Analyze the current git diff and generate a commit message.

Overall working tree state: !`git status`
Staged changes (what will be committed): !`git diff --staged`

**Step 2 — Analyze the changes:**

Examine what was changed, why it likely changed, and what category it falls into:

| Prefix     | Emoji | When to use                                             |
| ---------- | ----- | ------------------------------------------------------- |
| `feat`     | ✨    | New feature or capability                               |
| `fix`      | 🐛    | Bug fix                                                 |
| `refactor` | ♻️    | Code change that neither fixes a bug nor adds a feature |
| `docs`     | 📝    | Documentation only                                      |
| `style`    | 🎨    | Formatting, whitespace, missing semicolons, etc.        |
| `test`     | 🧪    | Adding or updating tests                                |
| `perf`     | ⚡    | Performance improvement                                 |

Prepend the emoji to the commit subject line, e.g.:

```
✨ feat(Navbar): add active link highlighting
```

**Step 3 — Write the commit message:**

Follow this format:

```
<type>(<optional scope>): <short imperative summary under 72 chars>

<optional body — explain the *why*, not the *what*, if non-obvious>
```

Rules:

- Use the imperative mood in the subject line ("add", not "added" or "adds")
- Do not end the subject line with a period
- Keep the subject under 72 characters
- Reference the file or component as the scope when helpful (e.g., `feat(Navbar):`)
- If multiple logical changes exist, briefly describe each in the body

**Step 4 — Output:**

Print the final commit message in a fenced code block so it is easy to copy, then briefly explain the reasoning behind the chosen type and scope (1–2 sentences).

Ask the user if it is fine to run git commit with the final commit message before proceeding.

If user approves to run git commit, run it with message in this format:

```
<type>(<optional scope>): <short imperative summary under 72 chars>

<optional body — explain the *why*, not the *what*, if non-obvious>
```

The message SHOULD NOT have

```
Co-Authored-By: Claude Sonnet 4.6
   <noreply@anthropic.com>
```
