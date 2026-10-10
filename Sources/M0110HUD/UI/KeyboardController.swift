import Foundation
import SwiftUI

/// Which M0110 model is on the desk. The shield's `m0110a_layout` covers every
/// model, so the firmware always reports 79 positions. The original M0110 has
/// no numpad or arrows, so those slots have no physical key.
enum KeyboardVariant: String, CaseIterable, Identifiable {
    case m0110 = "M0110"
    case m0110a = "M0110A"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .m0110: return "compact, with no numpad or arrow cluster"
        case .m0110a: return "full config layout, numpad and arrows"
        }
    }
}

/// `StudioClient` blocks, so every RPC runs on a private serial queue and
/// results are published on the main queue.
final class KeyboardController: ObservableObject {
    enum Connection: Equatable {
        case disconnected
        case connecting
        case connected(port: String, device: String)
        case failed(String)

        var isConnected: Bool { if case .connected = self { return true } else { return false } }

        var logLine: String {
            switch self {
            case .disconnected: return "disconnected"
            case .connecting: return "connecting"
            case .connected(let port, let device): return "connected to \(device) on \(port)"
            case .failed(let reason): return "failed: \(reason)"
            }
        }
    }

    @Published var connection: Connection = .disconnected {
        didSet {
            guard connection != oldValue else { return }
            DebugLog.shared.add(.studio, connection.logLine)
        }
    }
    @Published var lockState: LockState = .locked
    @Published var layout = PhysicalLayout()
    @Published var keymap = Keymap()
    @Published var activeLayerIndex = 0
    @Published var selectedKey: Int?
    @Published var pendingEdits = 0
    @Published var behaviors: [Int32: BehaviorInfo] = [:]
    /// Should come from the converter. The firmware does not read the
    /// keyboard's model yet, so this is always `.m0110` for now.
    @Published var variant: KeyboardVariant = .m0110 {
        didSet {
            if let selected = selectedKey, !isPresent(selected) { selectedKey = nil }
        }
    }
    @Published var status: String?

    private var client: StudioClient?
    /// Bluetooth peripheral name to match when USB discovery finds nothing.
    var deviceName = "M0110"
    private let queue = DispatchQueue(label: "m0110hud.studio", qos: .userInitiated)

    /// Last lock state seen from the keyboard, owned by `queue`. `lockState` is
    /// a main-queue copy that `queue` cannot read safely.
    private var lockOnWire: LockState = .locked
    private var lockPoll: DispatchSourceTimer?

    /// Cleared by `disconnect` so the retry loop stops.
    private var wantsConnection = false
    private var reconnect: DispatchWorkItem?
    private var retryDelay: TimeInterval = firstRetryDelay

    /// While locked, the poll asks for the lock state in case the unlock
    /// notification is missed. While unlocked, it only reads notifications,
    /// since any request would reset the keyboard's 10-minute idle re-lock timer.
    private static let lockPollInterval: TimeInterval = 1.5

    deinit { lockPoll?.cancel() }

    var activeLayer: KeymapLayer? {
        keymap.layers.indices.contains(activeLayerIndex) ? keymap.layers[activeLayerIndex] : nil
    }

    var canEdit: Bool { connection.isConnected && lockState == .unlocked }

    // MARK: - Connection

    func connect() {
        guard !connection.isConnected else { return }
        connection = .connecting
        status = nil
        wantsConnection = true
        queue.async { [weak self] in self?.attemptConnect() }
    }

    /// Tries once and reschedules itself on failure, since a Bluetooth link
    /// drops often (sleep, range, output switch). Must run on `queue`.
    private func attemptConnect() {
        guard wantsConnection, client == nil else { return }
        guard let found = StudioClient.discover(
            deviceName: deviceName,
            log: { DebugLog.shared.add(.studio, $0) }) else {
            let delay = nextRetryDelay()
            publish {
                self.connection = .failed(
                    "No keyboard answered over USB or Bluetooth; retrying. Studio binds to "
                    + "whichever endpoint the keyboard is outputting to, so if it is on "
                    + "Bluetooth, switch its output with the Fn-layer &out key.")
            }
            scheduleReconnect(after: delay)
            return
        }
        retryDelay = Self.firstRetryDelay
        client = found.client
        // Runs on `queue`: the client is only ever used there.
        found.client.onLockStateChanged = { [weak self] lock in self?.lockAnnounced(lock) }
        publish {
            self.connection = .connected(port: found.client.label, device: found.info.name)
        }
        reloadEverything()
    }

    /// Retry backoff in seconds. It starts short because most drops are brief.
    private static let firstRetryDelay: TimeInterval = 2
    private static let maxRetryDelay: TimeInterval = 15

