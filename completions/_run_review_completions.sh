_run_review_completions() {
    local cur prev repos commits
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    
    REPO_DIR="$HOME/auto_review_ws/repos"
    
    if [[ $COMP_CWORD -eq 1 ]]; then
        repos=$(ls "$REPO_DIR")
        COMPREPLY=( $(compgen -W "$repos" -- "$cur") )
    fi
}

# 绑定到 `run_review.sh`
complete -F _run_review_completions run_review.sh
