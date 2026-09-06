#!/usr/bin/env python3
"""Run a bounded Verilator boot probe and emit machine-readable speed metrics."""

from __future__ import annotations

from argparse import ArgumentParser
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
import platform
from pathlib import Path
import re
import select
import shutil
import signal
import subprocess
import time


RETIRED = re.compile(rb"\[linux-diag\] retired=([0-9]+)\b")
FAILURE = re.compile(rb"(?:%Error|\* Error:|\[linux-diag\] stalled after)")
SCHED_FIELDS = {
    "nr_switches": "context_switches",
    "nr_voluntary_switches": "voluntary_switches",
    "nr_involuntary_switches": "involuntary_switches",
    "se.nr_migrations": "migrations",
    "nr_migrations": "migrations",
}


@dataclass
class ProcessMetrics:
    cpu_seconds: float = 0.0
    context_switches: int = 0
    voluntary_switches: int = 0
    involuntary_switches: int = 0
    migrations: int = 0


def parse_cpu_list(value: str) -> set[int]:
    result: set[int] = set()
    for item in value.split(","):
        bounds = item.strip().split("-", 1)
        if len(bounds) == 1:
            result.add(int(bounds[0]))
        else:
            start, end = map(int, bounds)
            if end < start:
                raise ValueError(f"invalid CPU range: {item}")
            result.update(range(start, end + 1))
    if not result:
        raise ValueError("CPU list is empty")
    return result


def read_task_metrics(pid: int) -> tuple[ProcessMetrics, set[int], int]:
    total = ProcessMetrics()
    processors: set[int] = set()
    task_dir = Path(f"/proc/{pid}/task")
    try:
        tids = list(task_dir.iterdir())
    except (FileNotFoundError, PermissionError):
        return total, processors, 0
    for task in tids:
        values: dict[str, float] = {}
        try:
            for line in (task / "sched").read_text().splitlines():
                if ":" not in line:
                    continue
                key, raw = (part.strip() for part in line.split(":", 1))
                if key in SCHED_FIELDS:
                    values[SCHED_FIELDS[key]] = float(raw.split()[0])
            stat_fields = (task / "stat").read_text().split()
            processors.add(int(stat_fields[38]))
        except (FileNotFoundError, PermissionError, ValueError, IndexError):
            continue
        # /proc/<pid>/sched accounting is less consistent across kernels and
        # virtualized hosts.  The stat fields are USER_HZ ticks and portable.
        total.cpu_seconds += (
            int(stat_fields[13]) + int(stat_fields[14])
        ) / os.sysconf("SC_CLK_TCK")
        total.context_switches += int(values.get("context_switches", 0))
        total.voluntary_switches += int(values.get("voluntary_switches", 0))
        total.involuntary_switches += int(values.get("involuntary_switches", 0))
        total.migrations += int(values.get("migrations", 0))
    return total, processors, len(tids)


def stop_process_group(proc: subprocess.Popen[bytes]) -> None:
    if proc.poll() is not None:
        return
    os.killpg(proc.pid, signal.SIGTERM)
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait()


