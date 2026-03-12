#!/usr/bin/env bash
# OpenClaw 极简安全实践指南 v2.8 - 每晚全面安全巡检脚本
# 覆盖 13 项核心指标；具备跨平台自适应与提权环境降权探测能力

# 1. 安全加固：强制严格权限
umask 077

# 2. 跨平台操作系统探测
OS_TYPE=$(uname -s)
if [ "$OS_TYPE" = "Darwin" ]; then
  CMD_STAT="stat -f %A"
  CMD_SHA256="shasum -a 256"
  CMD_SS="netstat -an | grep LISTEN"
  CMD_TOP="top -l 1"
else
  CMD_STAT="stat -c %a"
  CMD_SHA256="sha256sum"
  CMD_SS="ss -tunlp"
  CMD_TOP="top -b -n 1"
fi

# 跨平台超时封装
exec_timeout() {
  local t=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$t" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$t" "$@"
  else
    "$@" # 兜底执行
  fi
}

# 3. 真实用户与家目录探测 (解决 sudo/cron 环境变量丢失)
if [ -n "$SUDO_USER" ]; then
  REAL_USER="$SUDO_USER"
  REAL_HOME=$(eval echo ~$REAL_USER)
else
  REAL_USER="$USER"
  REAL_HOME="$HOME"
fi

export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

