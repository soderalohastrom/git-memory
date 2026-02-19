# git-memory

**Instant project context for Claude Code sessions — powered by your git history.**

> You already write great commit messages. Why not let them work for you?

## The Problem

Every new Claude Code session starts cold. CC has to explore the codebase, read files, figure out what's active — burning tokens and time before it can do real work. CLAUDE.md helps, but keeping it manually updated is a chore nobody does consistently.

## The Solution

`git-memory` indexes your git history into a lightweight SQLite database and auto-generates a project context section in your CLAUDE.md. When a new CC session starts, a `SessionStart` hook refreshes it automatically. CC wakes up already knowing:

- **Hot files** — which files have the most churn recently
- **Active areas** — which directories are seeing action
- **Recent activity** — what happened in the last N commits, grouped by day
- **Branch context** — current branch, ahead/behind main

All in ~500 tokens. Huge signal, tiny footprint.

## Example Output

```
## Branch: main

## Hot Files (last 50 commits)
16|src/screens/TalentProfileFormScreen.tsx
11|app/(authenticated)/soup-client-ready.tsx
8|app.json
7|convex/schema.ts

## Active Areas
63|expo-app
40|(root)
18|docs-legacy
17|convex

## Recent Activity
2026-02-12|8e32057 feat(onboarding): Expand Manager onboarding to 11-step...
7954d1a feat(onboarding): Update hourly slider range to $22-$150...
fa7b317 fix(onboarding): Fix Step 18 skills persistence...
```

## Install

```bash
# Clone or copy the skill
git clone https://github.com/soderalohastrom/git-memory.git ~/.skills/git-memory

# Add alias (optional)
echo 'alias git-memory="bash ~/.skills/git-memory/scripts/git-memory.sh"' >> ~/.zshrc

# Init any repo
cd /your/project
git-memory init
```

`init` does everything:
1. Creates `.ai/memory.db` with indexed commits
2. Installs a Claude Code `SessionStart` hook in `.claude/settings.json`
3. Generates the project memory section in CLAUDE.md
4. Optionally installs a `post-commit` git hook for real-time indexing

## Commands

| Command | What it does |
|---------|-------------|
| `git-memory init` | First-time setup — indexes, hooks, CLAUDE.md |
| `git-memory index` | Incremental index (new commits only) |
| `git-memory status` | Show what's indexed |
| `git-memory context [--limit N]` | Output project context |
| `git-memory refresh-claude-md` | Update CLAUDE.md section |

## How It Works

- **No LLM calls** — just git + sqlite3 + bash. Zero API cost.
- **Idempotent** — safe to run `init` multiple times
- **Non-destructive** — merges into existing `.claude/settings.json` and CLAUDE.md without touching other content
- **Incremental** — only processes new commits after first run
- **Branch-aware** — context reflects your current branch

## Requirements

- `git` (obviously)
- `sqlite3` (available on macOS/Linux by default)
- `bash`

That's it. No Node, no Python, no npm install.

## Philosophy

If you commit frequently with descriptive messages — and you should — your git history is already the best documentation of what happened and why. `git-memory` just makes that history legible to your AI coding assistant at the moment it matters most: session start.

*Ma ka hana ka ʻike* — In working, one learns. 🌺🤙🏼🚀

---

**Author:** [@soderalohastrom](https://github.com/soderalohastrom)
**License:** MIT
