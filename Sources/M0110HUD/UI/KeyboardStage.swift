import AppKit
import SceneKit
import SwiftUI

/// One cap's top face as a texture, printed like the 2D `Keycap`. Legend sizes
/// are the 2D sizes converted at the case's key pitch, so a letter takes the
/// same share of the cap in both.
struct CapFace: View, Equatable {
    var legend: CapLegend = .blank
    var isSelected = false
    var isEditable = true
    var isSpacebar = false
    /// The face, in metres.
    let size: CGSize

    static let pointsPerMetre: CGFloat = 10_000
    /// One unit-hundredth at the case's 18.46 mm pitch, in points.
    private static let unit: CGFloat = 0.0001846 * pointsPerMetre

    private var top: Color {
        isSelected ? Theme.selectedCapTop : isSpacebar ? Theme.spacebarTop : Theme.capTop
    }
    private var skirt: Color {
        isSelected ? Theme.selectedCapSkirt : isSpacebar ? Theme.spacebarSkirt : Theme.capSkirt
    }
    private var ink: Color { isSelected ? Theme.selectedCapInk : Theme.capInk }

    var body: some View {
        let w = size.width * Self.pointsPerMetre, h = size.height * Self.pointsPerMetre
        ZStack(alignment: .topLeading) {
            top
            LinearGradient(stops: [.init(color: .white.opacity(0.22), location: 0),
                                   .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
            legendView
                .padding(6 * Self.unit)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // The clamped texture stretches its edge pixels down the walls, so
            // the edge uses the skirt color.
            Rectangle().strokeBorder(skirt, lineWidth: 3)
            if !isEditable && !isSelected {
                Theme.plate.opacity(0.38)
            }
        }
        .frame(width: w, height: h)
    }

    @ViewBuilder private var legendView: some View {
        switch legend {
        case .blank:
            EmptyView()
        case .single(let glyph):
            Text(glyph).font(Theme.capLegend(26 * Self.unit)).foregroundStyle(ink)
        case .pair(let shifted, let base):
            VStack(alignment: .leading, spacing: Self.unit) {
                Text(shifted)
                Text(base)
            }
            .font(Theme.capLegend(25 * Self.unit))
            .foregroundStyle(ink)
        case .word(let word):
            Text(word)
                .font(Theme.capLegend(17 * Self.unit))
                .foregroundStyle(ink)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
        }
    }

    @MainActor func image() -> NSImage? {
        let renderer = ImageRenderer(content: self)
        renderer.scale = 1.5
        return renderer.nsImage
    }
}

extension BoardStage {
    @MainActor func paintBlank() {
        applyPalette(case: NSColor(Theme.caseFlat), plate: NSColor(Theme.plate))
        for tag in capTags {
            guard let size = capFaces[tag] else { continue }
            let position = Int(tag.split(separator: "_").first ?? "")
            paint(tag, face: CapFace(isSpacebar: position == M0110Layout.spacebarPosition,
                                     size: size).image())
        }
    }
}

/// The Keyboard pane's 3D board. Clicking a cap selects it, as on the 2D board.
struct KeyboardStageView: NSViewRepresentable {
    @ObservedObject var controller: KeyboardController

    final class Coordinator: NSObject {
        let stage = BoardStage()
        var controller: KeyboardController?
        /// What each cap was last painted with, so only changes repaint.
        var painted: [String: CapFace] = [:]

        @MainActor @objc func clicked(_ gesture: NSClickGestureRecognizer) {
            guard let view = gesture.view as? SCNView, let stage, let controller,
                  let tag = stage.capTag(at: gesture.location(in: view), in: view),
                  let position = Int(tag.split(separator: "_").first ?? ""),
                  position != M0110Layout.unmapped else { return }
            stage.tap(tag)
            controller.selectedKey = controller.selectedKey == position ? nil : position
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.isPlaying = true
        if let stage = context.coordinator.stage {
            view.scene = stage.scene
            view.pointOfView = stage.cameraNode
            stage.applyPalette(case: NSColor(Theme.caseFlat), plate: NSColor(Theme.plate))
            // Coming back from another pane, start at its camera and pull out
            // to the whole board.
            let from = BoardStage.lastShown ?? .editor
            BoardStage.lastShown = nil
            stage.setFocus(from, animated: false)
            if from != .editor {
                DispatchQueue.main.async { stage.setFocus(.editor, animated: true) }
            }
        }
        view.fadeIn(duration: 0.2)
        view.addGestureRecognizer(NSClickGestureRecognizer(target: context.coordinator,
                                                           action: #selector(Coordinator.clicked)))
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        let coordinator = context.coordinator
        coordinator.controller = controller
        guard let stage = coordinator.stage else { return }
        for tag in stage.capTags {
            guard let size = stage.capFaces[tag] else { continue }
            let position = Int(tag.split(separator: "_").first ?? "") ?? M0110Layout.unmapped
            let face = CapFace(legend: controller.legend(forKeyAt: position),
                               isSelected: controller.selectedKey == position,
                               isEditable: controller.canEdit && controller.acceptsKeycode(at: position),
                               isSpacebar: position == M0110Layout.spacebarPosition,
                               size: size)
            guard coordinator.painted[tag] != face else { continue }
            coordinator.painted[tag] = face
            stage.paint(tag, face: face.image())
        }
    }
}
