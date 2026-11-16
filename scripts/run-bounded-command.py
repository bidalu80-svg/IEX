#!/usr/bin/env python3
"""Bound a subprocess tree; preserve its exit status and never infer success."""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import sys


def run(command, timeout, log):
    output = Path(log).open("w") if log else None
    process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT if output else None,
                               start_new_session=True)

    def stop():
        # Kill the group even if its leader exited: tools may leave helpers.
        for sig, grace in [(signal.SIGTERM, 3), (signal.SIGKILL, 3)]:
            try:
                os.killpg(process.pid, sig)
            except ProcessLookupError:
                break
            try:
                process.wait(timeout=grace)
            except subprocess.TimeoutExpired:
                pass

    def interrupted(signum, _frame):
        stop()
        raise SystemExit(128 + signum)

    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, interrupted)
    try:
        try:
            result = process.wait(timeout=timeout)
            if result:
                print(f"ERROR: command exited {result}: {command!r}", file=sys.stderr, flush=True)
            return result if result >= 0 else 128 - result
        except subprocess.TimeoutExpired:
            print(f"ERROR: command exceeded {timeout}s: {command!r}", file=sys.stderr, flush=True)
            stop()
            return 124
    finally:
        if output:
            output.close()
            # Cap untimed console output; retain the entire file as evidence.
            with Path(log).open("rb") as logged:
                logged.seek(0, os.SEEK_END)
                logged.seek(max(0, logged.tell() - 64 * 1024))
                print(logged.read(64 * 1024).decode(errors="replace"), end="", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("--log")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if args.timeout <= 0 or not command:
        parser.error("positive timeout and command required")
    return run(command, args.timeout, args.log)


if __name__ == "__main__":
    sys.exit(main())
