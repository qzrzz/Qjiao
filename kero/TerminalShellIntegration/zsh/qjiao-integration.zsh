# Semantic-prompt markers for Qjiao's embedded Ghostty terminal.
# `cl=line` and the `B` input-area marker are required for click-to-move.
if [[ -o interactive && -z "${_qjiao_semantic_prompt_loaded-}" ]]; then
    builtin typeset -gi _qjiao_semantic_prompt_loaded=1
    builtin typeset -gi _qjiao_command_active=0

    _qjiao_precmd() {
        builtin local exit_status=$?
        builtin local prompt_start=$'%{\e]133;A;cl=line\a%}'
        builtin local prompt_end=$'%{\e]133;B\a%}'

        if (( _qjiao_command_active )); then
            builtin print -rn -- $'\e]133;D;'"$exit_status"$'\a'
            _qjiao_command_active=0
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
