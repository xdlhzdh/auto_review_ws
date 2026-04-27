#!/bin/bash

log() {
    local message="$1"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    # 统一输出到 stdout 和 log 文件
    echo "[$timestamp] [RUN-REVIEW-AND-UPDATE-DB-SH] $message" | tee -a "$ERROR_LOG"
    printf "" >&1 # 强制刷新
}

# 检查参数
if [[ $# -lt 1 ]]; then
    log "Usage: $0 <REPO_NAME> [commitId] [--headless] [--force] [--email <email>]"
    log "  --headless Force review in headless mode (no browser GUI)"
    log "  --force    Force review even if the commit has already been reviewed"
    log "  --email    Specify user email for OBO authentication"
    log "  --update-last-commit Update the last commit record after processing"
    log ""
    log "Examples:"
    log "  $0 repo_name"
    log "  $0 repo_name abc123"
    log "  $0 repo_name abc123 --headless"
    log "  $0 repo_name abc123 --headless --force"
    log "  $0 repo_name abc123 --headless --force --update-last-commit"
    log "  $0 repo_name abc123 --headless --email user@example.com"
    exit 1
fi

# 获取当前脚本的目录
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

# TypeScript 脚本路径
RUN_REVIEW_SCRIPT="$SCRIPT_DIR/run_review.sh"
UPDATE_REVIEW_SCRIPT="$SCRIPT_DIR/auto_review_ui/update_review.mjs"
UPDATE_LAST_COMMIT_SCRIPT="$SCRIPT_DIR/auto_review_ui/update_last_commit.mjs"
UPDATE_REVIEW_STATUS_SCRIPT="$SCRIPT_DIR/auto_review_ui/update_review_status.mjs"
GET_LAST_COMMIT_SCRIPT="$SCRIPT_DIR/auto_review_ui/get_last_commit.mjs"
CHECK_REVIEW_STATUS_SCRIPT="$SCRIPT_DIR/auto_review_ui/check_review_status.mjs"

# 获取参数
REPO_NAME="$1"
COMMIT_ID=""
HEADLESS=false
FORCE=false
UPDATE_LAST_COMMIT=false
GERRIT_PROJECT=""
GERRIT_REF=""
EMAIL=""

# 解析参数
shift # 移除第一个参数 REPO_NAME
while [[ $# -gt 0 ]]; do
    case "$1" in
    --headless)
        HEADLESS=true
        shift
        ;;
    --force)
        FORCE=true
        shift
        ;;
    --update-last-commit)
        UPDATE_LAST_COMMIT=true
        shift
        ;;
    --gerrit-project)
        GERRIT_PROJECT="$2"
        shift 2
        ;;
    --ref)
        GERRIT_REF="$2"
        shift 2
        ;;
    --email)
        EMAIL="$2"
        shift 2
        ;;
    *)
        # 如果没有指定 COMMIT_ID 且不是选项参数
        if [[ -z "$COMMIT_ID" && ! "$1" =~ ^-- ]]; then
            COMMIT_ID="$1"
        fi
        shift
        ;;
    esac
done

REPO_DIR="$SCRIPT_DIR/repos/$REPO_NAME"
OUTPUT_DIR="$SCRIPT_DIR/output"
ERROR_LOG="$OUTPUT_DIR/error.log"

# 创建锁文件路径
LOCK_FILE="$OUTPUT_DIR/run_review.lock"
LOCK_INFO_FILE="$OUTPUT_DIR/run_review.lock.info"

