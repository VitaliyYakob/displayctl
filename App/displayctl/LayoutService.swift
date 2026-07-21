import CoreGraphics
import Foundation

/// The logical desktop geometry reported by CoreGraphics for one display.
struct DisplayLayoutItem {
    let display: DisplayDevice
    let x: Int32
    let y: Int32
    let width: Int
    let height: Int
    let rotation: Double
    let isMain: Bool
    let changed: Bool
}

/// Relative placement accepted by `set --layout`.
enum RelativeLayoutPosition: String {
    case left
    case right
    case above
    case below
}

/// Reads display geometry and persists layout changes through CoreGraphics.
final class LayoutService {
    func item(for display: DisplayDevice, changed: Bool = false) -> DisplayLayoutItem {
        let bounds = CGDisplayBounds(display.id)
        return DisplayLayoutItem(
            display: display,
            x: Self.int32(bounds.origin.x),
            y: Self.int32(bounds.origin.y),
            width: Int(bounds.width.rounded()),
            height: Int(bounds.height.rounded()),
            rotation: CGDisplayRotation(display.id),
            isMain: CGDisplayIsMain(display.id) != 0,
            changed: changed
        )
    }

    func setMain(
        _ target: DisplayDevice,
        among onlineDisplays: [DisplayDevice],
        dryRun: Bool
    ) throws -> [DisplayLayoutItem] {
        guard CGDisplayIsActive(target.id) != 0 else {
            throw DisplayCtlError.displayConfiguration(L10n.text(
                "монитор \(target.name) не является активным",
                "display \(target.name) is not active"
            ))
        }
        let active = onlineDisplays.filter { CGDisplayIsActive($0.id) != 0 }
        guard !active.contains(where: { $0.isMirrored }) else {
            throw DisplayCtlError.displayConfiguration(L10n.text(
                "сначала отключите зеркалирование",
                "disable mirroring first"
            ))
        }

        let before = Dictionary(uniqueKeysWithValues: active.map { ($0.id, item(for: $0)) })
        let targetBounds = CGDisplayBounds(target.id)
        // The main display must occupy (0, 0). Translate every active display
        // by the same delta so their relative arrangement does not change.
        let deltaX = Self.int32(targetBounds.origin.x)
        let deltaY = Self.int32(targetBounds.origin.y)
        let proposed = try active.map { display -> DisplayLayoutItem in
            let current = item(for: display)
            let newX = try Self.subtract(current.x, deltaX)
            let newY = try Self.subtract(current.y, deltaY)
            return DisplayLayoutItem(
                display: display,
                x: newX,
                y: newY,
                width: current.width,
                height: current.height,
                rotation: current.rotation,
                isMain: display.id == target.id,
                changed: newX != current.x || newY != current.y || current.isMain != (display.id == target.id)
            )
        }

        if !dryRun, proposed.contains(where: \.changed) {
            try apply(origins: proposed.map { ($0.display, $0.x, $0.y) })
            return active.map { display in
                let actual = item(for: display)
                guard let previous = before[display.id] else { return actual }
                return DisplayLayoutItem(
                    display: display,
                    x: actual.x,
                    y: actual.y,
                    width: actual.width,
                    height: actual.height,
                    rotation: actual.rotation,
                    isMain: actual.isMain,
                    changed: actual.x != previous.x
                        || actual.y != previous.y
                        || actual.isMain != previous.isMain
                )
            }
        }
        return proposed
    }

