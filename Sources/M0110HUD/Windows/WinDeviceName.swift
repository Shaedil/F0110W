import CM0110Win

extension DeviceName {
    /// This PC, e.g. "Windows 11 PC".
    static func current() -> String {
        let build = Int(m0110_windows_build())
        return build > 0 ? windows(build: build) : "Windows PC"
    }
}
