"""Stand-in for an interactive Claude Code session: turns on bracketed paste like Claude
does and appends every byte it receives to the log file given as the first argument."""
import os
import sys
import tty

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
