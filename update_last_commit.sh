#!/bin/bash

# 确保脚本出错时退出
set -e

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
UPDATE_LAST_COMMIT_SCRIPT="$SCRIPT_DIR/auto_review_ui/update_last_commit.mjs"

CWDS() {
    pushd $SCRIPT_DIR/auto_review_ui >/dev/null || exit 1
}

CWDE() {
    popd >/dev/null || exit 1
}

if [[ $# -eq 0 ]]; then
    # No parameters provided, output confirmation dialog
    declare -A DEFAULTS=(
        ["dat"]="c0392a96d4fd2ac466b6836ecc37a9e2384492a4"
        ["asm"]="9020355750e4b39df5e0b0471a86c348823e2da6"
        ["usermanagement"]="0f1f59a86fc8931591773f9c0b88435a7ca463d1"
    )

    echo "No parameters provided. Please confirm whether the last commit should be updated with the following:"
    i=1
    for REPO in "${!DEFAULTS[@]}"; do
        COMMIT_ID="${DEFAULTS[$REPO]}"
        printf "  %d | %-14s | %s\n" "$i" "$REPO" "$COMMIT_ID"
        ((i++))
    done

    read -p "Are you sure you want to continue? (yes/NO): " confirm1
    if [[ "$confirm1" != "yes" ]]; then
        echo "❌ Execution cancelled."
        exit 1
    fi

    # Iterate over all default values and run the script
    for REPO in "${!DEFAULTS[@]}"; do
        COMMIT_ID="${DEFAULTS[$REPO]}"
        echo "Updating $REPO to commit $COMMIT_ID..."
        CWDS && yarn ts-node "$UPDATE_LAST_COMMIT_SCRIPT" "$REPO" "$COMMIT_ID" && CWDE
        if [[ $? -ne 0 ]]; then
            echo "❌ Failed to update $REPO to commit $COMMIT_ID."
            exit 1
        else
            echo "✅ Successfully updated $REPO to commit $COMMIT_ID."
        fi
    done
    exit 0

# 检查参数
elif [[ $# -ne 2 ]]; then
    echo "Usage: $0 <REPO_NAME> <COMMIT_ID>|--delete"
    exit 1

else
    REPO_NAME="$1"
    ACTION="$2"

    if [[ "$ACTION" == "--delete" ]]; then
        CWDS && yarn ts-node "$UPDATE_LAST_COMMIT_SCRIPT" "$REPO_NAME" --delete && CWDE
        exit $?
    fi

    COMMIT_ID="$ACTION"
    CWDS && yarn ts-node "$UPDATE_LAST_COMMIT_SCRIPT" "$REPO_NAME" "$COMMIT_ID" && CWDE
    exit $?
fi
