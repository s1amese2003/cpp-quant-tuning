#!/usr/bin/env bash
#
# 把 cpp-quant-tuning skills 安装到各 agent 工具。
#
#   ./tools/install.sh codex            # Codex CLI  (~/.codex)
#   ./tools/install.sh cursor           # Cursor / Windsurf / Cline (当前项目)
#   ./tools/install.sh claude-user      # Claude Code 用户级 skills (~/.claude/skills)
#   ./tools/install.sh generic <DIR>    # 拷贝 skills/ 到任意目录
#
# Claude Code 的推荐安装方式是 marketplace，不需要本脚本，见 README。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-}"

die()  { echo "错误: $*" >&2; exit 1; }
info() { echo "  -> $*"; }

copy_skills() {
    local dest="$1"
    mkdir -p "$dest"
    for d in "$REPO_ROOT"/skills/*/; do
        local name
        name="$(basename "$d")"
        rm -rf "${dest:?}/$name"
        cp -r "$d" "$dest/$name"
        info "skills/$name -> $dest/$name"
    done
}

case "$TARGET" in
  codex)
    CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
    echo "安装到 Codex: $CODEX_HOME"

    # 1) skills（Codex 新版支持 $CODEX_HOME/skills；旧版忽略该目录，不影响其他功能）
    copy_skills "$CODEX_HOME/skills"

    # 2) commands -> prompts（在 Codex 中以 /quant-xxx 调用）
    mkdir -p "$CODEX_HOME/prompts"
    for f in "$REPO_ROOT"/commands/*.md; do
        cp "$f" "$CODEX_HOME/prompts/$(basename "$f")"
        info "commands/$(basename "$f") -> $CODEX_HOME/prompts/"
    done

    # 3) 全局 AGENTS.md 追加引用（这是所有 Codex 版本都生效的路径）
    GLOBAL_AGENTS="$CODEX_HOME/AGENTS.md"
    MARK="<!-- cpp-quant-tuning -->"
    if [ -f "$GLOBAL_AGENTS" ] && grep -qF "$MARK" "$GLOBAL_AGENTS"; then
        info "已存在引用，跳过 $GLOBAL_AGENTS"
    else
        {
            echo ""
            echo "$MARK"
            echo "## 量化开发 skills"
            echo ""
            echo "处理量化交易 / 低延迟 / 行情 / 订单 / 策略相关任务时，先读："
            echo "\`$CODEX_HOME/skills/quant-dev-playbook/SKILL.md\`，再按其路由表加载对应 skill。"
            echo "完整说明见 $REPO_ROOT/AGENTS.md"
        } >> "$GLOBAL_AGENTS"
        info "已追加引用到 $GLOBAL_AGENTS"
    fi

    echo
    echo "完成。在 Codex 中试试： /quant-review  或直接提问「优化这个订单簿的热路径」"
    ;;

  cursor)
    echo "安装到当前项目（Cursor / Windsurf / Cline 等读取 AGENTS.md 的工具）"
    echo
    echo "本仓库的 AGENTS.md 已经是完整入口。在你的项目里执行其一："
    echo
    echo "  # A. 作为 git submodule（推荐，便于更新）"
    echo "  git submodule add <本仓库地址> .agent/cpp-quant-tuning"
    echo "  # 然后在你项目的 AGENTS.md / .cursorrules 里加一行："
    echo "  #   量化任务先读 .agent/cpp-quant-tuning/skills/quant-dev-playbook/SKILL.md"
    echo
    echo "  # B. 直接拷贝"
    echo "  ./tools/install.sh generic /path/to/your/project/.agent/skills"
    ;;

  claude-user)
    DEST="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills"
    echo "安装到 Claude Code 用户级 skills: $DEST"
    echo "（推荐改用 marketplace 安装，见 README；本方式不含 commands 与 agents）"
    copy_skills "$DEST"
    ;;

  generic)
    DEST="${2:-}"
    [ -n "$DEST" ] || die "用法: $0 generic <目标目录>"
    echo "拷贝 skills 到: $DEST"
    copy_skills "$DEST"
    ;;

  *)
    sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
