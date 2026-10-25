import Darwin
import Foundation

/// Resource usage of this process, for the periodic health log line and the
/// soak test.
public struct ProcessStats: Sendable {
    /// Physical footprint in bytes (what Activity Monitor calls Memory).
    public var footprint: UInt64
    /// Resident set size in bytes.
    public var rss: UInt64
    public var threads: Int
    /// Total user+system CPU time consumed, in seconds.
    public var cpuSeconds: Double

    public static func current() -> ProcessStats {
        var s = ProcessStats(footprint: 0, rss: 0, threads: 0, cpuSeconds: 0)

        var vm = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            s.footprint = vm.phys_footprint
            s.rss = vm.resident_size
        }

        var list: thread_act_array_t?
        var n: mach_msg_type_number_t = 0
        if task_threads(mach_task_self_, &list, &n) == KERN_SUCCESS, let list {
            s.threads = Int(n)
            for i in 0..<Int(n) { mach_port_deallocate(mach_task_self_, list[i]) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(n) * MemoryLayout<thread_t>.stride))
        }

        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            s.cpuSeconds = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
                + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        }
        return s
    }

    public var fields: [String: Any] {
        ["footprint_mb": Double(footprint) / 1_048_576, "rss_mb": Double(rss) / 1_048_576,
         "threads": threads, "cpu_s": cpuSeconds]
    }
}
