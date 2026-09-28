import Foundation
import IOKit.ps
import Darwin

struct SystemPerformanceSample: Sendable {
    let isOnBattery: Bool
    let cpuUsage: Double?
    let isHighCPUUsage: Bool
}

actor SystemPerformanceSampler {
    private var previousCPUTicks: [UInt32]?
    private var consecutiveHighCPUSamples = 0

    func sample() -> SystemPerformanceSample {
        let cpuUsage = sampleCPUUsage()
        if let cpuUsage, cpuUsage >= 80 {
            consecutiveHighCPUSamples += 1
        } else {
            consecutiveHighCPUSamples = 0
        }

        return SystemPerformanceSample(
            isOnBattery: Self.isOnBatteryPower,
            cpuUsage: cpuUsage,
            isHighCPUUsage: consecutiveHighCPUSamples >= 2
        )
    }

    private static var isOnBatteryPower: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else {
            return false
        }
        return source as String == kIOPSBatteryPowerValue
    }

    private func sampleCPUUsage() -> Double? {
        var cpuInfo = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &cpuInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = withUnsafeBytes(of: cpuInfo.cpu_ticks) {
            Array($0.bindMemory(to: UInt32.self))
        }
        guard let previousCPUTicks else {
            self.previousCPUTicks = ticks
            return nil
        }
        self.previousCPUTicks = ticks
        let deltas = zip(ticks, previousCPUTicks).map { current, previous in
            current >= previous
                ? UInt64(current - previous)
                : UInt64(UInt32.max - previous) + 1 + UInt64(current)
        }
        let total = deltas.reduce(0, +)
        guard total > 0, deltas.count > Int(CPU_STATE_IDLE) else { return nil }
        let idle = deltas[Int(CPU_STATE_IDLE)]
        return Double(total - idle) / Double(total) * 100
    }
}
