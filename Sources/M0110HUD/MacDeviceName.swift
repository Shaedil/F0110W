import Foundation
import IOKit

extension DeviceName {
    /// This Mac, e.g. "MacBook Air M4".
    static func current() -> String {
        mac(productName: productName(),
            modelIdentifier: sysctlString("hw.model") ?? "",
            cpuBrand: sysctlString("machdep.cpu.brand_string") ?? "")
    }

    /// e.g. "MacBook Air (13-inch, M4, 2025)" from the device tree. Only Apple silicon Macs have it.
    private static func productName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let value = IORegistryEntryCreateCFProperty(
            entry, "product-name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
            let data = value as? Data else { return nil }
        let name = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        return name.isEmpty ? nil : name
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
