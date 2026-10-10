import Foundation

/// Wire format of the keyboard's profile names (`config/src/profile_names.h`). Read: format,
/// count, then a length byte and UTF-8 bytes per name. Write: op, index, UTF-8 name.
/// The keyboard stores the names so every paired computer shows the same ones.
enum ProfileNamesWire {
    static let format: UInt8 = 1
    /// Max name length the keyboard stores, in UTF-8 bytes.
    static let maxBytes = 24
    /// Max length for a computer's own name, leaving room for the keyboard to add a number.
    static let autoMaxBytes = 21

    enum Op: UInt8 {
        /// An empty name clears the profile's name.
        case set = 1
        /// Names a profile only if it has none. Duplicate names get numbered
        /// ("MacBook Pro M4 1", "MacBook Pro M4 2").
        case auto = 2
    }

    /// One name per profile ("" if unset). Nil if malformed.
    static func parse(_ data: Data) -> [String]? {
        decode([UInt8](data))?.names
    }

    /// Profiles whose name the keyboard read from the device, as a placeholder until the app
    /// names it. One bit per profile in the byte after the names. Older firmware omits it.
    static func fromDevice(_ data: Data) -> Set<Int> {
        let bytes = [UInt8](data)
        guard let (names, end) = decode(bytes), end < bytes.count else { return [] }
        return Set(names.indices.filter { $0 < 8 && bytes[end] & (1 << $0) != 0 })
    }

    /// The names, and the index of the first byte after them.
    private static func decode(_ bytes: [UInt8]) -> (names: [String], end: Int)? {
        guard bytes.count >= 2, bytes[0] == format else { return nil }
        var names: [String] = []
        var at = 2
        for _ in 0..<Int(bytes[1]) {
            guard at < bytes.count else { return nil }
            let len = Int(bytes[at])
            at += 1
            guard at + len <= bytes.count else { return nil }
            names.append(String(decoding: bytes[at..<at + len], as: UTF8.self))
            at += len
        }
        return (names, at)
    }

    static func write(_ op: Op, index: Int, name: String) -> Data {
        let limit = op == .auto ? autoMaxBytes : maxBytes
        return Data([op.rawValue, UInt8(index)] + Array(clean(name, maxBytes: limit).utf8))
    }

    /// `name` as the keyboard stores it: printable, trimmed, and cut to fit.
    static func clean(_ name: String, maxBytes: Int = maxBytes) -> String {
        let printable = String(String.UnicodeScalarView(
            name.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
        var out = printable.trimmingCharacters(in: .whitespaces)
        while out.utf8.count > maxBytes { out.removeLast() }
        return out.trimmingCharacters(in: .whitespaces)
    }
}

enum ProfileNameSync {
    struct Write: Equatable {
        var op: ProfileNamesWire.Op
        var index: Int
        var name: String
    }

    /// - own: this computer's profile, if known. The keyboard only takes names from a computer
    ///   bonded to one of its profiles, so nothing is sent until this is known.
    /// - deviceName: used for this computer's profile when it is unnamed or "Profile N".
    /// - fromDevice: profiles whose name the keyboard read from the device. On this computer's
    ///   profile that is a placeholder, which this computer's name may replace.
    static func writes(keyboard: [String], pending: [Int: String], own: Int?,
                       deviceName: String?, fromDevice: Set<Int> = []) -> [Write] {
        guard let own else { return [] }
        var names = keyboard
        var standIns = fromDevice
        var out: [Write] = []

        for (index, name) in pending.sorted(by: { $0.key < $1.key })
        where names.indices.contains(index) {
            let name = ProfileNamesWire.clean(name)
            // Sent even if it matches the device's own name, so the keyboard stores it as set here.
            guard names[index] != name || standIns.contains(index) else { continue }
            out.append(Write(op: .set, index: index, name: name))
            names[index] = name
            standIns.remove(index)
        }

        guard names.indices.contains(own),
              let deviceName = deviceName.map({
                  ProfileNamesWire.clean($0, maxBytes: ProfileNamesWire.autoMaxBytes)
              }),
              !deviceName.isEmpty else { return out }
        // "Profile N" is what an unnamed profile shows, so treat it as unnamed. The keyboard only
        // fills in a blank name, so clear it first.
        if names[own] == ProfileNames.placeholder(own) {
            out.append(Write(op: .set, index: own, name: ""))
            names[own] = ""
        }
        if names[own].isEmpty || standIns.contains(own) {
            out.append(Write(op: .auto, index: own, name: deviceName))
        }
        return out
    }

    /// Names set here before the keyboard stored names, for profiles the keyboard has no name
    /// for. "Profile N" is a placeholder and is skipped.
    static func carryOver(keyboard: [String], local: [String]) -> [Int: String] {
        var out: [Int: String] = [:]
        for index in keyboard.indices where keyboard[index].isEmpty && local.indices.contains(index) {
            let name = ProfileNamesWire.clean(local[index])
            if !name.isEmpty && name != ProfileNames.placeholder(index) {
                out[index] = name
            }
        }
        return out
    }
}

/// This computer's copy of the keyboard's names (what the HUD shows), plus renames the keyboard
/// has not taken yet. Stored in UserDefaults on the Mac and settings.json on Windows.
final class ProfileNameStore {
    struct State: Equatable {
        /// One per profile, "" if unset.
        var names: [String]
        var pending: [Int: String]
        /// Whether names set here before the keyboard stored them have been offered to it.
        var carriedOver: Bool
    }

    static let shared = ProfileNameStore(defaults: .standard)
    static let pendingKey = "profileNamesPending"
    static let carriedOverKey = "profileNamesCarriedOver"

    private let load: () -> State
    private let store: (State) -> Void

    init(load: @escaping () -> State, store: @escaping (State) -> Void) {
        self.load = load
        self.store = store
    }

    convenience init(defaults: UserDefaults) {
        self.init(
            load: {
                let raw = defaults.dictionary(forKey: Self.pendingKey) as? [String: String] ?? [:]
                return State(
                    names: (0..<ProfileNames.count).map {
                        defaults.string(forKey: ProfileNames.key($0)) ?? ""
                    },
                    pending: Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
                        Int(key).map { ($0, value) }
                    }),
                    carriedOver: defaults.bool(forKey: Self.carriedOverKey))
            },
            store: { state in
                for (index, name) in state.names.enumerated() {
                    if name.isEmpty {
                        defaults.removeObject(forKey: ProfileNames.key(index))
                    } else if defaults.string(forKey: ProfileNames.key(index)) != name {
                        defaults.set(name, forKey: ProfileNames.key(index))
                    }
                }
                if state.pending.isEmpty {
                    defaults.removeObject(forKey: Self.pendingKey)
                } else {
                    defaults.set(Dictionary(uniqueKeysWithValues: state.pending.map {
                        (String($0.key), $0.value)
                    }), forKey: Self.pendingKey)
                }
                defaults.set(state.carriedOver, forKey: Self.carriedOverKey)
            })
    }

