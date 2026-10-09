import Foundation

/// The profile names the keyboard keeps, as its names characteristic carries
/// them; see `config/src/profile_names.h` on the firmware branch.
///
/// The keyboard holds the names so every computer paired with it shows the
/// same ones. Each computer keeps a copy under `ProfileNames.key`, which is
/// what the HUD reads, for when the keyboard is not connected.
enum ProfileNamesWire {
    static let format: UInt8 = 1
    /// The longest name the keyboard stores, in UTF-8 bytes.
    static let maxBytes = 24
    /// The longest name a computer may offer for itself, leaving the keyboard
    /// room to number it.
    static let autoMaxBytes = 21

    enum Op: UInt8 {
        /// Names a profile; an empty name clears it.
        case set = 1
        /// Names a profile only if it has no name, numbering any other
        /// profile that already has it: "MacBook Pro M4 1", "MacBook Pro M4 2".
        case auto = 2
    }

    /// One name per profile, "" where none was given. Nil if malformed.
    static func parse(_ data: Data) -> [String]? {
        let bytes = [UInt8](data)
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
        return names
    }

    static func write(_ op: Op, index: Int, name: String) -> Data {
        let limit = op == .auto ? autoMaxBytes : maxBytes
        return Data([op.rawValue, UInt8(index)] + Array(clean(name, maxBytes: limit).utf8))
    }

    /// `name` as the keyboard will take it: no control characters, no
    /// surrounding spaces, cut at a character boundary to fit.
    static func clean(_ name: String, maxBytes: Int = maxBytes) -> String {
        let printable = String(String.UnicodeScalarView(
            name.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
        var out = printable.trimmingCharacters(in: .whitespaces)
        while out.utf8.count > maxBytes { out.removeLast() }
        return out.trimmingCharacters(in: .whitespaces)
    }
}

/// What to tell the keyboard after reading its names.
enum ProfileNameSync {
    struct Write: Equatable {
        var op: ProfileNamesWire.Op
        var index: Int
        var name: String
    }

    /// - keyboard: the names just read from the keyboard.
    /// - pending: renames made here that have not reached the keyboard yet.
    /// - own: the profile that is this computer, if known. The keyboard
    ///   takes names only from a computer that is one of its profiles, so
    ///   until that is known nothing is sent and renames wait.
    /// - deviceName: what this computer calls itself, for its own profile
    ///   when that has no name or is called "Profile N".
    static func writes(keyboard: [String], pending: [Int: String], own: Int?,
                       deviceName: String?) -> [Write] {
        guard let own else { return [] }
        var names = keyboard
        var out: [Write] = []

        for (index, name) in pending.sorted(by: { $0.key < $1.key })
        where names.indices.contains(index) {
            let name = ProfileNamesWire.clean(name)
            guard names[index] != name else { continue }
            out.append(Write(op: .set, index: index, name: name))
            names[index] = name
        }

        guard names.indices.contains(own),
              let deviceName = deviceName.map({
                  ProfileNamesWire.clean($0, maxBytes: ProfileNamesWire.autoMaxBytes)
              }),
              !deviceName.isEmpty else { return out }
        // "Profile N" is what an unnamed profile shows anyway, so a profile
        // named that is treated as unnamed. The keyboard only fills in a
        // blank name, so it is cleared first.
        if names[own] == ProfileNames.placeholder(own) {
            out.append(Write(op: .set, index: own, name: ""))
            names[own] = ""
        }
        if names[own].isEmpty {
            out.append(Write(op: .auto, index: own, name: deviceName))
        }
        return out
    }

    /// The names this computer had before the keyboard kept them, for the
    /// profiles the keyboard has no name for. "Profile N" is the placeholder,
    /// not a name, and is left out.
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

/// This computer's side of the names: its copy of the keyboard's, which is
/// what the HUD shows, and the renames made here that the keyboard has not
/// taken yet. The Mac keeps it in UserDefaults, under the keys `ProfileNames`
/// reads; Windows in settings.json.
final class ProfileNameStore {
    struct State: Equatable {
        /// One per profile, "" where there is none.
        var names: [String]
        var pending: [Int: String]
        /// Whether the names given here before the keyboard kept them have
        /// been offered to it.
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

    /// The copy here, one per profile, "" where there is none.
    func local(count: Int = ProfileNames.count) -> [String] {
        let names = load().names
        return (0..<count).map { names.indices.contains($0) ? names[$0] : "" }
    }

    /// A rename made here. It shows at once and goes to the keyboard when it
    /// next can.
    func edit(_ index: Int, _ name: String) {
        update { state in
            guard state.names.indices.contains(index) else { return }
            state.names[index] = name
            state.pending[index] = name
        }
    }

    /// The first time names are read from the keyboard, the ones given here
    /// before it kept them are queued for it.
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

    /// Takes the keyboard's names as the copy here, except where a rename made
    /// here is still on its way. A rename the keyboard already has is done
    /// with, sent or not.
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

    /// The keyboard answered a write. Taken or refused, the rename is done
    /// with: a refused one would only be refused again.
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

/// What a computer calls itself when it names its own profile: its kind and,
/// for a Mac, its chip, so "MacBook Air M4" rather than whatever the user
/// named the machine.
enum DeviceName {
    /// - productName: the IORegistry's "MacBook Air (13-inch, M4, 2025)", nil
    ///   on Macs that lack it.
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

    /// For Macs without a product name: Intel ones, whose identifiers still
    /// say what they are.
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
