#!/usr/bin/env python3
"""Prepare a relocatable Cadence input snapshot on the software build host."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


def adapt_tb(text):
    for name in ['cycle_count', 'retire_inst_in_period']:
        text, count = re.subn(r'^reg\s+\[31:0\]\s+' + name + r'\s*;\s*$', '', text, flags=re.M)
        if count != 1:
            raise RuntimeError('Unsupported TB declaration: ' + name)
    if text.count('module tb();') != 1:
        raise RuntimeError('Unsupported TB module declaration')
    text = text.replace('module tb();', 'module tb();\nreg [31:0] cycle_count;\nreg [31:0] retire_inst_in_period;', 1)
    lines, depth, removed = [], 0, 0
    for line in text.splitlines(True):
        if line.strip() == '`ifndef NO_DUMP':
            if depth:
                raise RuntimeError('Nested NO_DUMP block')
            depth, removed = 1, removed + 1
            lines.append('// Delivery profile: waveform generation physically removed.\n')
            continue
        if depth:
            if re.match(r'\s*`ifn?def\b', line):
                depth += 1
            elif re.match(r'\s*`endif\b', line):
                depth -= 1
            continue
        lines.append(line)
    text = ''.join(lines)
    if removed != 1 or depth or re.search(r'\$(?:dump|fsdb|shm)', text):
        raise RuntimeError('Unsupported waveform block')
    return text


def make_filelist(bundle):
    headers = ['cpu/rtl', 'idu/rtl', 'dtu/rtl', 'lsu/rtl', 'mmu/rtl', 'tdt/rtl/top']
    lines = ['+incdir+../rtl/gen_rtl/' + p for p in headers]
    for rel in ['rtl/gen_rtl/filelists/C906_asic_rtl.fl',
                'rtl/gen_rtl/filelists/tdt_dmi_top_rtl.fl', 'rtl/logical/filelists/smart.fl']:
        text = re.sub(r'/\*.*?\*/', '', (bundle / rel).read_text(), flags=re.S)
        text = re.sub(r'//[^\n]*', '', text)
        text = text.replace('${CODE_BASE_PATH}/gen_rtl/', '../rtl/gen_rtl/').replace('../logical/', '../rtl/logical/')
        if '${' in text:
            raise RuntimeError('Unresolved filelist variable')
        lines.extend(line.strip() for line in text.splitlines() if line.strip())
    lines += ['+incdir+../rtl/logical/tb', 'tb-linux.v']
    for line in lines:
        if line.startswith('+libext+'):
            continue
        path = line.replace('-y ', '').replace('+incdir+', '')
        if not (bundle / 'sim' / path).exists():
            raise RuntimeError('Missing filelist input: ' + line)
    return '\n'.join(lines) + '\n'


def revision(path):
    return subprocess.check_output(['git', '-C', str(path), 'rev-parse', 'HEAD']).decode().strip()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--firmware-dir', required=True, type=Path)
    p.add_argument('--linux-dir', required=True, type=Path)
    p.add_argument('--dtb', required=True, type=Path)
    p.add_argument('--output', type=Path, help='new directory; existing destinations are preserved')
    p.add_argument('--cache', required=True, choices=['off', 'i', 'id', 'full'])
    p.add_argument('--profile', required=True, choices=['trim', 'baseline'])
    p.add_argument('--diag', required=True, choices=['none', 'early', 'hang', 'trap'])
    args = p.parse_args()
    base = ROOT / 'output/cadence'
    base.mkdir(parents=True, exist_ok=True)
    if args.output:
        bundle = args.output.absolute()
        if bundle.exists() or bundle.is_symlink():
            p.error('Output exists; select a new LINUXCPU_CADENCE_OUTPUT to preserve prior results')
    else:
        delivery = tempfile.mkdtemp(prefix=datetime.now().strftime('%Y%m%d-%H%M%S-'), dir=str(base))
        bundle = Path(delivery) / 'linuxcpu-cadence'
    archive = bundle.with_name(bundle.name + '.tar.gz')
    if archive.exists() or archive.with_name(archive.name + '.sha256').exists():
        p.error('Archive destination already exists')
    # Validate configuration stamps before creating a snapshot.
    for name, expected in [('cache-mode', args.cache), ('diag-test', args.diag)]:
        if (args.firmware_dir / name).read_text().strip() != expected:
            p.error('Firmware configuration mismatch: ' + name)
    bundle.mkdir(parents=True)
    for src, dst in [('openc906/C906_RTL_FACTORY/gen_rtl', 'rtl/gen_rtl'),
                     ('openc906/smart_run/logical', 'rtl/logical')]:
        shutil.copytree(str(ROOT / src), str(bundle / dst))
    firmware = bundle / 'firmware'
    firmware.mkdir()
    for name in ['fw_payload.bin', 'fw_payload.elf']:
        shutil.copy2(str(args.firmware_dir / 'platform/generic/firmware' / name), str(firmware / name))
    for src, name in [(args.linux_dir / 'vmlinux', 'vmlinux'),
                      (args.linux_dir / '.config', 'linux.config'), (args.dtb, args.dtb.name)]:
        shutil.copy2(str(src), str(firmware / name))
    subprocess.check_call([sys.executable, str(ROOT / 'scripts/prepare-rtl-image.py'),
        '--image', str(firmware / 'fw_payload.bin'), '--tb', str(ROOT / 'openc906/smart_run/logical/tb/tb.v'),
        '--output', str(bundle / 'sim')])
    # Apply the maintained project patch to the copied RTL, never the checkout.
    patch = ROOT / 'patches/openc906/0001-mark-smart-run-uart-device.patch'
    subprocess.check_call(['patch', '--batch', '--forward', '-p3', '-i', str(patch)],
                          cwd=str(bundle / 'rtl/gen_rtl'))
    tb = bundle / 'sim/tb-linux.v'
    tb.write_text(adapt_tb(tb.read_text()))
    (bundle / 'sim/filelist.f').write_text(make_filelist(bundle))
    for name in ['cadence.py', 'README.md']:
        shutil.copy2(str(HERE / name), str(bundle / name))
    shutil.copy2(str(ROOT / 'openc906/LICENSE'), str(bundle / 'RTL-LICENSE'))
    provenance = dict(project_commit=revision(ROOT),
        project_dirty=bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=str(ROOT))),
        upstream={name: revision(ROOT / name) for name in ['openc906', 'linux', 'opensbi']},
        cache=args.cache, linux_profile=args.profile, diag_test=args.diag, fast_uart=False,
        simulator='Cadence Incisive 15.20-p001, 64-bit',
        reference_validation='User verified full-cache/trim on CentOS 7.9: PID 1 in 51 minutes (2026-09-08).',
        snapshot_validation='New snapshot; validate after software or RTL changes.')
    (bundle / 'provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
    hashes = {str(f.relative_to(bundle)): hashlib.sha256(f.read_bytes()).hexdigest()
              for f in sorted(bundle.rglob('*')) if f.is_file()}
    (bundle / 'manifest.json').write_text(json.dumps(hashes, indent=2) + '\n')
    with tarfile.open(str(archive), 'w:gz') as tar:
        tar.add(str(bundle), arcname=bundle.name)
    archive.with_name(archive.name + '.sha256').write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + '  ' + archive.name + '\n')
    latest = base / 'latest'
    if latest.exists() and not latest.is_symlink():
        raise RuntimeError('Preserving non-symlink output/cadence/latest; package is at ' + str(bundle))
    # Atomic pointer update; earlier bundles and their simulation results remain intact.
    with tempfile.TemporaryDirectory(dir=str(base)) as tmp:
        link = Path(tmp) / 'latest'
        link.symlink_to(bundle, target_is_directory=True)
        link.replace(latest)
    print('[cadence-package] bundle: ' + str(bundle))
    print('[cadence-package] archive: {} ({} bytes)'.format(archive, archive.stat().st_size))


if __name__ == '__main__':
    main()