    private func update(_ change: (inout State) -> Void) {
        let before = load()
        var state = before
        change(&state)
        if state != before { store(state) }
    }

    var pending: [Int: String] { load().pending }

    func local(count: Int = ProfileNames.count) -> [String] {
        let names = load().names
        return (0..<count).map { names.indices.contains($0) ? names[$0] : "" }
    }

    /// Shows at once and goes to the keyboard when it can.
    func edit(_ index: Int, _ name: String) {
        update { state in
            guard state.names.indices.contains(index) else { return }
            state.names[index] = name
            state.pending[index] = name
        }
    }

    /// On the first read from the keyboard, queues names set here before it stored them.
    func carryOverIfNeeded(keyboard: [String]) {
        update { state in
            guard !state.carriedOver else { return }
            state.carriedOver = true
            for (index, name) in ProfileNameSync.carryOver(keyboard: keyboard, local: state.names)
            where state.pending[index] == nil {
                state.pending[index] = name
            }
        }
    }

    /// Takes the keyboard's names, except where a rename from here is still pending. A rename
    /// the keyboard already has counts as done, sent or not.
    func cache(_ keyboard: [String]) {
        update { state in
            for (index, name) in keyboard.enumerated() where state.names.indices.contains(index) {
                if let wanted = state.pending[index] {
                    guard ProfileNamesWire.clean(wanted) == name else { continue }
                    state.pending[index] = nil
                }
                state.names[index] = name
            }
        }
    }

    /// Done whether taken or refused, since a refused rename would be refused again.
    func answered(_ write: ProfileNameSync.Write) {
        guard write.op == .set else { return }
        update { state in
            if let name = state.pending[write.index], ProfileNamesWire.clean(name) == write.name {
                state.pending[write.index] = nil
            }
        }
    }
}

extension Notification.Name {
    /// Posted after `ProfileNameStore.edit`.
    static let profileNameEdited = Notification.Name("M0110ProfileNameEdited")
}

/// What a computer calls its own profile: its kind and, on a Mac, its chip (e.g. "MacBook Air
/// M4") instead of the user's machine name.
enum DeviceName {
    /// - productName: IORegistry name like "MacBook Air (13-inch, M4, 2025)", nil if missing.
    /// - modelIdentifier: `hw.model`, e.g. "Mac16,12" or "MacBookPro16,1".
    /// - cpuBrand: `machdep.cpu.brand_string`, e.g. "Apple M4 Pro".
    static func mac(productName: String?, modelIdentifier: String, cpuBrand: String) -> String {
        var model = productName.flatMap { name -> String? in
            let base = name.components(separatedBy: " (").first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            return base.isEmpty ? nil : base
        } ?? macModel(fromIdentifier: modelIdentifier)

        if let chip = cpuBrand.range(of: #"\bM\d+\b"#, options: .regularExpression) {
            model += " " + cpuBrand[chip]
        } else if cpuBrand.localizedCaseInsensitiveContains("intel") {
            model += " Intel"
        }
        return model
    }

    /// For Intel Macs, which have no product name but whose identifiers name the model.
    static func macModel(fromIdentifier identifier: String) -> String {
        let known: [(String, String)] = [
            ("MacBookPro", "MacBook Pro"), ("MacBookAir", "MacBook Air"),
            ("MacBook", "MacBook"), ("Macmini", "Mac mini"), ("MacPro", "Mac Pro"),
            ("iMacPro", "iMac Pro"), ("iMac", "iMac"),
        ]
        return known.first { identifier.hasPrefix($0.0) }?.1 ?? "Mac"
    }

    /// Windows 11 kept 10's major version; its builds start at 22000.
    static func windows(build: Int) -> String {
        build >= 22000 ? "Windows 11 PC" : "Windows 10 PC"
    }
}
