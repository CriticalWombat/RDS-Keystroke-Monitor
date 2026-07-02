import json
import logging
import os
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


def handle_logon(d):
    parts = []
    for key, label, fmt in LOGON_FIELDS:
        val = d.get(key)
        if val not in (None, "", False) or key == "is_admin":
            parts.append(f"{label}=" + (fmt % val))
    line = f"[{d.get('timestamp', '')}] LOGON         " + "  ".join(parts)
    logging.info("LOGON         " + "  ".join(parts))
    write_user_log(d.get("username", "unknown"), line)


def handle_window_change(d):
    user    = d.get("username", "unknown")
    process = d.get("process")  or "unknown"   # null when Get-Process fails client-side
    title   = d.get("window_title", "")
    ts      = d.get("timestamp", "")
    line    = f"[{ts}] WINDOW_CHANGE  Process={process:<20s}  Title={title}"
    logging.info("WINDOW_CHANGE  User=%-20s Process=%-20s Title=%s", user, process, title)
    write_user_log(user, line)


def handle_keystrokes(d):
    user       = d.get("username",   "unknown")
    window     = d.get("window")  or ""
    keystrokes = (d.get("keystrokes") or "").replace("\n", "[ENTER]").replace("\r", "")
    ts         = d.get("timestamp",  "")
    pid        = d.get("pid", "?")
    seq        = d.get("seq", "?")
    line       = f"[{ts}] KEYSTROKES    pid={pid} seq={seq}  Window={window}  Keys={keystrokes}"
    logging.info("KEYSTROKES     User=%-20s pid=%s seq=%s Window=%s", user, pid, seq, window)
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
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logging.info("Stopped.")
