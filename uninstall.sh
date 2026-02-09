#!/usr/bin/env bash
set -euo pipefail

# claude-batch-toolkit uninstaller
# Usage: ./uninstall.sh [--purge-data] [--unattended]

# ─── Defaults ───────────────────────────────────────────────────────────────────
UNATTENDED=0
PURGE_DATA=0
CLAUDE_DIR="$HOME/.claude"
BATCHES_DIR="$CLAUDE_DIR/batches"
RESULTS_DIR="$BATCHES_DIR/results"
CLAUDE_JSON="$HOME/.claude.json"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
ENV_FILE="$CLAUDE_DIR/env"

# ─── Color helpers ──────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[info]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ok]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC}  $*"; }
err()   { echo -e "${RED}[error]${NC} $*" >&2; }
die()   { err "$@"; exit 1; }

# ─── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --purge-data)
            PURGE_DATA=1
            shift
            ;;
        --unattended)
            UNATTENDED=1
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--purge-data] [--unattended]"
            echo ""
            echo "Options:"
            echo "  --purge-data   Also remove jobs.json and results/ (default: preserve)"
            echo "  --unattended   No interactive prompts"
            exit 0
            ;;
        *)
            die "Unknown option: $1 (use --help)"
            ;;
    esac
done

# ─── Pre-flight checks ─────────────────────────────────────────────────────────
command -v jq &>/dev/null || die "jq is required for safe JSON manipulation but was not found."

echo ""
echo -e "${BOLD}claude-batch-toolkit uninstaller${NC}"
echo "─────────────────────────────────"
echo ""

# ─── Helper: atomic JSON write ─────────────────────────────────────────────────
# Usage: atomic_json_write <json_string> <target_file>
# Validates JSON, writes to temp, then atomically moves into place.
atomic_json_write() {
    local json_content="$1"
    local target="$2"
    local tmpfile="${target}.uninstall_tmp.$$"

    # Validate & pretty-print
    if ! echo "$json_content" | jq '.' > "$tmpfile" 2>/dev/null; then
        rm -f "$tmpfile"
        die "BUG: Generated invalid JSON for $target. Aborting (no changes made to this file)."
    fi

    mv -f "$tmpfile" "$target"
}

# ─── Build change manifest ─────────────────────────────────────────────────────
echo -e "${BOLD}Planned changes:${NC}"
echo ""

CHANGES=()
WARNINGS=()

# 1. ~/.claude.json — remove mcpServers["claude-batch"] only
if [[ -f "$CLAUDE_JSON" ]]; then
    if ! jq '.' "$CLAUDE_JSON" &>/dev/null; then
        WARNINGS+=("$CLAUDE_JSON is not valid JSON — will skip modifying it")
    elif jq -e '.mcpServers["claude-batch"]' "$CLAUDE_JSON" &>/dev/null; then
        CHANGES+=("BACKUP      $CLAUDE_JSON → ${CLAUDE_JSON}.bak")
        CHANGES+=("MODIFY      $CLAUDE_JSON  (remove mcpServers.claude-batch)")
    else
        CHANGES+=("NO CHANGE   $CLAUDE_JSON  (claude-batch entry not found)")
    fi
else
    CHANGES+=("NO CHANGE   $CLAUDE_JSON  (file not found)")
fi

# 2. settings.json — remove statusLine only if it points to our script
STATUS_CMD="bash $CLAUDE_DIR/statusline.sh"
if [[ -f "$SETTINGS_FILE" ]]; then
    if ! jq '.' "$SETTINGS_FILE" &>/dev/null; then
        WARNINGS+=("$SETTINGS_FILE is not valid JSON — will skip modifying it")
    else
        EXISTING_STATUS_CMD="$(jq -r '.statusLine.command // empty' "$SETTINGS_FILE" 2>/dev/null || true)"
        if [[ "$EXISTING_STATUS_CMD" == "$STATUS_CMD" ]]; then
            CHANGES+=("BACKUP      $SETTINGS_FILE → ${SETTINGS_FILE}.bak")
            CHANGES+=("MODIFY      $SETTINGS_FILE  (remove statusLine)")
        elif [[ -n "$EXISTING_STATUS_CMD" ]]; then
            CHANGES+=("NO CHANGE   $SETTINGS_FILE  (statusLine points to different script)")
        else
            CHANGES+=("NO CHANGE   $SETTINGS_FILE  (statusLine not set)")
        fi
    fi
