#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    QlikTaskMonitor.ps1'i Windows Görev Zamanlayıcı'ya kalıcı görev olarak kaydeder.

.DESCRIPTION
    - Sunucu açılışında başlar, ayrıca 5 dakikada bir "hâlâ çalışıyor mu" diye tetiklenir
      (çalışıyorsa yeni kopya açılmaz; çökmüşse yeniden başlar).
    - Qlik servis hesabıyla çalışır; böylece o hesabın Cert:\CurrentUser\My altındaki
      QlikClient sertifikası kullanılır.

.EXAMPLE
    .\Install-QlikTaskMonitor.ps1 -ServiceAccount 'SIRKET\svc_qlik'
.EXAMPLE
    .\Install-QlikTaskMonitor.ps1 -Uninstall
#>
param(
    [string]$ServiceAccount,
    [string]$TaskName = 'Qlik Task Monitor',
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$ScriptDir = $PSScriptRoot
if (-not $ScriptDir -and $MyInvocation.MyCommand.Path) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }

if ($Uninstall) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "'$TaskName' kaldırıldı."
    return
}

if (-not $ServiceAccount) { throw '-ServiceAccount gerekli (ör. SIRKET\svc_qlik).' }

$script = Join-Path $ScriptDir 'QlikTaskMonitor.ps1'
$config = Join-Path $ScriptDir 'config.json'
if (-not (Test-Path $script)) { throw "Bulunamadı: $script" }
if (-not (Test-Path $config)) { throw "Bulunamadı: $config (config.example.json'dan kopyalayıp doldurun)" }

$cred = Get-Credential -UserName $ServiceAccount -Message "$ServiceAccount parolası"

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`"" `
    -WorkingDirectory $ScriptDir

$triggers = @(
    (New-ScheduledTaskTrigger -AtStartup),
    (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5))
)

$settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Settings $settings `
    -User $cred.UserName -Password $cred.GetNetworkCredential().Password -RunLevel Highest -Force | Out-Null

Start-ScheduledTask -TaskName $TaskName
Write-Host "'$TaskName' kuruldu ve başlatıldı. Log: $(Join-Path $ScriptDir 'logs\monitor.log')"
