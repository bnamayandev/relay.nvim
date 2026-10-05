"""Stand-in for the npm wrappers of Codex and Copilot (`node .../bin/codex`): runs the native
binary given as the remaining arguments on the same terminal and waits for it."""
import subprocess
import sys

sys.exit(subprocess.call(sys.argv[1:]))
