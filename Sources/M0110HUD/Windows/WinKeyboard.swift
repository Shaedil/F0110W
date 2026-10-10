import Foundation

/// Keymap editor link over ZMK Studio on USB serial, like the Mac's KeyboardController.
/// StudioClient blocks, so calls run on a private queue and results come back on the app thread.
final class WinKeyboard {
    enum Connection: Equatable {
        case disconnected
        case connecting
        case connected(port: String, device: String)
        case failed(String)

        var isConnected: Bool { if case .connected = self { return true } else { return false } }
    }

    private(set) var connection: Connection = .disconnected
    private(set) var lockState: LockState = .locked
    private(set) var keymap = Keymap()
    private(set) var behaviors: [Int32: BehaviorInfo] = [:]
    private(set) var pendingEdits = 0
    private(set) var status: String?
    private(set) var layers: [LayerJSON] = []

    /// Called on the app thread after anything above changes.
    var onChange: (() -> Void)?
    /// Replaces StudioClient.discover. Tests pass in a scripted firmware here.
    var discover: (() -> (client: StudioClient, info: DeviceInfo)?)?
    var deviceName = "M0110"
    var verbose = false

    var canEdit: Bool { connection.isConnected && lockState == .unlocked }

    private var client: StudioClient?
    private let queue = DispatchQueue(label: "m0110hud.studio", qos: .userInitiated)
    /// Last lock state seen on the wire. Queue only.
    private var lockOnWire: LockState = .locked
    private var lockPoll: DispatchSourceTimer?
    private var wantsConnection = false
    private var reconnect: DispatchWorkItem?
    private var retryDelay: TimeInterval = firstRetryDelay

    /// While locked, poll in case the unlock notification is missed. While unlocked, only
    /// listen, because any request would reset the firmware's 10-minute idle lock.
    private static let lockPollInterval: TimeInterval = 1.5
    private static let firstRetryDelay: TimeInterval = 2
    private static let maxRetryDelay: TimeInterval = 15

    deinit { lockPoll?.cancel() }

    // MARK: Connection

    func connect() {
        guard !connection.isConnected else { return }
        connection = .connecting
        status = nil
        wantsConnection = true
        onChange?()
        queue.async { [weak self] in self?.attemptConnect() }
    }

    /// Must run on `queue`. Reschedules itself until the keyboard answers.
    private func attemptConnect() {
        guard wantsConnection, client == nil else { return }
        let verbose = self.verbose
        let found = discover.map { $0() } ?? StudioClient.discover(
            deviceName: deviceName, log: { log("[studio] \($0)", verbose: verbose) })
        guard let found else {
            let delay = nextRetryDelay()
            publish {
                self.connection = .failed(
                    "No keyboard answered over USB; retrying. Studio binds to whichever endpoint the keyboard "
                    + "is outputting to, so if it is on Bluetooth, switch its output to USB with the Fn-layer "
                    + "&out key.")
            }
            scheduleReconnect(after: delay)
            return
        }
        retryDelay = Self.firstRetryDelay
        client = found.client
        found.client.onLockStateChanged = { [weak self] lock in self?.lockAnnounced(lock) }
        publish { self.connection = .connected(port: found.client.label, device: found.info.name) }
        reloadEverything()
    }

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

    /// Frees the serial port when the window closes, so other tools like ZMK Studio can open it.
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
                self.layers = []
                self.pendingEdits = 0
                self.status = nil
            }
        }
    }

    /// Must run on `queue`.
    private func reloadEverything() {
        guard let client else { return }
        do {
            let lock = try client.lockState()
            noteLock(lock)
            guard lock == .unlocked else {
                publish { self.status = nil }
                return
            }
            // Keymap first, since layouts fail most often and the board drawing does not need them.
            let km = try retrying { try client.keymap() }
            let table = (try? client.behaviorTable()) ?? [:]
            let layers = KeymapModel.layers(km, behaviors: table)
            publish {
                self.keymap = km
                self.behaviors = table
                self.layers = layers
                self.status = nil
            }
        } catch let error as StudioError {
            if case .locked = error {
                noteLock(.locked)
                publish { self.status = nil }
            } else if case .portUnavailable = error {
                dropLink(because: error)
            } else {
                publish { self.status = "Reload failed: \(error)" }
            }
        } catch {
            publish { self.status = "Reload failed: \(error)" }
        }
    }

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

    func reload() {
        if connection.isConnected {
            queue.async { [weak self] in self?.reloadEverything() }
        } else {
            connect()
        }
    }

    func refreshLockState() {
        queue.async { [weak self] in
            guard let self, let client = self.client else { return }
            guard let lock = try? client.lockState() else { return }
            self.noteLock(lock)
            if lock == .unlocked { self.reloadEverything() }
        }
    }

    // MARK: Lock

    /// Must run on `queue`.
    private func noteLock(_ lock: LockState) {
        lockOnWire = lock
        publish { self.lockState = lock }
        startLockPolling()
    }

    /// The firmware reported a lock change. Must run on `queue`.
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
        timer.schedule(deadline: .now() + Self.lockPollInterval, repeating: Self.lockPollInterval)
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
            if lock == .unlocked { reloadEverything() }
        } catch {
            // The poll is the only regular traffic, so a pulled cable or a switch to Bluetooth shows up here.
            dropLink(because: error)
        }
    }

    /// Must run on `queue`.
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

    // MARK: Editing

    /// `param` is a page-encoded HID usage, as from the Mac's picker.
    func rebind(layerIndex: Int, position: Int, to param: UInt32) {
        guard keymap.layers.indices.contains(layerIndex) else { return }
        let layer = keymap.layers[layerIndex]
        guard layer.bindings.indices.contains(position) else { return }
        guard canEdit else {
            status = "Keyboard is locked. Press the key bound to &studio_unlock"
            onChange?()
            return
        }
        let previous = layer.bindings[position]
        guard let binding = previous.sending(param, behaviors: behaviors) else {
            let name = behaviors[previous.behaviorID]?.displayName ?? "behaviour \(previous.behaviorID)"
            status = "\(name) does not take a keycode parameter"
            onChange?()
            return
        }
        guard binding != previous else { return }

        let layerID = layer.id
        queue.async { [weak self] in
            guard let self, let client = self.client else { return }
            do {
                try client.setBinding(layerID: layerID, keyPosition: Int32(position), binding: binding)
                self.publish {
                    if self.keymap.layers.indices.contains(layerIndex),
                       self.keymap.layers[layerIndex].bindings.indices.contains(position) {
                        self.keymap.layers[layerIndex].bindings[position] = binding
                        self.layers = KeymapModel.layers(self.keymap, behaviors: self.behaviors)
                    }
                    self.pendingEdits += 1
                    self.status = "Set key \(position) to \(HIDKeycodes.name(for: binding.param1))"
                }
            } catch {
                self.editFailed(error)
            }
        }
    }

    /// Must run on `queue`.
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
                self.publish {
                    self.pendingEdits = 0
                    self.status = "Discarded unsaved changes"
                }
                self.reloadEverything()
            } catch {
                self.editFailed(error)
            }
        }
    }

    /// Uses Main.async because the Win32 loop owns the main thread on Windows.
    private func publish(_ work: @escaping () -> Void) {
        Main.async { [weak self] in
            work()
            self?.onChange?()
        }
    }
}
