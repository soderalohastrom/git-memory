#!/usr/bin/env bash
# git-memory — Index git history into SQLite for LLM context
# No dependencies beyond git, sqlite3, and standard unix tools.

set -euo pipefail

VERSION="1.1.0"
DB_DIR=".ai"
DB_PATH="$DB_DIR/memory.db"

# ── Helpers ──────────────────────────────────────────────────────────────────

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "· $*" >&2; }

check_deps() {
  command -v git     >/dev/null || die "git not found"
  command -v sqlite3 >/dev/null || die "sqlite3 not found"
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repo"
}

cd_to_root() {
  cd "$(git rev-parse --show-toplevel)"
}

ensure_db() {
  [[ -f "$DB_PATH" ]] || die "memory.db not found — run 'git-memory init' first"
}

db() { sqlite3 "$DB_PATH" "$@"; }

meta_get() { db "SELECT value FROM meta WHERE key='$1';" 2>/dev/null || echo ""; }
meta_set() { db "INSERT OR REPLACE INTO meta(key,value) VALUES('$1','$2');"; }

# ── Schema ───────────────────────────────────────────────────────────────────

create_schema() {
  db <<'SQL'
CREATE TABLE IF NOT EXISTS commits (
  hash TEXT PRIMARY KEY,
  author TEXT,
  ts INTEGER,
  message TEXT,
  files_changed INTEGER,
  insertions INTEGER,
  deletions INTEGER
);
CREATE TABLE IF NOT EXISTS file_changes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  commit_hash TEXT,
  file_path TEXT,
  status TEXT,
  FOREIGN KEY (commit_hash) REFERENCES commits(hash)
);
CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY,
  value TEXT
);
SQL
}

# ── Index commits ────────────────────────────────────────────────────────────

index_commits() {
  local range="$1"
  local count=0

  # Format: hash|author|timestamp|message
  while IFS='|' read -r hash author ts message; do
    [[ -z "$hash" ]] && continue

    # Check if already indexed
    local exists
    exists=$(db "SELECT 1 FROM commits WHERE hash='$hash' LIMIT 1;" 2>/dev/null || echo "")
    [[ -n "$exists" ]] && continue

    # Get numstat
    local files_changed=0 ins=0 del=0
    while IFS=$'\t' read -r a d f; do
      [[ -z "$f" ]] && continue
      files_changed=$((files_changed + 1))
      [[ "$a" != "-" ]] && ins=$((ins + ${a:-0}))
      [[ "$d" != "-" ]] && del=$((del + ${d:-0}))

      # Determine status
      local st="M"
      # We'll get status from diff-tree below
    done < <(git diff-tree --numstat --root "$hash" -- 2>/dev/null | tail -n +2)

    # Escape message for SQL
    local safe_msg="${message//\'/\'\'}"
    local safe_author="${author//\'/\'\'}"

    db "INSERT OR IGNORE INTO commits(hash,author,ts,message,files_changed,insertions,deletions) VALUES('$hash','$safe_author',$ts,'$safe_msg',$files_changed,$ins,$del);"

    # Index file changes with status
    while IFS=$'\t' read -r status filepath; do
      [[ -z "$filepath" ]] && continue
      local s="${status:0:1}"
      local safe_fp="${filepath//\'/\'\'}"
      db "INSERT INTO file_changes(commit_hash,file_path,status) VALUES('$hash','$safe_fp','$s');"
    done < <(git diff-tree --no-commit-id -r --name-status --root "$hash" -- 2>/dev/null)

    count=$((count + 1))
  done < <(git log $range --format="%H|%an|%at|%s" 2>/dev/null)

  meta_set "last_indexed_hash" "$(git rev-parse HEAD)"
  meta_set "last_indexed_at" "$(date +%s)"
  echo "$count"
}

# ── Subcommands ──────────────────────────────────────────────────────────────

cmd_init() {
  mkdir -p "$DB_DIR"
  create_schema
  info "Indexing last 100 commits..."
  local n
  n=$(index_commits "-n 100")
  info "Indexed $n commits → $DB_PATH"
  install_claude_hook
  cmd_refresh_claude_md
}

install_claude_hook() {
  local settings_dir=".claude"
  local settings_file="$settings_dir/settings.json"
  local hook_cmd="bash $HOME/clawd/skills/git-memory/scripts/git-memory.sh index && bash $HOME/clawd/skills/git-memory/scripts/git-memory.sh refresh-claude-md"

  mkdir -p "$settings_dir"

  if [[ -f "$settings_file" ]]; then
    # Check if hook already present
    if grep -q "git-memory" "$settings_file" 2>/dev/null; then
      info "Claude SessionStart hook already installed"
      return
    fi
    # Use python3 to merge into existing JSON
    python3 -c "
import json, sys
with open('$settings_file') as f:
    data = json.load(f)
hooks = data.setdefault('hooks', {})
ss = hooks.setdefault('SessionStart', [])
ss.append({'matcher': '', 'hooks': [{'type': 'command', 'command': '''$hook_cmd'''}]})
with open('$settings_file', 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
" 2>/dev/null && info "✅ Claude SessionStart hook added" || warn "Could not update $settings_file — add hook manually"
  else
    # Create fresh settings.json
    cat > "$settings_file" << SETTINGSEOF
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "$hook_cmd"
          }
        ]
      }
    ]
  }
}
SETTINGSEOF
    info "✅ Created $settings_file with SessionStart hook"
  fi
}

