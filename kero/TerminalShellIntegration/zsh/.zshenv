# Qjiao's zsh bootstrap. Restore the user's normal startup location before
# zsh reads its remaining login and interactive startup files.
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

if [[ -o interactive && -r "$QJIAO_ZSH_INTEGRATION_DIR/qjiao-integration.zsh" ]]; then
    builtin source "$QJIAO_ZSH_INTEGRATION_DIR/qjiao-integration.zsh"
fi
