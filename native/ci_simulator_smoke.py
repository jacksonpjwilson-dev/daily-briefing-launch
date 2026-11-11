#!/usr/bin/env python3
"""Install and launch the real app in an iPhone simulator; retain a review screenshot."""
import json, subprocess, time
from pathlib import Path

def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout

devices = json.loads(run('xcrun','simctl','list','devices','available','--json'))['devices']
phones = [d for runtime, values in devices.items() if '.iOS-' in runtime for d in values if d['name'].startswith('iPhone')]
assert phones, 'No available iPhone simulator runtime'
phone = phones[0]; udid = phone['udid']
if phone['state'] != 'Booted': run('xcrun','simctl','boot',udid)
run('xcrun','simctl','bootstatus',udid,'-b')
app = Path(__file__).resolve().parent/'DerivedData/Build/Products/Debug-iphonesimulator/DailyBriefing.app'
run('xcrun','simctl','install',udid,str(app))
print(run('xcrun','simctl','launch',udid,'com.example.DailyBriefing'))
# Wait for initial source requests without assuming a successful or connected source.
for _ in range(20):
    time.sleep(1)
    running = run('xcrun','simctl','spawn',udid,'launchctl','list')
    assert 'com.example.DailyBriefing' in running, 'App terminated after launch'
output = Path(__file__).resolve().parent/'artifacts'; output.mkdir(exist_ok=True)
run('xcrun','simctl','io',udid,'screenshot',str(output/'first-launch.png'))
print('PASS: simulator install, launch, process survival; screenshot captured. No provider permissions were granted.')
