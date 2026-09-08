#!/usr/bin/env python3
"""Bounded local tests using a fake irun, not a hardware/performance test."""
import ast
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
source = (HERE / 'cadence.py').read_text()
ast.parse(source, feature_version=(3, 6))
with tempfile.TemporaryDirectory(prefix='cadence-runner-test-', dir=str(HERE)) as tmp:
    root = Path(tmp)
    (root / 'sim').mkdir()
    shutil.copy2(str(HERE / 'cadence.py'), str(root / 'cadence.py'))
    (root / 'manifest.json').write_text(json.dumps({'cadence.py': hashlib.sha256(source.encode()).hexdigest()}))
    fake = root / 'irun'
    fake.write_text('''#!/usr/bin/env python3
import os, sys, time, resource
assert resource.getrlimit(resource.RLIMIT_CORE) == (0, 0)
assert resource.getrlimit(resource.RLIMIT_FSIZE)[0] == 256*1024*1024
assert os.isatty(1)
assert '-notimingcheck' not in sys.argv
if '-elaborate' in sys.argv:
    assert sys.argv[sys.argv.index('-default_ext')+1] == 'verilog'
mode = os.environ.get('FAKE_MODE', 'normal')
if '-elaborate' in sys.argv:
    if mode == 'compile-error':
        print('ncelab: *E,TEST: mock error', flush=True)
        sys.exit(0)
    sys.exit(0)
if mode == 'fatal':
    print('[fatal-diag] complete kind=trap', flush=True)
elif mode == 'early-exit':
    sys.exit(0)
elif mode == 'pid1':
    for b in b'linuxCPU: PID 1 is alive on OpenC906 RTL':
        print('[uart-diag] THR write #1 addr=0 data=%02x' % b, flush=True)
elif mode == 'log-limit':
    for i in range(300):
        print('x'*8192, flush=True)
else:
    for n in range(1, 4):
        print('[linux-diag] retired=%d pc=0x0 cycles=%d mhcr=0x17f' % (n*10000, n*50000), flush=True)
        time.sleep(.03)
time.sleep(5)
''')
    fake.chmod(0o755)

    def call(action, expected, mode='normal', extra=()):
        env = os.environ.copy()
        env['FAKE_MODE'] = mode
        result = subprocess.run([sys.executable, str(root / 'cadence.py'), action,
            '--irun', str(fake), '--timeout', '.4', '--free-mib', '1'] + list(extra),
            env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=6)
        assert result.returncode == expected, result.stdout[-3000:]
        print('PASS:', action, mode, expected)

    call('check', 0)
    call('build', 1, 'compile-error')
    assert not (root / 'work/build-ok.json').exists()
    call('build', 0)
    call('probe', 124)
    report = json.loads((root / 'work/probe.json').read_text())
    assert report['retired'] == 30000 and report['mhcr'] == 0x17f
    assert report['sampled_retired_per_hour'] > 0
    call('run', 1, 'fatal')
    call('run', 1, 'early-exit')
    call('run', 0, 'pid1')
    call('run', 2, 'log-limit', ['--log-mib', '1'])
    assert (root / 'work/run.log').stat().st_size <= 1024*1024
    call('probe', 2, extra=['--free-mib', '999999999'])
print('Python 3.6 grammar and launcher tests passed.')
