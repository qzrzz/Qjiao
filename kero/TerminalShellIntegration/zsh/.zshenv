# Qjiao 的 zsh bootstrap：先加载用户原有的 .zshenv，再暂时保留 bundled
# ZDOTDIR，让后续 .zprofile / .zshrc 能继续经过 Qjiao 的转发脚本。
if [[ "$QJIAO_ZDOTDIR_WAS_SET" == "1" ]]; then
    builtin export ZDOTDIR="$QJIAO_ORIGINAL_ZDOTDIR"
else
    builtin unset ZDOTDIR
fi

builtin typeset _qjiao_user_zshenv="${ZDOTDIR:-$HOME}/.zshenv"
if [[ -r "$_qjiao_user_zshenv" ]]; then
    builtin source "$_qjiao_user_zshenv"
fi
builtin unset _qjiao_user_zshenv

# 用户的 .zshenv 可能重新指定 ZDOTDIR；保存最终值，供剩余启动文件使用。
if [[ -n "${ZDOTDIR+x}" ]]; then
    builtin export QJIAO_USER_ZDOTDIR_WAS_SET=1
    builtin export QJIAO_USER_ZDOTDIR="$ZDOTDIR"
else
    builtin export QJIAO_USER_ZDOTDIR_WAS_SET=0
    builtin export QJIAO_USER_ZDOTDIR="$HOME"
fi
builtin export ZDOTDIR="$QJIAO_ZSH_INTEGRATION_DIR"
