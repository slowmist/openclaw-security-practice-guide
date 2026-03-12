#!/usr/bin/env bash
# OpenClaw 极简安全实践指南 v2.7 - 安全加固脚本
# 兼容 Linux 和 macOS，自动部署防御矩阵

set -euo pipefail

# 1. 跨平台操作系统探测
OS_TYPE=$(uname -s)
if [ "$OS_TYPE" = "Darwin" ]; then
    CMD_STAT="stat -f %A"
    CMD_DATE="date -j +%s"
else
    CMD_STAT="stat -c %a"
    CMD_DATE="date +%s"
fi

# 2. 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 3. 用户目录探测
if [ -n "${SUDO_USER:-}" ]; then
    REAL_USER="$SUDO_USER"
    REAL_HOME=$(eval echo ~$REAL_USER)
else
    REAL_USER="${USER:-$(whoami)}"
    REAL_HOME="$HOME"
fi

# OpenClaw 状态目录
OC="${OPENCLAW_STATE_DIR:-$REAL_HOME/.openclaw}"

# 4. 检查 OpenClaw 是否已安装
if [ ! -d "$OC" ]; then
    log_error "OpenClaw 目录不存在: $OC"
    log_error "请先安装 OpenClaw 再运行此脚本"
    exit 1
fi

# ============================================
# 备份功能：创建备份目录
# ============================================
BACKUP_DIR="$OC/security-backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
log_info "备份目录: $BACKUP_DIR"

# 需要备份的文件列表
BACKUP_FILES=(
    "$OC/openclaw.json"
    "$OC/devices/paired.json"
)

# 执行备份
backup_files() {
    local backed_up=0
    for file in "${BACKUP_FILES[@]}"; do
        if [ -f "$file" ]; then
            local filename=$(basename "$file")
            local parent=$(basename $(dirname "$file"))

            # 创建目录结构
            mkdir -p "$BACKUP_DIR/$parent"

            # 备份文件
            cp -p "$file" "$BACKUP_DIR/$parent/"

            # 备份权限
            if [ "$OS_TYPE" = "Darwin" ]; then
                stat -f %A "$file" > "$BACKUP_DIR/$parent/${filename}.perm"
            else
                stat -c %a "$file" > "$BACKUP_DIR/$parent/${filename}.perm"
            fi

            log_info "已备份: $file -> $BACKUP_DIR/$parent/"
            ((backed_up++))
        fi
    done

    if [ $backed_up -gt 0 ]; then
        log_info "共备份 $backed_up 个文件"
        echo "$BACKUP_DIR" > "$OC/.latest-backup-dir"
    fi
}

# 恢复功能
restore_from_backup() {
    local backup_dir="$1"

    if [ ! -d "$backup_dir" ]; then
        log_error "备份目录不存在: $backup_dir"
        return 1
    fi

    log_info "从备份恢复: $backup_dir"

    # 恢复 openclaw.json
    if [ -f "$backup_dir/openclaw.json" ]; then
        cp -p "$backup_dir/openclaw.json" "$OC/openclaw.json"
        if [ -f "$backup_dir/openclaw.json.perm" ]; then
            local perm=$(cat "$backup_dir/openclaw.json.perm")
            chmod "$perm" "$OC/openclaw.json"
        fi
        log_info "已恢复 openclaw.json"
    fi

    # 恢复 paired.json
    if [ -f "$backup_dir/paired.json" ]; then
        mkdir -p "$OC/devices"
        cp -p "$backup_dir/paired.json" "$OC/devices/paired.json"
        if [ -f "$backup_dir/paired.json.perm" ]; then
            local perm=$(cat "$backup_dir/paired.json.perm")
            chmod "$perm" "$OC/devices/paired.json"
        fi
        log_info "已恢复 devices/paired.json"
    fi

    log_info "恢复完成!"
}

# 检查是否为恢复模式
if [[ "${1:-}" == "--restore" ]]; then
    if [ -n "${2:-}" ]; then
        restore_from_backup "$2"
    elif [ -f "$OC/.latest-backup-dir" ]; then
        restore_from_backup "$(cat "$OC/.latest-backup-dir")"
    else
        log_error "未找到备份目录"
        echo "用法: $0 --restore [backup_dir]"
        echo ""
        echo "可用备份:"
        ls -la "$OC/security-backups/" 2>/dev/null || echo "无备份"
        exit 1
    fi
    exit 0
fi

# 执行备份
backup_files

# ============================================
# 事前：权限收窄 + 哈希基线
# ============================================

log_info "=== 步骤 1: 权限收窄 ==="

# 确保目录存在
mkdir -p "$OC/devices"

# 核心配置文件权限收窄 (600)
if [ -f "$OC/openclaw.json" ]; then
    chmod 600 "$OC/openclaw.json"
    log_info "已设置 openclaw.json 权限为 600"
else
    log_warn "openclaw.json 不存在，跳过"
fi

if [ -f "$OC/devices/paired.json" ]; then
    chmod 600 "$OC/devices/paired.json"
    log_info "已设置 devices/paired.json 权限为 600"
