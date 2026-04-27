#!/bin/bash

log() {
    local message="$1"
    # 只输出一次，让Node.js的child.stdout处理前缀
    echo "[RUN-REVIEW-SERVICE-SH] $message"
    printf "" >&1 # 强制刷新
}

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

RUN_REVIEW_SCRIPT="$SCRIPT_DIR/run_review_and_update_db.sh"

CRONTAB_LOG_DIR="$HOME/crontab_log"

# Function: Center-align a string and pad with the specified character
center_pad() {
    local input=$1                            # Input string, e.g. "usermanagement"
    local width=$2                            # Target length, e.g. 14
    local pad_char=$3                         # Padding character, e.g. "_"
    local len=${#input}                       # Length of input string
    local total_pad=$((width - len))          # Number of padding characters needed
    local left_pad=$((total_pad / 2))         # Number of left padding characters
    local right_pad=$((total_pad - left_pad)) # Number of right padding characters

    # If input length is greater than or equal to target length, return original string
    if [ $len -ge $width ]; then
        echo "$input"
        return
    fi

    # Use printf to generate left and right padding
    printf "%${left_pad}s%s%${right_pad}s" "$pad_char" "$input" "$pad_char" | tr ' ' "$pad_char"
}

pushd "$SCRIPT_DIR" >/dev/null || exit 1

# Get project list from repos directory
REPOS_DIR="repos"

if [ ! -d "$REPOS_DIR" ]; then
    log "ERROR: repos directory not found at $REPOS_DIR"
    exit 1
fi

# Get all directories in repos, sorted by name
mapfile -t projects < <(find "$REPOS_DIR" -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | sort -r)

if ((${#projects[@]} == 0)); then
    log "WARNING: No project directories found in $REPOS_DIR"
    exit 0
fi

log "Found projects: ${projects[*]}"

for project in "${projects[@]}"; do
    padded_project=$(center_pad "$project" 14 ".")
    log "=========================================="
    log "Starting review for project: $project"
    log "Time: $(date)"
    log "=========================================="

    "$RUN_REVIEW_SCRIPT" "$project" --headless --update-last-commit >"$CRONTAB_LOG_DIR/review_${padded_project}_$(date +%Y%m%d_%H%M%S).log" 2>&1

    log "=========================================="
    log "Completed review for project: $project"
    log "Time: $(date)"
    log "=========================================="
    log ""
done

popd >/dev/null || exit 1
