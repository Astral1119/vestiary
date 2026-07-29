import CoreGraphics
import Foundation

// The desktop wallpaper window: owned by fresco-scene, below the desktop icon
// layer, and wide enough not to be a stray helper panel.
let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
    as? [[String: Any]]) ?? []
for window in windows {
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
    guard owner == "fresco-scene", layer < 0, width > 100 else { continue }
    let id = (window[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0
    print(id)
    exit(0)
}
FileHandle.standardError.write("no fresco-scene desktop window found\n".data(using: .utf8)!)
exit(1)
