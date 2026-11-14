#!/usr/bin/env python3
"""Install and launch the real app with bounded simulator stages and a review screenshot."""
import json, os, re, subprocess, time
from pathlib import Path


def run(*args, timeout=60, quiet=False):
    if not quiet:
        print('+ ' + ' '.join(args), flush=True)
    try:
        return subprocess.run(args, check=True, capture_output=True, text=True, timeout=timeout).stdout
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f"Command failed: {args!r}\nstdout: {error.stdout}\nstderr: {error.stderr}", flush=True)
        raise


devices = json.loads(run('xcrun', 'simctl', 'list', 'devices', 'available', '--json'))['devices']
sdk = run('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version').strip()
phones = [(runtime, d) for runtime, values in devices.items() if '.iOS-' in runtime
          for d in values if d['name'].startswith('iPhone')]
assert phones, 'No available iPhone simulator runtime'
# Prefer the selected Xcode SDK's runtime, then the newest available runtime.
# Older installed runtimes can be unavailable or slow even when the SDK build succeeds.
phones.sort(key=lambda pair: (
    pair[0].endswith('.iOS-' + sdk.replace('.', '-')),
    tuple(int(n) for n in re.findall(r'\d+', pair[0])),
    pair[1]['state'] == 'Booted'), reverse=True)
runtime, phone = phones[0]
udid = phone['udid']
print(f"Selected {phone['name']} on {runtime}", flush=True)
if phone['state'] != 'Booted':
    run('xcrun', 'simctl', 'boot', udid)
# Report a simulator-startup failure separately from app installation/launch failures.
run('xcrun', 'simctl', 'bootstatus', udid, '-b', timeout=240)
app = Path(__file__).resolve().parent / 'DerivedData/Build/Products/Debug-iphonesimulator/DailyBriefing.app'
run('xcrun', 'simctl', 'install', udid, str(app), timeout=180)
launch = run('xcrun', 'simctl', 'launch', udid, 'com.example.DailyBriefing', timeout=90)
print(launch, flush=True)
match = re.search(r'com\.example\.DailyBriefing:\s*(\d+)', launch)
assert match, 'simctl did not return the launched app PID'
pid = int(match.group(1))
# Simulator apps are host macOS processes. Check the exact launched PID, not a
# launchd registration that can survive an app exit. Repeated simctl-spawn calls
# themselves timed out on a busy runner after a successful launch (run 43481237221).
print(f'Checking app PID {pid} survival for 20 seconds.', flush=True)
for _ in range(20):
    time.sleep(1)
    os.kill(pid, 0)  # Raises immediately if the actual app process has exited.
state = run('ps', '-p', str(pid), '-o', 'stat=', timeout=15).strip()
assert state and not state.startswith('Z'), 'App process is a zombie after launch'
output = Path(__file__).resolve().parent / 'artifacts'
output.mkdir(exist_ok=True)
run('xcrun', 'simctl', 'io', udid, 'screenshot', str(output / 'first-launch.png'), timeout=120)
print('PASS: simulator install, launch, process survival; screenshot captured. No provider permissions were granted.', flush=True)