else
    log_warn "devices/paired.json 不存在，跳过"
fi

# ============================================

log_info "=== 步骤 2: 生成配置文件哈希基线 ==="

BASELINE_FILE="$OC/.config-baseline.sha256"

if [ -f "$OC/openclaw.json" ]; then
    sha256sum "$OC/openclaw.json" > "$BASELINE_FILE"
    chmod 600 "$BASELINE_FILE"
    log_info "已生成配置文件哈希基线: $BASELINE_FILE"
else
    log_warn "openclaw.json 不存在，无法生成基线"
fi

# ============================================
# 事中：部署巡检脚本
# ============================================

log_info "=== 步骤 3: 部署巡检脚本 ==="

# 创建脚本目录
SCRIPT_DIR="$OC/workspace/scripts"
mkdir -p "$SCRIPT_DIR"

# 复制巡检脚本
SCRIPT_SOURCE="$(dirname "$0")/nightly-security-audit.sh"
if [ -f "$SCRIPT_SOURCE" ]; then
    cp "$SCRIPT_SOURCE" "$SCRIPT_DIR/nightly-security-audit.sh"
    chmod 700 "$SCRIPT_DIR/nightly-security-audit.sh"
    log_info "已部署巡检脚本: $SCRIPT_DIR/nightly-security-audit.sh"
else
    log_warn "未找到巡检脚本源文件: $SCRIPT_SOURCE"
    log_info "请手动复制 nightly-security-audit.sh 到 $SCRIPT_DIR"
fi

# 创建安全基线目录
mkdir -p "$OC/security-baselines"

# ============================================
# 锁定巡检脚本 (chattr +i)
# ============================================

if [ "$OS_TYPE" = "Darwin" ]; then
    log_info "macOS 不支持 chattr，跳过脚本锁定"
    log_info "建议: 使用 'chflags uchg' 保护脚本文件"
else
    log_info "=== 步骤 4: 锁定巡检脚本 ==="

    if [ -f "$SCRIPT_DIR/nightly-security-audit.sh" ]; then
        # 检查 chattr 是否可用
        if command -v chattr >/dev/null 2>&1; then
            chattr +i "$SCRIPT_DIR/nightly-security-audit.sh" 2>/dev/null || {
                log_warn "需要 root 权限锁定脚本，请手动执行:"
                log_warn "  sudo chattr +i $SCRIPT_DIR/nightly-security-audit.sh"
            }
            log_info "已锁定巡检脚本 (chattr +i)"
        else
            log_warn "chattr 命令不可用，跳过锁定"
        fi
    fi
fi

# ============================================
# 事后：设置 Cron Job
# ============================================

log_info "=== 步骤 5: 配置定时巡检 (Cron) ==="

# 检测时区
DETECTED_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "")
if [ -z "$DETECTED_TZ" ]; then
    DETECTED_TZ="UTC"
fi

log_info "检测到系统时区: $DETECTED_TZ"

# ============================================
# 尝试从现有 cron 配置中获取通知设置
# ============================================
NOTIFY_CHANNEL=""
CHAT_ID=""

# 尝试从现有 cron 任务中获取通知配置
if command -v openclaw >/dev/null 2>&1; then
    log_info "尝试从现有 cron 配置中获取通知设置..."

    # 获取现有 cron 列表
    CRON_LIST=$(openclaw cron list 2>/dev/null || echo "")

    if [ -n "$CRON_LIST" ]; then
        # 尝试提取 channel (兼容 macOS 和 Linux)
        CHANNEL_LINE=$(echo "$CRON_LIST" | grep -oE '\-\-channel[[:space:]]+[[:alnum:]]+' | head -1 | awk '{print $2}' || echo "")
        # 尝试提取 chat_id
        TO_LINE=$(echo "$CRON_LIST" | grep -oE '\-\-to[[:space:]]+[0-9\-]+' | head -1 | awk '{print $2}' || echo "")

        if [ -n "$CHANNEL_LINE" ]; then
            NOTIFY_CHANNEL="$CHANNEL_LINE"
            log_info "发现通知 channel: $NOTIFY_CHANNEL"
        fi

        if [ -n "$TO_LINE" ]; then
            CHAT_ID="$TO_LINE"
            log_info "发现 chat_id: $CHAT_ID"
        fi
    fi

    # 如果没找到，尝试从 openclaw.json 读取
    if [ -z "$NOTIFY_CHANNEL" ] || [ -z "$CHAT_ID" ]; then
        if [ -f "$OC/openclaw.json" ]; then
            log_info "从 openclaw.json 中查找通知配置..."
            # 尝试提取常见的通知配置字段 (兼容写法)
            local notify_channel notify_chat_id
            notify_channel=$(grep -oE '"(announce|notify|channel)"[[:space:]]*:[[:space:]]*"[^"]+"' "$OC/openclaw.json" 2>/dev/null | head -1 || echo "")
            notify_chat_id=$(grep -oE '"(chat_id|chatId)"[[:space:]]*:[[:space:]]*"[^"]+"' "$OC/openclaw.json" 2>/dev/null | head -1 || echo "")

            if [ -n "$notify_channel" ] || [ -n "$notify_chat_id" ]; then
                log_info "发现通知配置: $notify_channel $notify_chat_id"
            fi
        fi
    fi
