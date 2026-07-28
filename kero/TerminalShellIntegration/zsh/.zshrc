# Qjiao zsh integration: source user's original .zshrc first.
builtin typeset _qjiao_user_zshrc="${QJIAO_ORIGINAL_ZDOTDIR:-$HOME}/.zshrc"
if [[ -r "$_qjiao_user_zshrc" ]]; then
    builtin source "$_qjiao_user_zshrc"
fi
builtin unset _qjiao_user_zshrc

# Source Qjiao integration AFTER user's .zshrc
if [[ -o interactive && -r "$QJIAO_ZSH_INTEGRATION_DIR/qjiao-integration.zsh" ]]; then
    builtin source "$QJIAO_ZSH_INTEGRATION_DIR/qjiao-integration.zsh"
fi
