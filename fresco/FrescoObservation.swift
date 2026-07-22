import AppKit
import CoreGraphics
import Foundation

struct FrescoDisplayHardwareIdentity: Equatable {
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32
    let unit: UInt32

    var stableID: String {
        if serial != 0 {
            return String(format: "display:%08x-%08x-%08x", vendor, model, serial)
        }
        return String(format: "display:%08x-%08x-unit%08x", vendor, model, unit)
    }
}

enum FrescoMacObservation {
    static func displayID(for screen: NSScreen) -> String {
        hardwareIdentity(for: displayNumber(for: screen)).stableID
    }

    static func context(
        screens: [NSScreen],
        generation: String,
        locked: Bool,
        sleeping: Bool,
        occludedDisplayIDs: Set<String>
    ) -> FrescoObservedContext {
        let displays = screens.map { screen in
            let displayID = displayID(for: screen)
            return FrescoObservedDisplay(
                id: displayID,
                connected: true,
                frame: FrescoRect(
                    x: screen.frame.origin.x,
                    y: screen.frame.origin.y,
                    width: screen.frame.width,
                    height: screen.frame.height),
                scale: screen.backingScaleFactor,
                occluded: occludedDisplayIDs.contains(displayID))
        }
        return FrescoObservedContext(
            generation: generation,
            locked: locked,
            sleeping: sleeping,
            onBattery: false,
            pauseWhenOccluded: true,
            displays: displays,
            applications: [],
            reasons: [])
    }

    static func hardwareIdentity(for display: CGDirectDisplayID) -> FrescoDisplayHardwareIdentity {
        FrescoDisplayHardwareIdentity(
            vendor: CGDisplayVendorNumber(display),
            model: CGDisplayModelNumber(display),
            serial: CGDisplaySerialNumber(display),
            unit: CGDisplayUnitNumber(display))
    }

    private static func displayNumber(for screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber)?.uint32Value ?? 0
    }
}