    func setPosition(
        of target: DisplayDevice,
        x: Int32,
        y: Int32,
        dryRun: Bool
    ) throws -> DisplayLayoutItem {
        guard CGDisplayIsActive(target.id) != 0 else {
            throw DisplayCtlError.displayConfiguration(L10n.text(
                "монитор \(target.name) не является активным",
                "display \(target.name) is not active"
            ))
        }
        guard !target.isMirrored else {
            throw DisplayCtlError.displayConfiguration(L10n.text(
                "сначала отключите зеркалирование для \(target.name)",
                "disable mirroring for \(target.name) first"
            ))
        }
        let current = item(for: target)
        let changed = current.x != x || current.y != y
        if !dryRun, changed {
            try apply(origins: [(target, x, y)])
            let actual = item(for: target)
            return DisplayLayoutItem(
                display: target,
                x: actual.x,
                y: actual.y,
                width: actual.width,
                height: actual.height,
                rotation: actual.rotation,
                isMain: actual.isMain,
                changed: actual.x != current.x || actual.y != current.y
            )
        }
        return DisplayLayoutItem(
            display: target,
            x: x,
            y: y,
            width: current.width,
            height: current.height,
            rotation: current.rotation,
            isMain: current.isMain,
            changed: changed
        )
    }

    func setRelativePosition(
        of target: DisplayDevice,
        relativeTo reference: DisplayDevice,
        position: RelativeLayoutPosition,
        dryRun: Bool
    ) throws -> DisplayLayoutItem {
        guard target.id != reference.id else {
            throw DisplayCtlError.invalidArguments(L10n.text(
                "Монитор нельзя расположить относительно самого себя.",
                "A display cannot be positioned relative to itself."
            ))
        }
        let targetBounds = CGDisplayBounds(target.id)
        let referenceBounds = CGDisplayBounds(reference.id)
        let x: CGFloat
        let y: CGFloat
        switch position {
        case .left:
            x = referenceBounds.minX - targetBounds.width
            y = referenceBounds.minY
        case .right:
            x = referenceBounds.maxX
            y = referenceBounds.minY
        case .above:
            x = referenceBounds.minX
            y = referenceBounds.minY - targetBounds.height
        case .below:
            x = referenceBounds.minX
            y = referenceBounds.maxY
        }
        return try setPosition(
            of: target,
            x: Self.int32(x),
            y: Self.int32(y),
            dryRun: dryRun
        )
    }

    private func apply(origins: [(display: DisplayDevice, x: Int32, y: Int32)]) throws {
        // Staging every origin before completion avoids partially saved layouts.
        var configuration: CGDisplayConfigRef?
        let beginError = CGBeginDisplayConfiguration(&configuration)
        guard beginError == .success, let configuration else {
            throw DisplayCtlError.displayConfiguration(
                "CGBeginDisplayConfiguration: \(beginError.rawValue)"
            )
        }

        for origin in origins {
            let error = CGConfigureDisplayOrigin(
                configuration,
                origin.display.id,
                origin.x,
                origin.y
            )
            guard error == .success else {
                CGCancelDisplayConfiguration(configuration)
                throw DisplayCtlError.displayConfiguration(L10n.text(
                    "CGConfigureDisplayOrigin для \(origin.display.name): \(error.rawValue)",
                    "CGConfigureDisplayOrigin for \(origin.display.name): \(error.rawValue)"
                ))
            }
        }

        let completeError = CGCompleteDisplayConfiguration(configuration, .permanently)
        guard completeError == .success else {
            throw DisplayCtlError.displayConfiguration(
                "CGCompleteDisplayConfiguration: \(completeError.rawValue)"
            )
        }
    }

    private static func int32(_ value: CGFloat) -> Int32 {
        let rounded = value.rounded()
        return Int32(max(CGFloat(Int32.min), min(CGFloat(Int32.max), rounded)))
    }

    private static func subtract(_ lhs: Int32, _ rhs: Int32) throws -> Int32 {
        let value = Int64(lhs) - Int64(rhs)
        guard value >= Int64(Int32.min), value <= Int64(Int32.max) else {
            throw DisplayCtlError.displayConfiguration(L10n.text(
                "координаты раскладки выходят за допустимый диапазон",
                "layout coordinates are outside the supported range"
            ))
        }
        return Int32(value)
    }
}
