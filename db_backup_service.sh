#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
WORK_DIR="$SCRIPT_DIR/auto_review_ui"
OUTPUT_DIR="$HOME/rsync"

# 日志函数，输出到终端和日志文件
LOG_FILE="$OUTPUT_DIR/rsync.log"
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# 清空日志文件
>"$LOG_FILE"

# 检查目录权限
if [[ ! -d "$OUTPUT_DIR" || ! -w "$OUTPUT_DIR" ]]; then
    log "Error: Directory $OUTPUT_DIR not found or not writable"
    exit 1
fi

pushd "$WORK_DIR" >/dev/null || exit 1

# 加载环境变量
if [[ -f .env ]]; then
    set -o allexport
    source .env
    set +o allexport
else
    log "Error: .env file not found"
    popd >/dev/null || exit 1
    exit 1
fi

# 检查必要的数据库环境变量
if [[ -z "${PGHOST:-}" || -z "${PGUSER:-}" || -z "${PGDATABASE:-}" ]]; then
    log "Error: Required PostgreSQL environment variables (PGHOST, PGUSER, PGDATABASE) not set in .env"
    popd >/dev/null || exit 1
    exit 1
fi

tmp_file="$OUTPUT_DIR/autoreview.dump.tmp"
if [[ -f "$tmp_file" ]]; then
    log "Removing existing temporary file $tmp_file"
    rm -f "$tmp_file"
fi

trap 'rm -f "$tmp_file"; popd >/dev/null' ERR EXIT SIGINT SIGTERM SIGHUP SIGQUIT SIGABRT

log "Starting database dump..."
pg_dump -F c -b -v -f "$tmp_file" autoreview
dump_file="$OUTPUT_DIR/autoreview_$(date +%Y%m%d_%H%M%S).dump"
mv "$tmp_file" "$dump_file"
log "Database dump completed successfully: $dump_file"

# 删除旧文件（保留最新的15个）
# 使用 find 而非 ls，以安全处理包含特殊字符的文件名
mapfile -t old_files < <(find "$OUTPUT_DIR" -maxdepth 1 -name "autoreview_*.dump" -type f -printf "%T@ %p\n" | sort -n | head -n -15 | cut -d' ' -f2-)
if [[ ${#old_files[@]} -gt 0 ]]; then
    log "Found ${#old_files[@]} old dump files to delete (keeping latest 15)"
    for file in "${old_files[@]}"; do
        if rm -f "$file"; then
            log "Deleted old file: $file"
        else
            log "Warning: Failed to delete old file: $file"
        fi
    done
else
    log "No old files to delete (total files <= 15)"
fi

# 定义远程路径
REMOTE_DIR="/home/h9li/rsync"
REMOTE_HOST="user@<server-ip>"

# 测试 SSH 连接
if ! ssh -q -o ConnectTimeout=5 "$REMOTE_HOST" true; then
    log "Error: Cannot connect to $REMOTE_HOST via SSH"
    exit 1
fi

# 查找最新文件
LATEST_FILE=$(ls -t "$OUTPUT_DIR"/autoreview_*.dump 2>/dev/null | head -n 1)

# 检查文件是否存在
if [[ -z "$LATEST_FILE" || ! -f "$LATEST_FILE" ]]; then
    log "Error: No autoreview_*.dump file found in $OUTPUT_DIR"
    exit 1
fi

# 同步 dump 文件
log "Starting rsync for dump files in $OUTPUT_DIR to $REMOTE_HOST:$REMOTE_DIR"
if rsync -avzP --log-file="$LOG_FILE" "$OUTPUT_DIR/" "$REMOTE_HOST:$REMOTE_DIR"; then
    log "Finished rsync successfully for dump files in $OUTPUT_DIR"
else
    log "Error: rsync failed for dump files in $OUTPUT_DIR, check $LOG_FILE for details"
    exit 1
fi

popd >/dev/null || exit 1
