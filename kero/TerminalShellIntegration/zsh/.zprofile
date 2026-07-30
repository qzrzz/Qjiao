# Qjiao 在 bundled ZDOTDIR 中转发用户的登录 Shell 配置，并保持原生启动顺序。
if [[ "$QJIAO_USER_ZDOTDIR_WAS_SET" == "1" ]]; then
    builtin export ZDOTDIR="$QJIAO_USER_ZDOTDIR"
else
    builtin unset ZDOTDIR
fi

builtin typeset _qjiao_user_zprofile="${QJIAO_USER_ZDOTDIR:-$HOME}/.zprofile"
if [[ -r "$_qjiao_user_zprofile" ]]; then
    builtin source "$_qjiao_user_zprofile"
fi
builtin unset _qjiao_user_zprofile

# 用户的 .zprofile 也可能改变 ZDOTDIR；保存后继续从 bundled 目录加载 .zshrc。
if [[ -n "${ZDOTDIR+x}" ]]; then
    builtin export QJIAO_USER_ZDOTDIR_WAS_SET=1
    builtin export QJIAO_USER_ZDOTDIR="$ZDOTDIR"
else
    builtin export QJIAO_USER_ZDOTDIR_WAS_SET=0
    builtin export QJIAO_USER_ZDOTDIR="$HOME"
fi
builtin export ZDOTDIR="$QJIAO_ZSH_INTEGRATION_DIR"
