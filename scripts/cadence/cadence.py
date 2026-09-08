#!/usr/bin/env python3
"""Python 3.6+ Incisive launcher; no third-party Python dependencies."""
import argparse
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pty
import re
import resource
import select
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent
SUCCESS = b'linuxCPU: PID 1 is alive on OpenC906 RTL'


def verify():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    for name, expected in manifest.items():
        p = ROOT / name
        if not p.is_file() or hashlib.sha256(p.read_bytes()).hexdigest() != expected:
            raise RuntimeError('Input missing or changed: ' + name)
    print('[check] {} files verified'.format(len(manifest)), flush=True)


def usage_bytes(path):
    total = 0
    for base, dirs, files in os.walk(str(path), followlinks=False):
        for name in files:
            try:
                total += os.lstat(os.path.join(base, name)).st_size
            except FileNotFoundError:
                pass
    return total


def run(args):
    verify()
    if args.action == 'check':
        return 0
    irun = shutil.which(args.irun)
    if not irun:
        raise RuntimeError('irun not found; source the Cadence environment first')
    work = ROOT / 'work'
    work.mkdir(exist_ok=True)
    lock = (work / 'runner.lock').open('w')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise RuntimeError('Another runner is active in this bundle')
    (work / 'tmp').mkdir(exist_ok=True)
    built = work / 'build-ok.json'
    identity = hashlib.sha256((ROOT / 'manifest.json').read_bytes()).hexdigest()
    if args.action != 'build':
        if not built.exists() or json.loads(built.read_text()).get('manifest') != identity:
            raise RuntimeError('Run build successfully before probe/run')
    elif built.exists():
        built.unlink()  # Success stamp only; compiled libraries are preserved.
    command = [irun, '-64bit', '-nclibdirname', '../work/INCA_libs', '-nohistory', '-nolog']
    if args.action == 'build':
        command += ['-elaborate', '-top', 'tb', '+v2k', '-sysv', '+sv',
                    '-default_ext', 'verilog',
                    '-timescale', '1ns/100fs', '+define+NC_SIM', '+define+IVERILOG_SIM',
                    '+define+iverilog=1', '+define+NO_DUMP', '+define+no_warning',
                    '+define+TSMC_NO_WARNING', '-f', 'filelist.f']
        if args.access_read:
            command += ['-access', '+r']
    else:
        command += ['-R']
    timeout = args.timeout if args.timeout is not None else (600 if args.action == 'build' else 120)
    file_cap = args.file_mib * 1024 * 1024
    dir_cap = args.dir_mib * 1024 * 1024
    log_cap = args.log_mib * 1024 * 1024
    free_min = args.free_mib * 1024 * 1024

    def safety():
        if usage_bytes(ROOT) >= dir_cap:
            return 'bundle directory size limit'
        if shutil.disk_usage(str(ROOT)).free < free_min:
            return 'guest filesystem free-space floor'
        return None

    reason = safety()
    if reason:
        raise RuntimeError(reason)
    env = os.environ.copy()
    env['TMPDIR'] = str(work / 'tmp')
    env['TMP'] = env['TMPDIR']
    env['TEMP'] = env['TMPDIR']

    def child_limits():
        os.setsid()
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        old = resource.getrlimit(resource.RLIMIT_FSIZE)[1]
        cap = file_cap if old == resource.RLIM_INFINITY else min(file_cap, old)
        resource.setrlimit(resource.RLIMIT_FSIZE, (cap, cap))

    logpath = work / (args.action + '.log')
    print('[cadence] cwd={} command={}'.format(ROOT / 'sim', ' '.join(command)), flush=True)
    print('[cadence] timeout={}s; log={}'.format(timeout, logpath), flush=True)
    master, slave = pty.openpty()
    started = time.monotonic()
    proc = None
    reason, status = None, 1
    tail, partial, uart = b'', b'', b''
    retired, cycles, mhcr, log_size = 0, 0, None, 0
    first_sample, last_sample = None, None
    next_safety = started
    eof = False
    log = logpath.open('wb')  # Replaces this action's previous log; no unbounded log rotation.
    try:
        proc = subprocess.Popen(command, cwd=str(ROOT / 'sim'), env=env,
                                stdin=subprocess.DEVNULL, stdout=slave, stderr=slave,
                                preexec_fn=child_limits, close_fds=True)
        os.close(slave)
        slave = None
        while True:
            now = time.monotonic()
            if now >= next_safety:
                reason = safety()
                next_safety = now + 1
                if reason:
                    status = 2
                    break
            if timeout and now - started >= timeout:
                reason, status = 'wall-clock timeout', 124
                break
            ready, _, _ = select.select([master], [], [], 0.2)
            if ready:
                try:
                    data = os.read(master, 65536)
                except OSError as exc:
                    if exc.errno != errno.EIO:
                        raise
                    data = b''
                if not data:
                    eof = True
                else:
                    remaining = max(0, log_cap - log_size)
                    log.write(data[:remaining])
                    log.flush()
                    log_size += len(data)
                    sys.stdout.buffer.write(data)
                    sys.stdout.buffer.flush()
                    tail = (tail + data)[-65536:]
                    partial += data
                    lines = partial.split(b'\n')
                    partial = lines.pop()[-65536:]
                    for line in lines:
                        m = re.search(rb'\[linux-diag\] retired=(\d+).*?cycles=(\d+)', line)
                        if m:
                            retired, cycles = int(m[1]), int(m[2])
                            last_sample = (now, retired, cycles)
                            if first_sample is None and retired >= 10000:
                                first_sample = last_sample
                        m = re.search(rb'mhcr=(?:0x)?([0-9a-fA-F]+)', line)
                        if m:
                            mhcr = int(m[1], 16)
                        m = re.search(rb'\[uart-diag\] THR write #\d+ .*?\bdata=([0-9a-fA-F]{2})\b', line)
                        if m:
                            uart = (uart + bytes([int(m[1], 16)]))[-4096:]
                    if re.search(rb'\[fatal-diag\] complete kind=|\[linux-diag\] stalled|(?:ncvlog|ncelab|ncsim|irun): \*[EF],|%Error|Simulation Fail|meeting max simulation time', tail):
                        reason, status = 'simulator/RTL/fatal diagnostic error', 1
                        break
                    if args.action != 'build' and (SUCCESS in tail or SUCCESS in uart):
                        reason, status = 'PID 1 marker observed', 0
                        break
                    if log_size >= log_cap:
                        reason, status = 'log size limit', 2
                        break
            if eof and proc.poll() is not None:
                status = proc.returncode
                if args.action != 'build' and status == 0:
                    status = 1
                reason = 'process exited ({}){}'.format(proc.returncode, '' if args.action == 'build' else ' before PID 1')
                break
    except KeyboardInterrupt:
        reason, status = 'interrupted', 130
    finally:
        if proc is not None:
            # Kill the entire owned group, including children surviving an irun exit.
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                pass
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()
        os.close(master)
        if slave is not None:
            os.close(slave)
        log.close()
    elapsed = time.monotonic() - started
    sample_rate = None
    if first_sample and last_sample and last_sample[0] > first_sample[0]:
        sample_rate = (last_sample[1] - first_sample[1]) * 3600 / (last_sample[0] - first_sample[0])
    report = dict(action=args.action, reason=reason, exit_status=status, wall_seconds=elapsed,
                  retired=retired, cycles=cycles, mhcr=mhcr,
                  sampled_retired_per_hour=sample_rate,
                  note='Sample interval excludes startup; short intervals can be noisy.')
    (work / (args.action + '.json')).write_text(json.dumps(report, indent=2) + '\n')
    if args.action == 'build' and status == 0:
        built.write_text(json.dumps(dict(manifest=identity, command=command), indent=2) + '\n')
    print('\n[cadence] ' + json.dumps(report, sort_keys=True), flush=True)
    return status


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=['check', 'build', 'probe', 'run'])
    p.add_argument('--irun', default='irun')
    p.add_argument('--timeout', type=float, help='seconds; 0 explicitly means unlimited wall time')
    p.add_argument('--access-read', action='store_true', help='build with read access only, if required')
    p.add_argument('--file-mib', type=int, default=256)
    p.add_argument('--dir-mib', type=int, default=2048)
    p.add_argument('--log-mib', type=int, default=32)
    p.add_argument('--free-mib', type=int, default=4096)
    args = p.parse_args()
    if (args.timeout is not None and (args.timeout < 0 or not args.timeout < float('inf'))) or min(args.file_mib, args.dir_mib, args.log_mib, args.free_mib) <= 0:
        p.error('limits must be positive; timeout may be zero')
    try:
        return run(args)
    except (RuntimeError, OSError, ValueError) as exc:
        print('[cadence] ERROR: ' + str(exc), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
