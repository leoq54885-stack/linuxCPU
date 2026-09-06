#!/usr/bin/env python3
"""Run the Verilated OpenC906 model and stop when the PID 1 marker appears."""

from pathlib import Path
import argparse
import os
import re
import select
import shutil
import subprocess
import sys
import time


SUCCESS = b"linuxCPU: PID 1 is alive on OpenC906 RTL"
UART_THR_WRITE = re.compile(
    rb"\[uart-diag\] THR write #[0-9]+ .*?\bdata=([0-9a-fA-F]{2})\b"
)
RETIRED_PROGRESS = re.compile(rb"\[linux-diag\] retired=([0-9]+)\b")


def extract_uart_bytes(buffer: bytes, chunk: bytes) -> tuple[bytes, bytes]:
    """Return complete THR bytes plus the trailing incomplete output line."""
    lines = (buffer + chunk).split(b"\n")
    trailing = lines.pop()
    uart = bytearray()
    for line in lines:
        match = UART_THR_WRITE.search(line)
        if match:
            uart.append(int(match.group(1), 16))
    return trailing[-4096:], bytes(uart)


def extract_retired(buffer: bytes, chunk: bytes) -> tuple[bytes, list[int]]:
    """Return retirement counters from complete output lines."""
    lines = (buffer + chunk).split(b"\n")
    trailing = lines.pop()
    values = []
    for line in lines:
        match = RETIRED_PROGRESS.search(line)
        if match:
            values.append(int(match.group(1)))
    return trailing[-4096:], values


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--cwd", required=True, type=Path)
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--timeout", required=True, type=int)
    args = parser.parse_args()
    if args.timeout < 0:
        parser.error("--timeout must be >= 0 (0 disables the host-side timeout)")
    args.model = args.model.resolve()
    args.cwd = args.cwd.resolve()
    args.log = args.log.resolve()

    args.log.parent.mkdir(parents=True, exist_ok=True)
    deadline = None if args.timeout == 0 else time.monotonic() + args.timeout
    found = False
    command = [os.fspath(args.model)]
    if shutil.which("stdbuf"):
        command = ["stdbuf", "-o0", "-e0", *command]
    proc = subprocess.Popen(
        command,
        cwd=args.cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        bufsize=0,
    )
    assert proc.stdout is not None
    started = time.monotonic()
    try:
        recent = b""
        uart_recent = b""
        line_buffer = b""
        progress_buffer = b""
        last_progress: tuple[float, int] | None = None
        with args.log.open("wb") as log:
            while deadline is None or time.monotonic() < deadline:
                wait_seconds = 1.0
                if deadline is not None:
                    wait_seconds = min(
                        wait_seconds, max(0.0, deadline - time.monotonic())
                    )
                ready, _, _ = select.select(
                    [proc.stdout], [], [], wait_seconds
                )
                if not ready:
                    if proc.poll() is not None:
                        break
                    continue
                chunk = os.read(proc.stdout.fileno(), 4096)
                if not chunk:
                    break
                log.write(chunk)
                log.flush()
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()
                recent = (recent + chunk)[-2 * len(SUCCESS) :]
                line_buffer, uart = extract_uart_bytes(line_buffer, chunk)
                progress_buffer, retired_values = extract_retired(
                    progress_buffer, chunk
                )
                uart_recent = (uart_recent + uart)[-2 * len(SUCCESS) :]
                now = time.monotonic()
                for retired in retired_values:
                    if retired < 10_000:
                        continue
                    total_seconds = now - started
                    overall_rate = retired / total_seconds
                    window_text = "n/a"
                    if last_progress is not None and now > last_progress[0]:
                        window_rate = (retired - last_progress[1]) / (
                            now - last_progress[0]
                        )
                        window_text = f"{window_rate:.1f}"
                    print(
                        f"[rtl-speed] retired={retired} elapsed={total_seconds:.1f}s "
                        f"window_retired/s={window_text} "
                        f"overall_retired/s={overall_rate:.1f}",
                        file=sys.stderr,
                        flush=True,
                    )
                    last_progress = (now, retired)
                if SUCCESS in recent or SUCCESS in uart_recent:
                    found = True
                    break
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()

    if found:
        print("[rtl-linux] PASS: Linux reached the project PID 1 marker")
        return 0
    if deadline is not None and time.monotonic() >= deadline:
        print(f"[rtl-linux] timeout after {args.timeout}s; see {args.log}", file=sys.stderr)
        return 124
    print(f"[rtl-linux] model exited before the PID 1 marker; see {args.log}", file=sys.stderr)
    return proc.returncode or 1


if __name__ == "__main__":
    raise SystemExit(main())
