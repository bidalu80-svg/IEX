#!/usr/bin/env python3
"""Compile real coordinator/router declarations with deterministic native-executor fixtures.
Runs on macOS (xcrun swiftc); --prepare-only records source hashes without claiming tests passed.
"""
from pathlib import Path
import hashlib, json, os, shutil, subprocess, sys, tempfile
ROOT = Path(__file__).resolve().parents[1]
OUT = Path(os.environ.get('RUNNER_TEMP', tempfile.gettempdir())) / 'ze-kernel-tests'
OUT.mkdir(parents=True, exist_ok=True)
src = (ROOT / 'Agent/ISH/ISHExecutionCoordinator.swift').read_text(encoding='utf-8')
router = (ROOT / 'Agent/ISH/ZeFsRouter.swift').read_text(encoding='utf-8')
def between(a,b):
    return src[src.index(a):src.index(b,src.index(a))]
actor = 'actor ISHExecutionCoordinator {\n' + '''
    static let shared = ISHExecutionCoordinator()
    static let killQueue = DispatchQueue(label: "kernel-test-kill", qos: .userInitiated)
    static let kMaxPartialOutputChars = 256_000
    var mountedSessionId: String?
    static var mountedSessionIdSnapshot: String? { nil }
    func ensureStaticMountsInitialized(for sid: String) {}
    func debugInflightCount() -> Int { perSessionInflight.values.reduce(0) { $0 + $1.count } }
''' + between('    private struct InflightExec {','    /// Set of sessions') + between('    func execute(','    /// Called from loadSession') + between('    private func runCommand(','    // MARK: - Mount Logic') + between('    private static let inflightPidLock','    /// Read the current mount owner') + between('    /// The browser/offload caller','    static func setExternalMountSnapshot') + '\n}\n'
header = '''import Foundation
struct TestLogger {
 func info(_ s: String) {}
 func warning(_ s: String) {}
 func error(_ s: String) {}
}
private let logger = TestLogger()
struct ISHCommandResult { let output: String; let exitCode: Int }
enum ISHCoordinatorError: Error { case kernelNotBooted }
final class ISHKernel: @unchecked Sendable {
 static let shared = ISHKernel(); var isBooted = true
 func installPathTranslateHandler(_ f: @escaping (String, UInt64) -> String?) {}
 func installPathReverseHandler(_ f: @escaping (String) -> String?) {}
}
struct EnvVarStore { static let shared = EnvVarStore(); func allAsDict() -> [String:String] { [:] } }
struct MemoryPressureMonitor { static let shared = MemoryPressureMonitor(); func start() {} }
struct AOJITAcceleration { static let shared = AOJITAcceleration(); let isEnabled = false; func prepareOnce() {} }
struct AIChatViewModel {
 static let zePersistentBase = URL(fileURLWithPath: "/tmp/ze-kernel-fixture")
 static let zeOffloadsLinuxDir = "/var/ze/offloads"
 static let zeAttachmentsLinuxDir = "/var/ze/attachments"
 static let zeWorkspaceLinuxDir = "/var/ze/workspace"
 static let zeBrowserLinuxDir = "/var/ze/browser"
}
enum ISHShellExecutorError: Int { case processCreationFailed = -1, execFailed = -2, timeout = -3, cancelled = -4 }
struct NativeResult { let output: String; let errorOutput: String; let exitCode: Int32 }
final class ISHShellExecutor: @unchecked Sendable {
 static let lock = NSLock()
 nonisolated(unsafe) static var nextPid: Int32 = 2
 nonisolated(unsafe) static var callbacks: [Int32: (NativeResult) -> Void] = [:]
 nonisolated(unsafe) static var contexts: [Int32: UInt64] = [:]
 nonisolated(unsafe) static var killed: [Int32] = []
 static func executeExecutable(_ executable: String, arguments: [String]?, environment: [String:String]?, stdinData: Data?, fsContext: UInt64, lineCallback: @escaping (String, Bool) -> Void, completion: @escaping (NativeResult) -> Void) -> Int32 {
  lock.lock(); let pid = nextPid; nextPid += 1; callbacks[pid] = completion; contexts[pid] = fsContext; lock.unlock()
  let command = String(data: stdinData!, encoding: .utf8)!
  if command.contains("SYNC_DONE") { finish(pid); return pid }
  if command.contains("LONG_OUTPUT") { lineCallback(String(repeating: "x", count: 300_000) + "TAIL", false) }
  else { lineCallback("output-before-wait", false) }
  return pid
 }
 static func finish(_ pid: Int32) { lock.lock(); let c = callbacks.removeValue(forKey: pid); lock.unlock(); c?(NativeResult(output: "done",errorOutput:"",exitCode:0)) }
 static func killProcessGroup(_ pid: Int32) { lock.lock(); killed.append(pid); lock.unlock() }
 static func finalizeTimedOutPid(_ pid: Int32) { finish(pid) }
}
'''
fixture = (ROOT/'scripts/KernelRuntimeHarness.swift').read_text(encoding='utf-8')
production = OUT/'KernelProduction.swift'; production.write_text(header+router+actor,encoding='utf-8')
manifest = {'scope':'production coordinator/router with mocked native execution, not an iSH guest/device runtime test', 'sources': {str(p):hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in ['Agent/ISH/ISHExecutionCoordinator.swift','Agent/ISH/ZeFsRouter.swift','iSH/ISHShellExecutor.m','NativeOffloads/NativeOffloadUtils.m']}}
(OUT/'manifest.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
assert 'ownerId: ownerId,\n            fsContext:' in src
assert src.index('        defer {',src.index('    func execute(')) < src.index('        try Task.checkCancellation()')
assert 'AOJITAcceleration.shared.prepareOnce()' in src and 'MemoryPressureMonitor.shared.start()' in src
print('Prepared production extraction:',production,flush=True)
if '--prepare-only' in sys.argv:
 print('PREPARE ONLY: Swift compilation/runtime NOT executed');sys.exit(0)
compiler = ['xcrun','swiftc'] if shutil.which('xcrun') else ['swiftc']
subprocess.run(compiler+['-swift-version','5','-parse-as-library',str(production),str(ROOT/'scripts/KernelRuntimeHarness.swift'),'-o',str(OUT/'kernel-tests')],check=True)
subprocess.run([str(OUT/'kernel-tests')],check=True,timeout=30)