    private func nextRetryDelay() -> TimeInterval {
        defer { retryDelay = min(retryDelay * 2, Self.maxRetryDelay) }
        return retryDelay
    }

    /// Must run on `queue`.
    private func scheduleReconnect(after delay: TimeInterval) {
        guard wantsConnection else { return }
        reconnect?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.attemptConnect() }
        reconnect = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.wantsConnection = false
            self.reconnect?.cancel()
            self.reconnect = nil
            self.stopLockPolling()
            self.client?.close()
            self.client = nil
            self.lockOnWire = .locked
            self.publish {
                self.connection = .disconnected
                self.keymap = Keymap()
                self.layout = PhysicalLayout()
                self.selectedKey = nil
                self.pendingEdits = 0
            }
        }
    }

    /// Refresh lock state, layout and keymap. Must run on `queue`.
    private func reloadEverything() {
        guard let client else { return }
        do {
            let lock = try client.lockState()
            noteLock(lock)
            guard lock == .unlocked else {
                // Studio refuses reads while locked. `noteLock` has started
                // polling for the unlock.
                publish { self.status = nil }
                return
            }
            // Keymap first, so a failed layouts reply (the largest and most
            // likely to fail) does not lose the legends.
            let km = try retrying { try client.keymap() }
            let table = (try? client.behaviorTable()) ?? [:]
            let reported = try? retrying { try client.physicalLayouts() }
            let active = reported.map { layouts in
                layouts.layouts.indices.contains(Int(layouts.activeIndex))
                    ? layouts.layouts[Int(layouts.activeIndex)]
                    : (layouts.layouts.first ?? PhysicalLayout())
            }
            publish {
                if let active { self.layout = active }
                self.keymap = km
                self.behaviors = table
                if self.activeLayerIndex >= km.layers.count { self.activeLayerIndex = 0 }
                // A firmware limit, see CONFIG_ZMK_STUDIO_RPC_TX_BUF_SIZE in
                // config/m0110.conf.
                self.status = active == nil
                    ? "The keyboard could not send its physical layout: its Studio transmit "
                      + "buffer stalls part-way through that reply over Bluetooth. The board "
                      + "below is this app's own drawing; the key bindings are the keyboard's."
                    : nil
            }
        } catch let error as StudioError {
            if case .locked = error {
                noteLock(.locked)
                publish { self.status = nil }
            } else if case .portUnavailable = error {
                // Only a transport failure means the link is gone. Reconnecting
                // will not fix a reply that timed out.
                dropLink(because: error)
            } else {
                publish { self.status = "Reload failed: \(error)" }
            }
        } catch {
            publish { self.status = "Reload failed: \(error)" }
        }
    }

    /// Retries a Studio call, for replies that time out or a link still settling
    /// after new connection parameters. A lock error is thrown right away.
    private func retrying<T>(attempts: Int = 3, _ work: () throws -> T) throws -> T {
        var lastError: Error?
        for attempt in 0..<attempts {
            do {
                return try work()
            } catch let error as StudioError {
                if case .locked = error { throw error }
                lastError = error
            } catch {
                lastError = error
            }
            if attempt + 1 < attempts { Thread.sleep(forTimeInterval: 0.4) }
        }
        throw lastError ?? StudioError.rpc("the request failed")
    }

    func refresh() {
        queue.async { [weak self] in self?.reloadEverything() }
    }

    /// Re-reads the lock and reloads every time the keyboard is unlocked. That
    /// also recovers from an earlier reload that failed.
    func refreshLockState() {
        queue.async { [weak self] in
            guard let self, let client = self.client else { return }
            guard let lock = try? client.lockState() else { return }
            self.noteLock(lock)
            if lock == .unlocked { self.reloadEverything() }
        }
    }

    // MARK: - Lock

    /// Does not reload, since `reloadEverything` calls this. Must run on `queue`.
    private func noteLock(_ lock: LockState) {
        lockOnWire = lock
        publish { self.lockState = lock }
        startLockPolling()
    }

    /// Can arrive in the middle of another call's reply, so the reload is
    /// queued after that call. Must run on `queue`.
    private func lockAnnounced(_ lock: LockState) {
        guard lock != lockOnWire else { return }
        noteLock(lock)
        if lock == .unlocked {
            queue.async { [weak self] in self?.reloadEverything() }
        } else {
            publish {
                self.status = "Studio locked again. Press the key bound to &studio_unlock to keep editing."
            }
        }
    }

    /// Must run on `queue`.
    private func startLockPolling() {
        guard lockPoll == nil, client != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.lockPollInterval,
                       repeating: Self.lockPollInterval)
        timer.setEventHandler { [weak self] in self?.pollLock() }
        lockPoll = timer
        timer.resume()
    }

    /// Must run on `queue`.
    private func stopLockPolling() {
        lockPoll?.cancel()
        lockPoll = nil
    }

    /// Must run on `queue`.
    private func pollLock() {
        guard let client else { stopLockPolling(); return }
        do {
            guard lockOnWire == .locked else {
                try client.readNotifications()
                return
            }
            let lock = try client.lockState()
            guard lock != lockOnWire else { return }
            noteLock(lock)
            // Fetch the keymap now, or the board stays blank after the unlock.
            if lock == .unlocked { reloadEverything() }
        } catch {
            // The poll is the only regular traffic, so a dead link shows up here first.
            dropLink(because: error)
        }
    }

    /// `BLETransport` keeps throwing the same error after its first failure,
    /// so the client cannot be reused. Must run on `queue`.
    private func dropLink(because error: Error) {
        stopLockPolling()
        client?.close()
        client = nil
        lockOnWire = .locked
        publish {
            self.connection = .failed("The link dropped; reconnecting. (\(error))")
            self.status = nil
        }
        scheduleReconnect(after: Self.firstRetryDelay)
    }

    // MARK: - Editing

    /// `param` is a page-encoded HID usage. The key keeps its behavior and only
    /// the keycode changes, except `&trans`/`&none`, which become `&kp`.
    func rebind(keyPosition: Int, to param: UInt32) {
        guard let layer = activeLayer else { return }
        guard layer.bindings.indices.contains(keyPosition) else { return }
        guard canEdit else {
            status = "Keyboard is locked. Press the key bound to &studio_unlock"
            return
        }
        let previous = layer.bindings[keyPosition]
        guard let binding = previous.sending(param, behaviors: behaviors) else {
            status = "\(behaviorName(at: keyPosition)) does not take a keycode parameter"
            return
        }
        guard binding != previous else { return }

        let layerID = layer.id
        // Captured now, since the user may switch layers before the reply.
        let layerIndex = activeLayerIndex
        queue.async { [weak self] in
            guard let self, let client = self.client else { return }
            do {
                try client.setBinding(layerID: layerID,
                                     keyPosition: Int32(keyPosition),
                                     binding: binding)
                self.publish {
                    if self.keymap.layers.indices.contains(layerIndex),
                       self.keymap.layers[layerIndex].bindings.indices.contains(keyPosition) {
                        self.keymap.layers[layerIndex].bindings[keyPosition] = binding
                    }
                    self.pendingEdits += 1
                    self.status = "Set key \(keyPosition) to \(HIDKeycodes.name(for: binding.param1))"
                }
            } catch {
                self.editFailed(error)
            }
        }
    }

    /// A lock error means Studio re-locked without telling the app, so record
    /// it and let the poll catch the unlock. Must run on `queue`.
    private func editFailed(_ error: Error) {
        if let studio = error as? StudioError, case .locked = studio {
            noteLock(.locked)
            publish {
                self.status = "Studio locked again. Press the key bound to &studio_unlock, then try again."
            }
        } else {
            publish { self.status = "\(error)" }
        }
    }

    func save() {
        guard pendingEdits > 0 else { return }
        queue.async { [weak self] in
            guard let self, let client = self.client else { return }
            do {
                try client.saveChanges()
                self.publish {
                    self.pendingEdits = 0
                    self.status = "Saved to the keyboard's flash"
                }
            } catch {
                self.editFailed(error)
            }
        }
    }

    func discard() {
        guard pendingEdits > 0 else { return }
        queue.async { [weak self] in
            guard let self, let client = self.client else { return }
            do {
                try client.discardChanges()
                self.publish { self.pendingEdits = 0; self.status = "Discarded unsaved changes" }
                self.reloadEverything()
            } catch {
                self.editFailed(error)
            }
        }
    }

    /// The keys to draw and the firmware position each one edits. The M0110
    /// uses a hand-built ANSI table because the firmware's layout is an
    /// all-models superset with ISO proportions.
    var displayKeys: [DisplayKey] {
        switch variant {
        case .m0110:
            return M0110Layout.ansi
        case .m0110a:
            return layout.keys.isEmpty ? [] : M0110Layout.m0110a
        }
    }

    /// Board width in hundredths of a key unit.
    var displayWidth: Int32 {
        switch variant {
        case .m0110: return M0110Layout.unitsWide
        case .m0110a: return M0110Layout.m0110aUnitsWide
        }
    }

    /// Whether this keymap position has a physical key on the selected model.
    func isPresent(_ position: Int) -> Bool {
        switch variant {
        case .m0110: return M0110Layout.ansiPositions.contains(position)
        case .m0110a: return layout.keys.indices.contains(position)
        }
    }


    /// Five rows, in hundredths of a key unit.
    var displayHeight: Int32 { 500 }

    /// Recessed key wells in the case. The M0110A adds one for the numpad.
    var boardWells: [CGRect] {
        switch variant {
        case .m0110:
            return [CGRect(x: 0, y: 0, width: 1500, height: 500)]
        case .m0110a:
            return [CGRect(x: 0, y: 0, width: 1500, height: 500),
                    CGRect(x: 1520, y: 0, width: 440, height: 500)]
        }
    }

    var boardBezel: BoardCase.Bezel {
        variant == .m0110 ? .m0110 : .m0110a
    }

    /// Parts of the plate that are really bezel; see `M0110Layout.bezelPatches`.
    var boardBezelPatches: [CGRect] {
        switch variant {
        case .m0110: return M0110Layout.bezelPatches
        case .m0110a: return []
        }
    }

    /// Gap left of the M0110's bottom row, where the case has the Apple logo.
    var boardLogoCell: CGRect? {
        variant == .m0110 ? M0110Layout.appleLogoCell : nil
    }

    func label(forKeyAt position: Int) -> String {
        guard position != M0110Layout.unmapped else { return "\u{2014}" }
        guard let layer = activeLayer, layer.bindings.indices.contains(position) else { return "" }
        let binding = layer.bindings[position]
        guard let info = behaviors[binding.behaviorID] else {
            // Unknown behavior: show the raw parameter instead of guessing it
            // is a keycode.
            return binding.param1 == 0 ? "·" : "0x\(String(binding.param1, radix: 16))"
        }
        switch info.param1 {
        case .hidUsage:
            return HIDKeycodes.label(for: binding.param1)
        case .layerID:
            // A layer-tap has the layer in param1 and the tapped keycode in
            // param2. Label it with the keycode.
            if binding.param2 != 0 { return HIDKeycodes.label(for: binding.param2) }
            return "\(info.shortName)\(binding.param1)"
        case .none, .other:
            return info.shortName
        }
    }

    /// Same lookup as `label(forKeyAt:)`, but keeps the HID usage because the
    /// cap's legend style depends on it.
    func legend(forKeyAt position: Int) -> CapLegend {
        guard position != M0110Layout.unmapped else { return .single("\u{2014}") }
        guard let layer = activeLayer, layer.bindings.indices.contains(position) else { return .blank }
        let binding = layer.bindings[position]
        guard let info = behaviors[binding.behaviorID] else {
            return CapLegend.forText(label(forKeyAt: position))
        }
        switch info.param1 {
        case .hidUsage:
            return usageLegend(binding.param1)
        case .layerID where binding.param2 != 0:
            return usageLegend(binding.param2)
        case .layerID, .none, .other:
            return CapLegend.forText(label(forKeyAt: position))
        }
    }

    /// Usages off the keyboard page have no real legend, so use the label text.
    private func usageLegend(_ param: UInt32) -> CapLegend {
        let (page, usage) = HIDKeycodes.decode(param)
        guard page == HIDKeycodes.keyboardPage else {
            return CapLegend.forText(HIDKeycodes.label(for: param))
        }
        return CapLegend.forUsage(usage)
    }

    /// True for keycode behaviors and for `&trans`/`&none`, which become `&kp`.
    func acceptsKeycode(at position: Int) -> Bool {
        guard position != M0110Layout.unmapped else { return false }
        guard let layer = activeLayer, layer.bindings.indices.contains(position) else { return false }
        return layer.bindings[position].sending(0, behaviors: behaviors) != nil
    }

    func keycode(at position: Int) -> UInt32? {
        guard position != M0110Layout.unmapped else { return nil }
        guard let layer = activeLayer, layer.bindings.indices.contains(position) else { return nil }
        let binding = layer.bindings[position]
        guard behaviors[binding.behaviorID]?.param1 == .hidUsage else { return nil }
        return binding.param1
    }

    func behaviorName(at position: Int) -> String {
        guard position != M0110Layout.unmapped else { return "not in the matrix transform" }
        guard let layer = activeLayer, layer.bindings.indices.contains(position) else { return "—" }
        let id = layer.bindings[position].behaviorID
        return behaviors[id]?.displayName ?? "behaviour \(id)"
    }

    private func publish(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }
}
