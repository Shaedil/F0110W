import Foundation
import SwiftUI

/// Observable state for the keyboard's live connection and keymap.
///
/// `StudioClient` is blocking, so every RPC runs on a private serial queue and
/// results are published back on the main queue.
/// Which physical M0110 variant is actually on the desk.
///
/// The shield's `m0110a_layout` is a superset covering every variant, so the
/// firmware reports 79 positions regardless of the board in hand. The original
/// M0110 has no numpad and no arrow cluster, so those slots exist in the keymap
/// but have no keys to press.
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
    /// The board on the desk. Not a choice: it is whatever the converter
    /// detects, and the M0110 until it says otherwise. The firmware does not
    /// yet ask the keyboard for its model, so for now that is always.
    @Published var variant: KeyboardVariant = .m0110 {
        didSet {
            if let selected = selectedKey, !isPresent(selected) { selectedKey = nil }
        }
    }
    @Published var status: String?

    private var client: StudioClient?
    /// Name to match the Bluetooth peripheral on, when discovery falls through
    /// to the wireless route.
    var deviceName = "M0110"
    private let queue = DispatchQueue(label: "m0110hud.studio", qos: .userInitiated)

    /// Lock state as last seen on the wire. Owned by `queue`; the published
    /// `lockState` is its mirror. Kept separately because the reaction to an
    /// unlock has to happen on the serial queue, where the published property
    /// cannot be read safely.
    private var lockOnWire: LockState = .locked
    private var lockPoll: DispatchSourceTimer?

    /// Whether the app should be holding a link at all. Cleared by `disconnect`
    /// so the retry loop stops rather than fighting a deliberate teardown.
    private var wantsConnection = false
    private var reconnect: DispatchWorkItem?
    private var retryDelay: TimeInterval = firstRetryDelay

    /// How often to check the lock. While locked the app asks, in case the
    /// firmware's notification of an unlock is missed. While unlocked it only
    /// reads what the firmware has sent: the keyboard re-locks after ten idle
    /// minutes, any request would restart that clock, and without listening
    /// the app went on showing an unlocked editor whose every write the
    /// keyboard refused.
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

    /// One attempt, which reschedules itself if it fails. Must run on `queue`.
    ///
    /// The link is expected to come and go: a Bluetooth keyboard sleeps, wanders
    /// out of range, and drops the connection every time its output endpoint
    /// changes. Parking in a failed state and waiting to be told to retry made
    /// that routine churn look like a fault the user had to clear by hand.
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

    /// Backs off so an absent keyboard is not hammered, but stays responsive
    /// for the common case of a link that just blipped.
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
                // Studio refuses reads as well as writes while locked, so there
                // is nothing further to fetch. `noteLock` has started polling
                // for the unlock; the pane explains the lock on its own.
                publish { self.status = nil }
                return
            }
            // Keymap first. It is what the editor cannot work without, and the
            // physical layouts, the largest reply the firmware sends, are the
            // call most likely to fail. Fetching layouts first meant one failed
            // call cost the legends too.
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
                // A firmware limit rather than a passing failure, so it is
                // spelled out: see CONFIG_ZMK_STUDIO_RPC_TX_BUF_SIZE in
                // config/m0110.conf.
                self.status = active == nil
                    ? "The keyboard could not send its physical layout: its Studio transmit "
                      + "buffer stalls part-way through that reply over Bluetooth. The board "
                      + "below is this app's own drawing; the key bindings are the keyboard's."
                    : nil
            }
        } catch let error as StudioError {
            if case .locked = error {
                // The lock re-armed mid-reload.
                noteLock(.locked)
                publish { self.status = nil }
            } else if case .portUnavailable = error {
                // Only a transport-level failure means the link itself is gone.
                // Tearing down on any error would put a call that simply timed
                // out into the reconnect loop, and reconnecting cannot fix a
                // reply the firmware will not finish sending.
                dropLink(because: error)
            } else {
                publish { self.status = "Reload failed: \(error)" }
            }
        } catch {
            publish { self.status = "Reload failed: \(error)" }
        }
    }

    /// Run a Studio call, retrying before giving up.
    ///
    /// Every failure mode worth retrying here is transient: a reply that
    /// overran its window, or a link still settling after the connection
    /// parameters were renegotiated. The alternative is an empty editor. A lock
    /// is not transient, so it returns immediately rather than spending the
    /// attempts on a call that cannot succeed.
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

    /// Re-read the lock, and fetch the keymap if it is open.
    ///
    /// Reloads whenever the keyboard is unlocked rather than only on the
    /// transition: if an earlier reload failed, the app can be unlocked and
    /// still showing nothing, and this is the button someone presses to fix
    /// that.
    func refreshLockState() {
        queue.async { [weak self] in
            guard let self, let client = self.client else { return }
            guard let lock = try? client.lockState() else { return }
            self.noteLock(lock)
            if lock == .unlocked { self.reloadEverything() }
        }
    }

    // MARK: - Lock

    /// Record a lock state read from the keyboard. Must run on `queue`.
    ///
    /// Deliberately does not reload: `reloadEverything` calls this, and the two
    /// calling each other would recurse. Callers that want the keymap fetched
    /// on an unlock ask for it themselves.
    private func noteLock(_ lock: LockState) {
        lockOnWire = lock
        publish { self.lockState = lock }
        startLockPolling()
    }

    /// The firmware said the lock changed. Must run on `queue`.
    ///
    /// Can arrive in the middle of another call's reply, so a reload it needs
    /// is queued behind that call rather than started inside it.
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
            // The whole point of the poll: the unlock happens at the keyboard,
            // and until it does there is no keymap to draw. Seeing the state
            // change without going back for the data leaves a board that is
            // correctly labelled "unlocked" and completely blank.
            if lock == .unlocked { reloadEverything() }
        } catch {
            // The poll is the app's only regular traffic, so it is where a dead
            // link shows up first. Swallowing the error, as `try?` did, left the
            // app claiming to be connected while polling a link that had gone,
            // with an empty board and nothing on screen to explain it. A
            // dropped Bluetooth link is routine: sleep, range, or the keyboard
            // switching its output endpoint.
            dropLink(because: error)
        }
    }

    /// Give up on the current client and let the user reconnect.
    ///
    /// `BLETransport` latches its failure and every later call throws the same
    /// error, so there is nothing to salvage once one does. Must run on
    /// `queue`.
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

    /// Rebind one key to send `param`, a page-encoded HID usage. A keycode
    /// behaviour is preserved, so a `&kp` stays a key press and only the
    /// keycode moves; an empty `&trans`/`&none` slot becomes a `&kp`.
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
        // The layer the edit was made on, not whichever is showing when the
        // reply lands.
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

    /// Report a write the keyboard did not take. Must run on `queue`.
    ///
    /// A lock error means Studio re-locked without the app hearing of it, so
    /// the lock is recorded: the editor stops offering writes and the poll
    /// picks up the unlock.
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

    /// The keys to draw, and which firmware position each one edits.
    ///
    /// For a US ANSI M0110 this is a hand-built table rather than the firmware's
    /// geometry, because the reported layout is an all-variants superset with ISO
    /// proportions. The M0110A case draws exactly what the firmware reports.
    var displayKeys: [DisplayKey] {
        switch variant {
        case .m0110:
            return M0110Layout.ansi
        case .m0110a:
            // Only fall back to the firmware's own geometry if it reports a
            // layout we do not have a hand-shaped table for.
            return layout.keys.isEmpty ? [] : M0110Layout.m0110a
        }
    }

    /// Board width in hundredths of a key unit, for sizing the canvas.
    var displayWidth: Int32 {
        switch variant {
        case .m0110: return M0110Layout.unitsWide
        case .m0110a: return M0110Layout.m0110aUnitsWide
        }
    }

    /// Whether this keymap position corresponds to a key that physically exists
    /// on the selected variant. Derived from the geometry the firmware reports,
    /// matching the shield's layout: the numpad block sits at x >= 1500, and the
    /// arrow cluster is Up at (1325,300) plus Left/Right/Down on the bottom row.
    func isPresent(_ position: Int) -> Bool {
        switch variant {
        case .m0110: return M0110Layout.ansiPositions.contains(position)
        case .m0110a: return layout.keys.indices.contains(position)
        }
    }


    /// Rows are always five deep, in hundredths of a key unit.
    var displayHeight: Int32 { 500 }

    /// Recessed key blocks in the drawn case: one for the M0110, plus the numpad
    /// for the M0110A.
    var boardWells: [CGRect] {
        switch variant {
        case .m0110:
            return [CGRect(x: 0, y: 0, width: 1500, height: 500)]
        case .m0110a:
            return [CGRect(x: 0, y: 0, width: 1500, height: 500),
                    CGRect(x: 1520, y: 0, width: 440, height: 500)]
        }
    }

    /// Bezel widths for the selected variant.
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

    /// The M0110's bottom row is inset at the left, and that gap is where the
    /// case carries the embossed Apple logo. The M0110A's bottom row is full
    /// width, so it has none.
    var boardLogoCell: CGRect? {
        variant == .m0110 ? M0110Layout.appleLogoCell : nil
    }

    /// Keycap text for a slot, honouring what the binding's behaviour means.
    func label(forKeyAt position: Int) -> String {
        guard position != M0110Layout.unmapped else { return "\u{2014}" }
        guard let layer = activeLayer, layer.bindings.indices.contains(position) else { return "" }
        let binding = layer.bindings[position]
        guard let info = behaviors[binding.behaviorID] else {
            // Unknown behaviour: fall back to the raw parameter rather than
            // pretending it is a keycode.
            return binding.param1 == 0 ? "·" : "0x\(String(binding.param1, radix: 16))"
        }
        switch info.param1 {
        case .hidUsage:
            return HIDKeycodes.label(for: binding.param1)
        case .layerID:
            // A layer-tap carries the layer in param1 and the tapped keycode in
            // param2. The keycode is what the key types, so label with that.
            if binding.param2 != 0 { return HIDKeycodes.label(for: binding.param2) }
            return "\(info.shortName)\(binding.param1)"
        case .none, .other:
            return info.shortName
        }
    }

    /// How a slot's cap is printed. Resolves the binding exactly as
    /// `label(forKeyAt:)` does, but keeps the HID usage instead of collapsing
    /// straight to a string, because the M0110's legend style (word, shifted
    /// pair, or centred glyph) is a property of the usage rather than of the
    /// text.
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
            // A layer-tap prints what it types, same as `label(forKeyAt:)`.
            return usageLegend(binding.param2)
        case .layerID, .none, .other:
            return CapLegend.forText(label(forKeyAt: position))
        }
    }

    /// A parameter off the keyboard page has no printed legend to imitate, so it
    /// falls back to whatever text the label logic produced.
    private func usageLegend(_ param: UInt32) -> CapLegend {
        let (page, usage) = HIDKeycodes.decode(param)
        guard page == HIDKeycodes.keyboardPage else {
            return CapLegend.forText(HIDKeycodes.label(for: param))
        }
        return CapLegend.forUsage(usage)
    }

    /// Bindings whose behaviour takes a keycode can be remapped by keycode, and
    /// so can empty `&trans`/`&none` slots, which become a `&kp`.
    func acceptsKeycode(at position: Int) -> Bool {
        guard position != M0110Layout.unmapped else { return false }
        guard let layer = activeLayer, layer.bindings.indices.contains(position) else { return false }
        return layer.bindings[position].sending(0, behaviors: behaviors) != nil
    }

    /// The keycode a slot sends now, or nil if its behaviour takes none.
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
