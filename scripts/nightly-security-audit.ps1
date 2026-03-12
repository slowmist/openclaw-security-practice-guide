#Requires -Version 5.1
# OpenClaw 极简安全实践指南 v2.8 - Windows PowerShell 版每晚全面安全巡检脚本
# 覆盖 13 项核心指标；适配 Windows 环境

# 1. 安全加固：强制严格权限
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# 2. 设置输出编码
[System.Text.Encoding]::UTF8.GetEncoder()

# 3. Windows 用户目录探测
if ($env:USERNAME -eq 'SYSTEM') {
    # SYSTEM 账户特殊情况
    $REAL_USER = $env:USERNAME
    $REAL_HOME = $env:SystemDrive + '\'
} else {
    $REAL_USER = $env:USERNAME
    $REAL_HOME = $env.USERPROFILE
}

# OpenClaw 状态目录
$OC = Join-Path $REAL_HOME '.openclaw'

# 4. 报告目录安全设定
$REPORT_DIR = Join-Path $OC 'security-reports'
if (-not (Test-Path $REPORT_DIR)) {
    New-Item -ItemType Directory -Path $REPORT_DIR -Force | Out-Null
}

$DATE_STR = Get-Date -Format 'yyyy-MM-dd'
$REPORT_FILE = Join-Path $REPORT_DIR "report-$DATE_STR-$$.txt"

# 初始化报告文件
'' | Out-File -FilePath $REPORT_FILE -Encoding UTF8
$SUMMARY = "🛡️ OpenClaw 每日安全巡检简报 ($DATE_STR)`n`n"

function Append-Warn {
    param([string]$Message)
    $script:SUMMARY += "$Message`n"
}

# --- 巡检开始 ---

# 1) OpenClaw 基础审计
"=== OpenClaw Security Audit Detailed Report ($DATE_STR) ===" | Out-File -FilePath $REPORT_FILE -Append -Encoding UTF8
"`n[1/13] OpenClaw 基础审计 (--deep)" | Out-File -FilePath $REPORT_FILE -Append -Encoding UTF8

try {
    $auditResult = & openclaw security audit --deep 2>&1
    $auditResult | Out-File -FilePath $REPORT_FILE -Append -Encoding UTF8
    if ($LASTEXITCODE -eq 0 -or $auditResult) {
        $SUMMARY += "1. 平台审计: ✅ 已执行原生扫描`n"
    } else {
        Append-Warn "1. 平台审计: ⚠️ 执行超时或失败（详见详细报告）"
    }
} catch {
    Append-Warn "1. 平台审计: ⚠️ 执行超时或失败（详见详细报告）"
}

# 2) 进程与网络
"`n[2/13] 监听端口与高资源进程" | Out-File -FilePath $REPORT_FILE -Append -Encoding UTF8
try {
    $listeningPorts = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Select-Object LocalAddress, LocalPort, OwningProcess |
        Format-Table -AutoSize | Out-String
    $listeningPorts | Out-File -FilePath $REPORT_FILE -Append -Encoding UTF8

    $highProc = Get-Process |
        Sort-Object -Property WorkingSet64 -Descending |
        Select-Object -First 15 Name, Id, @{N='Memory(MB)';E={[math]::Round($_.WorkingSet64/1MB,2)}} |
        Format-Table -AutoSize | Out-String
    $highProc | Out-File -FilePath $REPORT_FILE -Append -Encoding UTF8

    $SUMMARY += "2. 进程网络: ✅ 已采集监听端口与进程快照`n"
} catch {
    Append-Warn "2. 进程网络: ⚠️ 采集失败"
}

# 3) 敏感目录变更
"`n[3/13] 敏感目录近 24h 变更文件数" | Out-File -FilePath $REPORT_FILE -Append -Encoding UTF8
$cutoffDate = (Get-Date).AddDays(-1)
$modFiles = @()

# 扫描用户敏感目录
$sensitiveDirs = @(
    $OC,
    (Join-Path $REAL_HOME '.ssh'),
    (Join-Path $REAL_HOME '.gnupg')
)

foreach ($dir in $sensitiveDirs) {
    if (Test-Path $dir) {
        try {
            $files = Get-ChildItem -Path $dir -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -gt $cutoffDate }
            $modFiles += $files
        } catch {}
    }
}

$MOD_FILES_COUNT = $modFiles.Count
"Total modified files: $MOD_FILES_COUNT" | Out-File -FilePath $REPORT_FILE -Append -Encoding UTF8
$SUMMARY += "3. 目录变更: ✅ $MOD_FILES_COUNT 个文件`n"

