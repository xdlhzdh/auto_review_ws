_update_last_commit_completions() {
    local cur prev repos commits
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    
    REPO_DIR="$HOME/auto_review_ws/repos"
    
    if [[ $COMP_CWORD -eq 1 ]]; then
        repos=$(ls "$REPO_DIR")
        COMPREPLY=( $(compgen -W "$repos" -- "$cur") )
    elif [[ $COMP_CWORD -eq 2 ]]; then
        repo_path="$REPO_DIR/$prev"
        if [[ -d "$repo_path/.git" ]]; then
            mapfile -t commits < <(git -C "$repo_path" log --pretty=format:"%H" -n 20)
            COMPREPLY=()
            for commit in "${commits[@]}"; do
                if [[ $commit == "$cur"* ]]; then
                    COMPREPLY+=("$commit")
                fi
            done
            if [[ "--delete" == "$cur"* ]]; then
                COMPREPLY+=("--delete")
            fi
            # 防止自动按字母排序
            compopt -o nosort
        else
            COMPREPLY=()
        fi
    else
        COMPREPLY=()
    fi
}

# 绑定到 `run_review.sh`
complete -F _update_last_commit_completions update_last_commit.sh
