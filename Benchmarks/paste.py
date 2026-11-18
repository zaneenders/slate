#!/usr/bin/env python3
"""Time a single key and a key queued behind a 1 MiB bracketed paste in the starter.

Build with swift build -c release --product starter, then run python3 Benchmarks/paste.py.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import statistics
import struct
import subprocess
import termios
import time


def exchange(master, payload, marker):
    """Pump both sides of the pseudo-terminal until the response is visible."""
    pending = memoryview(payload)
    output = bytearray()
    start = time.monotonic()
    deadline = start + 30
    while marker not in output:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"Timed out waiting for {marker!r}")
        readable, writable, _ = select.select([master], [master] if pending else [], [], remaining)
        if writable:
            try:
                pending = pending[os.write(master, pending[:4096]):]
            except BlockingIOError:
                pass
        if readable:
            output.extend(os.read(master, 65536))
    if pending:
        raise RuntimeError("Response arrived before the request was sent")
    return 1000 * (time.monotonic() - start)


def measure(executable, paste):
    master, slave = pty.openpty()
    try:
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        os.set_blocking(master, False)
        with subprocess.Popen([executable], stdin=slave, stdout=slave, stderr=slave) as child:
            try:
                exchange(master, b"", b"Hello, Slate!")
                key_ms = exchange(master, b"@", b"@")
                paste_ms = exchange(master, paste, b"%")
                exchange(master, b"\x03", b"\x1b[?1049l")
                if child.wait(timeout=5) != 0:
                    raise RuntimeError("Starter exited with an error")
                return key_ms, paste_ms
            finally:
                if child.poll() is None:
                    child.kill()
    finally:
        os.close(slave)
        os.close(master)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", nargs="?", type=Path, default=Path(".build/release/starter"))
    parser.add_argument("--iterations", type=int, default=5)
    args = parser.parse_args()
    if args.iterations < 1:
        parser.error("--iterations must be positive")
    payload = b"\x1b[200~" + b"a" * 1048576 + b"\x1b[201~%"
    results = [measure(args.executable.resolve(), payload) for _ in range(args.iterations)]
    keys, pastes = zip(*results)
    print(json.dumps({"iterations": args.iterations, "single_key_median_ms": statistics.median(keys),
                      "paste_and_key_median_ms": statistics.median(pastes)}))
