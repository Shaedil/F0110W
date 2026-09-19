import Foundation

/// Command-line check that the RPC layer actually talks to the keyboard.
/// Exists so the protocol can be validated without any UI in the picture.
enum StudioProbe {
    static func run(verbose: Bool) -> Int32 {
        let ports = SerialTransport.candidatePorts()
        print("candidate ports: \(ports.isEmpty ? "none found" : ports.joined(separator: ", "))")
        print("bluetooth: tried after the serial ports")

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
            print("\nkeymap (\(keymap.layers.count) layers, \(keymap.availableLayers) available):")
            for layer in keymap.layers {
                let name = layer.name.isEmpty ? "(unnamed)" : layer.name
                print("  id \(layer.id): \(name) (\(layer.bindings.count) bindings)")
                if verbose {
                    let sample = layer.bindings.prefix(8)
                        .map { "\($0.behaviorID)/\($0.param1)" }
                        .joined(separator: " ")
                    print("       first bindings: \(sample)")
                }
            }
        } catch {
            print("keymap: failed (\(error))")
            return 1
        }

        return 0
    }
}