else
    CHANGES+=("NO CHANGE   $SETTINGS_FILE  (file not found)")
fi

# 3. Env file — remove ANTHROPIC_API_KEY line only
if [[ -f "$ENV_FILE" ]]; then
    if grep -q '^export ANTHROPIC_API_KEY=' "$ENV_FILE" 2>/dev/null; then
        # Check if there are other lines (non-empty, non-ANTHROPIC_API_KEY)
        OTHER_LINES="$(grep -v '^export ANTHROPIC_API_KEY=' "$ENV_FILE" 2>/dev/null | grep -c '[^[:space:]]' || true)"
        if [[ "$OTHER_LINES" -gt 0 ]]; then
            CHANGES+=("MODIFY      $ENV_FILE  (remove ANTHROPIC_API_KEY, preserve other vars)")
        else
            CHANGES+=("REMOVE      $ENV_FILE  (contains only ANTHROPIC_API_KEY)")
        fi
    else
        CHANGES+=("NO CHANGE   $ENV_FILE  (ANTHROPIC_API_KEY not found)")
    fi
else
    CHANGES+=("NO CHANGE   $ENV_FILE  (file not found)")
fi

# 4. Toolkit files
if [[ -f "$CLAUDE_DIR/mcp/claude_batch_mcp.py" ]]; then
    CHANGES+=("REMOVE      $CLAUDE_DIR/mcp/claude_batch_mcp.py")
else
    CHANGES+=("NO CHANGE   $CLAUDE_DIR/mcp/claude_batch_mcp.py  (not found)")
fi

if [[ -f "$CLAUDE_DIR/skills/batch/SKILL.md" ]]; then
    CHANGES+=("REMOVE      $CLAUDE_DIR/skills/batch/SKILL.md")
else
    CHANGES+=("NO CHANGE   $CLAUDE_DIR/skills/batch/SKILL.md  (not found)")
fi

if [[ -f "$CLAUDE_DIR/statusline.sh" ]]; then
    CHANGES+=("REMOVE      $CLAUDE_DIR/statusline.sh")
else
    CHANGES+=("NO CHANGE   $CLAUDE_DIR/statusline.sh  (not found)")
fi

# 5. Poll cache and lock
if [[ -f "$BATCHES_DIR/.poll_cache" ]]; then
    CHANGES+=("REMOVE      $BATCHES_DIR/.poll_cache")
fi
if [[ -f "$BATCHES_DIR/.poll.lock" ]]; then
    CHANGES+=("REMOVE      $BATCHES_DIR/.poll.lock")
fi

# 6. Empty directory cleanup (only if they would be empty)
for d in "$CLAUDE_DIR/mcp" "$CLAUDE_DIR/skills/batch" "$CLAUDE_DIR/skills"; do
    if [[ -d "$d" ]]; then
        CHANGES+=("RMDIR       $d  (only if empty after removal)")
    fi
done

# 7. Data files (jobs.json, results)
if [[ "$PURGE_DATA" -eq 1 ]]; then
    if [[ -f "$BATCHES_DIR/jobs.json" ]]; then
        CHANGES+=("REMOVE      $BATCHES_DIR/jobs.json  (--purge-data)")
    fi
    if [[ -d "$RESULTS_DIR" ]]; then
        RESULT_COUNT="$(find "$RESULTS_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
        if [[ "$RESULT_COUNT" -gt 0 ]]; then
            CHANGES+=("REMOVE      $RESULTS_DIR  ($RESULT_COUNT result file(s), --purge-data)")
        else
            CHANGES+=("RMDIR       $RESULTS_DIR  (empty, --purge-data)")
        fi
    fi
    if [[ -d "$BATCHES_DIR" ]]; then
        CHANGES+=("RMDIR       $BATCHES_DIR  (only if empty after removal)")
    fi
else
    if [[ -f "$BATCHES_DIR/jobs.json" ]]; then
        CHANGES+=("PRESERVE    $BATCHES_DIR/jobs.json  (use --purge-data to remove)")
    fi
    if [[ -d "$RESULTS_DIR" ]]; then
        RESULT_COUNT="$(find "$RESULTS_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
        if [[ "$RESULT_COUNT" -gt 0 ]]; then
            CHANGES+=("PRESERVE    $RESULTS_DIR  ($RESULT_COUNT result file(s), use --purge-data to remove)")
        fi
    fi
fi

# Print the manifest
for change in "${CHANGES[@]}"; do
    echo -e "  ${CYAN}•${NC} $change"
done

