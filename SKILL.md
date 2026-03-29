# git-memory v1.1.0

Git history as lean project memory. Indexes commits into SQLite and generates a noise-filtered context section in CLAUDE.md so new Claude Code sessions start with signal, not commit dumps.

## When to Use
- Starting a new CC session on any git repo
- Asked about recent project activity, hot files, or active areas
- CLAUDE.md project memory section is stale or bloated
- After a `/dream`-style cleanup, to prevent re-bloat

## Setup (once per repo)
```bash
git-memory init
```
Creates `.ai/memory.db` with the last ~100 commits indexed, installs SessionStart hook, writes first CLAUDE.md section.

## Session Start (automated via hook)
```bash
git-memory index && git-memory refresh-claude-md
```
Incremental — only processes new commits. Runs automatically on `SessionStart` after `init`.

## Commands
| Command | Purpose |
|---------|---------|
| `init` | First-time setup |
| `index` | Incremental update (fast) |
| `status` | What's indexed, branch info |
| `context [--limit N]` | Output context (default: 15 feature commits) |
| `refresh-claude-md` | Regenerate CLAUDE.md section |

## What the Output Looks Like
- **Hot Files** — top churned real code files (lockfiles/generated excluded)
- **Active Areas** — top directories by activity
- **Recent Feature Commits** — up to 15 `feat:`/`fix:`/`refactor:` commits; merge commits, build bumps, `ci:`, `style:` are filtered out

## Noise Filtering (v1.1.0)
Excluded from commits: merge commits, `chore: bump`, `chore: release`, `chore: update deps`, `ci:`, `style:`, build number bumps
Excluded from files: `*.lock`, `package-lock.json`, `yarn.lock`, `Podfile.lock`, `node_modules/`, `dist/`, `build/`, `.expo/`, root `package.json`/`app.json`

## Dependencies
- `git`, `sqlite3`, `bash` — nothing else
- Script: `~/clawd/skills/git-memory/scripts/git-memory.sh`