# 创建跨环境可靠的锁定函数
acquire_lock() {
    local lock_file="$1"
    local lock_info_file="$2"
    local timeout=300 # 5分钟超时
    local waited=0

    # 确保目录存在
    mkdir -p "$(dirname "$lock_file")"

    log "Attempting to acquire lock: $lock_file"

    local current_info="PID:$$|HOST:$(hostname)|TIME:$(date '+%Y-%m-%d %H:%M:%S')|USER:$(whoami)"

    while [[ $waited -lt $timeout ]]; do
        # 尝试创建锁文件（原子操作）
        if (
            # 使用 flock 和文件创建的组合方式
            exec 200>"$lock_file"
            if flock -n 200; then
                echo "$current_info" >"$lock_info_file"
                echo "$current_info" >&200
                echo "LOCKED" >&200
                # 保持锁文件描述符打开
                exec 200>&-
                exit 0
            else
                exit 1
            fi
        ); then
            log "Lock acquired successfully: $lock_file"
            log "Lock info: $current_info"

            # 重新打开文件描述符用于释放锁
            exec 200>"$lock_file"
            if ! flock -n 200; then
                log "Warning: Could not re-acquire lock for cleanup"
            fi

            # 设置 trap 确保退出时释放锁
            trap 'release_lock "$lock_file" "$lock_info_file" 200' EXIT INT TERM
            return 0
        fi

        # 检查现有锁的信息
        if [[ -f "$lock_info_file" ]]; then
            local existing_lock_info
            if existing_lock_info=$(cat "$lock_info_file" 2>/dev/null); then
                log "Lock currently held by: $existing_lock_info"

                # 解析进程ID和主机名
                local existing_pid=$(echo "$existing_lock_info" | grep -o 'PID:[0-9]*' | cut -d':' -f2)
                local existing_host=$(echo "$existing_lock_info" | grep -o 'HOST:[^|]*' | cut -d':' -f2)
                local current_host=$(hostname)

                # 如果是同一主机，检查进程是否还存在
                if [[ "$existing_host" == "$current_host" && -n "$existing_pid" ]]; then
                    if ! kill -0 "$existing_pid" 2>/dev/null; then
                        log "Detected stale lock (process $existing_pid no longer exists), attempting cleanup..."
                        rm -f "$lock_file" "$lock_info_file" 2>/dev/null || true
                        continue
                    fi
                fi

                # 检查锁文件的时间戳，如果超过1小时认为是僵尸锁
                if [[ -f "$lock_file" ]]; then
                    local lock_age_minutes=$((($(date +%s) - $(stat -c %Y "$lock_file" 2>/dev/null || echo 0)) / 60))
                    if [[ $lock_age_minutes -gt 60 ]]; then
                        log "Detected very old lock (${lock_age_minutes} minutes), attempting cleanup..."
                        rm -f "$lock_file" "$lock_info_file" 2>/dev/null || true
                        continue
                    fi
                fi
            fi
        fi

        log "Waiting for lock... (${waited}s/${timeout}s)"
        sleep 5
        waited=$((waited + 5))

        # 每3个等待周期输出更详细的信息
        if [[ $((waited % 15)) -eq 0 ]]; then
            log "Still waiting for lock release. Current holder info:"
            if [[ -r "$lock_info_file" ]]; then
                log "$(</"$lock_info_file")"
            else
                log "  (lock info file not readable)"
            fi
        fi
    done

    log "Failed to acquire lock after ${timeout}s timeout"
    exit 2
}

release_lock() {
    local lock_file="$1"
    local lock_info_file="$2"
    local fd="$3"

    log "Releasing lock..."

    # 释放文件锁
    flock -u "$fd" 2>/dev/null || true
    exec 200>&- 2>/dev/null || true

    # 清理锁文件
    rm -f "$lock_file" "$lock_info_file" 2>/dev/null || true

    log "Lock released"
}

# 获取锁
acquire_lock "$LOCK_FILE" "$LOCK_INFO_FILE"

log "Processing repository: $REPO_NAME"

# 创建 output 目录
if [[ ! -d "$OUTPUT_DIR" ]]; then
    mkdir "$OUTPUT_DIR"
fi

# 只保留最新的200个文件
KEEP_FILES=200

