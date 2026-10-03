import Darwin

/// `phys_footprint` of this process: the figure Xcode's memory gauge and jetsam use.
public enum ProcessFootprint {
    public static var current: UInt64? { vmInfo.map { UInt64($0.phys_footprint) } }

    public static var resident: UInt64? { vmInfo.map { UInt64($0.resident_size) } }

    private static var vmInfo: task_vm_info_data_t? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info : nil
    }
}