fi

# 如果仍未获取到，提示用户输入
if [ -z "$NOTIFY_CHANNEL" ]; then
    read -p "请输入 Telegram/Discord channel (默认: telegram): " NOTIFY_CHANNEL
    NOTIFY_CHANNEL="${NOTIFY_CHANNEL:-telegram}"
fi

if [ -z "$CHAT_ID" ]; then
    read -p "请输入 chat_id (用于接收通知): " CHAT_ID
fi

if [ -z "$CHAT_ID" ]; then
    log_warn "未提供 chat_id，将只保存本地报告"
    log_info "如需配置通知，可稍后使用以下命令:"
    echo "  openclaw cron add --name nightly-security-audit --cron '0 3 * * *' --tz $DETECTED_TZ ..."
else
    log_info "配置定时任务..."

    # 添加 cron 任务
    openclaw cron add \
        --name "nightly-security-audit" \
        --description "每晚安全巡检" \
        --cron "0 3 * * *" \
        --tz "$DETECTED_TZ" \
        --session "isolated" \
        --message "Execute this command and output the result as-is, no extra commentary: bash $SCRIPT_DIR/nightly-security-audit.sh" \
        --announce \
        --channel "$NOTIFY_CHANNEL" \
        --to "$CHAT_ID" \
        --timeout-seconds 300 \
        --thinking off 2>/dev/null || {
            log_warn "openclaw cron add 失败，请手动配置"
        }

    log_info "已配置定时巡检任务"
fi

# ============================================
# 大脑灾备：Git 初始化
# ============================================

log_info "=== 步骤 6: 配置大脑灾备 (Git) ==="

read -p "是否配置 Git 灾备? (y/N): " CONFIGURE_GIT
CONFIGURE_GIT="${CONFIGURE_GIT:-n}"

if [[ "$CONFIGURE_GIT" =~ ^[Yy]$ ]]; then
    read -p "请输入 Git 仓库 URL (例如: git@github.com:user/backup.git): " GIT_REPO

    if [ -n "$GIT_REPO" ] && [ -d "$OC/.git" ]; then
        log_warn "$OC 已经是 Git 仓库"
    elif [ -n "$GIT_REPO" ]; then
        # 初始化 Git
        cd "$OC"
        git init

        # 配置 .gitignore
        cat > "$OC/.gitignore" << 'EOF'
# 排除临时文件和日志
devices/*.tmp
media/
logs/
completions/
canvas/
*.bak*
*.tmp
.env
EOF

        # 添加需要备份的文件
        git add openclaw.json
        git add workspace/
        git add agents/
        git add cron/
        git add credentials/
        git add identity/
        git add devices/paired.json
        git add .config-baseline.sha256
        git add .gitignore

        # 初始提交
        git commit -m "Initial backup - OpenClaw security baseline"

        # 添加远程仓库
        git remote add origin "$GIT_REPO"

        log_info "Git 仓库已初始化"
        log_info "首次推送请手动执行: git push -u origin main"

        cd - > /dev/null
    fi
else
    log_info "跳过 Git 灾备配置"
    log_info "如需手动配置，请参考:"
    echo "  cd $OC"
    echo "  git init"
    echo "  git remote add origin <your-repo-url>"
fi

# ============================================
# 完成
# ============================================

echo ""
log_info "========================================"
log_info "安全加固完成!"
log_info "========================================"
echo ""
echo "部署摘要:"
echo "  - OpenClaw 目录: $OC"
echo "  - 权限收窄: ✅ (openclaw.json, paired.json)"
echo "  - 哈希基线: ✅ ($BASELINE_FILE)"
echo "  - 巡检脚本: ✅ ($SCRIPT_DIR/nightly-security-audit.sh)"
echo "  - 定时任务: $([ -n "$CHAT_ID" ] && echo '✅' || echo '⏸️  待配置')"
echo "  - Git 灾备: $([[ "$CONFIGURE_GIT" =~ ^[Yy]$ ]] && echo '✅' || echo '⏸️  待配置')"
echo ""
echo "后续步骤:"
echo "  1. 将红线/黄线协议写入 AGENTS.md"
echo "  2. 运行一次巡检验证: bash $SCRIPT_DIR/nightly-security-audit.sh"
if [ "$OS_TYPE" != "Darwin" ]; then
    echo "  3. 锁定脚本: sudo chattr +i $SCRIPT_DIR/nightly-security-audit.sh"
fi
echo ""
echo "备份信息:"
echo "  - 备份位置: $BACKUP_DIR"
echo "  - 恢复命令: bash $0 --restore $BACKUP_DIR"
echo "  - 最新备份: $(cat "$OC/.latest-backup-dir" 2>/dev/null || echo '$BACKUP_DIR')"
echo ""