# 检查文件数量并删除多余的老文件（排除 ERROR_LOG 和 LOCK_FILE)
mapfile -t old_files < <(find "$OUTPUT_DIR" -maxdepth 1 -type f ! -name "$(basename "$ERROR_LOG")" ! -name "$(basename "$JOB_ONGOING_FILE")" -printf "%T@ %p\n" | sort -n | head -n -$KEEP_FILES | cut -d' ' -f2-)
if [[ ${#old_files[@]} -gt 0 ]]; then
    echo "Found ${#old_files[@]} old files to delete (keeping latest $KEEP_FILES)"
    for file in "${old_files[@]}"; do
        if rm -f "$file"; then
            log "Deleted old file: $file"
        else
            log "Warning: Failed to delete old file: $file"
        fi
    done
else
    log "No old files to delete."
fi

# 检查 ERROR_LOG 行数，如果超过3000行，则保留最新的1500行
MAX_LINES=3000
KEEP_LINES=1500

if [[ -f "$ERROR_LOG" && $(wc -l <"$ERROR_LOG") -gt $MAX_LINES ]]; then
    log "Removing oldest lines from error log..."
    tmp_file="$ERROR_LOG.tmp.$$"                                        # 使用 PID 避免临时文件冲突
    trap 'rm -f "$tmp_file"' EXIT SIGINT SIGTERM SIGHUP SIGQUIT SIGABRT # 确保异常退出时删除临时文件

    if ! tail -n $KEEP_LINES "$ERROR_LOG" >"$tmp_file"; then
        log "Error: Failed to extract last $KEEP_LINES lines"
        rm -f "$tmp_file"
        exit 1
    fi

    if ! mv "$tmp_file" "$ERROR_LOG"; then
        log "Error: Failed to overwrite $ERROR_LOG"
        rm -f "$tmp_file"
        exit 1
    fi

    log "Successfully retained last $KEEP_LINES lines"
fi

# 检查仓库路径是否存在
if [[ ! -d "$REPO_DIR" ]]; then
    log "Error: Directory '$REPO_DIR' does not exist."
    exit 1
fi

# 检查是否是有效的 Git 仓库
if [[ ! -d "$REPO_DIR/.git" ]]; then
    log "Error: '$REPO_DIR' is not a valid Git repository."
    exit 1
fi

CHANGE_NUM=""
PATCHSET=""
# 获取远程最新的 master 分支，并强制同步
# 检查是否提供了 GERRIT_REF（优先使用）或 COMMIT_ID 是否是 ref 格式
if [[ -n "$GERRIT_REF" ]]; then
    # 如果提供了 GERRIT_REF，优先使用它
    log "Using provided Gerrit ref: $GERRIT_REF"

    # Normalize GERRIT_REF: strip trailing slash and support Gerrit web URL formats
    # Examples supported:
    # - refs/changes/85/1234567/15
    # - /c/your-project/+/1234567/15
    # - https://.../c/your-project/.../+/1234567/15/
    # - 1234567/15  (change/patchset)
    # - 1234567     (change only)
    GERRIT_REF="${GERRIT_REF%/}"

    # First check if it is already in refs/changes/XX/YYYYYY/ZZ format
    if echo "$GERRIT_REF" | grep -q "^refs/changes/"; then
        # Extract from refs/changes/XX/CHANGE/PATCHSET format
        read CHANGE_NUM PATCHSET <<<$(echo "$GERRIT_REF" | sed -n "s|^refs/changes/[0-9]\\+/\\([0-9]\\+\\)/\\([0-9]\\+\\)$|\\1 \\2|p")
        log "Already in refs/changes format: change=$CHANGE_NUM, patchset=$PATCHSET"
    fi

    # Extract from web-style URLs containing /+/
    if [[ -z "$CHANGE_NUM" ]] && echo "$GERRIT_REF" | grep -q "/+/"; then
        read CHANGE_NUM PATCHSET <<<$(echo "$GERRIT_REF" | sed -n "s|.*/+/\\([0-9]\\+\\)/\\?\\([0-9]*\\).*|\\1 \\2|p")
        log "Extracted from web URL: change=$CHANGE_NUM, patchset=$PATCHSET"
    fi

    # Also support URLs that end with /<change>/<patch> or /<change> (but not refs/changes format)
    if [[ -z "$CHANGE_NUM" ]] && ! echo "$GERRIT_REF" | grep -q "^refs/changes/"; then
        read CHANGE_NUM PATCHSET <<<$(echo "$GERRIT_REF" | sed -n "s|.*/\\([0-9]\\+\\)/\\?\\([0-9]*\\)/*$|\\1 \\2|p")
        log "Extracted from path format: change=$CHANGE_NUM, patchset=$PATCHSET"
    fi

    # If we successfully extracted a change number, build refs/changes/... ref
    if [[ -n "$CHANGE_NUM" ]]; then
        SUFFIX=$(printf "%02d" $((CHANGE_NUM % 100)))
        if [[ -z "$PATCHSET" ]]; then
            PATCHSET=1
        fi
        GERRIT_REF="refs/changes/${SUFFIX}/${CHANGE_NUM}/${PATCHSET}"
        log "Normalized GERRIT_REF to: $GERRIT_REF"
    fi

    # 从环境变量获取 Gerrit URL，默认使用HTTPS协议
    GERRIT_URL="${GERRIT_URL:-https://gerrit.company.example.com/gerrit/a}"
    log "Using Gerrit URL: $GERRIT_URL"
    FULL_GERRIT_URL="$GERRIT_URL/$GERRIT_PROJECT"
    if [[ -n "$GERRIT_PROJECT" ]]; then
        # 构建完整的Git URL
        if [[ "$GERRIT_URL" =~ ^ssh:// ]]; then
            # SSH URL格式: ssh://user@gerrit.company.example.com:29418/project
            log "Using SSH for Gerrit URL"
        else
            # export GERRIT_URL="https://gerrit.company.example.com/gerrit/a"
            # Git会自动使用配置的凭据存储（credential helper）进行认证
            log "Using HTTPS with Git credential helper"
        fi

        log "Fetching from Gerrit: $FULL_GERRIT_URL $GERRIT_REF on repo: $REPO_DIR"

        if ! timeout 30 git -C "$REPO_DIR" fetch --no-progress "$FULL_GERRIT_URL" "$GERRIT_REF"; then
            log "Error: Failed to fetch ref: $GERRIT_REF from $FULL_GERRIT_URL"
            exit 1
        fi

        if ! git -C "$REPO_DIR" reset --hard FETCH_HEAD; then
            log "Error: Failed to reset to FETCH_HEAD after Gerrit fetch"
            exit 1
        fi
        if ! git -C "$REPO_DIR" clean -fd; then
            log "Error: Failed to clean untracked files in repository"
            exit 1
        fi
    else
        # 回退到原来的方法
        log "Warning: GERRIT_PROJECT not provided, using origin"
        if ! timeout 30 git -C "$REPO_DIR" fetch --no-progress origin "$GERRIT_REF"; then
            log "Error: Failed to fetch from origin: $GERRIT_REF"
            exit 1
        fi
        if ! git -C "$REPO_DIR" reset --hard FETCH_HEAD; then
            log "Error: Failed to reset to FETCH_HEAD after origin fetch"
            exit 1
        fi
    fi
elif [[ -n "$COMMIT_ID" && "$COMMIT_ID" =~ ^refs/ ]]; then
    # 如果COMMIT_ID是ref格式，从Gerrit获取特定的ref
    log "Detected Gerrit ref format in COMMIT_ID: $COMMIT_ID"

    # 从环境变量获取 Gerrit URL，默认使用HTTPS协议
    GERRIT_URL="${GERRIT_URL:-https://gerrit.company.example.com/gerrit/a}"
    log "Using Gerrit URL: $GERRIT_URL"

    if [[ -n "$GERRIT_PROJECT" ]]; then
        FULL_GERRIT_URL="$GERRIT_URL/$GERRIT_PROJECT"
        # 构建完整的Git URL
        if [[ "$GERRIT_URL" =~ ^ssh:// ]]; then
            # SSH URL格式: ssh://user@host:port/project
            log "Using SSH for Gerrit URL"
        else
            # HTTPS URL格式: https://host/context/project
            # Git会自动使用配置的凭据存储（credential helper）进行认证
            log "Using HTTPS with Git credential helper"
        fi

        log "Fetching from Gerrit: $FULL_GERRIT_URL $COMMIT_ID on repo: $REPO_DIR"

        if ! timeout 30 git -C "$REPO_DIR" fetch --no-progress "$FULL_GERRIT_URL" "$COMMIT_ID"; then
            log "Error: Failed to fetch ref: $COMMIT_ID from $FULL_GERRIT_URL"
            exit 1
        fi

        if ! git -C "$REPO_DIR" reset --hard FETCH_HEAD; then
            log "Error: Failed to reset to FETCH_HEAD after Gerrit fetch"
            exit 1
        fi
    else
        # 回退到原来的方法
        log "Warning: GERRIT_PROJECT not provided, using origin"
        if ! timeout 30 git -C "$REPO_DIR" fetch --no-progress origin "$COMMIT_ID"; then
            log "Error: Failed to fetch from origin: $COMMIT_ID"
            exit 1
        fi
        if ! git -C "$REPO_DIR" reset --hard FETCH_HEAD; then
            log "Error: Failed to reset to FETCH_HEAD after origin fetch"
            exit 1
        fi
    fi
elif [[ -n "$COMMIT_ID" ]]; then
    # 如果提供了COMMIT_ID但不是ref格式，说明是纯粹的commit id，使用原始方法
    log "Using pure commit ID: $COMMIT_ID"
    if ! timeout 30 git -C "$REPO_DIR" fetch --no-progress origin master; then
        log "Error: Failed to fetch master branch from origin"
        exit 1
    fi
    if ! git -C "$REPO_DIR" reset --hard "$COMMIT_ID"; then
        log "Error: Failed to reset to commit: $COMMIT_ID"
        exit 1
    fi
else
    # 默认情况：获取 master 分支
    if ! timeout 30 git -C "$REPO_DIR" fetch --no-progress origin master; then
        log "Error: Failed to fetch master branch from origin"
        exit 1
    fi
    if ! git -C "$REPO_DIR" reset --hard FETCH_HEAD; then
        log "Error: Failed to reset to FETCH_HEAD after master fetch"
        exit 1
    fi
fi # 获取最新 commit ID

LATEST_COMMIT=$(git -C "$REPO_DIR" rev-parse HEAD)
log "Latest commit ID: $LATEST_COMMIT"

CWDS() {
    pushd "$SCRIPT_DIR"/auto_review_ui >/dev/null || exit 1
}

CWDE() {
    popd >/dev/null || exit 1
}

# 检查提交是否已经被审核
check_commit_reviewed() {
    local repo="$1"
    local commit="$2"
    local changeId="$3"
    local ref="$4"

    CWDS && result=$(yarn --silent ts-node "$CHECK_REVIEW_STATUS_SCRIPT" --repo-name "$repo" --commit-id "$commit" --change-id "$changeId" --ref "$ref" | tail -n 1) && CWDE

    if [[ "$result" == "true" ]]; then
        return 0 # 已审核
    else
        return 1 # 未审核
    fi
}

# 如果提供了 COMMIT_ID，则只处理该 commit，否则按照原逻辑处理
if [[ -n "$COMMIT_ID" ]]; then
    NEW_COMMITS="$COMMIT_ID"
else
    # 查询数据库中的 last commit
    if ! (CWDS && LAST_COMMIT=$(yarn --silent ts-node "$GET_LAST_COMMIT_SCRIPT" "$REPO_NAME" | tail -n 1) && CWDE); then
        log "Error retrieving last commit from DB for repository: $REPO_NAME"
        exit 1
    fi

    log "Last commit ID: $LAST_COMMIT"

    # 如果是首次运行或没有新 commit，直接更新记录并退出
    if [[ "$LAST_COMMIT" == "$LATEST_COMMIT" ]]; then
        log "No new commits to process."
        exit 0
    fi

    if [[ -z "$LAST_COMMIT" ]]; then
        log "First run detected."
        NEW_COMMITS="$LATEST_COMMIT"
    else
        log "Processing commits from $LAST_COMMIT to $LATEST_COMMIT."
        NEW_COMMITS=$(git -C "$REPO_DIR" rev-list --reverse "$LAST_COMMIT"..HEAD)
    fi
fi

# 处理每个 commit
for commit in $NEW_COMMITS; do
    log "Processing commit: $commit"

    # 执行review流程（新记录或强制重新review）
    username=$(git -C ${REPO_DIR} show -s --format=%an $commit)
    email=$(git -C ${REPO_DIR} show -s --format=%ae $commit)
    commitDate=$(git -C ${REPO_DIR} show -s --format=%cI $commit)
    commitMessage=$(git -C ${REPO_DIR} log --pretty=format:%B -n 1 ${commit})

    # 获取 changeId - 首先尝试从 commit message 中提取 Change-Id，如果没有则使用 commitId
    changeId=$(git -C ${REPO_DIR} log --pretty=format:%B -n 1 ${commit} | grep -o "Change-Id: I[a-f0-9]\{40\}" | sed 's/Change-Id: //' || log "")
    if [[ -z "$changeId" ]]; then
        changeId="$commit"
    fi

    log "username: $username"
    log "email: $email"
    log "commitDate: $commitDate"
    log "commitMessage: $commitMessage"
    log "changeId: $changeId"
    log "GERRIT_REF: $GERRIT_REF"

    # 检查是否已经审核过这个提交
    if check_commit_reviewed "$REPO_NAME" "$commit" "$changeId" "$GERRIT_REF"; then
        if [[ "$FORCE" == true ]]; then
            log "Commit $commit in repository $REPO_NAME has already been reviewed but --force option is enabled, forcing re-review..."
            # 强制重新执行review流程
        else
            log "Commit $commit in repository $REPO_NAME has already been reviewed, skipping. Use --force to override."
            continue
        fi
    fi

    # 检查邮箱是否在允许列表中
    NOT_ALLOWED_EMAILS=(
        "bot.account@company.example.com"
        "user.b@company.example.com"
    )

    ALLOWED_EMAILS=(
        "user.c@company.example.com"
        "user.d@company.example.com"
        "user.e@company.example.com"
        "user.f@company.example.com"
        "user.g@company.example.com"
        "user.h@company.example.com"
        "user.i@company.example.com"
        "user.j@company.example.com"
        "user.k@company.example.com"
        "user.l@company.example.com"
        "user.m@company.example.com"
        "user.n@company.example.com"
        "user.o@company.example.com"
        "user.p@company.example.com"
        "user.q@company.example.com"
    )

    # 检查邮箱是否在允许列表中
    email_found=false
    for allowed_email in "${ALLOWED_EMAILS[@]}"; do
        if [[ "$email" == "$allowed_email" ]]; then
            email_found=true
            break
        fi
    done

    # 如果邮箱不在允许列表中，则跳过review
    if [[ "$email_found" == false ]]; then
        log "Skipping review for commit: $commit in repository: $REPO_NAME - email $email is not in allowed list"
        if [[ "$UPDATE_LAST_COMMIT" == true ]]; then
            # 更新last commit记录
            CWDS && yarn ts-node "$UPDATE_LAST_COMMIT_SCRIPT" "$REPO_NAME" "$commit" && CWDE
            if [[ $? -ne 0 ]]; then
                log "Error updating last commit (skipped due to not allowed) to DB for \"$REPO_NAME\" with commit: \"$commit\""
                exit 1
            fi
        fi
        continue # 跳过当前commit，继续处理下一个
    fi

    log "Running review script..."

    # 构建 run_review.sh 的参数
    REVIEW_ARGS=""
    if [[ "$HEADLESS" == true ]]; then
        REVIEW_ARGS="$REVIEW_ARGS --headless"
    fi
    if [[ -n "$EMAIL" ]]; then
        REVIEW_ARGS="$REVIEW_ARGS --email $EMAIL"
    fi
    if [[ -n "$CHANGE_NUM" ]]; then
        REVIEW_ARGS="$REVIEW_ARGS --change-number $CHANGE_NUM"
    fi

    log "Command: bash \"$RUN_REVIEW_SCRIPT\" \"$REPO_NAME\" \"$commit\" $REVIEW_ARGS"
    bash "$RUN_REVIEW_SCRIPT" "$REPO_NAME" "$commit" $REVIEW_ARGS

    # 更新 Skipped (Review Status表)
    review_exit_code=$?
    if [[ $review_exit_code -eq 1 ]]; then
        log "Error running review for \"$REPO_NAME\" with commit: \"$commit\""
        exit 1
    elif [[ $review_exit_code -eq 2 ]]; then
        log "Review script returned exit code 2 for \"$REPO_NAME\" with commit: \"$commit\", updating status to Skipped"
        # 更新review stuatus记录 (包含更多详细信息)
        CWDS && yarn ts-node "$UPDATE_REVIEW_STATUS_SCRIPT" \
            --repo-name "$REPO_NAME" \
            --commit-id "$commit" \
            --status "Skipped" \
            --commit-date "$commitDate" \
            --author-name "$username" \
            --author-email "$email" \
            --commit-message "$commitMessage" \
            --change-id "$changeId" && CWDE

        if [[ $? -ne 0 ]]; then
            log "Error updating review status to Skipped for \"$REPO_NAME\" with commit: \"$commit\""
            exit 1
        fi
        if [[ "$UPDATE_LAST_COMMIT" == true ]]; then
            # 更新last commit记录
            CWDS && yarn ts-node "$UPDATE_LAST_COMMIT_SCRIPT" "$REPO_NAME" "$commit" && CWDE
            if [[ $? -ne 0 ]]; then
                log "Error updating last commit (skipped) to DB for \"$REPO_NAME\" with commit: \"$commit\""
                exit 1
            fi
        fi
        continue
    elif [[ $review_exit_code -ne 0 ]]; then
        log "Unexpected Error running review for \"$REPO_NAME\" with commit: \"$commit\" (exit code: $review_exit_code)"
        exit 1
    fi
    log "GPT review completed for commit: $commit in repository: $REPO_NAME"

    # 更新Review表，Review Status表，并删除相关的Review Feedback
    COMMENT_JSON_FILE="$SCRIPT_DIR/output/${REPO_NAME}-${commit}.comment.json"
    COMMENT_REVIEW_REPORT="$SCRIPT_DIR/output/${REPO_NAME}-${commit}.comment.html"
    if [[ -s "$COMMENT_REVIEW_REPORT" ]]; then
        # 构建公共参数
        COMMON_ARGS=(
            --repo-name "$REPO_NAME"
            --commit-id "$commit"
            --author-name "$username"
            --author-email "$email"
            --commit-message "$commitMessage"
            --commit-date "$commitDate"
            --comments-json "$COMMENT_JSON_FILE"
            --review-report "$COMMENT_REVIEW_REPORT"
            --change-id "$changeId"
            --ref "$GERRIT_REF"
        )

        if [[ "$UPDATE_LAST_COMMIT" == true ]]; then
            COMMON_ARGS+=(--update-last-commit)
        fi

        if ! (CWDS && yarn ts-node "$UPDATE_REVIEW_SCRIPT" "${COMMON_ARGS[@]}" && CWDE); then
            log "Error updating review to DB for \"$REPO_NAME\" with commit: \"$commit\""
            exit 1
        fi
    else
        log "Error generating comments for commit: $commit in repository: $REPO_NAME"
        exit 1
    fi
done

log "All new commits processed."
exit 0