if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    echo ""
    for w in "${WARNINGS[@]}"; do
        warn "$w"
    done
fi

echo ""

# ─── Confirm with user ─────────────────────────────────────────────────────────
if [[ "$UNATTENDED" -eq 0 ]]; then
    echo -e -n "${BOLD}Proceed with uninstall? [Y/n]${NC} "
    read -r CONFIRM
    case "${CONFIRM:-Y}" in
        [Yy]|[Yy]es|"") ;;
        *) echo "Aborted."; exit 0 ;;
    esac
    echo ""
fi

# ─── Track removals ────────────────────────────────────────────────────────────
REMOVED=0

# ─── Remove MCP server registration from ~/.claude.json ────────────────────────
if [[ -f "$CLAUDE_JSON" ]]; then
    if jq '.' "$CLAUDE_JSON" &>/dev/null; then
        if jq -e '.mcpServers["claude-batch"]' "$CLAUDE_JSON" &>/dev/null; then
            # Backup before modifying
            cp -p "$CLAUDE_JSON" "${CLAUDE_JSON}.bak"
            info "Backed up ${CLAUDE_JSON} → ${CLAUDE_JSON}.bak"

            EXISTING=$(cat "$CLAUDE_JSON")
            UPDATED=$(echo "$EXISTING" | jq 'del(.mcpServers["claude-batch"])')

            atomic_json_write "$UPDATED" "$CLAUDE_JSON"
            ok "Removed claude-batch from $CLAUDE_JSON"
            REMOVED=$((REMOVED + 1))
        else
            info "claude-batch not found in $CLAUDE_JSON (already removed)"
        fi
    else
        warn "$CLAUDE_JSON is not valid JSON — skipping"
    fi
else
    info "$CLAUDE_JSON not found"
fi

# ─── Remove statusLine from settings.json ───────────────────────────────────────
if [[ -f "$SETTINGS_FILE" ]]; then
    if jq '.' "$SETTINGS_FILE" &>/dev/null; then
        EXISTING_STATUS_CMD="$(jq -r '.statusLine.command // empty' "$SETTINGS_FILE" 2>/dev/null || true)"
        if [[ "$EXISTING_STATUS_CMD" == "$STATUS_CMD" ]]; then
            # Backup before modifying
            cp -p "$SETTINGS_FILE" "${SETTINGS_FILE}.bak"
            info "Backed up ${SETTINGS_FILE} → ${SETTINGS_FILE}.bak"

            EXISTING_SETTINGS=$(cat "$SETTINGS_FILE")
            UPDATED_SETTINGS=$(echo "$EXISTING_SETTINGS" | jq 'del(.statusLine)')

            atomic_json_write "$UPDATED_SETTINGS" "$SETTINGS_FILE"
            ok "Removed statusLine from $SETTINGS_FILE"
            REMOVED=$((REMOVED + 1))
        elif [[ -n "$EXISTING_STATUS_CMD" ]]; then
            info "statusLine points to a different script — leaving as-is"
        else
            info "statusLine not set in $SETTINGS_FILE"
        fi
    else
        warn "$SETTINGS_FILE is not valid JSON — skipping"
    fi
else
    info "$SETTINGS_FILE not found"
fi

# ─── Remove ANTHROPIC_API_KEY from env file ─────────────────────────────────────
if [[ -f "$ENV_FILE" ]]; then
    if grep -q '^export ANTHROPIC_API_KEY=' "$ENV_FILE" 2>/dev/null; then
        # Build new content: everything except ANTHROPIC_API_KEY lines
        FILTERED="$(grep -v '^export ANTHROPIC_API_KEY=' "$ENV_FILE" 2>/dev/null || true)"

        # Check if anything meaningful remains
        if echo "$FILTERED" | grep -q '[^[:space:]]'; then
            # Write filtered content atomically
            TMPFILE="${ENV_FILE}.uninstall_tmp.$$"
            echo "$FILTERED" > "$TMPFILE"
            chmod 600 "$TMPFILE"
            mv -f "$TMPFILE" "$ENV_FILE"
            ok "Removed ANTHROPIC_API_KEY from $ENV_FILE (other vars preserved)"
        else
            rm -f "$ENV_FILE"
            ok "Removed $ENV_FILE (contained only ANTHROPIC_API_KEY)"
        fi
        REMOVED=$((REMOVED + 1))
    else
        info "ANTHROPIC_API_KEY not found in $ENV_FILE"
    fi