cmd_index() {
  ensure_db
  local last
  last=$(meta_get "last_indexed_hash")
  local range
  if [[ -n "$last" ]]; then
    # Check if the commit still exists (force push / rebase)
    if git cat-file -t "$last" >/dev/null 2>&1; then
      range="${last}..HEAD"
    else
      range="-n 100"
    fi
  else
    range="-n 100"
  fi
  local n
  n=$(index_commits "$range")
  info "Indexed $n new commits"
}

cmd_status() {
  ensure_db
  local total
  total=$(db "SELECT COUNT(*) FROM commits;")
  local last_hash
  last_hash=$(meta_get "last_indexed_hash")
  local last_at
  last_at=$(meta_get "last_indexed_at")
  local branch
  branch=$(git branch --show-current 2>/dev/null || echo "detached")

  echo "Branch:    $branch"
  echo "Indexed:   $total commits"
  [[ -n "$last_hash" ]] && echo "Last hash: ${last_hash:0:8}"
  if [[ -n "$last_at" ]]; then
    if date -r "$last_at" "+%Y-%m-%d %H:%M" 2>/dev/null; then
      :
    else
      date -d "@$last_at" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "$last_at"
    fi | { read -r d; echo "Last run:  $d"; }
  fi

  # Ahead/behind main
  local main_branch
  for candidate in main master; do
    if git rev-parse --verify "$candidate" >/dev/null 2>&1; then
      main_branch="$candidate"
      break
    fi
  done
  if [[ -n "${main_branch:-}" && "$branch" != "$main_branch" ]]; then
    local ab
    ab=$(git rev-list --left-right --count "$main_branch...$branch" 2>/dev/null || echo "0	0")
    local behind ahead
    behind=$(echo "$ab" | cut -f1)
    ahead=$(echo "$ab" | cut -f2)
    echo "vs $main_branch: +${ahead}/-${behind}"
  fi
}

cmd_context() {
  ensure_db
  local limit=15  # max meaningful commits shown (not raw commits scanned)
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --limit) limit="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local branch
  branch=$(git branch --show-current 2>/dev/null || echo "detached")

  # Branch info
  echo "## Branch: $branch"
  local main_branch=""
  for candidate in main master; do
    if git rev-parse --verify "$candidate" >/dev/null 2>&1; then
      main_branch="$candidate"
      break
    fi
  done
  if [[ -n "$main_branch" && "$branch" != "$main_branch" ]]; then
    local ab
    ab=$(git rev-list --left-right --count "$main_branch...$branch" 2>/dev/null || echo "0	0")
    echo "Ahead: $(echo "$ab" | cut -f2) / Behind: $(echo "$ab" | cut -f1) vs $main_branch"
  fi
  echo ""

  # Hot files — exclude lockfiles and generated noise
  echo "## Hot Files (last 50 commits)"
  db <<'SQL'
SELECT COUNT(*) as n, file_path
FROM file_changes
WHERE commit_hash IN (SELECT hash FROM commits ORDER BY ts DESC LIMIT 50)
  AND file_path NOT LIKE '%package-lock.json'
  AND file_path NOT LIKE '%yarn.lock'
  AND file_path NOT LIKE '%Podfile.lock'
  AND file_path NOT LIKE '%.lock'
  AND file_path NOT LIKE '%.expo/%'
  AND file_path NOT LIKE '%node_modules/%'
  AND file_path NOT LIKE '%dist/%'
  AND file_path NOT LIKE '%build/%'
  AND file_path NOT IN ('app.json', 'package.json', '.gitignore')
GROUP BY file_path ORDER BY n DESC LIMIT 10;
SQL
  echo ""

  # Active areas — same noise filter
  echo "## Active Areas"
  db <<'SQL'
SELECT COUNT(*) as n,
  CASE WHEN INSTR(file_path,'/') > 0
    THEN SUBSTR(file_path, 1, INSTR(file_path,'/') - 1)
    ELSE '(root)'
  END as area
FROM file_changes
WHERE commit_hash IN (SELECT hash FROM commits ORDER BY ts DESC LIMIT 50)
  AND file_path NOT LIKE '%package-lock.json'
  AND file_path NOT LIKE '%yarn.lock'
  AND file_path NOT LIKE '%Podfile.lock'
  AND file_path NOT LIKE '%.lock'
  AND file_path NOT LIKE '%node_modules/%'
