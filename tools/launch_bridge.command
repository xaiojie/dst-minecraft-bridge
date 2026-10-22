#!/bin/zsh
set -eu
SCRIPT_DIR="${0:A:h}"
exec /usr/bin/arch -arm64 /usr/bin/python3 -B "$SCRIPT_DIR/launch_bridge.py" "$@"
