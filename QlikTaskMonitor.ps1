#Requires -Version 5.1
<#
.SYNOPSIS
    Qlik Sense Enterprise task'larını QRS API üzerinden izler, fail olanları Microsoft Teams'e bildirir.

.DESCRIPTION
    - Her PollIntervalSeconds saniyede bir /qrs/reloadtask/full (ve istenirse externalprogramtask) okunur.
    - Her task'ın son çalışması (operational.lastExecutionResult) daha önce görülmemişse değerlendirilir.
    - Durumu FailStatuses içindeyse Teams'e kırmızı kart, daha önce fail olan task tekrar başarılı
      olursa (NotifyOnRecovery) yeşil kart gönderilir.
    - QRS'e üst üste ConnectionFailureThreshold kez ulaşılamazsa uyarı, bağlantı geri gelince bilgi gönderilir.
    - İlk çalıştırmada mevcut durum sessizce kaydedilir (eski hatalar için bildirim yağmuru olmaz).

.PARAMETER ConfigPath
    config.json yolu. Varsayılan: script ile aynı klasör.
.PARAMETER Once
    Tek bir kontrol yapıp çıkar (test / Görev Zamanlayıcı ile dakikalık çalıştırma için).
.PARAMETER TestNotification
    Sadece Teams'e deneme kartı gönderir ve çıkar.
.PARAMETER ResetState
    Kayıtlı durumu silip baştan başlar.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [switch]$Once,
    [switch]$TestNotification,
    [switch]$ResetState
)

$ErrorActionPreference = 'Stop'

# Script klasörü: PS 5.1'de bazı çağrı şekillerinde $PSScriptRoot boş gelebiliyor
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir -and $MyInvocation.MyCommand.Path) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }
if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptDir 'config.json' }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$script:IsCore = $PSVersionTable.PSVersion.Major -ge 6

# --- QRS ExecutionResult durum kodları ---------------------------------------
$StatusNames = @{
    0 = 'Hiç çalışmadı'; 1 = 'Tetiklendi'; 2 = 'Çalışıyor'; 3 = 'Kuyrukta'
    4 = 'İptal başlatıldı'; 5 = 'İptal ediliyor'; 6 = 'İptal edildi'; 7 = 'Başarılı'
    8 = 'Başarısız'; 9 = 'Atlandı'; 10 = 'Yeniden deneniyor'; 11 = 'Hata'; 12 = 'Sıfırlandı'
}
$FinalStatuses = @(6, 7, 8, 9, 11, 12)

# --- Config --------------------------------------------------------------------
if (-not (Test-Path $ConfigPath)) { throw "Config bulunamadı: $ConfigPath (config.example.json dosyasını kopyalayın)" }
$cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

function Get-Cfg([string]$Name, $Default) {
    $p = $cfg.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value -and "$($p.Value)" -ne '') { return $p.Value }
    return $Default
}

$PollSeconds    = [int](Get-Cfg 'PollIntervalSeconds' 60)
$FailStatuses   = @(Get-Cfg 'FailStatuses' @(6, 8, 11)) | ForEach-Object { [int]$_ }
$ConnThreshold  = [int](Get-Cfg 'ConnectionFailureThreshold' 3)
$MaxCards       = [int](Get-Cfg 'MaxCardsPerCycle' 5)
$EnvName        = [string](Get-Cfg 'EnvironmentName' 'Qlik')
$StateFile      = [string](Get-Cfg 'StateFile' (Join-Path $ScriptDir 'state.json'))
$LogFile        = [string](Get-Cfg 'LogFile' (Join-Path $ScriptDir 'logs\monitor.log'))
$IncludeRegex   = [string](Get-Cfg 'TaskNameInclude' '')
$ExcludeRegex   = [string](Get-Cfg 'TaskNameExclude' '')
$HubBaseUrl     = [string](Get-Cfg 'HubBaseUrl' '')
$QmcBaseUrl     = [string](Get-Cfg 'QmcBaseUrl' '')
if (-not [IO.Path]::IsPathRooted($StateFile)) { $StateFile = Join-Path $ScriptDir $StateFile }
if (-not [IO.Path]::IsPathRooted($LogFile))   { $LogFile   = Join-Path $ScriptDir $LogFile }

