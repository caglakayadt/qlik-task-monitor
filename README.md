# Qlik Task Monitor

Watches Qlik Sense Enterprise (on-prem) tasks through the QRS API every minute and posts a Microsoft Teams card when a task fails.

**What it reports**
- 🔴 Task failed / errored / aborted, with the task, app, stream, duration, node, error details, and links to the QMC and the app
- 🟢 A task that had failed has succeeded again (`NotifyOnRecovery`)
- ⚠️ The QRS was unreachable N times in a row (the monitor itself has gone blind), and again when the connection comes back
- One summary card when many tasks fail in the same cycle (more than `MaxCardsPerCycle`)

On the first run the current state is recorded silently. Only failures **after** that are reported.

> The script's log lines and Teams cards are in Turkish. The original messages are quoted below where they matter, with a translation.

## Requirements
- Windows PowerShell 5.1 on the Qlik Sense server (the central node is recommended). Nothing to install.
- The Qlik service account (its certificate store holds the QlikClient certificate) **or** a `client.pfx` exported from the QMC
- A webhook in a Teams channel

## Installation, step by step

> You do **not** need to install PowerShell. Windows Server 2012 R2 and later ship with Windows PowerShell 5.1; you only check it.
> Try it on a test server first. Once it works, repeat the same steps on production.
> Install folder: **`C:\ProgramData\QlikTaskMonitor`**. ProgramData is hidden; type the path into File Explorer's address bar to open it.

Wherever the commands show `COMPANY\svc_qlik`, use the service account you find in step 1.

### Step 1 — Checks on the server
Connect to the server over Remote Desktop. Open Start → **Windows PowerShell** and run:

```powershell
$PSVersionTable.PSVersion                         # Major should be 5 (Minor 1)
hostname                                          # machine name → becomes QrsHost in the config
Test-NetConnection localhost -Port 4242           # should show TcpTestSucceeded : True (QRS API)
```

**Find the Qlik service account:** Start → `services.msc` → **Qlik Sense Repository Service** → double-click → **Log On** tab. The account shown there (e.g. `COMPANY\svc_qlik`) is the "service account" used below. Get its password from your system administrator.

### Step 2 — Create the Teams webhook (on your own computer)
1. In Teams, go to the channel that should receive the alerts (e.g. "Qlik Alerts").
2. Next to the channel name: `...` → **Workflows**.
3. Search for **webhook** and pick the **"Send webhook alerts to a channel"** template (its older name is *"Post to a channel when a webhook request is received"*).
4. Name the workflow → check that the connection gets a green tick → **Next** → choose the team and channel → **Add workflow**.
5. Copy the long URL shown on the last screen. You can find it later in Teams → Workflows app → the workflow → the *When a Teams webhook request is received* step. Treat this URL like a password.
6. Set **Who can trigger the flow?** on that trigger to **Anyone**. With the default ("Any user in my tenant") the script gets `401 Unauthorized`.

