#!/usr/bin/env pwsh
# Windows 一键启动 DSH + dsh-remote bridge。
# 用法（PowerShell）:
#   powershell -ExecutionPolicy Bypass -File .\start_dsh_remote.ps1
# 可先用环境变量或参数覆盖路径：
#   .\start_dsh_remote.ps1 -DshBin "C:\Users\you\AppData\Roaming\npm\dsh.cmd" -NodeBin "C:\Program Files\nodejs\node.exe"

param(
  [string]$DshBin = '',
  [string]$NodeBin = '',
  [string]$BridgeJs = (Join-Path $PSScriptRoot 'bridge\server.js'),
  [string]$DshWorkdir = ''
)

$ErrorActionPreference = 'Stop'
$LogDir = Join-Path $HOME '.dsh'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Resolve-CommandPath([string]$Name) {
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return ''
}

if (-not $DshBin) { $DshBin = Resolve-CommandPath 'dsh' }
if (-not $NodeBin) { $NodeBin = Resolve-CommandPath 'node' }
if (-not $DshWorkdir) { $DshWorkdir = $HOME }
if (-not (Test-Path -LiteralPath $BridgeJs -PathType Leaf)) { throw "找不到 bridge/server.js: $BridgeJs" }
if (-not $NodeBin) { throw '找不到 node.exe，请安装 Node.js 或用 -NodeBin 指定路径' }

function Test-ListeningPort([int]$Port) {
  $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
  return $null -ne $conn
}

Write-Host '==> 检查 DSH (127.0.0.1:3080) ...'
if (Test-ListeningPort 3080) {
  Write-Host '    DSH 已在运行'
} else {
  if (-not $DshBin) { throw '找不到 dsh 命令，请先用 npm 安装 DSH 或用 -DshBin 指定路径' }
  Write-Host "    DSH 未运行，正在启动: $DshBin"
  Start-Process -FilePath $DshBin -ArgumentList @('web') -WorkingDirectory $DshWorkdir -WindowStyle Hidden
  Start-Sleep -Seconds 3
}

Write-Host '==> 检查 bridge (0.0.0.0:8787) ...'
if (Test-ListeningPort 8787) {
  Write-Host '    bridge 已在运行'
} else {
  Write-Host "    bridge 未运行，正在启动: $NodeBin $BridgeJs"
  Start-Process -FilePath $NodeBin -ArgumentList @($BridgeJs) -WorkingDirectory (Split-Path $BridgeJs) -WindowStyle Hidden
  Start-Sleep -Seconds 2
}

Write-Host '==> 验证 DSH ...'
if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
  curl.exe -sS -m 3 -o NUL -w "    DSH HTTP %{http_code}`n" http://127.0.0.1:3080/
} else {
  Write-Host '    未找到 curl.exe，跳过 HTTP 验证'
}

Write-Host '==> 验证 bridge ...'
try {
  $health = Invoke-RestMethod -Uri 'http://127.0.0.1:8787/health' -TimeoutSec 3
  Write-Host "    bridge 正常: $($health.service)"
} catch {
  Write-Host "    bridge 启动失败，请查看 $LogDir\dsh-bridge.log（如存在）"
}

Write-Host '==> Tailscale ...'
$tailscale = Get-Command tailscale -ErrorAction SilentlyContinue
if ($tailscale) {
  $tsCmd = $tailscale.Source
  $tsIp = (& $tsCmd ip -4 2>$null | Select-Object -First 1)
  if ($tsIp) {
    Write-Host "    Tailscale IP: $($tsIp.Trim())"
    Write-Host ''
    Write-Host '手机 App 填写:'
    Write-Host "  服务器地址: http://$($tsIp.Trim()):8787"
    Write-Host '  Token: 查看 bridge/config.json'
  }
} else {
  Write-Host '    Tailscale 未安装；同一局域网下可直接用本机局域网 IP 访问'
}

$pairPage = 'http://127.0.0.1:8787/pair/qr'
Write-Host ''
Write-Host '==> 配对手机 =='
Write-Host "    在电脑浏览器打开: $pairPage"
Write-Host '    生成二维码后，用手机 DSH-Remote App 扫码绑定。'
Start-Process $pairPage

Write-Host ''
Write-Host '完成。首次启动 bridge 时 Windows 防火墙如弹出授权，请允许专用网络访问。'
