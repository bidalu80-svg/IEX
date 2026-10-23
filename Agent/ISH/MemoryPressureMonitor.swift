//
//  MemoryPressureMonitor.swift
//  ZeApp
//
//  [T-ish-footprint-brake] Feeds the iSH kernel the number jetsam actually
//  kills on: the app's physical footprint against its live allowance.
//
//  The kernel's page ledger charges COMMITMENT; jetsam charges DIRTY pages.
//  A V8 cage commits ~640MB while dirtying tens of MB, so a fixed ledger cap
//  refuses workloads the device runs easily, and cannot see the app's own
//  memory (WebViews, transcripts) at all. Once this feed is installed the
//  kernel switches admission to footprint mode (see kernel/mm.h): OK admits
//  everything, BRAKE refuses new anonymous commitments, 10%/15% hysteresis,
//  and a feed older than 2s reads as BRAKE.
//
//  Sampling: 4 Hz plus the OS memory-pressure source. `limit` is
//  phys_footprint + os_proc_available_memory(), i.e. the live jetsam
//  allowance, so no per-device table and no boot-time snapshot can go stale.
//

import Foundation
import Darwin

final class MemoryPressureMonitor {
    static let shared = MemoryPressureMonitor()

    private let queue = DispatchQueue(label: "com.ze.memory-footprint", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var critical = false

    private init() {}

    /// Idempotent. Call once the kernel has booted.
    func start() {
        guard timer == nil else { return }

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.critical = source.data.contains(.critical)
            self.push()
        }
        source.resume()
        pressureSource = source

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.push() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel(); timer = nil
        pressureSource?.cancel(); pressureSource = nil
        critical = false
    }

    private func push() {
        let footprint = Self.physFootprint()
        let available = os_proc_available_memory()
        // os_proc_available_memory() returns 0 when the app is not limited
        // (or the call is unavailable); leave the kernel in ledger mode then.
        guard footprint > 0, available > 0 else { return }
        ish_set_memory_status(footprint + UInt64(available),
                              UInt64(available),
                              critical)
    }

    private static func physFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebased in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebased, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