**If the template does not show up:**
- **With Power Automate:** [make.powerautomate.com](https://make.powerautomate.com) → *Create* → *Instant cloud flow* → trigger **"When a Teams webhook request is received"** → *Who can trigger*: **Anyone** → add **Apply to each** (input: `attachments`) → inside it **"Post card in a chat or channel"** (Post as: Flow bot, Post in: Channel, Adaptive Card: `content`) → the URL appears on the trigger once you save.
- **If the Workflows app is disabled:** company policy may block it. Channel → `...` → *Manage channel* → *Connectors* → **Incoming Webhook** (the legacy method; Microsoft is retiring it, but it accepts the same message format). If that is missing too, ask your Teams admin to enable Workflows.

### Step 3 — Files and folder permissions
Put these files in `C:\ProgramData\QlikTaskMonitor`: `QlikTaskMonitor.ps1`, `Install-QlikTaskMonitor.ps1`, `config.example.json`, `README.md`.

Run once in a PowerShell window opened **as Administrator**:
```powershell
# Let the service account write state.json and logs\ in this folder
icacls "C:\ProgramData\QlikTaskMonitor" /grant "COMPANY\svc_qlik:(OI)(CI)M"

# Remove the Windows block on downloaded / copied files
Get-ChildItem "C:\ProgramData\QlikTaskMonitor" | Unblock-File
```
`icacls` should print `Successfully processed 1 files`.

### Step 4 — Verify the webhook from the server
This step does not use the script. It only proves that the server can post to Teams.

In a normal PowerShell window, replace `'PASTE-URL-HERE'` below with the URL from step 2. **Keep the single quotes**, otherwise the `&` characters cause an error. Then paste and run the whole block:

```powershell
$url = 'PASTE-URL-HERE'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 1) Network access: should show TcpTestSucceeded : True
Test-NetConnection ([uri]$url).Host -Port 443

# 2) Test message
$body = '{"type":"message","attachments":[{"contentType":"application/vnd.microsoft.card.adaptive","content":{"type":"AdaptiveCard","version":"1.4","body":[{"type":"TextBlock","text":"Webhook test: the server can reach Teams","wrap":true}]}}]}'
Invoke-RestMethod -Uri $url -Method Post -ContentType 'application/json' -Body $body -UseBasicParsing
```

**Reading the result:**
| What you see | Meaning |
|---|---|
| No error, empty output, and "Webhook test..." appears in the channel | ✅ Done, go to step 5 |
| `TcpTestSucceeded : False`, or `Unable to connect` / timeout | The server has no outbound internet access. Ask the network team to allow `*.logic.azure.com:443` (and if needed `*.environment.api.powerplatform.com:443`). If a proxy is used, get its address; proxy support can be added to the script |
| `401` / `DirectApiAuthorizationRequired` | *Who can trigger* on the workflow is not **Anyone** → edit the workflow and change it |
| `400 Bad Request` | The URL may be cut off. It should end with `...&sig=...` |
| `202` with no error but no message | Check the error under Teams → Workflows → the workflow → *Run history* |
| `The request was aborted: Could not create SSL/TLS secure channel` | The `Tls12` line was not run; run the whole block again |

### Step 5 — Prepare config.json
Copy `config.example.json` to `config.json` in the same folder:
```powershell
Copy-Item "C:\ProgramData\QlikTaskMonitor\config.example.json" "C:\ProgramData\QlikTaskMonitor\config.json"
notepad "C:\ProgramData\QlikTaskMonitor\config.json"
```

Change these fields:

| Field | Value |
|---|---|
| `EnvironmentName` | Label shown on the cards: `TEST` or `PROD` |
| `QrsHost` | The `hostname` output from step 1 |
| `TeamsWebhookUrl` | The URL from step 2. Paste it between the two quotes and keep the comma at the end of the line |
| `QmcBaseUrl` | The address you open the QMC with, e.g. `https://qliksense.company.local/qmc` |
| `HubBaseUrl` | The root of the hub address, e.g. `https://qliksense.company.local` |

Example:
```json
"TeamsWebhookUrl": "https://xxxx.logic.azure.com:443/workflows/.../invoke?api-version=1&sp=...&sv=1.0&sig=...",
```
Leave the other fields as they are for now. Save and close.

The webhook URL can also be set in the `QLIK_MONITOR_TEAMS_WEBHOOK` environment variable instead of the config file.

### Step 6 — Open PowerShell as the service account
The script uses the service account's certificate, so test **as that account**:
```powershell
runas /user:COMPANY\svc_qlik powershell
```
Enter the password. In the **new** window, check that the certificate is there:
```powershell
Get-ChildItem Cert:\CurrentUser\My | Where-Object Subject -eq 'CN=QlikClient'
```
It should return one line. If it is empty you are in the wrong account (or switch to the `Pfx` method under "Authentication options" below).

> Domain service accounts lock after a few wrong passwords. If `runas` returns `1326: The user name or password is incorrect`, confirm the password before trying again; a locked Qlik service account can break the Qlik services.

### Step 7 — Teams test through the script
In the window from step 6:
```powershell
cd C:\ProgramData\QlikTaskMonitor
powershell -ExecutionPolicy Bypass -File .\QlikTaskMonitor.ps1 -TestNotification
```
A "✅ [TEST] Qlik Task Monitor test mesajı" (test message) card should appear in the channel. If step 4 worked, an error here comes from config.json.

### Step 8 — QRS test
In the same window:
```powershell
powershell -ExecutionPolicy Bypass -File .\QlikTaskMonitor.ps1 -Once -Verbose
```
Expected output: `İlk tarama tamam: N task kaydedildi ...` ("First scan done: N tasks recorded"). This first scan sends no alerts; it only records the current state. `state.json` and `logs\monitor.log` should now exist in the folder. Compare N with the task count in the QMC.

### Step 9 — End-to-end test with a real failure
1. In the hub, create an empty app named `Monitor_Test`. Put this single line in the Data load editor and save (it fails on purpose):
   ```
   LOAD * FROM [lib://MissingFolder/missing.qvd] (qvd);
   ```
2. In the window from step 6, start the monitor in continuous mode and keep the window open. `-Verbose` prints a `Tur tamam` ("cycle done") line every minute so you can see it is alive:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\QlikTaskMonitor.ps1 -Verbose
   ```
3. QMC → **Tasks** → create a reload task for `Monitor_Test` and **Start** it.
4. Within about a minute a 🔴 card should arrive in Teams.
5. Remove the line from the load script (empty script) and run the task again → a 🟢 "back to success" card should arrive.
6. Stop with `Ctrl+C`. You can then delete the test app and its task.

`-Once` checks a single time and exits. It will not catch a failure that happens after it has finished.

### Step 10 — Permanent install
Open a normal PowerShell (not the service account one) **as Administrator**:
```powershell
cd C:\ProgramData\QlikTaskMonitor
powershell -ExecutionPolicy Bypass -File .\Install-QlikTaskMonitor.ps1 -ServiceAccount 'COMPANY\svc_qlik'
```
Enter the service account's password when asked.

### Step 11 — Check that it runs
- Start → `taskschd.msc` → task **Qlik Task Monitor** → Status: *Running*.
- `C:\ProgramData\QlikTaskMonitor\logs\monitor.log` should contain a `Başladı. QRS: ...` ("Started") line.
- The task starts by itself when the server reboots.

To uninstall (PowerShell as Administrator):
```powershell
cd C:\ProgramData\QlikTaskMonitor
powershell -ExecutionPolicy Bypass -File .\Install-QlikTaskMonitor.ps1 -Uninstall
```

### Common errors
| Error in the log / on screen | Cause → fix |
|---|---|
| `The ampersand (&) character is not allowed` | The URL was typed without quotes → wrap it in single quotes, or only put it in config.json |
| `Config bulunamadı` (config not found) | `config.json` was not created, or you are in the wrong folder → step 5, the `cd` command |
| `Sertifika bulunamadı` (certificate not found) | The script is not running as the service account → step 6 |
| `Access to the path ... is denied` (state.json / logs) | The service account cannot write to the folder → `icacls` in step 3 |
| `Unable to connect` / timeout (QRS) | Wrong `QrsHost`, or port 4242 closed → step 1 |
| `403 Forbidden` (QRS) | The `X-Qlik-User` user lacks rights → keep `sa_repository` |
| `Teams gönderilemedi` (could not send to Teams) / timeout | No outbound internet from the server → step 4 |
| `running scripts is disabled` | Run it as `powershell -ExecutionPolicy Bypass -File ...` |
| `Invalid JSON primitive` / `ConvertFrom-Json` error on config.json | A missing quote or comma → check the URL line in Notepad |

## Installing on another server
- Install **once per Qlik site**, on the **central node**. The QRS already covers the tasks on every node; installing on two nodes of the same site sends every alert twice.
- Copy only the four files from step 3 plus your `config.json`. **Do not copy `state.json` or `logs\`.** A copied `state.json` skips the silent first scan, and every task that is failing at that moment gets alerted at once.
- In `config.json` change `EnvironmentName`, `QrsHost`, `QmcBaseUrl`, `HubBaseUrl`, and `TeamsWebhookUrl` if the new server should post to a different channel.
- Repeat steps 1, 3, 4 and 6 to 8: the service account, port, outbound access and certificate can differ per server. Then step 10.

## Authentication options
| `Auth.Mode` | When |
|---|---|
| `CertStore` (default) | The script runs as the Qlik service account and uses `CN=QlikClient` from `Cert:\CurrentUser\My` |
| `Pfx` | For another account or another machine. QMC → Certificates → Export (**Windows format**, not platform-independent PEM, private key included). The password can be kept in the `QLIK_MONITOR_PFX_PASSWORD` environment variable |

`UserDirectory=INTERNAL; UserId=sa_repository` gives the QRS calls full read access. For a narrower account, use one that can read tasks and apps.

`SkipServerCertValidation: true`: the Qlik-signed server certificate fails validation when the host name does not match, so this is on by default. Set it to `false` if the Qlik root CA is trusted and `QrsHost` matches the name on the certificate.

## Settings
| Field | Default | Description |
|---|---|---|
| `PollIntervalSeconds` | 60 | How often to check. Restart the scheduled task after changing any setting |
| `FailStatuses` | `[6, 8, 11]` | Statuses to alert on: 6 Aborted, 8 Failed, 11 Error. Add `9` to include Skipped |
| `NotifyOnRecovery` | true | Green card on the first success after a failure |
| `AlertExistingFailuresOnStart` | false | Also alert on tasks that are already failed at the first start |
| `ConnectionFailureThreshold` | 3 | Consecutive QRS errors before the "cannot monitor" warning |
| `MaxCardsPerCycle` | 5 | Above this many failures in one cycle, send one summary card |
| `IncludeExternalProgramTasks` | true | Also monitor external program tasks |
| `TaskNameInclude` / `TaskNameExclude` | empty | Regex filter on task names, e.g. `"^PROD_"` / `"TEST|DEMO"` |

Restart after a config change (PowerShell as Administrator):
```powershell
Stop-ScheduledTask -TaskName 'Qlik Task Monitor'
Start-ScheduledTask -TaskName 'Qlik Task Monitor'
```

The scheduled task fires at startup and every 5 minutes. That trigger does not restart a running monitor (a second instance is never started); it only brings it back if it has stopped.

## Files
- `state.json` — which task runs have already been reported. Delete it, or run with `-ResetState`, to repeat the silent first scan
- `logs\monitor.log` — rotated to `.old` above 10 MB

## Limitations
- Only each task's **latest** run is checked. If a task fails and then succeeds again between two checks (60 s), that failure is not seen; in practice reloads rarely finish that fast.
- The card does not include the script log; the error text comes from the QRS `details` field. For the full log use the task in the QMC → *Download script log*.
- With *Who can trigger* set to **Anyone**, anyone who has the webhook URL can post to the channel. Keep the URL only in `config.json`, which is excluded from git.
