#!/usr/bin/env python3
"""Resolve Apple's iOS 18.4/18.5 simulator overlay workaround, without relinking."""
import argparse
import json
import pathlib
import subprocess


def resolve_runtime(device, devices, runtimes):
    identifier = next((runtime for runtime, entries in devices['devices'].items()
                       if any(entry['udid'] == device for entry in entries)), None)
    if identifier is None:
        raise ValueError('Simulator device is absent from simctl inventory: ' + device)
    return next(runtime for runtime in runtimes['runtimes'] if runtime['identifier'] == identifier)


def overlay_environment(runtime):
    if runtime.get('version') not in ('18.4', '18.5'):
        return {}
    root = pathlib.Path(runtime.get('runtimeRoot') or
                        pathlib.Path(runtime['bundlePath']) / 'Contents/Resources/RuntimeRoot')
    normal = root / 'usr/lib/swift/libswiftWebKit.dylib'
    fallback = root / 'System/Cryptexes/OS/usr/lib/swift'
    legacy = fallback / 'libswiftWebKit.dylib'
    # Do not set a fallback for fixed runtimes or guess directories that do not
    # contain the library. The system runtime, not app-vendored code, supplies it.
    if not normal.exists() and legacy.exists():
        return {'SIMCTL_CHILD_DYLD_FALLBACK_LIBRARY_PATH': str(fallback)}
    return {}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('device')
    parser.add_argument('--output', required=True)
    parser.add_argument('--app', help='Built .app to record actual Mach-O load commands')
    args = parser.parse_args()
    def inventory(kind):
        return json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', kind, '--json']))
    runtime = resolve_runtime(args.device, inventory('devices'), inventory('runtimes'))
    environment = overlay_environment(runtime)
    out = pathlib.Path(args.output); out.mkdir(parents=True, exist_ok=True)
    report = {'runtime': runtime, 'environment': environment,
              'source': 'https://bugs.webkit.org/show_bug.cgi?id=293831#c2',
              'binaryChanged': False}
    if args.app:
        import plistlib
        app = pathlib.Path(args.app)
        executable = plistlib.loads((app/'Info.plist').read_bytes())['CFBundleExecutable']
        binaries = [app / executable] + list(app.glob('*.debug.dylib'))
        for binary in binaries:
            load = subprocess.check_output(['xcrun', 'otool', '-l', str(binary)], text=True)
            deps = subprocess.check_output(['xcrun', 'otool', '-L', str(binary)], text=True)
            (out / (binary.name + '-load-commands.txt')).write_text(load, encoding='utf-8')
            (out / (binary.name + '-dependencies.txt')).write_text(deps, encoding='utf-8')
    (out/'webkit-runtime.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    # One machine-readable value for the launch script, never shell code.
    print(environment.get('SIMCTL_CHILD_DYLD_FALLBACK_LIBRARY_PATH', ''))


if __name__ == '__main__':
    main()