$WebhookUrl = [string](Get-Cfg 'TeamsWebhookUrl' '')
if ($env:QLIK_MONITOR_TEAMS_WEBHOOK) { $WebhookUrl = $env:QLIK_MONITOR_TEAMS_WEBHOOK }
if (-not $WebhookUrl) { throw 'TeamsWebhookUrl tanımlı değil (config veya QLIK_MONITOR_TEAMS_WEBHOOK).' }

# --- Log -----------------------------------------------------------------------
function Write-Log([string]$Message, [string]$Level = 'INFO') {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    try {
        $dir = Split-Path $LogFile -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 10MB) {
            Move-Item $LogFile "$LogFile.old" -Force
        }
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    } catch { Write-Host "Log yazılamadı: $_" }
}

# --- Sertifika / QRS -----------------------------------------------------------
function Get-QlikCertificate {
    $auth = $cfg.Auth
    if ($auth.Mode -eq 'Pfx') {
        $pw = [string]$auth.PfxPassword
        if ($env:QLIK_MONITOR_PFX_PASSWORD) { $pw = $env:QLIK_MONITOR_PFX_PASSWORD }
        return New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($auth.PfxPath, $pw)
    }
    $location = if ($auth.CertStoreLocation) { $auth.CertStoreLocation } else { 'CurrentUser' }
    $subject  = if ($auth.CertSubject) { $auth.CertSubject } else { 'CN=QlikClient' }
    $cert = Get-ChildItem "Cert:\$location\My" |
        Where-Object { $_.Subject -eq $subject -and $_.HasPrivateKey } |
        Sort-Object NotAfter -Descending | Select-Object -First 1
    if (-not $cert) { throw "Sertifika bulunamadı: Cert:\$location\My altında '$subject' (private key'li). Script'i Qlik servis hesabıyla çalıştırın veya Auth.Mode=Pfx kullanın." }
    return $cert
}