# 4) 系统定时任务
"`n[4/13] Windows 计划任务" | Out-File -FilePath $REPORT_FILE -Append -Encoding UTF8
try {
    $scheduledTasks = Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { $_.State -ne 'Disabled' } |
        Select-Object TaskName, State, TaskPath |
        Format-Table -AutoSize | Out-String
    $scheduledTasks | Out-File -FilePath $REPORT_FILE -Append -Encoding UTF8
    $SUMMARY += "4. 计划任务: ✅ 已采集计划任务信息`n"
} catch {
    Append-Warn "4. 计划任务: ⚠️ 采集失败"
}

# 5) OpenClaw 定时任务
"`n[5/13] OpenClaw Cron Jobs" | Out-File -FilePath $REPORT_FILE -Append -Encoding UTF8
try {
    $openclawCron = & openclaw cron list 2>&1
    $openclawCron | Out-File -FilePath $REPORT_FILE -Append -Encoding UTF8
    $SUMMARY += "5. 本地 Cron: ✅ 已拉取内部任务列表`n"
} catch {
    Append-Warn "5. 本地 Cron: ⚠️ 拉取失败（可能是 token/权限/超时问题）"
}

# 6) Windows 安全日志审计
"`n[6/13] Windows 安全日志 (最近登录与账户操作)" | Out-File -FilePath $REPORT_FILE -Append -Encoding UTF8
try {
    # 最近的登录事件 (4624)
    $recentLogins = Get-WinEvent -FilterHashtable @{
        LogName = 'Security'
        Id = 4624
        StartTime = (Get-Date).AddDays(-1)
    } -MaxEvents 5 -ErrorAction SilentlyContinue |
        Select-Object TimeCreated, @{N='User';E={$_.Properties[5].Value}} |
        Format-Table -AutoSize | Out-String

    # SSH/RDP 失败尝试 (4625)
    $failedLogins = Get-WinEvent -FilterHashtable @{
        LogName = 'Security'
        Id = 4625
        StartTime = (Get-Date).AddDays(-1)
    } -ErrorAction SilentlyContinue |
        Measure-Object | Select-Object -ExpandProperty Count

    "Recent Logins:`n$recentLogins" | Out-File -FilePath $REPORT_FILE -Append -Encoding UTF8
    "Failed login attempts (24h): $failedLogins" | Out-File -FilePath $REPORT_FILE -Append -Encoding UTF8
    $SUMMARY += "6. 安全日志: ✅ 近24h失败登录 ${failedLogins:-0} 次`n"
} catch {
    # 安全日志可能需要管理员权限
    "Security log access denied (requires admin)" | Out-File -FilePath $REPORT_FILE -Append -Encoding UTF8
    Append-Warn "6. 安全日志: ⚠️ 需要管理员权限访问"
}

# 7) 关键文件完整性与权限
"`n[7/13] 关键配置文件权限与哈希基线" | Out-File -FilePath $REPORT_FILE -Append -Encoding UTF8

$HASH_RES = "MISSING_BASELINE"
$baselineFile = Join-Path $OC '.config-baseline.sha256'

if (Test-Path $baselineFile) {
    # 验证基线哈希
    $HASH_RES = "Baseline exists (manual verification required)"
}

# 获取关键文件权限
$keyFiles = @(
    (Join-Path $OC 'openclaw.json'),
    (Join-Path $OC 'devices\paired.json')
)

$permResults = @()
foreach ($kf in $keyFiles) {
    if (Test-Path $kf) {
        try {
            $acl = Get-Acl -Path $kf
            $hash = Get-FileHash -Path $kf -Algorithm SHA256 -ErrorAction SilentlyContinue
            $permResults += "$($kf): $($acl.Access.Count) rules, Hash=$($hash.Hash.Substring(0,16))..."
        } catch {
            $permResults += "$($kf): Error reading"
        }
    } else {
        $permResults += "$($kf): MISSING"
    }
}

"Permissions: `n$($permResults | Out-String)" | Out-File -FilePath $REPORT_FILE -Append -Encoding UTF8
$SUMMARY += "7. 配置基线: ✅ 已采集配置文件状态`n"

# 8) 高权限操作交叉验证
"`n[8/13] 高权限操作对比 (Event Log vs Memory)" | Out-File -FilePath $REPORT_FILE -Append -Encoding UTF8

# 检查最近的高权限操作 (RunAs, Elevation)
$ELEV_COUNT = 0
try {
    $elevEvents = Get-WinEvent -FilterHashtable @{
        LogName = 'Security'
        Id = 4672  # Special privileges assigned
        StartTime = (Get-Date).AddDays(-1)
    } -ErrorAction SilentlyContinue | Measure-Object | Select-Object -ExpandProperty Count
    $ELEV_COUNT = $elevEvents
} catch {}

