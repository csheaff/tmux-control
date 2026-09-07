"""Numbered ASCII terminal fixture. Commands: history, stream, stop, quit.

Run only in a dedicated test tmux server. Rows deliberately avoid wide glyphs
and fit an 80-column pane, making row identity a stable pixel coordinate.
"""
import sys
import threading
import time

number = 0
stop = threading.Event()
worker = None


def row():
    global number
    number += 1
    print(f"\033[32mROW {number:06d}\033[0m | "
          "\033[34mfixed height colored output\033[0m | scroll trajectory", flush=True)


def stream():
    deadline = time.monotonic() + 7
    next_row = time.monotonic()
    while not stop.is_set() and time.monotonic() < deadline:
        row()
        next_row += 1 / 300
        stop.wait(max(0, next_row - time.monotonic()))


print("Scroll trace fixture ready: history, stream, stop, quit", flush=True)
for command in sys.stdin:
    stop.set()
    if worker:
        worker.join()
    command = command.strip()
    if command == "history":
        for _ in range(6000):
            row()
    elif command == "stream":
        stop.clear()
        worker = threading.Thread(target=stream)
        worker.start()
    elif command == "quit":
        break
stop.set()
if worker:
    worker.join()
