# git-memory

**Instant project context for Claude Code sessions — powered by your git history.**

> You already write great commit messages. Why not let them work for you?

## The Problem

Every new Claude Code session starts cold. CC has to explore the codebase, read files, figure out what's active — burning tokens and time before it can do real work. CLAUDE.md helps, but keeping it manually updated is a chore nobody does consistently.

Worse: naive git-history tools dump *everything* into CLAUDE.md — build bumps, merge commits, lockfile noise — and the section bloats to 200+ lines of signal-to-noise disaster.

## The Solution

`git-memory` indexes your git history into a lightweight SQLite database and auto-generates a **lean, signal-rich** project context section in your CLAUDE.md. When a new CC session starts, a `SessionStart` hook refreshes it automatically. CC wakes up already knowing:

- **Hot files** — which real code files have the most churn (lockfiles/generated files excluded)
- **Active areas** — which directories are seeing action
- **Recent feature commits** — what actually shipped: `feat:`, `fix:`, `refactor:` — not build bumps

All in ~50–80 tokens. Huge signal, tiny footprint.

## Example Output

```
## Branch: main

## Hot Files (last 50 commits)
17|expo-app/src/screens/TalentProfileFormScreen.tsx
6|convex/schema.ts
4|expo-app/src/components/ui/ScheduleWidget.tsx
3|expo-app/src/screens/MyMatchesScreen.tsx

## Active Areas
82|expo-app
22|convex
8|(root)

## Recent Feature Commits
4e2a730 feat(matches): Add Tinder-style swipe gestures to new match cards
1b2a9f0 feat(matches): Add 4-tier interest levels and Tinder-style swipe cards
3233080 fix(ui): Relax Step 22 spacing, make all My Matches sections collapsible
6b77132 refactor(navigation): Route all job-board links to my-matches
967f029 fix(onboarding): Restore full 25-step flow, fix schedule dots
...
```

No merge commits. No `chore: bump build 97`. No `package-lock.json` churn. Just the 15 commits CC actually needs to understand what you've been building.

## Install

```bash
# Clone or copy the skill
git clone https://github.com/soderalohastrom/git-memory.git ~/.skills/git-memory

# Add alias (optional but recommended)
echo 'alias git-memory="bash ~/.skills/git-memory/scripts/git-memory.sh"' >> ~/.zshrc
source ~/.zshrc

# Init any repo
cd /your/project
git-memory init
```

`init` does everything:
1. Creates `.ai/memory.db` with indexed commits
2. Installs a Claude Code `SessionStart` hook in `.claude/settings.json`
3. Generates the first project memory section in CLAUDE.md

## Commands

| Command | What it does |
|---------|-------------|
| `git-memory init` | First-time setup — indexes, installs hook, writes CLAUDE.md |
| `git-memory index` | Incremental index (new commits only, run after commits) |
| `git-memory status` | Show what's indexed, branch info |
| `git-memory context [--limit N]` | Output project context (default: 15 feature commits) |
| `git-memory refresh-claude-md` | Re-generate CLAUDE.md section from current index |

## How It Works

- **No LLM calls** — just git + sqlite3 + bash. Zero API cost.
- **Idempotent** — safe to run `init` multiple times
- **Non-destructive** — merges into existing `.claude/settings.json` and CLAUDE.md without touching other content
- **Incremental** — only processes new commits after first run
- **Branch-aware** — context reflects your current branch
- **Noise-filtered** — lockfiles, generated files, and chore/ci/merge/build-bump commits are excluded automatically

## What Gets Filtered

**Commit noise (excluded from Recent Feature Commits):**
- Merge commits (`Merge branch ...`, `Merge pull request ...`)
- Build bumps (`chore: bump build`, `chore: release`, `chore: update deps`)
- CI/style/format commits (`ci:`, `style:`)
- Package lockfile-only commits

**File noise (excluded from Hot Files / Active Areas):**
- `package-lock.json`, `yarn.lock`, `Podfile.lock`, `*.lock`
- `node_modules/`, `dist/`, `build/`, `.expo/`
- Root-level `package.json`, `app.json`

## The Right Limit

The default `--limit 15` means "show the 15 most recent *meaningful* commits" — not raw commits. If your project has 200 commits but only 15 are `feat:`/`fix:`/`refactor:`, you'll see those 15. Build bumps don't eat into your limit.

**Why 15?** Empirically derived from `/dream` consolidation runs: sessions reading 12–15 feature commits perform as well as sessions reading 260 raw commits, at a fraction of the token cost.

## Requirements

- `git` (obviously)
- `sqlite3` (available on macOS/Linux by default)
- `bash`

That's it. No Node, no Python, no npm install.

## Philosophy

If you commit frequently with descriptive messages — and you should — your git history is already the best documentation of what happened and why. `git-memory` just makes that history legible to your AI coding assistant at the moment it matters most: session start.

The signal is in `feat:` and `fix:`. The noise is in `chore: bump build 97`. `git-memory` knows the difference.

*Ma ka hana ka ʻike* — In working, one learns. 🌺🤙🏼🚀

---

**Author:** [@soderalohastrom](https://github.com/soderalohastrom)
**License:** MIT

## Changelog

### v1.1.0
- **Recent Activity → Recent Feature Commits**: only `feat:`, `fix:`, `refactor:`, `perf:`, `add`, `implement`, `ship`, `revert` patterns shown. Merge commits, `chore: bump`, `ci:`, `style:` silently excluded.
- **Hot Files**: lockfiles, `node_modules/`, `dist/`, `build/`, `.expo/`, and root `package.json`/`app.json` excluded from churn counts.
- **Active Areas**: same lockfile exclusions applied.
- **`--limit N`** now means "max meaningful commits shown" (default 15, was 20 raw commits).
- Motivated by `/dream` consolidation results: 12 feature commits > 260 raw commits for LLM context quality.

### v1.0.0
- Initial release: SQLite-backed git history indexing, CLAUDE.md auto-update, SessionStart hook.