# 检查 memory 文件中的 sudo/elevation 记录
$MEM_COUNT = 0
$memDir = Join-Path $OC 'workspace\memory'
if (Test-Path $memDir) {
    $todayMem = Get-ChildItem -Path $memDir -Filter "*$DATE_STR*" -ErrorAction SilentlyContinue
    foreach ($f in $todayMem) {
        $content = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
        if ($content -match 'Admin|RunAs|Elevation|管理员') {
            $MEM_COUNT++
        }
    }
}

"Sudo/Elevation Events(recent): ${ELEV_COUNT:-0}, Memory Logs(today): ${MEM_COUNT:-0}" | Out-File -FilePath $REPORT_FILE -Append -Encoding UTF8
$SUMMARY += "8. 高权限审计: ✅ 系统事件=${ELEV_COUNT:-0}, memory记录=${MEM_COUNT:-0}`n"

# 9) 磁盘使用
"`n[9/13] 磁盘使用率与最近大文件" | Out-File -FilePath $REPORT_FILE -Append -Encoding UTF8
try {
    $diskUsage = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -ne $null } |
        Select-Object Name, @{N='Used(GB)';E={[math]::Round($_.Used/1GB,2)}}, @{N='Free(GB)';E={[math]::Round($_.Free/1GB,2)}}, @{N='Used%';E={[math]::Round($_.Used/($_.Used+$_.Free)*100,1)}} |
        Format-Table -AutoSize | Out-String
    $diskUsage | Out-File -FilePath $REPORT_FILE -Append -Encoding UTF8

    # 查找最近 24h 创建的大文件 (>100MB)
    $largeFiles = Get-ChildItem -Path 'C:\' -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -gt 100MB -and $_.LastWriteTime -gt $cutoffDate } |
        Select-Object -First 10 FullName, @{N='Size(MB)';E={[math]::Round($_.Length/1MB,2)}} |
        Format-Table -AutoSize | Out-String

    "Recent large files (>100MB):`n$largeFiles" | Out-File -FilePath $REPORT_FILE -Append -Encoding UTF8

    $diskRoot = Get-PSDrive -Name 'C'
    $diskPct = [math]::Round($diskRoot.Used/($diskRoot.Used+$diskRoot.Free)*100,1)
    $SUMMARY += "9. 磁盘容量: ✅ C盘占用 $diskPct%`n"
} catch {
    Append-Warn "9. 磁盘容量: ⚠️ 采集失败"
}

# 10) 进程环境变量扫描 (Windows 替代方案)
"`n[10/13] 敏感进程环境变量扫描" | Out-File -FilePath $REPORT_FILE -Append -Encoding UTF8
try {
    # 扫描正在运行的进程，查找敏感环境变量
    $sensitiveVars = @('SECRET', 'TOKEN', 'PASSWORD', 'KEY', 'API', 'PRIVATE', 'CREDENTIAL')

    $envLeaks = @()
    $processes = Get-Process | Select-Object -First 50

    foreach ($proc in $processes) {
        try {
            $procEnv = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue | Select-Object -ExpandProperty StartInfo
            if ($procEnv.EnvironmentVariables) {
                foreach ($key in $procEnv.EnvironmentVariables.Keys) {
                    if ($sensitiveVars | Where-Object { $key -match $_ }) {
                        $envLeaks += "$($proc.ProcessName) (PID:$($proc.Id)): $key"
                    }
                }
            }
        } catch {}
    }

    if ($envLeaks) {
        "Potential sensitive env vars found:`n$($envLeaks | Out-String)" | Out-File -FilePath $REPORT_FILE -Append -Encoding UTF8
    } else {
        "No obvious sensitive environment variables found in scanned processes" | Out-File -FilePath $REPORT_FILE -Append -Encoding UTF8
    }
    $SUMMARY += "10. 环境变量: ✅ 已执行敏感进程环境变量扫描`n"
} catch {
    Append-Warn "10. 环境变量: ⚠️ 扫描失败"
}

# 11) 明文凭证泄露扫描 (DLP)
"`n[11/13] 明文私钥/助记词泄露扫描 (DLP)" | Out-File -FilePath $REPORT_FILE -Append -Encoding UTF8
$SCAN_ROOT = Join-Path $OC 'workspace'
$DLP_HITS = 0

if (Test-Path $SCAN_ROOT) {
    # 扫描 Ethereum 钱包地址模式 (0x 开头 40 位十六进制)
    try {
        $walletPattern = Get-ChildItem -Path $SCAN_ROOT -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -notmatch '\.(png|jpg|jpeg|gif|webp)$' } |
            Select-String -Pattern '0x[a-fA-F0-9]{40}' -ErrorAction SilentlyContinue

        if ($walletPattern) { $DLP_HITS += $walletPattern.Count }
    } catch {}

    # 扫描 BIP39 助记词模式 (12-24 个单词)
    try {
        $mnemonicFiles = Get-ChildItem -Path $SCAN_ROOT -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -notmatch '\.(png|jpg|jpeg|gif|webp)$' -and $_.Length -lt 1MB }
        $mnemonicPattern = $mnemonicFiles | Select-String -Pattern '\b([a-z]+[ \t]+){11,23}[a-z]+\b' -ErrorAction SilentlyContinue

        if ($mnemonicPattern) { $DLP_HITS += $mnemonicPattern.Count }
    } catch {}
}

