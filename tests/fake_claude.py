"""Stand-in for an interactive agent session (Claude Code, Codex, Copilot): turns on bracketed
paste like they do and appends every byte it receives to the log file given as the first
argument. FAKE_COMM renames the process, like Copilot's native binary ("MainThread").
FAKE_DIALOG first shows a startup screen that waits for Enter (like a trust dialog) and drops
whatever else it receives. FAKE_REGISTRY=<dir> then registers the session there the way Claude
Code does once its prompt is up."""
import json
import os
import sys
import tty

if os.environ.get("FAKE_COMM"):
    import ctypes

    ctypes.CDLL(None).prctl(15, os.environ["FAKE_COMM"].encode(), 0, 0, 0)  # PR_SET_NAME

log = sys.argv[1]
fd = sys.stdin.fileno()
tty.setraw(fd)
if os.environ.get("FAKE_DIALOG"):
    os.write(sys.stdout.fileno(), b"\x1b[?2004hTrust this folder?\r\n  Enter to confirm\r\n")
    while b"\r" not in os.read(fd, 65536):
        pass
    os.write(sys.stdout.fileno(), b"\x1b[2J\x1b[H")
os.write(sys.stdout.fileno(), b"\x1b[?2004hfake claude ready\r\n")
if os.environ.get("FAKE_REGISTRY"):
    entry = {"pid": os.getpid(), "cwd": os.getcwd(), "name": "launched", "status": "idle", "kind": "interactive"}
    with open(os.path.join(os.environ["FAKE_REGISTRY"], "%d.json" % os.getpid()), "w") as f:
        json.dump(entry, f)
with open(log, "ab", buffering=0) as f:
    while True:
        try:
            data = os.read(fd, 65536)
        except OSError:
            break
        if not data:
            break
        f.write(data)