else
    info "$ENV_FILE not found"
fi

# ─── Remove toolkit files ──────────────────────────────────────────────────────
if [[ -f "$CLAUDE_DIR/mcp/claude_batch_mcp.py" ]]; then
    rm -f "$CLAUDE_DIR/mcp/claude_batch_mcp.py"
    ok "Removed $CLAUDE_DIR/mcp/claude_batch_mcp.py"
    REMOVED=$((REMOVED + 1))
fi

if [[ -f "$CLAUDE_DIR/skills/batch/SKILL.md" ]]; then
    rm -f "$CLAUDE_DIR/skills/batch/SKILL.md"
    ok "Removed $CLAUDE_DIR/skills/batch/SKILL.md"
    REMOVED=$((REMOVED + 1))
fi

if [[ -f "$CLAUDE_DIR/statusline.sh" ]]; then
    rm -f "$CLAUDE_DIR/statusline.sh"
    ok "Removed $CLAUDE_DIR/statusline.sh"
    REMOVED=$((REMOVED + 1))
fi

# ─── Remove poll cache and lock files ──────────────────────────────────────────
if [[ -f "$BATCHES_DIR/.poll_cache" ]]; then
    rm -f "$BATCHES_DIR/.poll_cache"
    info "Removed poll cache"
fi

if [[ -f "$BATCHES_DIR/.poll.lock" ]]; then
    rm -f "$BATCHES_DIR/.poll.lock"
    info "Removed poll lock"
fi

# ─── Clean up empty directories (rmdir only — safe for non-empty) ──────────────
rmdir "$CLAUDE_DIR/mcp" 2>/dev/null && info "Removed empty directory $CLAUDE_DIR/mcp/" || true
rmdir "$CLAUDE_DIR/skills/batch" 2>/dev/null && info "Removed empty directory $CLAUDE_DIR/skills/batch/" || true
rmdir "$CLAUDE_DIR/skills" 2>/dev/null && info "Removed empty directory $CLAUDE_DIR/skills/" || true

# ─── Handle data files ─────────────────────────────────────────────────────────
if [[ "$PURGE_DATA" -eq 1 ]]; then
    # Remove individual result files (not rm -rf)
    if [[ -d "$RESULTS_DIR" ]]; then
        RESULT_COUNT="$(find "$RESULTS_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
        if [[ "$RESULT_COUNT" -gt 0 ]]; then
            find "$RESULTS_DIR" -type f -delete 2>/dev/null
            ok "Removed $RESULT_COUNT result file(s) from $RESULTS_DIR"
        fi
        # Remove result subdirectories (empty ones only, bottom-up)
        find "$RESULTS_DIR" -depth -type d -empty -delete 2>/dev/null || true
        rmdir "$RESULTS_DIR" 2>/dev/null && info "Removed empty directory $RESULTS_DIR" || true
    fi

    if [[ -f "$BATCHES_DIR/jobs.json" ]]; then
        rm -f "$BATCHES_DIR/jobs.json"
        ok "Removed $BATCHES_DIR/jobs.json"
    fi

    rmdir "$BATCHES_DIR" 2>/dev/null && info "Removed empty directory $BATCHES_DIR" || true
else
    # Preserve and notify
    if [[ -d "$RESULTS_DIR" ]]; then
        RESULT_COUNT="$(find "$RESULTS_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
        if [[ "$RESULT_COUNT" -gt 0 ]]; then
            warn "Preserving $RESULT_COUNT result file(s) in $RESULTS_DIR"
        fi
    fi

    if [[ -f "$BATCHES_DIR/jobs.json" ]]; then
        warn "Preserving $BATCHES_DIR/jobs.json"
    fi
fi

# ─── Done ───────────────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────"
if [[ "$REMOVED" -gt 0 ]]; then
    echo -e "${GREEN}${BOLD}Uninstall complete!${NC}"
else
    echo -e "${YELLOW}${BOLD}Nothing to uninstall (toolkit files not found).${NC}"
fi
echo ""

if [[ "$PURGE_DATA" -eq 0 ]]; then
    echo "Preserved:"
    echo "  • Results:   $RESULTS_DIR"
    echo "  • Jobs log:  $BATCHES_DIR/jobs.json"
    echo ""
    echo "To fully remove all data:"
    echo "  $0 --purge-data --unattended"
    echo "  # or manually: rm -rf \"$BATCHES_DIR\""
    echo ""
else
    echo "All toolkit files and data have been removed."
    echo ""
fi
