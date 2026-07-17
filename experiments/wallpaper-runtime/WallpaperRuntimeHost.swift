import Darwin
import Foundation

// Deliberately tiny and version-stable. This app is the responsible process
// for TCC while the frequently rebuilt wallpaper renderer runs as its child.
// Do not rebuild an installed host for ordinary renderer source changes.

private let stateDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/wallpaper-runtime")
private let worker = stateDirectory.appendingPathComponent("bin/wallpaper-runtime")
private let hostPID = stateDirectory.appendingPathComponent("host-pid")
private let logURL = stateDirectory.appendingPathComponent("log")

guard FileManager.default.isExecutableFile(atPath: worker.path) else {
    FileHandle.standardError.write(Data("wallpaper runtime worker is missing: \(worker.path)\n".utf8))
    exit(EX_CONFIG)
}

try? FileManager.default.createDirectory(
    at: stateDirectory,
    withIntermediateDirectories: true
)
do {
    try "\(getpid())\n".write(to: hostPID, atomically: true, encoding: .utf8)
} catch {
    FileHandle.standardError.write(Data("could not write host pid: \(error)\n".utf8))
    exit(EX_CANTCREAT)
}
defer { try? FileManager.default.removeItem(at: hostPID) }

let child = Process()
child.executableURL = worker
child.arguments = ["--daemon"]
if !FileManager.default.fileExists(atPath: logURL.path) {
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
}
if let log = try? FileHandle(forWritingTo: logURL) {
    _ = try? log.seekToEnd()
    child.standardOutput = log
    child.standardError = log
}

// launchd terminates the host, while wallpaperctl normally signals the worker
// directly. Forward termination so neither route can orphan the renderer.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let signalQueue = DispatchQueue(label: "wallpaper.runtime.host.signals")
let terminationSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
let interruptSignal = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
for source in [terminationSignal, interruptSignal] {
    source.setEventHandler {
        if child.isRunning { child.terminate() }
    }
    source.resume()
}

do {
    try child.run()
} catch {
    FileHandle.standardError.write(Data("could not launch wallpaper runtime: \(error)\n".utf8))
    exit(EX_OSERR)
}

child.waitUntilExit()
exit(child.terminationStatus)