GROUP BY area ORDER BY n DESC LIMIT 8;
SQL
  echo ""

  # Recent meaningful commits — filter noise, show feat/fix/refactor/perf
  # Skips: merge commits, chore: bump/update/release, ci:, style:, build:, lockfile-only
  echo "## Recent Feature Commits"
  db <<SQL
SELECT SUBSTR(hash,1,7) || ' ' || SUBSTR(message,1,72) as entry
FROM commits
WHERE (
  -- include semantic feat/fix/refactor/perf/docs with substance
  message LIKE 'feat%'
  OR message LIKE 'fix%'
  OR message LIKE 'refactor%'
  OR message LIKE 'perf%'
  OR message LIKE 'add %'
  OR message LIKE 'Add %'
  OR message LIKE 'implement%'
  OR message LIKE 'Implement%'
  OR message LIKE 'ship%'
  OR message LIKE 'Ship%'
  OR message LIKE 'update%'
  OR message LIKE 'Update%'
  OR message LIKE 'revert%'
)
  -- exclude obvious noise patterns
  AND message NOT LIKE 'chore: bump%'
  AND message NOT LIKE 'chore: update deps%'
  AND message NOT LIKE 'chore: release%'
  AND message NOT LIKE '%build number%'
  AND message NOT LIKE 'Merge branch%'
  AND message NOT LIKE 'Merge pull request%'
  AND message NOT LIKE 'ci:%'
  AND message NOT LIKE 'style:%'
  AND message NOT LIKE 'update package%'
  AND message NOT LIKE 'Update package%'
ORDER BY ts DESC LIMIT $limit;
SQL
}

cmd_refresh_claude_md() {
  ensure_db
  local claude_md="CLAUDE.md"
  local start_marker="<!-- git-memory:start -->"
  local end_marker="<!-- git-memory:end -->"

  # Generate context into a temp file (avoids multiline variable quoting issues)
  local tmp_ctx tmp_out
  tmp_ctx=$(mktemp)
  tmp_out=$(mktemp)
  {
    printf '%s\n' "$start_marker"
    echo "## Project Memory (auto-generated)"
    echo ""
    cmd_context "$@"
    printf '%s\n' "$end_marker"
  } > "$tmp_ctx"

  if [[ ! -f "$claude_md" ]]; then
    mv "$tmp_ctx" "$claude_md"
    info "Created $claude_md with project memory"
    return
  fi

  # Check if markers exist
  if grep -qF "$start_marker" "$claude_md"; then
    # Replace between markers (inclusive) using python3 for reliable multiline handling
    python3 - "$claude_md" "$tmp_ctx" "$tmp_out" << 'PYEOF'
import sys

orig_path, new_section_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
START = "<!-- git-memory:start -->"
END   = "<!-- git-memory:end -->"

with open(orig_path) as f:
    lines = f.read().splitlines(keepends=True)
with open(new_section_path) as f:
    replacement = f.read()

out = []
skip = False
injected = False
for line in lines:
    stripped = line.rstrip('\n')
    if stripped == START:
        out.append(replacement if replacement.endswith('\n') else replacement + '\n')
        skip = True
        injected = True
        continue
    if stripped == END:
        skip = False
        continue
    if not skip:
        out.append(line)

if not injected:
    out.append('\n' + replacement)

with open(out_path, 'w') as f:
    f.writelines(out)
PYEOF
    mv "$tmp_out" "$claude_md"
    rm -f "$tmp_ctx"
    info "Updated project memory section in $claude_md"
  else
    # Append
    printf '\n' >> "$claude_md"
    cat "$tmp_ctx" >> "$claude_md"
    rm -f "$tmp_ctx"
    info "Appended project memory section to $claude_md"
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

check_deps
cd_to_root

case "${1:-help}" in
  init)              cmd_init ;;
  index)             cmd_index ;;
  status)            cmd_status ;;
  context)           shift; cmd_context "$@" ;;
  refresh-claude-md) shift; cmd_refresh_claude_md "$@" ;;
  version)           echo "git-memory $VERSION" ;;
  *)
    echo "git-memory $VERSION — Git history as project memory"
    echo ""
    echo "Usage: git-memory <command>"
    echo ""
    echo "  init              Create .ai/memory.db and index last 100 commits"
    echo "  index             Incremental index (new commits only)"
    echo "  status            Show index status and branch info"
    echo "  context [--limit N]  Output project context (default: 15 feature commits)"
    echo "  refresh-claude-md Update CLAUDE.md with project memory section"
    echo "  version           Show version"
    echo ""
    echo "v1.1.0 changes:"
    echo "  - Recent Activity → Recent Feature Commits (filters noise commits)"
    echo "  - Hot Files / Active Areas exclude lockfiles and generated noise"
    echo "  - --limit N controls meaningful commits shown (not raw commits scanned)"
    echo "  - Default limit: 15 (was 20 raw commits)"
    ;;
esac
