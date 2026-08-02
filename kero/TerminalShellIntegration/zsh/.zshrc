# Qjiao zsh integration：加载用户 .zshrc，再安装 Qjiao OSC / pending 等 hooks。
#
# 重要（ghost-complete 等 PTY proxy 兼容）：
# 用户 ~/.zshrc 顶部的 `ghost-complete install` 块会在加载中途 `exec ghost-complete`，
# 再由 proxy 拉起内层 shell。内层进程继承当时的环境变量。
# 若此处把 ZDOTDIR 切成用户目录后再 source 用户 rc，exec 发生时 ZDOTDIR 已是用户目录，
# 内层 shell 将完全跳过 Qjiao 的 bootstrap（无 click-to-move、无 prompt-ready、无 pending 命令）。
#
# 因此在 source 用户 rc 期间保持 ZDOTDIR=$QJIAO_ZSH_INTEGRATION_DIR，并用绝对路径
# 读取用户 rc。用户逻辑上的 ZDOTDIR 始终在 $QJIAO_USER_ZDOTDIR（见 .zshenv / .zprofile）。

builtin typeset _qjiao_user_zshrc="${QJIAO_USER_ZDOTDIR:-$HOME}/.zshrc"
if [[ -r "$_qjiao_user_zshrc" ]]; then
    # 保持 ZDOTDIR 指向 integration，便于 mid-rc 的 PTY proxy re-exec 仍进入本 bootstrap。
    if [[ -n "${QJIAO_ZSH_INTEGRATION_DIR-}" ]]; then
        builtin export ZDOTDIR="$QJIAO_ZSH_INTEGRATION_DIR"
    fi
    builtin source "$_qjiao_user_zshrc"
fi
builtin unset _qjiao_user_zshrc

# 必须在用户主题和插件之后安装 OSC 133 hooks，避免 precmd_functions 被覆盖。
if [[ -o interactive && -r "$QJIAO_ZSH_INTEGRATION_DIR/qjiao-integration.zsh" ]]; then
    builtin source "$QJIAO_ZSH_INTEGRATION_DIR/qjiao-integration.zsh"
fi

# 用户 .zshrc 可能改写 ZDOTDIR：仅当结果不是 integration 目录时，才视为用户意图。
if [[ -n "${ZDOTDIR+x}" && -n "${QJIAO_ZSH_INTEGRATION_DIR-}" && "$ZDOTDIR" != "$QJIAO_ZSH_INTEGRATION_DIR" ]]; then
    builtin export QJIAO_USER_ZDOTDIR_WAS_SET=1
    builtin export QJIAO_USER_ZDOTDIR="$ZDOTDIR"
fi
# 恢复用户逻辑 ZDOTDIR，供后续 .zlogin 与用户手动起的子 shell 使用。
if [[ "$QJIAO_USER_ZDOTDIR_WAS_SET" == "1" ]]; then
    builtin export ZDOTDIR="$QJIAO_USER_ZDOTDIR"
else
    builtin unset ZDOTDIR
fi