if ($cfg.SkipServerCertValidation -and -not $script:IsCore) {
    if (-not ('TrustAllCertsPolicy' -as [type])) {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@
    }
    [Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
}

function Invoke-Qrs([string]$Path) {
    $xrf = -join ((48..57) + (97..122) | Get-Random -Count 16 | ForEach-Object { [char]$_ })
    $sep = if ($Path.Contains('?')) { '&' } else { '?' }
    $port = if ($cfg.QrsPort) { $cfg.QrsPort } else { 4242 }
    $uri = "https://$($cfg.QrsHost):$port/qrs/$Path${sep}xrfkey=$xrf"
    $params = @{
        Uri         = $uri
        Method      = 'Get'
        Certificate = $script:Cert
        TimeoutSec  = 60
        Headers     = @{
            'X-Qlik-Xrfkey' = $xrf
            'X-Qlik-User'   = "UserDirectory=$($cfg.Auth.UserDirectory); UserId=$($cfg.Auth.UserId)"
        }
    }
    if ($script:IsCore) { if ($cfg.SkipServerCertValidation) { $params.SkipCertificateCheck = $true } }
    else { $params.UseBasicParsing = $true }
    # PS 5.1'de Invoke-RestMethod JSON dizisini tek nesne (Object[]) olarak verir;
    # değişkene alıp döndürünce elemanlar tek tek açılır.
    $response = Invoke-RestMethod @params
    return $response
}

function Get-QlikTasks {
    $tasks = New-Object System.Collections.Generic.List[object]
    foreach ($t in @(Invoke-Qrs 'reloadtask/full')) {
        $stream = ''
        if ($t.app -and $t.app.stream) { $stream = $t.app.stream.name }
        $tasks.Add([pscustomobject]@{
            Id = $t.id; Name = $t.name; Type = 'Reload'; Enabled = $t.enabled
            AppId = $t.app.id; AppName = $t.app.name; Stream = $stream
            Last = $t.operational.lastExecutionResult
        })
    }
    if ($cfg.IncludeExternalProgramTasks) {
        try {
            foreach ($t in @(Invoke-Qrs 'externalprogramtask/full')) {
                $tasks.Add([pscustomobject]@{
                    Id = $t.id; Name = $t.name; Type = 'External program'; Enabled = $t.enabled
                    AppId = $null; AppName = $t.path; Stream = ''
                    Last = $t.operational.lastExecutionResult
                })
            }
        } catch { Write-Log "externalprogramtask okunamadı: $($_.Exception.Message)" 'WARN' }
    }
    $filtered = $tasks | Where-Object {
        (-not $IncludeRegex -or $_.Name -match $IncludeRegex) -and
        (-not $ExcludeRegex -or $_.Name -notmatch $ExcludeRegex)
    }
    return @($filtered)
}

# --- Yardımcılar -----------------------------------------------------------------
function ConvertTo-LocalTimeText($v) {
    if (-not $v) { return '-' }
    try {
        $d = if ($v -is [datetime]) { $v } else { [datetime]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
        return $d.ToLocalTime().ToString('dd.MM.yyyy HH:mm:ss')
    } catch { return [string]$v }
}

function Format-Duration($ms) {
    if (-not $ms) { return '-' }
    $ts = [TimeSpan]::FromMilliseconds([double]$ms)
    if ($ts.TotalHours -ge 1) { return '{0}sa {1}dk {2}sn' -f [int][Math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds }
    if ($ts.TotalMinutes -ge 1) { return '{0}dk {1}sn' -f $ts.Minutes, $ts.Seconds }
    return '{0}sn' -f $ts.Seconds
}

function Get-ResultKey($last) {
    # Aynı çalışmayı iki kez bildirmemek için: sonuç id + başlangıç + bitiş zamanı
    return '{0}|{1}|{2}' -f $last.id, [string]$last.startTime, [string]$last.stopTime
}

function Get-StatusText([int]$s) { if ($StatusNames.ContainsKey($s)) { $StatusNames[$s] } else { "Durum $s" } }

# --- Teams -----------------------------------------------------------------------
function New-TeamsMessage {
    param([string]$Title, [string]$Color, [object[]]$Facts, [string]$Text, [object[]]$Links)
    $body = New-Object System.Collections.Generic.List[object]
    $body.Add(@{ type = 'TextBlock'; text = $Title; weight = 'Bolder'; size = 'Large'; color = $Color; wrap = $true })
    if ($Facts) {
        $body.Add(@{ type = 'FactSet'; facts = @($Facts | ForEach-Object { @{ title = $_[0]; value = [string]$_[1] } }) })
    }
    if ($Text) { $body.Add(@{ type = 'TextBlock'; text = $Text; wrap = $true; size = 'Small'; spacing = 'Medium' }) }
    $card = [ordered]@{
        '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'
        type      = 'AdaptiveCard'
        version   = '1.4'
        msteams   = @{ width = 'Full' }
        body      = $body.ToArray()
    }
    $actions = @($Links | Where-Object { $_ -and $_[1] } | ForEach-Object { @{ type = 'Action.OpenUrl'; title = $_[0]; url = $_[1] } })
    if ($actions.Count -gt 0) { $card.actions = $actions }
    return @{ type = 'message'; attachments = @(@{ contentType = 'application/vnd.microsoft.card.adaptive'; content = $card }) }
}

function Send-Teams($message) {
    $json = $message | ConvertTo-Json -Depth 20
    $params = @{
        Uri = $WebhookUrl; Method = 'Post'; TimeoutSec = 30
        ContentType = 'application/json; charset=utf-8'
        Body = [Text.Encoding]::UTF8.GetBytes($json)
    }
    if (-not $script:IsCore) { $params.UseBasicParsing = $true }
    Invoke-RestMethod @params | Out-Null
}

function Get-TaskLinks($task) {
    $links = @()
    if ($QmcBaseUrl) { $links += ,@("QMC'de task'lar", "$($QmcBaseUrl.TrimEnd('/'))/tasks") }
    if ($HubBaseUrl -and $task.AppId) { $links += ,@("Uygulamayı aç", "$($HubBaseUrl.TrimEnd('/'))/sense/app/$($task.AppId)") }
    return ,$links
}

function New-FailureMessage($task) {
    $last = $task.Last
    $details = @($last.details | Where-Object { $_.message } | Select-Object -Last 6 | ForEach-Object { '- ' + $_.message.Trim() })
    $facts = @(
        ,@('Task', $task.Name)
        ,@('Uygulama', $(if ($task.AppName) { $task.AppName } else { '-' }))
        ,@('Stream', $(if ($task.Stream) { $task.Stream } else { '-' }))
        ,@('Durum', (Get-StatusText $last.status))
        ,@('Başlangıç', (ConvertTo-LocalTimeText $last.startTime))
        ,@('Bitiş', (ConvertTo-LocalTimeText $last.stopTime))
        ,@('Süre', (Format-Duration $last.duration))
        ,@('Node', $(if ($last.executingNodeName) { $last.executingNodeName } else { '-' }))
    )
    $text = if ($details.Count) { "**Detay:**`n" + ($details -join "`n") } else { '' }
    return New-TeamsMessage -Title "🔴 [$EnvName] Task başarısız: $($task.Name)" -Color 'Attention' -Facts $facts -Text $text -Links (Get-TaskLinks $task)
}

function New-RecoveryMessage($task) {
    $facts = @(
        ,@('Task', $task.Name)
        ,@('Uygulama', $(if ($task.AppName) { $task.AppName } else { '-' }))
        ,@('Bitiş', (ConvertTo-LocalTimeText $task.Last.stopTime))
        ,@('Süre', (Format-Duration $task.Last.duration))
    )
    return New-TeamsMessage -Title "🟢 [$EnvName] Task tekrar başarılı: $($task.Name)" -Color 'Good' -Facts $facts -Links (Get-TaskLinks $task)
}

function New-SummaryMessage($failedTasks) {
    $lines = @($failedTasks | ForEach-Object {
        '- **{0}** ({1}) — {2}' -f $_.Name, (Get-StatusText $_.Last.status), (ConvertTo-LocalTimeText $_.Last.stopTime)
    })
    $link = @()
    if ($QmcBaseUrl) { $link = @(,@("QMC'de task'lar", "$($QmcBaseUrl.TrimEnd('/'))/tasks")) }
    return New-TeamsMessage -Title "🔴 [$EnvName] $($failedTasks.Count) task başarısız" -Color 'Attention' -Text ($lines -join "`n") -Links $link
}

# --- Durum dosyası -----------------------------------------------------------------
function Read-State {
    $state = @{ Initialized = $false; Tasks = @{} }
    if ((Test-Path $StateFile) -and -not $ResetState) {
        try {
            $raw = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $state.Initialized = [bool]$raw.Initialized
            foreach ($e in @($raw.Tasks)) {
                if ($e.TaskId) { $state.Tasks[$e.TaskId] = @{ Key = $e.Key; Failing = [bool]$e.Failing; Name = $e.Name } }
            }
        } catch { Write-Log "State okunamadı, sıfırdan başlanıyor: $($_.Exception.Message)" 'WARN' }
    }
    return $state
}

function Save-State($state) {
    $entries = @($state.Tasks.GetEnumerator() | ForEach-Object {
        [ordered]@{ TaskId = $_.Key; Name = $_.Value.Name; Key = $_.Value.Key; Failing = $_.Value.Failing }
    })
    $obj = [ordered]@{ Initialized = $state.Initialized; SavedAt = (Get-Date).ToString('o'); Tasks = $entries }
    $tmp = "$StateFile.tmp"
    $obj | ConvertTo-Json -Depth 5 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item $tmp $StateFile -Force
}

# --- Ana kontrol döngüsü -------------------------------------------------------------
function Invoke-PollCycle($state) {
    $tasks = Get-QlikTasks
    $failures = New-Object System.Collections.Generic.List[object]
    $recoveries = New-Object System.Collections.Generic.List[object]

    foreach ($task in $tasks) {
        $last = $task.Last
        if (-not $last -or $null -eq $last.status) { continue }
        $status = [int]$last.status
        if ($FinalStatuses -notcontains $status) { continue }   # hâlâ çalışıyor / kuyrukta

        $key  = Get-ResultKey $last
        $prev = $state.Tasks[$task.Id]
        if ($prev -and $prev.Key -eq $key) { continue }         # bu çalışma zaten işlendi

        $isFail = $FailStatuses -contains $status
        $wasFailing = $prev -and $prev.Failing
        $entry = @{ Key = $key; Failing = $isFail; Name = $task.Name }

        if (-not $state.Initialized) {
            $state.Tasks[$task.Id] = $entry
            if ($isFail -and $cfg.AlertExistingFailuresOnStart) { $failures.Add($task) }
            continue
        }

        if ($isFail) {
            $failures.Add($task)
        } elseif ($status -eq 7 -and $wasFailing -and $cfg.NotifyOnRecovery) {
            $recoveries.Add($task)
        } else {
            $state.Tasks[$task.Id] = $entry
        }
    }

    # Bildirimler: başarılı gönderilenlerin durumu kaydedilir, gönderilemeyen bir sonraki turda tekrar denenir.
    if ($failures.Count -gt $MaxCards) {
        try {
            Send-Teams (New-SummaryMessage $failures)
            foreach ($t in $failures) { $state.Tasks[$t.Id] = @{ Key = (Get-ResultKey $t.Last); Failing = $true; Name = $t.Name } }
            Write-Log "$($failures.Count) başarısız task için özet bildirim gönderildi."
        } catch { Write-Log "Teams özet gönderilemedi: $($_.Exception.Message)" 'ERROR' }
    } else {
        foreach ($t in $failures) {
            try {
                Send-Teams (New-FailureMessage $t)
                $state.Tasks[$t.Id] = @{ Key = (Get-ResultKey $t.Last); Failing = $true; Name = $t.Name }
                Write-Log "FAIL bildirildi: $($t.Name) ($(Get-StatusText $t.Last.status))" 'WARN'
            } catch { Write-Log "Teams gönderilemedi ($($t.Name)): $($_.Exception.Message)" 'ERROR' }
        }
    }
    foreach ($t in $recoveries) {
        try {
            Send-Teams (New-RecoveryMessage $t)
            $state.Tasks[$t.Id] = @{ Key = (Get-ResultKey $t.Last); Failing = $false; Name = $t.Name }
            Write-Log "Düzelme bildirildi: $($t.Name)"
        } catch { Write-Log "Teams gönderilemedi ($($t.Name)): $($_.Exception.Message)" 'ERROR' }
    }

    if (-not $state.Initialized) {
        $state.Initialized = $true
        $failingNow = @($state.Tasks.Values | Where-Object { $_.Failing }).Count
        Write-Log "İlk tarama tamam: $($tasks.Count) task kaydedildi ($failingNow tanesi şu an fail durumunda). Bundan sonraki fail'ler bildirilecek."
    }
    Save-State $state
    Write-Verbose "Tur tamam: $($tasks.Count) task, $($failures.Count) fail, $($recoveries.Count) düzelme."
}

# --- Giriş noktası -------------------------------------------------------------------
if ($TestNotification) {
    Send-Teams (New-TeamsMessage -Title "✅ [$EnvName] Qlik Task Monitor test mesajı" -Color 'Good' `
        -Facts @(@('Sunucu', $env:COMPUTERNAME), @('Zaman', (Get-Date -Format 'dd.MM.yyyy HH:mm:ss'))) `
        -Text 'Bu kartı görüyorsanız Teams bağlantısı çalışıyor.')
    Write-Log 'Test bildirimi gönderildi.'
    return
}

$script:Cert = Get-QlikCertificate
Write-Log "Başladı. QRS: $($cfg.QrsHost) | Sertifika: $($script:Cert.Subject) (bitiş $($script:Cert.NotAfter.ToString('dd.MM.yyyy'))) | Aralık: ${PollSeconds}sn"

$state = Read-State
$consecutiveErrors = 0
$connAlertSent = $false

while ($true) {
    try {
        Invoke-PollCycle $state
        if ($connAlertSent) {
            try {
                Send-Teams (New-TeamsMessage -Title "🟢 [$EnvName] QRS bağlantısı geri geldi" -Color 'Good' -Facts @(,@('Sunucu', $cfg.QrsHost)))
                $connAlertSent = $false
            } catch { Write-Log "Teams gönderilemedi: $($_.Exception.Message)" 'ERROR' }
        }
        $consecutiveErrors = 0
    } catch {
        $pollError = $_.Exception.Message
        $consecutiveErrors++
        Write-Log "Kontrol başarısız ($consecutiveErrors. kez): $pollError" 'ERROR'
        if ($consecutiveErrors -ge $ConnThreshold -and -not $connAlertSent) {
            try {
                Send-Teams (New-TeamsMessage -Title "⚠️ [$EnvName] Qlik task'ları izlenemiyor" -Color 'Warning' `
                    -Facts @(@('Sunucu', $cfg.QrsHost), @('Ardışık hata', $consecutiveErrors)) `
                    -Text "Son hata: $pollError")
                $connAlertSent = $true
            } catch { Write-Log "Teams gönderilemedi: $($_.Exception.Message)" 'ERROR' }
        }
    }
    if ($Once) { break }
    Start-Sleep -Seconds $PollSeconds
}
