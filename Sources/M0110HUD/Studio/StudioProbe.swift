import Foundation

/// Command-line check that the RPC layer can talk to the keyboard, without the UI.
enum StudioProbe {
    static func run(verbose: Bool) -> Int32 {
        let ports = SerialTransport.candidatePorts()
        print("candidate ports: \(ports.isEmpty ? "none found" : ports.joined(separator: ", "))")
        #if canImport(CoreBluetooth)
        print("bluetooth: tried after the serial ports")
        #else
        print("bluetooth: not on this platform; USB only")
        #endif

        guard let (client, info) = StudioClient.discover(
            deviceName: "M0110", log: { if verbose { print("  \($0)") } }) else {
            print("Nothing answered get_device_info over USB or Bluetooth.")
            print("Check that CONFIG_ZMK_STUDIO=y is flashed, and note that the firmware binds")
            print("its RPC to the endpoint the keyboard is outputting to: a board on USB will")
            print("not answer over Bluetooth, and vice versa.")
            return 1
        }
        defer { client.close() }

        print("\nconnected on \(client.label)")
        let serial = info.serialNumber.map { String(format: "%02X", $0) }.joined()
        print("  device name   : \(info.name)")
        print("  serial number : \(serial.isEmpty ? "(none)" : serial)")

        do {
            let lock = try client.lockState()
            print("  lock state    : \(lock == .unlocked ? "UNLOCKED" : "LOCKED (press the &studio_unlock key to edit)")")
        } catch {
            print("  lock state    : failed (\(error))")
        }

        do {
            let layouts = try client.physicalLayouts()
            print("\nphysical layouts (active index \(layouts.activeIndex)):")
            for (i, layout) in layouts.layouts.enumerated() {
                let marker = i == Int(layouts.activeIndex) ? "*" : " "
                print("  \(marker) [\(i)] \(layout.name) (\(layout.keys.count) keys)")
                if verbose, let first = layout.keys.first {
                    print("       first key: \(first.width)x\(first.height) at (\(first.x),\(first.y))")
                }
            }
        } catch {
            print("physical layouts: failed (\(error))")
        }

        do {
            let keymap = try client.keymap()
            let behaviors = verbose ? (try? client.behaviorTable()) ?? [:] : [:]
            print("\nkeymap (\(keymap.layers.count) layers, \(keymap.availableLayers) available):")
            for layer in keymap.layers {
                let name = layer.name.isEmpty ? "(unnamed)" : layer.name
                print("  id \(layer.id): \(name) (\(layer.bindings.count) bindings)")
                guard verbose else { continue }
                // Every binding as position=behavior(keycode), skipping &trans.
                let shown = layer.bindings.enumerated().compactMap { position, binding -> String? in
                    let behavior = behaviors[binding.behaviorID]?.displayName ?? "#\(binding.behaviorID)"
                    if behavior.lowercased() == "transparent" { return nil }
                    let key = binding.param1 == 0 ? "" : "(\(HIDKeycodes.name(for: binding.param1)))"
                    return "\(position)=\(behavior)\(key)"
                }
                for line in stride(from: 0, to: shown.count, by: 6) {
                    print("       " + shown[line..<min(line + 6, shown.count)].joined(separator: "  "))
                }
            }
        } catch {
            print("keymap: failed (\(error))")
            return 1
        }

        return 0
    }
}
