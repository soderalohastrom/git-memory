#!/usr/bin/env bash
# git-memory — Index git history into SQLite for LLM context
# No dependencies beyond git, sqlite3, and standard unix tools.

set -euo pipefail

VERSION="1.0.0"
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
  local limit=20
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

  # Hot files (last 50 commits)
  echo "## Hot Files (last 50 commits)"
  db <<'SQL'
SELECT COUNT(*) as changes, file_path
FROM file_changes
WHERE commit_hash IN (SELECT hash FROM commits ORDER BY ts DESC LIMIT 50)
GROUP BY file_path ORDER BY changes DESC LIMIT 10;
SQL
  echo ""

  # Active areas
  echo "## Active Areas"
  db <<SQL
SELECT COUNT(*) as changes,
  CASE WHEN INSTR(file_path,'/') > 0
    THEN SUBSTR(file_path, 1, INSTR(file_path,'/') - 1)
    ELSE '(root)'
  END as area
FROM file_changes
WHERE commit_hash IN (SELECT hash FROM commits ORDER BY ts DESC LIMIT 50)
GROUP BY area ORDER BY changes DESC LIMIT 8;
SQL
  echo ""

  # Recent activity grouped by day
  echo "## Recent Activity"
  db <<SQL
SELECT DATE(ts, 'unixepoch', 'localtime') as day, COUNT(*) as n,
  GROUP_CONCAT(SUBSTR(hash,1,7) || ' ' || SUBSTR(message,1,60), CHAR(10)) as commits
FROM commits ORDER BY ts DESC LIMIT $limit;
SQL
}

cmd_refresh_claude_md() {
  ensure_db
  local claude_md="CLAUDE.md"
  local start_marker="<!-- git-memory:start -->"
  local end_marker="<!-- git-memory:end -->"

  # Generate context
  local context
  context=$(cmd_context "$@")
  local section
  section=$(printf '%s\n## Project Memory (auto-generated)\n\n%s\n%s' "$start_marker" "$context" "$end_marker")

  if [[ ! -f "$claude_md" ]]; then
    echo "$section" > "$claude_md"
    info "Created $claude_md with project memory"
    return
  fi

  # Check if markers exist
  if grep -q "$start_marker" "$claude_md"; then
    # Replace between markers (inclusive)
    local tmp
    tmp=$(mktemp)
    awk -v start="$start_marker" -v end="$end_marker" -v replacement="$section" '
      $0 == start { print replacement; skip=1; next }
      $0 == end { skip=0; next }
      !skip { print }
    ' "$claude_md" > "$tmp"
    mv "$tmp" "$claude_md"
    info "Updated project memory section in $claude_md"
  else
    # Append
    printf '\n%s\n' "$section" >> "$claude_md"
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
    echo "  context [--limit] Output project context for LLM sessions"
    echo "  refresh-claude-md Update CLAUDE.md with project memory section"
    echo "  version           Show version"
    ;;
esac