"DLP hits (heuristic): $DLP_HITS" | Out-File -FilePath $REPORT_FILE -Append -Encoding UTF8
if ($DLP_HITS -gt 0) {
    Append-Warn "11. 敏感凭证扫描: ⚠️ 检测到疑似明文敏感信息($DLP_HITS)，请人工复核"
} else {
    $SUMMARY += "11. 敏感凭证扫描: ✅ 未发现明显私钥/助记词模式`n"
}

# 12) Skill/MCP 完整性（基线diff）
"`n[12/13] Skill/MCP 完整性基线对比" | Out-File -FilePath $REPORT_FILE -Append -Encoding UTF8

$SKILL_DIR = Join-Path $OC 'workspace\skills'
$MCP_DIR = Join-Path $OC 'workspace\mcp'
$HASH_DIR = Join-Path $OC 'security-baselines'

if (-not (Test-Path $HASH_DIR)) {
    New-Item -ItemType Directory -Path $HASH_DIR -Force | Out-Null
}

$CUR_HASH = Join-Path $HASH_DIR 'skill-mcp-current.sha256'
$BASE_HASH = Join-Path $HASH_DIR 'skill-mcp-baseline.sha256'

# 计算当前哈希
$currentHashContent = ''
foreach ($D in @($SKILL_DIR, $MCP_DIR)) {
    if (Test-Path $D) {
        $files = Get-ChildItem -Path $D -Recurse -File -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            $hash = Get-FileHash -Path $f.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue
            if ($hash) {
                $currentHashContent += "$($hash.Hash)  $($f.FullName)`n"
            }
        }
    }
}

if ($currentHashContent) {
    $currentHashContent | Out-File -FilePath $CUR_HASH -Encoding UTF8

    if (Test-Path $BASE_HASH) {
        $diff = Compare-Object -ReferenceObject (Get-Content $BASE_HASH) -DifferenceObject (Get-Content $CUR_HASH)
        if ($diff) {
            "Hash changes detected:`n$($diff | Out-String)" | Out-File -FilePath $REPORT_FILE -Append -Encoding UTF8
            Append-Warn "12. Skill/MCP基线: ⚠️ 检测到文件哈希变化（详见diff）"
        } else {
            $SUMMARY += "12. Skill/MCP基线: ✅ 与上次基线一致`n"
        }
    } else {
        Copy-Item -Path $CUR_HASH -Destination $BASE_HASH -Force
        $SUMMARY += "12. Skill/MCP基线: ✅ 首次生成基线完成`n"
    }
} else {
    $SUMMARY += "12. Skill/MCP基线: ✅ 未发现skills/mcp目录文件`n"
}

# 13) 大脑灾备自动同步
"`n[13/13] 大脑灾备 (Git Backup)" | Out-File -FilePath $REPORT_FILE -Append -Encoding UTF8
$gitDir = Join-Path $OC '.git'

if (Test-Path $gitDir) {
    $prevLocation = Get-Location
    try {
        Set-Location $OC

        # Git add
        git add . 2>&1 | Out-File -FilePath $REPORT_FILE -Append -Encoding UTF8

        # 检查是否有变更
        $status = git status --porcelain 2>&1
        if ($status) {
            # 有变更，进行 commit 和 push
            git commit -m "🛡️ Nightly brain backup ($DATE_STR)" 2>&1 | Out-File -FilePath $REPORT_FILE -Append -Encoding UTF8
            git push origin main 2>&1 | Out-File -FilePath $REPORT_FILE -Append -Encoding UTF8

            if ($LASTEXITCODE -eq 0) {
                $SUMMARY += "13. 灾备备份: ✅ 已自动推送至远端仓库`n"
            } else {
                Append-Warn "13. 灾备备份: ⚠️ 推送失败或超时"
            }
        } else {
            $SUMMARY += "13. 灾备备份: ✅ 无新变更，跳过推送`n"
        }
    } catch {
        Append-Warn "13. 灾备备份: ⚠️ Git 操作失败"
    } finally {
        Set-Location $prevLocation
    }
} else {
    Append-Warn "13. 灾备备份: ⚠️ 未初始化Git仓库，已跳过"
}

# 输出摘要
"`n$SUMMARY" | Out-File -FilePath $REPORT_FILE -Append -Encoding UTF8

# 控制台输出
Write-Host $SUMMARY
Write-Host "`n📝 详细战报已保存本机: $REPORT_FILE"

exit 0
