# Qjiao zsh integration：先加载用户最终 ZDOTDIR 中的 .zshrc。
if [[ "$QJIAO_USER_ZDOTDIR_WAS_SET" == "1" ]]; then
    builtin export ZDOTDIR="$QJIAO_USER_ZDOTDIR"
else
    builtin unset ZDOTDIR
fi

builtin typeset _qjiao_user_zshrc="${QJIAO_USER_ZDOTDIR:-$HOME}/.zshrc"
if [[ -r "$_qjiao_user_zshrc" ]]; then
    builtin source "$_qjiao_user_zshrc"
fi
builtin unset _qjiao_user_zshrc

# 必须在用户主题和插件之后安装 OSC 133 hooks，避免 precmd_functions 被覆盖。
if [[ -o interactive && -r "$QJIAO_ZSH_INTEGRATION_DIR/qjiao-integration.zsh" ]]; then
    builtin source "$QJIAO_ZSH_INTEGRATION_DIR/qjiao-integration.zsh"
fi

# 用户的 .zshrc 可能再次调整 ZDOTDIR；保留该结果供后续 .zlogin 及子 Shell 使用。
if [[ -n "${ZDOTDIR+x}" ]]; then
    builtin export QJIAO_USER_ZDOTDIR_WAS_SET=1
    builtin export QJIAO_USER_ZDOTDIR="$ZDOTDIR"
else
    builtin export QJIAO_USER_ZDOTDIR_WAS_SET=0
    builtin export QJIAO_USER_ZDOTDIR="$HOME"
fi
if [[ "$QJIAO_USER_ZDOTDIR_WAS_SET" == "1" ]]; then
    builtin export ZDOTDIR="$QJIAO_USER_ZDOTDIR"
else
    builtin unset ZDOTDIR
fi
