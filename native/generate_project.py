#!/usr/bin/env python3
"""Reproducible Xcode project generation with Python's standard library only."""
from pathlib import Path
import hashlib, json, plistlib
ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / 'DailyBriefing'
objects = {}
def uid(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def q(value): return json.dumps(str(value))
def obj(name, body):
    key = uid(name); objects[key] = body; return key
def array(values): return '(' + ', '.join(values) + (',' if values else '') + ')'
def plist(path, data):
    path.write_bytes(plistlib.dumps(data, sort_keys=False))
base = {'CFBundleDevelopmentRegion':'en','CFBundleExecutable':'$(EXECUTABLE_NAME)', 'CFBundleIdentifier':'$(PRODUCT_BUNDLE_IDENTIFIER)',
        'CFBundleName':'$(PRODUCT_NAME)','CFBundlePackageType':'$(PRODUCT_BUNDLE_PACKAGE_TYPE)',
        'CFBundleShortVersionString':'1.0','CFBundleVersion':'1'}
app = dict(base, CFBundleDisplayName='Daily Briefing', LSRequiresIPhoneOS=True,
    NSCalendarsFullAccessUsageDescription='Include events from calendars you select in your daily briefing.',
    NSRemindersFullAccessUsageDescription='Include your outstanding reminders in your briefing.',
    NSLocationWhenInUseUsageDescription='Request weather near your current location.',
    BGTaskSchedulerPermittedIdentifiers=['com.example.DailyBriefing.refresh'],
    UIBackgroundModes=['fetch','audio'], NSSupportsLiveActivities=True, WeatherKitConfigured=False,
    UILaunchScreen={}, UISupportedInterfaceOrientations=['UIInterfaceOrientationPortrait'],
    CFBundleURLTypes=[{'CFBundleURLName':'DailyBriefing','CFBundleURLSchemes':['dailybriefing']}])
plist(SOURCE/'Resources/App-Info.plist', app)
plist(SOURCE/'Resources/Widgets-Info.plist', dict(base, CFBundleDisplayName='Daily Briefing Widgets', NSExtension={'NSExtensionPointIdentifier':'com.apple.widgetkit-extension'}))
plist(SOURCE/'Resources/Watch-Info.plist', dict(base, CFBundleDisplayName='Daily Briefing', WKApplication=True, WKCompanionAppBundleIdentifier='com.example.DailyBriefing'))
plist(SOURCE/'Resources/WatchWidgets-Info.plist', dict(base, CFBundleDisplayName='Briefing Smart Stack', NSExtension={'NSExtensionPointIdentifier':'com.apple.widgetkit-extension'}))
group = {'com.apple.security.application-groups':['group.com.example.DailyBriefing']}
plist(SOURCE/'Resources/App.entitlements', group)
plist(SOURCE/'Resources/Extension.entitlements', group)
# Optional capabilities are deliberately not included in the default signing configuration.
plist(SOURCE/'Resources/OptionalCloudWeather.entitlements', dict(group, **{
    'com.apple.developer.icloud-container-identifiers':['iCloud.com.example.DailyBriefing'],
    'com.apple.developer.icloud-services':['CloudKit'], 'com.apple.developer.weatherkit': True}))
plist(SOURCE/'Resources/PrivacyInfo.xcprivacy', {
    'NSPrivacyTracking':False, 'NSPrivacyTrackingDomains':[], 'NSPrivacyCollectedDataTypes':[],
    'NSPrivacyAccessedAPITypes':[{'NSPrivacyAccessedAPIType':'NSPrivacyAccessedAPICategoryUserDefaults',
        'NSPrivacyAccessedAPITypeReasons':['CA92.1','1C8F.1']}]
})
files = sorted(SOURCE.rglob('*.swift')) + [SOURCE/'Resources/PrivacyInfo.xcprivacy']
refs = {}
for path in files:
    rel = path.relative_to(ROOT).as_posix()
    filetype = 'sourcecode.swift' if path.suffix == '.swift' else 'text.xml'
    refs[rel] = obj('file:'+rel, f'isa = PBXFileReference; lastKnownFileType = {filetype}; path = {q(rel)}; sourceTree = SOURCE_ROOT;')
configs = ['Debug','Release']
def configlist(name, common, extra=None):
    ids = []
    for config in configs:
        settings = dict(common)
        settings.update({'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if config=='Debug' else '-O',
                         'DEBUG_INFORMATION_FORMAT':'dwarf' if config=='Debug' else 'dwarf-with-dsym',
                         'SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG' if config=='Debug' else ''})
        ids.append(obj(f'{name}:{config}', 'isa = XCBuildConfiguration; name = '+q(config)+'; buildSettings = {' + ''.join(f'{k} = {q(v)};' for k,v in settings.items()) + '};'))
    return obj(name+':configlist', f'isa = XCConfigurationList; buildConfigurations = {array(ids)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
core = [p.relative_to(ROOT).as_posix() for p in sorted((SOURCE/'Core').glob('*.swift'))] + ['DailyBriefing/Shared/SharedSnapshot.swift']
target_defs = {
    'DailyBriefing': {'sources': core + ['DailyBriefing/Shared/ShiftActivityAttributes.swift'] + [p.relative_to(ROOT).as_posix() for p in files if p.suffix=='.swift' and p.parent.name in ['App','Services','Views']], 'type':'com.apple.product-type.application','ext':'app','bundle':'com.example.DailyBriefing','info':'App','watch':False},
    'DailyBriefingWidgets': {'sources': core + ['DailyBriefing/Shared/ShiftActivityAttributes.swift','DailyBriefing/Widgets/BriefingWidgets.swift'], 'type':'com.apple.product-type.app-extension','ext':'appex','bundle':'com.example.DailyBriefing.widgets','info':'Widgets','watch':False},
    'DailyBriefingWatch': {'sources': core + ['DailyBriefing/Watch/DailyBriefingWatchApp.swift'], 'type':'com.apple.product-type.application','ext':'app','bundle':'com.example.DailyBriefing.watchkitapp','info':'Watch','watch':True},
    'DailyBriefingWatchWidgets': {'sources': core + ['DailyBriefing/Watch/WatchWidget.swift'], 'type':'com.apple.product-type.app-extension','ext':'appex','bundle':'com.example.DailyBriefing.watchkitapp.widgets','info':'WatchWidgets','watch':True},
}
products = {}
for name,t in target_defs.items():
    products[name] = obj(name+':product', f'isa = PBXFileReference; explicitFileType = {"wrapper.application" if t["ext"]=="app" else "wrapper.app-extension"}; includeInIndex = 0; path = {q(name+"."+t["ext"])}; sourceTree = BUILT_PRODUCTS_DIR;')
def dependency(parent, child):
    proxy = obj(parent+':proxy:'+child, f'isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {uid(child+":target")}; remoteInfo = {q(child)};')
    return obj(parent+':dep:'+child, f'isa = PBXTargetDependency; target = {uid(child+":target")}; targetProxy = {proxy};')
def embed(parent, child, dest, path=''):
    build = obj(parent+':embedbuild:'+child, f'isa = PBXBuildFile; fileRef = {products[child]}; settings = {{ ATTRIBUTES = (RemoveHeadersOnCopy,); }};')
    return obj(parent+':embed:'+child, f'isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = {q(path)}; dstSubfolderSpec = {dest}; files = ({build},); name = {q("Embed "+child)}; runOnlyForDeploymentPostprocessing = 0;')
for name,t in target_defs.items():
    builds=[]
    for path in t['sources']:
        builds.append(obj(name+':build:'+path, f'isa = PBXBuildFile; fileRef = {refs[path]};'))
    sources = obj(name+':sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {array(builds)}; runOnlyForDeploymentPostprocessing = 0;')
    resource = obj(name+':privacy', f'isa = PBXBuildFile; fileRef = {refs["DailyBriefing/Resources/PrivacyInfo.xcprivacy"]};')
    resources = obj(name+':resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({resource},); runOnlyForDeploymentPostprocessing = 0;')
    frameworks = obj(name+':frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
    phases = [sources, frameworks, resources]; deps=[]
    if name == 'DailyBriefing':
        phases += [embed(name,'DailyBriefingWidgets',13), embed(name,'DailyBriefingWatch',16,'$(CONTENTS_FOLDER_PATH)/Watch')]
        deps += [dependency(name,'DailyBriefingWidgets'), dependency(name,'DailyBriefingWatch')]
    if name == 'DailyBriefingWatch':
        phases += [embed(name,'DailyBriefingWatchWidgets',13)]; deps += [dependency(name,'DailyBriefingWatchWidgets')]
    settings = {'PRODUCT_NAME':'$(TARGET_NAME)', 'PRODUCT_BUNDLE_IDENTIFIER':t['bundle'], 'INFOPLIST_FILE':f'DailyBriefing/Resources/{t["info"]}-Info.plist',
        'GENERATE_INFOPLIST_FILE':'NO', 'SWIFT_VERSION':'5.0','SWIFT_STRICT_CONCURRENCY':'targeted',
        'CODE_SIGN_STYLE':'Automatic', 'CODE_SIGN_ENTITLEMENTS':'DailyBriefing/Resources/App.entitlements' if name=='DailyBriefing' else 'DailyBriefing/Resources/Extension.entitlements',
        'SDKROOT':'watchos' if t['watch'] else 'iphoneos', 'TARGETED_DEVICE_FAMILY':'4' if t['watch'] else '1',
        'SUPPORTED_PLATFORMS':'watchos watchsimulator' if t['watch'] else 'iphoneos iphonesimulator',
        'WATCHOS_DEPLOYMENT_TARGET':'10.0','IPHONEOS_DEPLOYMENT_TARGET':'17.0',
        'SKIP_INSTALL':'NO' if name=='DailyBriefing' else 'YES', 'ENABLE_USER_SCRIPT_SANDBOXING':'YES',
        'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks'}
    if t['ext']=='appex': settings['APPLICATION_EXTENSION_API_ONLY']='YES'
    cl = configlist(name, settings)
    obj(name+':target', f'isa = PBXNativeTarget; buildConfigurationList = {cl}; buildPhases = {array(phases)}; buildRules = (); dependencies = {array(deps)}; name = {q(name)}; productName = {q(name)}; productReference = {products[name]}; productType = {q(t["type"])};')
sourcegroup = obj('sourcegroup', f'isa = PBXGroup; children = {array(list(refs.values()))}; name = Sources; sourceTree = "<group>";')
productgroup = obj('productgroup', f'isa = PBXGroup; children = {array(list(products.values()))}; name = Products; sourceTree = "<group>";')
main = obj('main', f'isa = PBXGroup; children = ({sourcegroup}, {productgroup},); sourceTree = "<group>";')
projectconfigs = configlist('project', {'CLANG_ENABLE_MODULES':'YES','SWIFT_VERSION':'5.0','ENABLE_TESTABILITY':'YES','GCC_C_LANGUAGE_STANDARD':'gnu17','SWIFT_EMIT_LOC_STRINGS':'YES'})
obj('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 1600; BuildIndependentTargetsInParallel = YES; }}; buildConfigurationList = {projectconfigs}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base,); mainGroup = {main}; productRefGroup = {productgroup}; projectDirPath = ""; projectRoot = ""; targets = {array([uid(n+":target") for n in target_defs])};')
project = ROOT/'DailyBriefing.xcodeproj'; project.mkdir(exist_ok=True)
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+ '\n'.join(f'{k} = {{ {v} }};' for k,v in sorted(objects.items())) + '\n}; rootObject = '+uid('project')+'; }\n')
for name in ['DailyBriefing','DailyBriefingWatch']:
    schemes = project/'xcshareddata/xcschemes'; schemes.mkdir(parents=True,exist_ok=True)
    ref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid(name+":target")}" BuildableName="{name}.app" BlueprintName="{name}" ReferencedContainer="container:DailyBriefing.xcodeproj"/>'
    (schemes/(name+'.xcscheme')).write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"/>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>\n''')
print(f'Generated {len(target_defs)} targets, {len(objects)} project objects')