if [ -n "$REAL_HOME" ]; then
  # 注入 npm、yarn 本地全局目录
  export PATH="$REAL_HOME/.npm-global/bin:$REAL_HOME/.local/bin:$REAL_HOME/.yarn/bin:$PATH"
  # 注入 nvm 目录
  if [ -d "$REAL_HOME/.nvm/versions/node" ]; then
    NVM_BIN=$(ls -1d "$REAL_HOME"/.nvm/versions/node/*/bin 2>/dev/null | head -n 1)
    [ -n "$NVM_BIN" ] && export PATH="$NVM_BIN:$PATH"
  fi
  export OPENCLAW_STATE_DIR="${OPENCLAW_STATE_DIR:-$REAL_HOME/.openclaw}"
fi

OC="$OPENCLAW_STATE_DIR"

# 4. 报告目录安全设定
REPORT_DIR="/var/log/openclaw-audits"
if [ ! -d "$REPORT_DIR" ]; then
  mkdir -p "$REPORT_DIR" 2>/dev/null || REPORT_DIR="$OC/security-reports"
  mkdir -p "$REPORT_DIR"
fi

DATE_STR=$(date +%F)
REPORT_FILE="$REPORT_DIR/report-$DATE_STR-$$.txt"
SUMMARY="🛡️ OpenClaw 每日安全巡检简报 ($DATE_STR)\n\n"

> "$REPORT_FILE"
chmod 600 "$REPORT_FILE"
echo "=== OpenClaw Security Audit Detailed Report ($DATE_STR) ===" >> "$REPORT_FILE"

append_warn() {
  SUMMARY+="$1\n"
}

# --- 巡检开始 ---

# 1) OpenClaw 基础审计
echo "[1/13] OpenClaw 基础审计 (--deep)" >> "$REPORT_FILE"
if exec_timeout 300s openclaw security audit --deep >> "$REPORT_FILE" 2>&1; then
  SUMMARY+="1. 平台审计: ✅ 已执行原生扫描\n"
else
  append_warn "1. 平台审计: ⚠️ 执行超时或失败（详见详细报告）"
fi

# 2) 进程与网络
echo -e "\n[2/13] 监听端口与高资源进程" >> "$REPORT_FILE"
eval "$CMD_SS" >> "$REPORT_FILE" 2>/dev/null || true
eval "$CMD_TOP" | head -n 15 >> "$REPORT_FILE" 2>/dev/null || true
SUMMARY+="2. 进程网络: ✅ 已采集监听端口与进程快照\n"

# 3) 敏感目录变更
echo -e "\n[3/13] 敏感目录近 24h 变更文件数" >> "$REPORT_FILE"

echo "=== 扫描目录 ===" >> "$REPORT_FILE"
echo "- OpenClaw 目录: $OC" >> "$REPORT_FILE"
echo "- 系统配置: /etc" >> "$REPORT_FILE"
echo "- SSH 配置: ~/.ssh" >> "$REPORT_FILE"
echo "- GnuPG: ~/.gnupg" >> "$REPORT_FILE"
echo "- 自定义 bin: /usr/local/bin" >> "$REPORT_FILE"

echo "" >> "$REPORT_FILE"
echo "=== 变更文件列表 ===" >> "$REPORT_FILE"

# 按目录分组收集变更文件
MOD_COUNT=0
MOD_BY_DIR=""

# 扫描 OpenClaw 目录
OC_MOD=$(find "$OC" -type f -mtime -1 2>/dev/null | head -30 || true)
OC_COUNT=$(echo "$OC_MOD" | grep -v '^$' | wc -l | xargs)

# 扫描 /etc 目录
ETC_MOD=$(find /etc -type f -mtime -1 2>/dev/null | grep -v '/proc\|/sys\|/run' | head -30 || true)
ETC_COUNT=$(echo "$ETC_MOD" | grep -v '^$' | wc -l | xargs)

# 扫描 ~/.ssh 目录
SSH_MOD=$(find ~/.ssh -type f -mtime -1 2>/dev/null | head -30 || true)
SSH_COUNT=$(echo "$SSH_MOD" | grep -v '^$' | wc -l | xargs)

# 扫描 ~/.gnupg 目录
GPG_MOD=$(find ~/.gnupg -type f -mtime -1 2>/dev/null | head -30 || true)
GPG_COUNT=$(echo "$GPG_MOD" | grep -v '^$' | wc -l | xargs)

# 扫描 /usr/local/bin
BIN_MOD=$(find /usr/local/bin -type f -mtime -1 2>/dev/null | head -30 || true)
BIN_COUNT=$(echo "$BIN_MOD" | grep -v '^$' | wc -l | xargs)

MOD_COUNT=$((OC_COUNT + ETC_COUNT + SSH_COUNT + GPG_COUNT + BIN_COUNT))

echo "OpenClaw ($OC): $OC_COUNT 个" >> "$REPORT_FILE"
if [ -n "$OC_MOD" ]; then
  echo "$OC_MOD" | sed 's/^/  /' >> "$REPORT_FILE"
fi

echo "" >> "$REPORT_FILE"
echo "/etc: $ETC_COUNT 个" >> "$REPORT_FILE"
if [ -n "$ETC_MOD" ]; then
  echo "$ETC_MOD" | sed 's/^/  /' >> "$REPORT_FILE"
fi

echo "" >> "$REPORT_FILE"
echo "~/.ssh: $SSH_COUNT 个" >> "$REPORT_FILE"
if [ -n "$SSH_MOD" ]; then
  echo "$SSH_MOD" | sed 's/^/  /' >> "$REPORT_FILE"
fi

echo "" >> "$REPORT_FILE"
echo "~/.gnupg: $GPG_COUNT 个" >> "$REPORT_FILE"
if [ -n "$GPG_MOD" ]; then
  echo "$GPG_MOD" | sed 's/^/  /' >> "$REPORT_FILE"
fi

echo "" >> "$REPORT_FILE"
echo "/usr/local/bin: $BIN_COUNT 个" >> "$REPORT_FILE"
if [ -n "$BIN_MOD" ]; then
  echo "$BIN_MOD" | sed 's/^/  /' >> "$REPORT_FILE"
fi

echo "" >> "$REPORT_FILE"
echo "=== 汇总 ===" >> "$REPORT_FILE"
echo "总计: $MOD_COUNT 个文件" >> "$REPORT_FILE"

# 安全分析
if [ "$MOD_COUNT" -gt 0 ]; then
  echo "" >> "$REPORT_FILE"
  echo "【安全分析】" >> "$REPORT_FILE"

  # 检查 ~/.ssh 变更
  if [ "$SSH_COUNT" -gt 0 ]; then
    echo "⚠️ 检测到 ~/.ssh 目录有 $SSH_COUNT 个文件变更!" >> "$REPORT_FILE"
    echo "  - 可能风险: 未经授权的 SSH 密钥添加、authorized_keys 被篡改" >> "$REPORT_FILE"
    echo "  - 建议: 检查是否有新增的公钥，确认是本人操作" >> "$REPORT_FILE"
  fi

  # 检查 /etc 变更
  if [ "$ETC_COUNT" -gt 10 ]; then
    echo "⚠️ 检测到 /etc 目录有 $ETC_COUNT 个文件变更!" >> "$REPORT_FILE"
    echo "  - 可能风险: 系统配置被恶意修改" >> "$REPORT_FILE"
    echo "  - 建议: 检查关键配置文件 (passwd, shadow, sudoers, sshd_config)" >> "$REPORT_FILE"
  fi

  # 检查 /usr/local/bin 变更
  if [ "$BIN_COUNT" -gt 0 ]; then
    echo "⚠️ 检测到 /usr/local/bin 有 $BIN_COUNT 个文件变更!" >> "$REPORT_FILE"
    echo "  - 可能风险: 可执行恶意程序被植入" >> "$REPORT_FILE"
    echo "  - 建议: 验证新增二进制文件的来源和哈希" >> "$REPORT_FILE"
  fi

  # 检查 OpenClaw 目录变更
  if [ "$OC_COUNT" -gt 0 ]; then
    echo "ℹ️ OpenClaw 目录有 $OC_COUNT 个文件变更 (正常)" >> "$REPORT_FILE"
    echo "  - 可能是正常的 Agent 运行产生的 memory 和 logs" >> "$REPORT_FILE"
  fi

  echo "" >> "$REPORT_FILE"
  echo "【修复建议】" >> "$REPORT_FILE"
  echo "1. 逐一核实每个变更文件的来源和用途" >> "$REPORT_FILE"
  echo "2. 对于可疑的 SSH 公钥添加: 检查 ~/.ssh/authorized_keys" >> "$REPORT_FILE"
  echo "3. 对于系统配置变更: 使用 'stat' 查看详细变更时间" >> "$REPORT_FILE"
  echo "4. 对于新增二进制: 使用 'file' 和 'sha256sum' 验证" >> "$REPORT_FILE"
  echo "5. 如非本人操作，立即撤销未知变更" >> "$REPORT_FILE"

  if [ "$SSH_COUNT" -gt 0 ] || [ "$ETC_COUNT" -gt 10 ] || [ "$BIN_COUNT" -gt 0 ]; then
    append_warn "3. 目录变更: ⚠️ 检测到 $MOD_COUNT 个变更文件 (含可疑变更)"
  else
    SUMMARY+="3. 目录变更: ✅ $MOD_COUNT 个文件变更\n"
  fi
else
  SUMMARY+="3. 目录变更: ✅ 无变更文件\n"
fi

# 4) 系统定时任务
echo -e "\n[4/13] 系统级定时任务与 Systemd Timers" >> "$REPORT_FILE"
if [ "$OS_TYPE" = "Linux" ]; then
  ls -la /etc/cron.* /var/spool/cron/crontabs/ >> "$REPORT_FILE" 2>/dev/null || true
  systemctl list-timers --all >> "$REPORT_FILE" 2>/dev/null || true
else
  ls -la /Library/LaunchDaemons /Library/LaunchAgents ~/Library/LaunchAgents >> "$REPORT_FILE" 2>/dev/null || true
fi
SUMMARY+="4. 系统 Cron: ✅ 已采集系统级定时任务信息\n"

# 5) OpenClaw 定时任务
echo -e "\n[5/13] OpenClaw Cron Jobs" >> "$REPORT_FILE"
if exec_timeout 60s openclaw cron list >> "$REPORT_FILE" 2>&1; then
  SUMMARY+="5. 本地 Cron: ✅ 已拉取内部任务列表\n"
else
  append_warn "5. 本地 Cron: ⚠️ 拉取失败（可能是 token/权限/超时问题）"
fi

# 6) 登录与 SSH 审计
echo -e "\n[6/13] 最近登录记录与 SSH 失败尝试" >> "$REPORT_FILE"
last -a -n 5 >> "$REPORT_FILE" 2>/dev/null || true
FAILED_SSH=0
if [ "$OS_TYPE" = "Linux" ] && command -v journalctl >/dev/null 2>&1; then
  FAILED_SSH=$(journalctl -u sshd --since "24 hours ago" 2>/dev/null | grep -Ei "Failed|Invalid" | wc -l | xargs)
else
  for LOGF in /var/log/auth.log /var/log/secure /var/log/system.log; do
    if [ -f "$LOGF" ]; then
      FAILED_SSH=$(grep -Ei "sshd.*(Failed|Invalid)" "$LOGF" 2>/dev/null | tail -n 1000 | wc -l | xargs)
      break
    fi
  done
fi
echo "Failed SSH attempts (recent): $FAILED_SSH" >> "$REPORT_FILE"
SUMMARY+="6. SSH 安全: ✅ 近24h失败尝试 ${FAILED_SSH:-0} 次\n"

# 7) 关键文件完整性与权限
echo -e "\n[7/13] 关键配置文件权限与哈希基线" >> "$REPORT_FILE"
HASH_RES="MISSING_BASELINE"
if [ -f "$OC/.config-baseline.sha256" ]; then
  HASH_RES=$(cd "$OC" && eval "$CMD_SHA256" -c .config-baseline.sha256 2>&1 || true)
fi
echo "Hash Check: $HASH_RES" >> "$REPORT_FILE"
PERM_OC=$(eval "$CMD_STAT" "$OC/openclaw.json" 2>/dev/null || echo "MISSING")
PERM_PAIRED=$(eval "$CMD_STAT" "$OC/devices/paired.json" 2>/dev/null || echo "MISSING")
PERM_SSHD=$(eval "$CMD_STAT" /etc/ssh/sshd_config 2>/dev/null || echo "N/A")
PERM_AUTH_KEYS=$(eval "$CMD_STAT" "$REAL_HOME/.ssh/authorized_keys" 2>/dev/null || echo "N/A")
echo "Permissions: openclaw=$PERM_OC, paired=$PERM_PAIRED, sshd_config=$PERM_SSHD, authorized_keys=$PERM_AUTH_KEYS" >> "$REPORT_FILE"
if [[ "$HASH_RES" == *"OK"* ]] && [[ "$PERM_OC" == "600" ]]; then
  SUMMARY+="7. 配置基线: ✅ 哈希校验通过且权限合规\n"
else
  append_warn "7. 配置基线: ⚠️ 基线缺失/校验异常或权限不合规"
fi

# 8) 黄线操作交叉验证
echo -e "\n[8/13] 黄线操作对比 (sudo logs vs memory)" >> "$REPORT_FILE"

# 获取 sudo 命令日志
SUDO_COUNT=0
SUDO_CMDS=""
for LOGF in /var/log/auth.log /var/log/secure /var/log/system.log; do
  if [ -f "$LOGF" ]; then
    SUDO_COUNT=$(grep -Ei "sudo.*COMMAND" "$LOGF" 2>/dev/null | tail -n 2000 | wc -l | xargs)
    # 获取最近 20 条 sudo 命令
    SUDO_CMDS=$(grep -Ei "sudo.*COMMAND" "$LOGF" 2>/dev/null | tail -n 20 | sed 's/.*COMMAND=//' | sed 's/;.*//' || echo "")
    break
  fi
done

# 获取 memory 中的记录
MEM_FILE="$OC/workspace/memory/$DATE_STR.md"
MEM_COUNT=0
MEM_SUDO_ENTRIES=""
if [ -f "$MEM_FILE" ]; then
  MEM_COUNT=$(grep -i "sudo\|chattr\|systemctl\|crontab\|docker" "$MEM_FILE" 2>/dev/null | wc -l | xargs)
  # 获取 memory 中的黄线操作记录
  MEM_SUDO_ENTRIES=$(grep -i "sudo\|chattr\|systemctl\|crontab\|docker" "$MEM_FILE" 2>/dev/null | head -n 20 || echo "")
fi

echo "=== 系统日志中的 sudo 执行记录 ===" >> "$REPORT_FILE"
echo "近24h sudo 执行次数: ${SUDO_COUNT:-0}" >> "$REPORT_FILE"
if [ -n "$SUDO_CMDS" ]; then
  echo "最近执行的 sudo 命令:" >> "$REPORT_FILE"
  echo "$SUDO_CMDS" | head -n 10 | sed 's/^/  - /' >> "$REPORT_FILE"
fi

echo "" >> "$REPORT_FILE"
echo "=== Memory 日志中的黄线操作记录 ===" >> "$REPORT_FILE"
echo "今日黄线操作记录次数: ${MEM_COUNT:-0}" >> "$REPORT_FILE"
if [ -n "$MEM_SUDO_ENTRIES" ]; then
  echo "Memory 中的黄线操作:" >> "$REPORT_FILE"
  echo "$MEM_SUDO_ENTRIES" | head -n 10 | sed 's/^/  - /' >> "$REPORT_FILE"
else
  echo "  (无记录)" >> "$REPORT_FILE"
fi

echo "" >> "$REPORT_FILE"
echo "=== 交叉对比分析 ===" >> "$REPORT_FILE"
if [ "$SUDO_COUNT" -gt 0 ] && [ "$MEM_COUNT" -eq 0 ]; then
  echo "⚠️ 警告: 检测到 $SUDO_COUNT 次 sudo 执行，但 memory 中无对应记录!" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
  echo "【修复建议】" >> "$REPORT_FILE"
  echo "这是严重的安全风险! OpenClaw 执行了 sudo 命令但未在 memory 中记录。" >> "$REPORT_FILE"
  echo "1. 检查 memory 文件是否存在: $MEM_FILE" >> "$REPORT_FILE"
  echo "2. 确认 OpenClaw 遵守黄线规则: 所有 sudo 执行必须记录到 memory" >> "$REPORT_FILE"
  echo "3. 更新 AGENTS.md 中的黄线规则，确保强制记录" >> "$REPORT_FILE"
  append_warn "8. 黄线审计: ⚠️ sudo记录=${SUDO_COUNT:-0}, memory记录=${MEM_COUNT:-0} - 未记录的高权操作!"
elif [ "$SUDO_COUNT" -gt 0 ] && [ "$MEM_COUNT" -gt 0 ]; then
  DIFF=$((SUDO_COUNT - MEM_COUNT))
  if [ "$DIFF" -gt 5 ]; then
    echo "⚠️ 警告: sudo 执行次数 ($SUDO_COUNT) 与 memory 记录 ($MEM_COUNT) 差异较大!" >> "$REPORT_FILE"
    echo "【修复建议】: 检查 memory 记录是否完整，确认所有 sudo 操作都被记录" >> "$REPORT_FILE"
    append_warn "8. 黄线审计: ⚠️ sudo记录=${SUDO_COUNT:-0}, memory记录=${MEM_COUNT:-0} - 记录不完整"
  else
    SUMMARY+="8. 黄线审计: ✅ sudo记录=${SUDO_COUNT:-0}, memory记录=${MEM_COUNT:-0}\n"
  fi
else
  SUMMARY+="8. 黄线审计: ✅ sudo记录=${SUDO_COUNT:-0}, memory记录=${MEM_COUNT:-0}\n"
fi

# 9) 磁盘使用
echo -e "\n[9/13] 磁盘使用率与最近大文件" >> "$REPORT_FILE"

# 获取各分区磁盘使用情况
echo "=== 各分区磁盘使用情况 ===" >> "$REPORT_FILE"
df -h 2>/dev/null | grep -E '^/dev|Filesystem' >> "$REPORT_FILE"

# 获取根分区使用率
DISK_USAGE=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')

# 查找最近 24h 的大文件
echo "" >> "$REPORT_FILE"
echo "=== 最近 24h 新增大文件 (>100MB) ===" >> "$REPORT_FILE"

# 使用 find 查找大文件
LARGE_FILES=$(find / -xdev -type d \( -name docker -o -name proc -o -name sys -o -name run \) -prune -o -type f -size +100M -mtime -1 -print 2>/dev/null)
LARGE_COUNT=$(echo "$LARGE_FILES" | grep -v '^$' | wc -l | xargs)

if [ "$LARGE_COUNT" -gt 0 ]; then
  echo "发现 $LARGE_COUNT 个大文件:" >> "$REPORT_FILE"
  echo "$LARGE_FILES" | while read f; do
    if [ -f "$f" ]; then
      SIZE=$(du -h "$f" 2>/dev/null | cut -f1 || echo "unknown")
      MTIME=$(stat -c %y "$f" 2>/dev/null | cut -d' ' -f1 || stat -f "%Sm" -t "%Y-%m-%d" "$f" 2>/dev/null || echo "unknown")
      echo "  - $f (大小: $SIZE, 修改时间: $MTIME)" >> "$REPORT_FILE"
    fi
  done
else
  echo "  未发现新增大文件" >> "$REPORT_FILE"
fi

# 磁盘告警检查
echo "" >> "$REPORT_FILE"
echo "=== 磁盘健康检查 ===" >> "$REPORT_FILE"
if [ "${DISK_USAGE:-0}" -ge 90 ]; then
  echo "⚠️ 严重告警: 根分区使用率 ${DISK_USAGE}% (超过90%)!" >> "$REPORT_FILE"
  echo "【修复建议】:" >> "$REPORT_FILE"
  echo "1. 清理日志文件: sudo journalctl --vacuum-time=7d" >> "$REPORT_FILE"
  echo "2. 清理临时文件: sudo rm -rf /tmp/*" >> "$REPORT_FILE"
  echo "3. 清理 Docker: docker system prune -a" >> "$REPORT_FILE"
  echo "4. 清理旧内核: sudo apt autoremove (Debian/Ubuntu)" >> "$REPORT_FILE"
  append_warn "9. 磁盘容量: ⚠️ 根分区占用 ${DISK_USAGE}%, 超过90%!"
elif [ "${DISK_USAGE:-0}" -ge 85 ]; then
  echo "⚠️ 警告: 根分区使用率 ${DISK_USAGE}% (超过85%)" >> "$REPORT_FILE"
  echo "【修复建议】: 建议清理不必要的文件避免磁盘占满" >> "$REPORT_FILE"
  append_warn "9. 磁盘容量: ⚠️ 根分区占用 ${DISK_USAGE}%, 超过85%"
else
  SUMMARY+="9. 磁盘容量: ✅ 根分区占用 ${DISK_USAGE}%, 新增 $LARGE_COUNT 个大文件\n"
fi

# 10) Gateway 环境变量 (Linux Only)
echo -e "\n[10/13] Gateway 环境变量泄露扫描" >> "$REPORT_FILE"

if [ "$OS_TYPE" = "Linux" ]; then
  GW_PID=$(pgrep -f "openclaw-gateway" | head -n 1 || true)

  if [ -n "$GW_PID" ] && [ -r "/proc/$GW_PID/environ" ]; then
    echo "=== openclaw-gateway 进程信息 ===" >> "$REPORT_FILE"
    echo "进程 PID: $GW_PID" >> "$REPORT_FILE"
    echo "进程命令: $(ps -p $GW_PID -o cmd= 2>/dev/null || echo 'unknown')" >> "$REPORT_FILE"
    echo "启动时间: $(ps -p $GW_PID -o lstart= 2>/dev/null || echo 'unknown')" >> "$REPORT_FILE"

    echo "" >> "$REPORT_FILE"
    echo "=== 敏感环境变量扫描结果 ===" >> "$REPORT_FILE"

    # 扫描敏感变量 - 使用正确的方式提取变量名并隐藏值
    # 使用 tr '\0' '\n' 正确分隔环境变量
    SENSITIVE_VARS_RAW=$(tr '\0' '\n' < "/proc/$GW_PID/environ" 2>/dev/null | grep -iE 'SECRET|TOKEN|PASSWORD|KEY|API|PRIVATE|CREDENTIAL|Auth|Bearer' || true)

    if [ -n "$SENSITIVE_VARS_RAW" ]; then
      # 计算敏感变量数量
      SENSITIVE_VAR_COUNT=$(echo "$SENSITIVE_VARS_RAW" | grep -v '^$' | wc -l | xargs)

      echo "发现以下敏感环境变量 (值已隐藏):" >> "$REPORT_FILE"

      # 按行处理，提取变量名
      echo "$SENSITIVE_VARS_RAW" | while IFS= read -r line; do
        # 提取等号前的变量名
        var_name=$(echo "$line" | sed 's/=.*//')
        if [ -n "$var_name" ]; then
          echo "  ⚠️ $var_name" >> "$REPORT_FILE"
        fi
      done

      echo "" >> "$REPORT_FILE"
      echo "【安全分析】" >> "$REPORT_FILE"
      echo "检测到 $SENSITIVE_VAR_COUNT 个敏感环境变量，存在以下风险:" >> "$REPORT_FILE"
      echo "1. 如果 OpenClaw 被攻破，攻击者可读取这些变量" >> "$REPORT_FILE"
      echo "2. 敏感凭证可能被意外记录到日志或 memory 中" >> "$REPORT_FILE"
      echo "3. JWT token 等可能被解码和利用" >> "$REPORT_FILE"

      echo "" >> "$REPORT_FILE"
      echo "【修复建议】" >> "$REPORT_FILE"
      echo "1. 优先使用文件方式存储凭证，而非环境变量" >> "$REPORT_FILE"
      echo "2. 使用 OpenClaw 的 credential 存储机制" >> "$REPORT_FILE"
      echo "3. 避免在启动脚本中直接设置敏感变量，改用 .env 文件" >> "$REPORT_FILE"
      echo "4. 考虑使用 HashiCorp Vault 等密钥管理服务" >> "$REPORT_FILE"
      echo "5. 对于 JWT token，确保使用短期 token 并定期轮换" >> "$REPORT_FILE"

      append_warn "10. 环境变量: ⚠️ 检测到 $SENSITIVE_VAR_COUNT 个敏感变量"
    else
      echo "  ✅ 未检测到明显敏感环境变量" >> "$REPORT_FILE"
      SUMMARY+="10. 环境变量: ✅ 未发现敏感变量泄露\n"
    fi
  else
    echo "⚠️ 未定位到 openclaw-gateway 进程或无法读取环境变量" >> "$REPORT_FILE"
    echo "可能原因:" >> "$REPORT_FILE"
    echo "  - Gateway 未运行" >> "$REPORT_FILE"
    echo "  - 权限不足无法读取 /proc" >> "$REPORT_FILE"
    echo "  - 进程名称不匹配" >> "$REPORT_FILE"
    append_warn "10. 环境变量: ⚠️ 未定位到 Gateway 进程"
  fi
else
  echo "=== macOS 环境变量扫描 ===" >> "$REPORT_FILE"
  echo "macOS 系统不直接支持 /proc 扫描，改为扫描环境变量文件" >> "$REPORT_FILE"

  # 尝试从 launchd 获取环境变量
  if [ -f "$REAL_HOME/.openclaw/.env" ]; then
    echo "发现 .env 文件:" >> "$REPORT_FILE"
    grep -E 'SECRET|TOKEN|PASSWORD|KEY|API' "$REAL_HOME/.openclaw/.env" 2>/dev/null | sed 's/=.*/=(Hidden)/' >> "$REPORT_FILE" || true
    echo "【修复建议】: .env 文件应加入 .gitignore 并限制权限 chmod 600" >> "$REPORT_FILE"
  fi

  SUMMARY+="10. 环境变量: ✅ macOS 系统免于 /proc 扫描\n"
fi

# 11) 明文凭证泄露扫描 (DLP)
echo -e "\n[11/13] 明文私钥/助记词泄露扫描 (DLP)" >> "$REPORT_FILE"

SCAN_ROOT="$OC/workspace"
DLP_HITS=0

echo "=== DLP 扫描配置 ===" >> "$REPORT_FILE"
echo "扫描目录: $SCAN_ROOT" >> "$REPORT_FILE"
echo "扫描排除:" >> "$REPORT_FILE"
echo "  - node_modules, .git, .next, build, dist" >> "$REPORT_FILE"
echo "  - *.md (文档文件), *.map (源码映射)" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
echo "扫描模式:" >> "$REPORT_FILE"
echo "  1. 高置信度以太坊私钥 (0x + 64位十六进制)" >> "$REPORT_FILE"
echo "  2. BIP39 助记词 (纯单词序列，无标点)" >> "$REPORT_FILE"
echo "  3. RSA/EC 私钥文件头" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

if [ -d "$SCAN_ROOT" ]; then
  echo "=== 扫描结果 ===" >> "$REPORT_FILE"

  # 定义排除模式
  EXCLUDE_PATTERN="--exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.next --exclude-dir=build --exclude-dir=dist --exclude='*.map' --exclude='*.md' --exclude='*.png' --exclude='*.jpg' --exclude='*.jpeg' --exclude='*.gif' --exclude='*.webp'"

  # 模式1: 高置信度以太坊私钥 (0x 开头 + 64位十六进制 = 私钥，不是地址)
  # 注意: 40位是地址，64位是私钥
  echo "正在扫描以太坊私钥模式 (0x + 64位十六进制)..." >> "$REPORT_FILE"
  ETH_RESULTS=$(exec_timeout 60s grep -RInE $EXCLUDE_PATTERN '\b0x[a-fA-F0-9]{64}\b' "$SCAN_ROOT" 2>/dev/null | head -n 20 || true)
  ETH_COUNT=$(echo "$ETH_RESULTS" | grep -v '^$' | wc -l | xargs)

  # 模式2: 私钥头格式 (PEM)
  echo "正在扫描私钥文件格式..." >> "$REPORT_FILE"
  PRIVKEY_RESULTS=$(exec_timeout 60s grep -RInE $EXCLUDE_PATTERN '-----BEGIN.*PRIVATE KEY-----' "$SCAN_ROOT" 2>/dev/null | head -n 20 || true)
  PRIVKEY_COUNT=$(echo "$PRIVKEY_RESULTS" | grep -v '^$' | wc -l | xargs)

  # 模式3: 严格的助记词检测
  # 必须满足：12-24个单词，全部小写，单词之间只有空格，无任何其他字符
  echo "正在扫描 BIP39 助记词模式..." >> "$REPORT_FILE"
  # 扫描 memory 和 logs 目录（高风险区域）
  MNEMONIC_RESULTS=""
  for subdir in memory logs credentials; do
    if [ -d "$SCAN_ROOT/$subdir" ]; then
      result=$(exec_timeout 30s grep -RInE --exclude-dir=.git --exclude='*.png' --exclude='*.jpg' --exclude='*.jpeg' --exclude='*.gif' --exclude='*.webp' -E '^[a-z]+(\s+[a-z]+){11,23}$' "$SCAN_ROOT/$subdir" 2>/dev/null | head -n 10 || true)
      MNEMONIC_RESULTS="$MNEMONIC_RESULTS$result"
    fi
  done
  MNEMONIC_COUNT=$(echo "$MNEMONIC_RESULTS" | grep -v '^$' | wc -l | xargs)

  # 模式4: 检查常见密钥文件扩展名
  echo "正在扫描可疑密钥文件..." >> "$REPORT_FILE"
  KEYFILE_RESULTS=""
  for ext in .pem .key .priv .wallet; do
    result=$(find "$SCAN_ROOT" -type f -name "*$ext" 2>/dev/null | grep -v node_modules | head -n 10 || true)
    KEYFILE_RESULTS="$KEYFILE_RESULTS$result"
  done
  KEYFILE_COUNT=$(echo "$KEYFILE_RESULTS" | grep -v '^$' | wc -l | xargs)

  DLP_HITS=$((${ETH_COUNT:-0} + ${MNEMONIC_COUNT:-0} + ${PRIVKEY_COUNT:-0} + ${KEYFILE_COUNT:-0}))

  echo "" >> "$REPORT_FILE"
  echo "=== 详细结果 ===" >> "$REPORT_FILE"

  # 以太坊私钥
  echo "以太坊私钥 (64位十六进制): ${ETH_COUNT:-0} 处" >> "$REPORT_FILE"
  if [ -n "$ETH_RESULTS" ]; then
    echo "  ⚠️ 高风险! 这些可能是真实的以太坊私钥" >> "$REPORT_FILE"
    echo "  匹配详情 (前10条):" >> "$REPORT_FILE"
    echo "$ETH_RESULTS" | head -n 10 | sed 's/^/    /' >> "$REPORT_FILE"
  fi

  # 私钥文件格式
  echo "" >> "$REPORT_FILE"
  echo "PEM 私钥格式: ${PRIVKEY_COUNT:-0} 处" >> "$REPORT_FILE"
  if [ -n "$PRIVKEY_RESULTS" ]; then
    echo "  ⚠️ 发现私钥文件格式" >> "$REPORT_FILE"
    echo "  匹配详情 (前10条):" >> "$REPORT_FILE"
    echo "$PRIVKEY_RESULTS" | head -n 10 | sed 's/^/    /' >> "$REPORT_FILE"
  fi

  # 助记词
  echo "" >> "$REPORT_FILE"
  echo "BIP39 助记词 (严格匹配): ${MNEMONIC_COUNT:-0} 处" >> "$REPORT_FILE"
  if [ -n "$MNEMONIC_RESULTS" ]; then
    echo "  ⚠️ 高风险! 这可能是真实的钱包助记词" >> "$REPORT_FILE"
    echo "  匹配详情 (前10条):" >> "$REPORT_FILE"
    echo "$MNEMONIC_RESULTS" | head -n 10 | sed 's/^/    /' >> "$REPORT_FILE"
  fi

  # 密钥文件
  echo "" >> "$REPORT_FILE"
  echo "可疑密钥文件: ${KEYFILE_COUNT:-0} 个" >> "$REPORT_FILE"
  if [ -n "$KEYFILE_RESULTS" ]; then
    echo "  匹配详情:" >> "$REPORT_FILE"
    echo "$KEYFILE_RESULTS" | grep -v '^$' | head -n 10 | sed 's/^/    /' >> "$REPORT_FILE"
  fi

  echo "" >> "$REPORT_FILE"
  echo "=== 汇总 ===" >> "$REPORT_FILE"
  echo "高置信度 DLP 告警: $DLP_HITS" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
  echo "注: 已排除 node_modules、文档文件、构建产物，大幅减少误报" >> "$REPORT_FILE"

  if [ "$DLP_HITS" -gt 0 ]; then
    echo "" >> "$REPORT_FILE"
    echo "【风险分析】" >> "$REPORT_FILE"
    echo "检测到 $DLP_HITS 处高置信度敏感凭证泄露! 这可能导致:" >> "$REPORT_FILE"
    echo "1. 加密货币资产被盗 (以太坊私钥/助记词)" >> "$REPORT_FILE"
    echo "2. 服务器身份被冒充 (RSA/EC 私钥)" >> "$REPORT_FILE"
    echo "3. 钱包资产完全控制权丢失" >> "$REPORT_FILE"

    echo "" >> "$REPORT_FILE"
    echo "【紧急修复步骤】" >> "$REPORT_FILE"
    echo "1. 立即离线备份当前钱包（如果私钥真实存在）" >> "$REPORT_FILE"
    echo "2. 将资产转移到新钱包（新私钥/新助记词）" >> "$REPORT_FILE"
    echo "3. 删除泄露的私钥/助记词文件" >> "$REPORT_FILE"
    echo "4. 检查泄露路径，堵住泄露源头" >> "$REPORT_FILE"
    echo "5. 后续使用环境变量或加密存储替代明文" >> "$REPORT_FILE"

    append_warn "11. 敏感凭证扫描: ⚠️ 检测到 $DLP_HITS 处高置信度敏感凭证泄露!"
  else
    SUMMARY+="11. 敏感凭证扫描: ✅ 未发现高置信度私钥/助记词\n"
  fi
else
  echo "扫描目录不存在: $SCAN_ROOT" >> "$REPORT_FILE"
  SUMMARY+="11. 敏感凭证扫描: ✅ workspace 目录不存在\n"
fi

# 12) Skill/MCP 完整性（基线diff）
echo -e "\n[12/13] Skill/MCP 完整性基线对比" >> "$REPORT_FILE"

SKILL_DIR="$OC/workspace/skills"
MCP_DIR="$OC/workspace/mcp"
HASH_DIR="$OC/security-baselines"
mkdir -p "$HASH_DIR" 2>/dev/null || true
CUR_HASH="$HASH_DIR/skill-mcp-current.sha256"
BASE_HASH="$HASH_DIR/skill-mcp-baseline.sha256"

echo "=== Skill/MCP 基线扫描 ===" >> "$REPORT_FILE"
echo "Skills 目录: $SKILL_DIR" >> "$REPORT_FILE"
echo "MCP 目录: $MCP_DIR" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

# 列出当前安装的 Skills
echo "=== 已安装的 Skills ===" >> "$REPORT_FILE"
if [ -d "$SKILL_DIR" ]; then
  SKILL_COUNT=$(ls -1 "$SKILL_DIR" 2>/dev/null | wc -l | xargs)
  if [ "$SKILL_COUNT" -gt 0 ]; then
    ls -la "$SKILL_DIR" 2>/dev/null >> "$REPORT_FILE"
  else
    echo "  (无)" >> "$REPORT_FILE"
  fi
else
  echo "  Skills 目录不存在" >> "$REPORT_FILE"
fi

echo "" >> "$REPORT_FILE"
echo "=== 已安装的 MCP ===" >> "$REPORT_FILE"
if [ -d "$MCP_DIR" ]; then
  MCP_COUNT=$(ls -1 "$MCP_DIR" 2>/dev/null | wc -l | xargs)
  if [ "$MCP_COUNT" -gt 0 ]; then
    ls -la "$MCP_DIR" 2>/dev/null >> "$REPORT_FILE"
  else
    echo "  (无)" >> "$REPORT_FILE"
  fi
else
  echo "  MCP 目录不存在" >> "$REPORT_FILE"
fi

# 计算当前哈希
> "$CUR_HASH"
for D in "$SKILL_DIR" "$MCP_DIR"; do
  if [ -d "$D" ]; then
    find "$D" -type f -exec eval "$CMD_SHA256" {} + 2>/dev/null | awk '{print $1, $2}' | sort >> "$CUR_HASH" || true
  fi
done

echo "" >> "$REPORT_FILE"
echo "=== 基线对比结果 ===" >> "$REPORT_FILE"

if [ -s "$CUR_HASH" ]; then
  CURRENT_FILE_COUNT=$(wc -l < "$CUR_HASH" | xargs)
  echo "当前文件数: $CURRENT_FILE_COUNT" >> "$REPORT_FILE"

  if [ -f "$BASE_HASH" ]; then
    BASELINE_FILE_COUNT=$(wc -l < "$BASE_HASH" | xargs)
    echo "基线文件数: $BASELINE_FILE_COUNT" >> "$REPORT_FILE"

    # 执行 diff 对比
    DIFF_RESULTS=$(diff "$BASE_HASH" "$CUR_HASH" 2>&1)
    DIFF_EXIT=$?

    if [ $DIFF_EXIT -eq 0 ]; then
      echo "" >> "$REPORT_FILE"
      echo "✅ 所有文件哈希与基线一致，未检测到篡改" >> "$REPORT_FILE"
      SUMMARY+="12. Skill/MCP基线: ✅ 与基线一致 ($CURRENT_FILE_COUNT 个文件)\n"
    else
      echo "" >> "$REPORT_FILE"
      echo "⚠️ 检测到文件变化!" >> "$REPORT_FILE"
      echo "" >> "$REPORT_FILE"
      echo "=== 变化详情 ===" >> "$REPORT_FILE"
      echo "$DIFF_RESULTS" >> "$REPORT_FILE"

      # 分析变化类型
      ADDED=$(echo "$DIFF_RESULTS" | grep '^>' | wc -l | xargs)
      REMOVED=$(echo "$DIFF_RESULTS" | grep '^<' | wc -l | xargs)

      echo "" >> "$REPORT_FILE"
      echo "【变化分析】" >> "$REPORT_FILE"
      echo "新增文件: $ADDED" >> "$REPORT_FILE"
      echo "删除文件: $REMOVED" >> "$REPORT_FILE"

      echo "" >> "$REPORT_FILE"
      echo "【风险评估】" >> "$REPORT_FILE"
      echo "文件变化可能意味着:" >> "$REPORT_FILE"
      echo "1. ✅ 正常更新: Skill/MCP 作者发布了新版本" >> "$REPORT_FILE"
      echo "2. ⚠️ 供应链投毒: 有人篡改了第三方包" >> "$REPORT_FILE"
      echo "3. ⚠️ 未授权安装: 未经审计安装了新 Skill/MCP" >> "$REPORT_FILE"

      echo "" >> "$REPORT_FILE"
      echo "【修复建议】" >> "$REPORT_FILE"
      echo "1. 验证新增 Skill/MCP 的来源和完整性" >> "$REPORT_FILE"
      echo "2. 使用 'clawhub inspect <slug>' 审计新安装的 Skill" >> "$REPORT_FILE"
      echo "3. 确认所有变更都经过安全审计" >> "$REPORT_FILE"
      echo "4. 如需恢复基线: cp $CUR_HASH $BASE_HASH" >> "$REPORT_FILE"
      echo "5. 如确认安全，可更新基线: cp $CUR_HASH $BASE_HASH" >> "$REPORT_FILE"

      append_warn "12. Skill/MCP基线: ⚠️ 检测到 $CURRENT_FILE_COUNT 个文件变化 (新增:$ADDED, 删除:$REMOVED)"
    fi
  else
    # 首次生成基线
    cp "$CUR_HASH" "$BASE_HASH" 2>/dev/null || true
    echo "首次生成基线，已保存 $CURRENT_FILE_COUNT 个文件哈希" >> "$REPORT_FILE"
    SUMMARY+="12. Skill/MCP基线: ✅ 首次生成基线 ($CURRENT_FILE_COUNT 个文件)\n"
  fi
else
  echo "未发现 Skills/MCP 目录文件" >> "$REPORT_FILE"
  SUMMARY+="12. Skill/MCP基线: ✅ 未发现 skills/mcp 目录文件\n"
fi

# 13) 大脑灾备自动同步
echo -e "\n[13/13] 大脑灾备 (Git Backup)" >> "$REPORT_FILE"
BACKUP_STATUS=""
if [ -d "$OC/.git" ]; then
  CURRENT_DIR=$(pwd)
  cd "$OC" || exit 1
  git add . >> "$REPORT_FILE" 2>&1 || true
  if git diff --cached --quiet; then
    echo "No staged changes" >> "$REPORT_FILE"
    BACKUP_STATUS="skip"
  else
    export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10"
    if git commit -m "🛡️ Nightly brain backup ($DATE_STR)" >> "$REPORT_FILE" 2>&1 && exec_timeout 30s git push origin main >> "$REPORT_FILE" 2>&1; then
      BACKUP_STATUS="ok"
    else
      BACKUP_STATUS="fail"
    fi
  fi
  cd "$CURRENT_DIR" || true
else
  BACKUP_STATUS="nogit"
fi

case "$BACKUP_STATUS" in
  ok)   SUMMARY+="13. 灾备备份: ✅ 已自动推送至远端仓库\n" ;;
  skip) SUMMARY+="13. 灾备备份: ✅ 无新变更，跳过推送\n" ;;
  nogit) append_warn "13. 灾备备份: ⚠️ 未初始化Git仓库，已跳过" ;;
  *)    append_warn "13. 灾备备份: ⚠️ 推送失败或超时（不影响本次巡检）" ;;
esac

echo -e "$SUMMARY\n📝 详细战报已保存本机: $REPORT_FILE"
exit 0
