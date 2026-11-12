#!/usr/bin/env python3
"""Install and launch the real app with bounded simulator stages and a review screenshot."""
import json, re, subprocess, time
from pathlib import Path


def run(*args, timeout=60, quiet=False):
    if not quiet:
        print('+ ' + ' '.join(args), flush=True)
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=timeout).stdout


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
run('xcrun', 'simctl', 'install', udid, str(app), timeout=90)
print(run('xcrun', 'simctl', 'launch', udid, 'com.example.DailyBriefing', timeout=90), flush=True)
print('Checking app process survival for 20 seconds.', flush=True)
for _ in range(20):
    time.sleep(1)
    running = run('xcrun', 'simctl', 'spawn', udid, 'launchctl', 'list', timeout=30, quiet=True)
    assert 'com.example.DailyBriefing' in running, 'App terminated after launch'
output = Path(__file__).resolve().parent / 'artifacts'
output.mkdir(exist_ok=True)
run('xcrun', 'simctl', 'io', udid, 'screenshot', str(output / 'first-launch.png'))
print('PASS: simulator install, launch, process survival; screenshot captured. No provider permissions were granted.', flush=True)
