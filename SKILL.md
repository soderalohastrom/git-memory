# git-memory

Git history as project memory. Indexes commits into SQLite so new Claude Code sessions can instantly understand a project's recent activity.

## When to Use
- Starting a new CC session on any git repo
- Asked about project history, recent changes, or active areas
- Need to understand what's been happening in a codebase

## Setup (once per repo)
```bash
git-memory init
```
Creates `.ai/memory.db` with the last ~100 commits indexed.

## Session Start (recommended)
```bash
git-memory index && git-memory refresh-claude-md
```
Incrementally indexes new commits, then updates CLAUDE.md with a `## Project Memory` section that CC reads automatically.

## Commands
| Command | Purpose |
|---------|---------|
| `init` | First-time setup, index last 100 commits |
| `index` | Incremental update (fast, only new commits) |
| `status` | What's indexed, branch info |
| `context [--limit N]` | Output context for injection (hot files, recent activity, active areas) |
| `refresh-claude-md` | Auto-update CLAUDE.md with project memory section |

## How It Works
- Stores raw git data (no LLM summarization — commit messages are already good)
- SQLite DB at `.ai/memory.db` (add `.ai/` to .gitignore)
- Branch-aware: shows current branch, ahead/behind main
- CLAUDE.md section uses markers so it only replaces its own content

## Dependencies
- `git`, `sqlite3`, `bash` — nothing else
