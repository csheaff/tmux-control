#!/usr/bin/env python3
"""A deterministic raw TUI and byte recorder for real tmux integration tests."""
import argparse
import os
import signal
import sys
import termios
import tty

parser = argparse.ArgumentParser()
parser.add_argument("--input-file", required=True)
parser.add_argument("--alternate", action="store_true")
args = parser.parse_args()
fd = sys.stdin.fileno()
original = termios.tcgetattr(fd)
tty.setraw(fd)


def paint(*_):
    sys.stdout.write("\x1b[H\x1b[2JPROBE READY\r\nUnicode: 世界 café e\u0301 😀\r\n")
    sys.stdout.write("\x1b[4;1H\x1b[32mInput recorder\x1b[0m\x1b[?25l")
    sys.stdout.flush()


try:
    if args.alternate:
        sys.stdout.write("\x1b[?1049h")
    sys.stdout.write("\x1b[?1002h\x1b[?1006h\x1b[?2004h\x1b[?1h")
    signal.signal(signal.SIGWINCH, paint)
    paint()
    with open(args.input_file, "ab", buffering=0) as received:
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            received.write(chunk)
finally:
    termios.tcsetattr(fd, termios.TCSANOW, original)