def sha256_file(path: Path) -> str | None:
    if not path.is_file():
        return None
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def command_output(command: list[str], cwd: Path) -> str | None:
    try:
        return subprocess.run(
            command,
            cwd=cwd,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def main() -> int:
    parser = ArgumentParser()
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--model-arg", action="append", default=[])
    parser.add_argument("--cwd", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--label", default="probe")
    parser.add_argument("--duration", type=float, default=120.0)
    parser.add_argument("--warmup", type=float, default=10.0)
    parser.add_argument("--cpus", help="Linux CPU list, for example 2 or 2,4-6")
    parser.add_argument("--min-retired", type=int, default=10_000)
    args = parser.parse_args()
    if args.duration <= 0 or args.warmup < 0 or args.warmup >= args.duration:
        parser.error("require duration > warmup >= 0")

    allowed = os.sched_getaffinity(0)
    cpus = parse_cpu_list(args.cpus) if args.cpus else set(allowed)
    if not cpus <= allowed:
        parser.error(f"CPUs {sorted(cpus - allowed)} are outside current affinity")
    args.model = args.model.resolve()
    args.cwd = args.cwd.resolve()
    if not args.model.is_file():
        parser.error(f"model not found: {args.model}")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    log_path = args.output_dir / f"{args.label}.log"
    json_path = args.output_dir / f"{args.label}.json"
    command = [os.fspath(args.model), *args.model_arg]
    if shutil.which("stdbuf"):
        command = ["stdbuf", "-o0", "-e0", *command]

    def configure_child() -> None:
        os.setsid()
        os.sched_setaffinity(0, cpus)

    started_at = datetime.now(timezone.utc).isoformat()
    start = time.monotonic()
    proc = subprocess.Popen(
        command,
        cwd=args.cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        bufsize=0,
        preexec_fn=configure_child,
    )
    assert proc.stdout is not None
    samples: list[tuple[float, int]] = []
    failure_lines: list[str] = []
    observed_cpus: set[int] = set()
    peak_threads = 0
    last_metrics = ProcessMetrics()
    buffer = b""
    deadline = start + args.duration
    ended_early = False
    early_returncode: int | None = None
    with log_path.open("wb") as log:
        try:
            while time.monotonic() < deadline and proc.poll() is None:
                ready, _, _ = select.select([proc.stdout], [], [], 0.25)
                now = time.monotonic()
                metrics, processors, threads = read_task_metrics(proc.pid)
                if threads:
                    last_metrics = metrics
                    observed_cpus.update(processors)
                    peak_threads = max(peak_threads, threads)
                if not ready:
                    continue
                chunk = os.read(proc.stdout.fileno(), 65536)
                if not chunk:
                    break
                log.write(chunk)
                buffer += chunk
                lines = buffer.split(b"\n")
                buffer = lines.pop()
                for line in lines:
                    match = RETIRED.search(line)
                    if match:
                        samples.append((now - start, int(match.group(1))))
                    if FAILURE.search(line) and len(failure_lines) < 10:
                        failure_lines.append(line.decode("utf-8", errors="replace"))
        finally:
            early_returncode = proc.poll()
            ended_early = early_returncode is not None and time.monotonic() < deadline
            stop_process_group(proc)
            if buffer:
                log.write(buffer)

    elapsed = time.monotonic() - start
    stable = [sample for sample in samples if sample[0] >= args.warmup]
    if len(stable) >= 2:
        stable_rate = (stable[-1][1] - stable[0][1]) / (stable[-1][0] - stable[0][0])
    else:
        stable_rate = None
    max_retired = max((value for _, value in samples), default=0)
    project_root = Path(__file__).resolve().parent.parent
    build_info_path = args.model.with_name(args.model.name + ".build-info")
    firmware_path = project_root / "output/opensbi-c906/platform/generic/firmware/fw_payload.bin"
    cpu_model = None
    try:
        cpu_model = next(
            line.split(":", 1)[1].strip()
            for line in Path("/proc/cpuinfo").read_text().splitlines()
            if line.startswith("model name")
        )
    except (FileNotFoundError, StopIteration, IndexError):
        pass
    summary = {
        "schema_version": 2,
        "started_at_utc": started_at,
        "label": args.label,
        "model": str(args.model.resolve()),
        "model_args": args.model_arg,
        "model_threads": None,
        "model_sha256": sha256_file(args.model),
        "build_info": build_info_path.read_text().strip()
        if build_info_path.is_file()
        else None,
        "firmware_sha256": sha256_file(firmware_path),
        "project_commit": command_output(["git", "rev-parse", "HEAD"], project_root),
        "project_dirty": bool(command_output(["git", "status", "--porcelain"], project_root)),
        "host": {
            "platform": platform.platform(),
            "cpu_model": cpu_model,
            "logical_cpus": os.cpu_count(),
        },
        "affinity_cpus": sorted(cpus),
        "duration_requested_seconds": args.duration,
        "elapsed_seconds": elapsed,
        "warmup_seconds": args.warmup,
        "max_retired": max_retired,
        "retired_per_wall_second_total": max_retired / elapsed,
        "retired_per_wall_second_stable": stable_rate,
        "sample_count": len(samples),
        "peak_host_threads": peak_threads,
        "observed_host_cpus": sorted(observed_cpus),
        "process": asdict(last_metrics),
        "model_exit_code_before_stop": early_returncode if ended_early else None,
        "failure_lines": failure_lines,
        "log": str(log_path.resolve()),
        "pass": not failure_lines and max_retired >= args.min_retired and (
            not ended_early or early_returncode == 0
        ),
    }
    model_thread_match = re.search(r"-t([0-9]+)$", args.model.name)
    summary["model_threads"] = int(model_thread_match.group(1)) if model_thread_match else 1
    json_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")

    rate_text = "n/a" if stable_rate is None else f"{stable_rate:.1f}"
    print(
        f"[perf-smoke] {args.label}: retired={max_retired} "
        f"stable_retired/s={rate_text} elapsed={elapsed:.2f}s "
        f"threads={peak_threads} migrations={last_metrics.migrations}"
    )
    print(f"[perf-smoke] result: {json_path}")
    return 0 if summary["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
