#!/usr/bin/env python3
"""Validate plist syntax, PBX references, target membership and generator reproducibility."""
from pathlib import Path
import plistlib, re, subprocess, xml.etree.ElementTree as ET
root = Path(__file__).resolve().parent
project = root/'DailyBriefing.xcodeproj/project.pbxproj'
# Small OpenStep reader for the generated project; catches syntax errors rather than just grepping.
tokens = re.findall(r'"(?:\\.|[^"\\])*"|[A-Za-z0-9_./$<>+\-]+|[{}()=;,]', re.sub(r'//[^\n]*', '', project.read_text()))
position = 0
def read():
    global position
    token = tokens[position]; position += 1
    if token == '{':
        result = {}
        while tokens[position] != '}':
            key = read(); assert tokens[position] == '='; position += 1
            assert key not in result, f'Duplicate key {key}'
            result[key] = read(); assert tokens[position] == ';'; position += 1
        position += 1; return result
    if token == '(':
        result = []
        while tokens[position] != ')':
            result.append(read())
            if tokens[position] == ',': position += 1
            else: assert tokens[position] == ')'
        position += 1; return result
    if token.startswith('"'):
        import json
        return json.loads(token)
    return token
parsed = read(); assert position == len(tokens)
objects = parsed['objects']; assert parsed['rootObject'] in objects
refs = ['fileRef','target','targetProxy','productReference','buildConfigurationList','containerPortal','mainGroup','productRefGroup','remoteGlobalIDString']
arrays = ['children','buildConfigurations','buildPhases','dependencies','targets','files']
for key, item in objects.items():
    for field in refs:
        if field in item: assert item[field] in objects, (key, field, item[field])
    for field in arrays:
        for value in item.get(field, []): assert value in objects, (key, field, value)
    if item['isa']=='PBXFileReference' and item.get('sourceTree')=='SOURCE_ROOT':
        assert (root/item['path']).is_file(), item['path']
targets = {v['name']:v for v in objects.values() if v['isa']=='PBXNativeTarget'}
assert len(targets)==4
for name, target in targets.items():
    configs = objects[target['buildConfigurationList']]['buildConfigurations']
    for c in configs:
        settings = objects[c]['buildSettings']
        for field in ['INFOPLIST_FILE','CODE_SIGN_ENTITLEMENTS']:
            assert (root/settings[field]).is_file(), settings[field]
    source_phase = next(objects[p] for p in target['buildPhases'] if objects[p]['isa']=='PBXSourcesBuildPhase')
    source_files = [objects[objects[b]['fileRef']]['path'] for b in source_phase['files']]
    assert len(source_files)==len(set(source_files)), name
    assert sum('@main' in (root/p).read_text() for p in source_files)==1, name
for p in root.rglob('*'):
    if '.build' in p.parts or 'DerivedData' in p.parts: continue
    if p.suffix in ['.plist','.entitlements','.xcprivacy']:
        with p.open('rb') as f: plistlib.load(f)
    if p.suffix=='.xcscheme': ET.parse(p)
tracked = [project] + list((root/'DailyBriefing/Resources').glob('*')) + list((root/'DailyBriefing.xcodeproj/xcshareddata/xcschemes').glob('*'))
before = {p:p.read_bytes() for p in tracked}
subprocess.run(['python3', str(root/'generate_project.py')], check=True)
assert all(p.read_bytes()==data for p,data in before.items()), 'Generated output drifted'
print(f'PASS: {len(objects)} PBX objects; four targets; source membership; plist/scheme syntax; reproducible generation')
