_run_review_and_update_db_completions() {
    local cur prev repos commits options
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD - 1]}"

    REPO_DIR="$HOME/auto_review_ws/repos"

    # 可用的选项参数
    options="--headless --force --update-last-commit --email"

    if [[ $COMP_CWORD -eq 1 ]]; then
        # 第一个参数：repo名称
        repos=$(ls "$REPO_DIR" 2>/dev/null)
        COMPREPLY=($(compgen -W "$repos" -- "$cur"))
    elif [[ $COMP_CWORD -eq 2 ]]; then
        # 第二个参数：commit ID 或选项
        repo_name="${COMP_WORDS[1]}"
        repo_path="$REPO_DIR/$repo_name"

        if [[ "$cur" == --* ]]; then
            # 如果输入的是选项
            COMPREPLY=($(compgen -W "$options" -- "$cur"))
        elif [[ -d "$repo_path/.git" ]]; then
            # 如果是有效的git仓库，提供commit ID补全
            mapfile -t commits < <(git -C "$repo_path" log --pretty=format:"%H" -n 20 2>/dev/null)
            # 同时提供选项
            local all_options=("${commits[@]}" "--headless" "--force" "--update-last-commit" "--email")
            COMPREPLY=()
            for option in "${all_options[@]}"; do
                if [[ $option == "$cur"* ]]; then
                    COMPREPLY+=("$option")
                fi
            done
            # 防止自动按字母排序
            compopt -o nosort 2>/dev/null || true
        else
            # 如果不是有效仓库，只提供选项
            COMPREPLY=($(compgen -W "$options" -- "$cur"))
        fi
    else
        # 第三个参数及以后：只提供选项或选项值
        if [[ "$prev" == "--email" ]]; then
            # 如果前一个参数是--email，提供邮箱地址补全
            # 可以从环境变量或常用邮箱域名提供建议
            local email_suggestions=""
            if [[ -n "$USER" ]]; then
                email_suggestions="$USER@company.example.com $USER@example.com"
            fi
            COMPREPLY=($(compgen -W "$email_suggestions" -- "$cur"))
        elif [[ "$cur" == --* ]]; then
            # 检查已使用的选项，避免重复
            local used_options=""
            for ((i = 2; i < COMP_CWORD; i++)); do
                if [[ "${COMP_WORDS[i]}" == --* ]]; then
                    used_options="$used_options ${COMP_WORDS[i]}"
                fi
            done

            # 过滤掉已使用的选项
            local available_options=""
            for opt in $options; do
                if [[ ! "$used_options" =~ $opt ]]; then
                    available_options="$available_options $opt"
                fi
            done

            COMPREPLY=($(compgen -W "$available_options" -- "$cur"))
        else
            COMPREPLY=()
        fi
    fi
}

# 绑定到 `run_review_and_update_db.sh`
complete -F _run_review_and_update_db_completions run_review_and_update_db.sh
