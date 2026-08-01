# Semantic-prompt markers and idle title integration for Qjiao's embedded Ghostty terminal.
# `cl=line` and the `B` input-area marker are required for click-to-move.
if [[ -o interactive && -z "${_qjiao_semantic_prompt_loaded-}" ]]; then
    builtin typeset -gi _qjiao_semantic_prompt_loaded=1
    builtin typeset -gi _qjiao_command_active=0
    builtin typeset -gi _qjiao_prompt_ready_emitted=0

    _qjiao_get_idle_title_pattern() {
        builtin local config_file="${QJIAO_CONFIG_DIR:-$HOME/.config/qjiao}/idle_title"
        if [[ -r "$config_file" ]]; then
            # cat 不是 zsh 内建命令；用 command 绕过用户别名/函数，执行真正的 cat。
            command cat "$config_file" 2>/dev/null
        else
            builtin print -rn -- "${ZSH_THEME_TERM_TITLE_IDLE-}"
        fi
    }

    _qjiao_precmd() {
        builtin local exit_status=$?
        builtin local prompt_start=$'%{\e]133;A;cl=line\a%}'
        builtin local prompt_end=$'%{\e]133;B\a%}'

        # 首个提示符就绪标记：宿主应用据此得知登录 shell 已可安全接收命令，
        # 避免在 shell 初始化期间注入的命令被回显但不执行。
        if (( ! _qjiao_prompt_ready_emitted )); then
            builtin print -rn -- $'\e]2;qjiao-prompt-ready\a'
            _qjiao_prompt_ready_emitted=1
        fi

        if (( _qjiao_command_active )); then
            builtin print -rn -- $'\e]133;D;'"$exit_status"$'\a'
            _qjiao_command_active=0
        fi

        builtin local pattern
        pattern=$(_qjiao_get_idle_title_pattern)
        if [[ -n "$pattern" ]]; then
            builtin print -Pn -- $'\e]2;'"$pattern"$'\a'
        fi

        # Rebuild from an unmarked prompt each time, so asynchronous prompt
        # themes do not accumulate semantic markers across commands.
        PS1=${PS1//$prompt_start}
        PS1=${PS1//$prompt_end}
        PS1="${prompt_start}${PS1}${prompt_end}"
    }

    _qjiao_preexec() {
        builtin local prompt_start=$'%{\e]133;A;cl=line\a%}'
        builtin local prompt_end=$'%{\e]133;B\a%}'
        PS1=${PS1//$prompt_start}
        PS1=${PS1//$prompt_end}
        builtin print -rn -- $'\e]133;C\a'
        _qjiao_command_active=1
    }

    _qjiao_install_semantic_prompt() {
        builtin typeset -ag precmd_functions preexec_functions
        precmd_functions=(
            ${precmd_functions:#_qjiao_install_semantic_prompt}
            ${precmd_functions:#_qjiao_precmd}
            _qjiao_precmd
        )
        preexec_functions=(
            ${preexec_functions:#_qjiao_preexec}
            _qjiao_preexec
        )
        _qjiao_precmd
        builtin unfunction _qjiao_install_semantic_prompt
    }

    builtin typeset -ag precmd_functions
    precmd_functions+=(_qjiao_install_semantic_prompt)
fi
