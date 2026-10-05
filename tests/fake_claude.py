"""Stand-in for an interactive agent session (Claude Code, Codex, Copilot): turns on bracketed
paste like they do and appends every byte it receives to the log file given as the first
argument. FAKE_COMM renames the process, like Copilot's native binary ("MainThread")."""
import os
import sys
import tty

if os.environ.get("FAKE_COMM"):
    import ctypes

    ctypes.CDLL(None).prctl(15, os.environ["FAKE_COMM"].encode(), 0, 0, 0)  # PR_SET_NAME

log = sys.argv[1]
fd = sys.stdin.fileno()
tty.setraw(fd)
os.write(sys.stdout.fileno(), b"\x1b[?2004hfake claude ready\r\n")
with open(log, "ab", buffering=0) as f:
    while True:
        try:
            data = os.read(fd, 65536)
        except OSError:
            break
        if not data:
            break
        f.write(data)
