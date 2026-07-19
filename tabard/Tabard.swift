// tabard — the herald's garment. Vestiary's OSD agent: floats brief
// announcements (task attention, task completion, look changes) on the
// theme contract's inverse-polarity roles (contract SPEC §2.5). Herald
// subscriber under the SPEC §4 conformance rules; also the host's
// designated reaper (herald SPEC §5, v1.2).
//
// Verbs: run (default) | pause | resume | status | install-agent |
// uninstall-agent. Env: TABARD_HERALD_ROOT, LIVERY_RUNTIME (contract
// §2.1 reserved override), TABARD_REAPER_GRACE / TABARD_REAPER_INTERVAL
// (seconds; testing).
//
// The notifyd doorbell is deliberately not subscribed: the directory
// watcher already delivers sub-100ms latency on the same host, and the
// doorbell is a SHOULD-level optimization for consumers without one.

import AppKit
import CoreGraphics

// MARK: - configuration

let home = FileManager.default.homeDirectoryForCurrentUser.path

func env(_ name: String) -> String? { ProcessInfo.processInfo.environment[name] }

enum Config {
  static let heraldRoot = env("TABARD_HERALD_ROOT") ?? home + "/.config/herald"
  static var tasksDir: String { heraldRoot + "/tasks.d" }
  static let liveryRoot = env("LIVERY_RUNTIME") ?? home + "/.config/livery"
  static let stateDir = home + "/.local/state/tabard"
  static var pauseFlag: String { stateDir + "/paused" }
  static var logPath: String { stateDir + "/tabard.log" }
  static let label = "local.vestiary.tabard"
  static var plistPath: String { home + "/Library/LaunchAgents/\(label).plist" }

  static let dwellDone: Double = 5
  static let dwellWaiting: Double = 10
  static let maxVisible = 3
  static let idleThreshold: Double = 30     // countdown holds while user away
  static let debounce: Double = 0.08        // herald S5: 50-100ms
  static let reconcileInterval: Double = 30 // belt for missed events
  static let reaperGrace = Double(env("TABARD_REAPER_GRACE") ?? "") ?? 60
  static let reaperInterval = Double(env("TABARD_REAPER_INTERVAL") ?? "") ?? 300
  static let chipWidth: CGFloat = 320
  static let margin: CGFloat = 12
}

func log(_ message: String) {
  let stamp = ISO8601DateFormatter().string(from: Date())
  FileHandle.standardError.write(Data("\(stamp) \(message)\n".utf8))
}

// MARK: - theme (direct manifest consumer — no adapter, by design)

struct Theme {
  var chipBG = NSColor(red: 0.94, green: 0.93, blue: 0.91, alpha: 1)
  var chipFG = NSColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1)
  var chipAccent = NSColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1)
  var displayFamily: String?
  var uiFamily: String?
  var lookName = ""

  static func color(_ node: Any?) -> NSColor? {
    guard let dict = node as? [String: Any],
          let hex = dict["hex"] as? String, hex.count == 7, hex.hasPrefix("#"),
          let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
    return NSColor(red: CGFloat((value >> 16) & 0xff) / 255,
                   green: CGFloat((value >> 8) & 0xff) / 255,
                   blue: CGFloat(value & 0xff) / 255, alpha: 1)
  }

  // theme-supported, not theme-critical: any failure keeps the
  // built-in monochrome chip and never kills the agent.
  static func load() -> Theme {
    var theme = Theme()
    let path = Config.liveryRoot + "/current/manifest.json"
    guard let data = FileManager.default.contents(atPath: path),
          let json = try? JSONSerialization.jsonObject(with: data),
          let root = json as? [String: Any] else { return theme }
    if let ui = root["ui"] as? [String: Any] {
      theme.chipBG = color(ui["inverseSurface"]) ?? theme.chipBG
      theme.chipFG = color(ui["inverseText"]) ?? theme.chipFG
      theme.chipAccent = color(ui["inversePrimary"]) ?? theme.chipFG
    }
    if let fonts = root["fonts"] as? [String: Any] {
      theme.displayFamily = (fonts["display"] as? [String: Any])?["family"] as? String
      theme.uiFamily = (fonts["ui"] as? [String: Any])?["family"] as? String
    }
    if let meta = root["meta"] as? [String: Any] {
      theme.lookName = meta["name"] as? String ?? ""
    }
    return theme
  }

  func font(family: String?, size: CGFloat) -> NSFont {
    if let family,
       let font = NSFontManager.shared.font(withFamily: family, traits: [],
                                            weight: 5, size: size) {
      return font
    }
    return NSFont.systemFont(ofSize: size)
  }
}

// MARK: - herald tasks channel

struct TaskEntry {
  var id: String
  var kind: String
  var state: String
  var title: String
  var outcome: String?
  var attention: String?
  var lastMessage: String?
  var pane: String?
  var pid: Int?

  // Envelope per herald SPEC §6; generic core only per the ship
  // boundary — the kind block is read solely for the advisory pid.
  static func parse(_ data: Data) -> TaskEntry? {
    guard let json = try? JSONSerialization.jsonObject(with: data),
          let root = json as? [String: Any],
          let payload = root["data"] as? [String: Any],
          let id = payload["id"] as? String,
          let kind = payload["kind"] as? String,
          let state = payload["state"] as? String else { return nil }
    let focus = payload["focus"] as? [String: Any]
    let tmux = focus?["tmux"] as? [String: Any]
    let extensionBlock = payload[kind] as? [String: Any]
    return TaskEntry(
      id: id, kind: kind, state: state,
      title: payload["title"] as? String ?? id,
      outcome: payload["outcome"] as? String,
      attention: payload["attention"] as? String,
      lastMessage: payload["lastMessage"] as? String,
      pane: tmux?["pane"] as? String,
      pid: extensionBlock?["pid"] as? Int)
  }
}

func readTasks() -> [String: (entry: TaskEntry, path: String)] {
  var merged: [String: (TaskEntry, String)] = [:]
  let dir = Config.tasksDir
  guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir)
  else { return merged }  // missing dir = documented empty state (S4)
  for name in names {
    if name.hasPrefix(".") { continue }  // tmp files are contract-invisible (P2)
    guard name.hasSuffix(".json") else { continue }
    let path = dir + "/" + name
    guard let data = FileManager.default.contents(atPath: path),
          let entry = TaskEntry.parse(data) else { continue }
    merged[entry.id] = (entry, path)
  }
  return merged
}

// MARK: - tmux (the one read outside herald + the manifest; severable)

func runTool(_ arguments: [String]) -> String? {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = arguments
  // launchd agents get a bare PATH; brew-installed tmux would silently
  // vanish (the fresco shell() lesson).
  var environment = ProcessInfo.processInfo.environment
  environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:"
    + (environment["PATH"] ?? "/usr/bin:/bin")
  process.environment = environment
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = FileHandle.nullDevice
  do { try process.run() } catch { return nil }
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else { return nil }
  return String(data: data, encoding: .utf8)
}

// nil = tmux unavailable; callers must degrade, never assume empty.
func livePanes() -> Set<String>? {
  guard let output = runTool(["tmux", "list-panes", "-a", "-F", "#{pane_id}"])
  else { return nil }
  return Set(output.split(separator: "\n").map(String.init))
}

func focusedPanes() -> Set<String> {
  guard let output = runTool(["tmux", "list-panes", "-a",
                              "-f", "#{&&:#{pane_active},#{session_attached}}",
                              "-F", "#{pane_id}"]) else { return [] }
  return Set(output.split(separator: "\n").map(String.init))
}

func pidAlive(_ pid: Int) -> Bool {
  kill(pid_t(pid), 0) == 0 || errno == EPERM
}

// MARK: - toast model

enum ToastKind { case waiting, done, look }

final class Toast {
  let id: String
  let kind: ToastKind
  var glyph: String
  var heading: String
  var body: String
  var remaining: Double

  init(id: String, kind: ToastKind, glyph: String, heading: String,
       body: String, dwell: Double) {
    self.id = id; self.kind = kind; self.glyph = glyph
    self.heading = heading; self.body = body; self.remaining = dwell
  }

  static func waiting(_ entry: TaskEntry) -> Toast {
    let reasons = ["permission": "permission wanted", "input": "input wanted",
                   "sandbox": "sandbox approval", "dialog": "dialog open",
                   "idle_prompt": "idle at prompt"]
    var body = reasons[entry.attention ?? ""] ?? entry.attention ?? "waiting"
    if let message = entry.lastMessage { body += " · " + message }
    return Toast(id: entry.id, kind: .waiting, glyph: "✳",
                 heading: entry.title, body: body, dwell: Config.dwellWaiting)
  }

  static func done(_ entry: TaskEntry) -> Toast {
    let glyphs = ["success": "✓", "failure": "✕", "stopped": "■"]
    let words = ["success": "success", "failure": "failed", "stopped": "stopped"]
    var body = words[entry.outcome ?? ""] ?? "finished"
    if let message = entry.lastMessage { body += " · " + message }
    return Toast(id: entry.id, kind: .done,
                 glyph: glyphs[entry.outcome ?? ""] ?? "●",
                 heading: entry.title, body: body, dwell: Config.dwellDone)
  }

  static func look(_ name: String) -> Toast {
    Toast(id: "look", kind: .look, glyph: "◆",
          heading: name.isEmpty ? "look" : name, body: "look applied",
          dwell: Config.dwellDone)
  }
}

// MARK: - chip rendering

final class ChipView: NSView {
  init(toast: Toast, theme: Theme) {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = theme.chipBG.cgColor
    layer?.cornerRadius = 10

    let glyph = NSTextField(labelWithString: toast.glyph)
    glyph.font = theme.font(family: theme.uiFamily, size: 13)
    glyph.textColor = theme.chipAccent

    let heading = NSTextField(labelWithString: toast.heading)
    heading.font = theme.font(family: theme.displayFamily, size: 15)
    heading.textColor = theme.chipFG
    heading.lineBreakMode = .byTruncatingTail
    heading.maximumNumberOfLines = 1

    let body = NSTextField(wrappingLabelWithString: toast.body)
    body.font = theme.font(family: theme.uiFamily, size: 11)
    body.textColor = theme.chipFG.withAlphaComponent(0.8)
    body.maximumNumberOfLines = 2
    body.lineBreakMode = .byTruncatingTail

    let padding: CGFloat = 12
    let textX: CGFloat = padding + 20
    let textWidth = Config.chipWidth - textX - padding
    let bodyHeight = min(
      body.attributedStringValue.boundingRect(
        with: NSSize(width: textWidth, height: 1000),
        options: [.usesLineFragmentOrigin]).height,
      2.6 * body.font!.pointSize)
    let headingHeight: CGFloat = 20
    let height = padding + headingHeight + 2 + bodyHeight + padding

    frame = NSRect(x: 0, y: 0, width: Config.chipWidth, height: height)
    glyph.frame = NSRect(x: padding, y: height - padding - headingHeight + 1,
                         width: 18, height: headingHeight)
    heading.frame = NSRect(x: textX, y: height - padding - headingHeight,
                           width: textWidth, height: headingHeight)
    body.frame = NSRect(x: textX, y: padding,
                        width: textWidth, height: bodyHeight)
    addSubview(glyph); addSubview(heading); addSubview(body)
  }

  required init?(coder: NSCoder) { fatalError() }
}

final class OverflowChip: NSView {
  init(count: Int, theme: Theme) {
    super.init(frame: NSRect(x: 0, y: 0, width: Config.chipWidth, height: 22))
    wantsLayer = true
    let label = NSTextField(labelWithString: "+\(count)")
    label.font = theme.font(family: theme.uiFamily, size: 11)
    label.textColor = theme.chipAccent
    label.alignment = .right
    label.frame = NSRect(x: 0, y: 2, width: Config.chipWidth - 6, height: 16)
    addSubview(label)
  }
  required init?(coder: NSCoder) { fatalError() }
}

// MARK: - the agent

final class Tabard: NSObject, NSApplicationDelegate {
  var panel: NSPanel!
  var theme = Theme.load()
  var previous: [String: TaskEntry]?      // nil until the baseline read
  var visible: [Toast] = []
  var queue: [Toast] = []                 // expiry paused until shown
  var lookBaseline: String?
  var dwellTimer: Timer?
  var reapCandidates: [String: Date] = [:]
  var tasksWatch: DispatchSourceFileSystemObject?
  var liveryWatch: DispatchSourceFileSystemObject?
  var pendingReconcile: DispatchWorkItem?

  func applicationDidFinishLaunching(_ notification: Notification) {
    try? FileManager.default.createDirectory(
      atPath: Config.stateDir, withIntermediateDirectories: true)
    makePanel()
    lookBaseline = currentLookIdentity()
    reconcile()                            // baseline: state, not news (S3)
    armWatch()
    Timer.scheduledTimer(withTimeInterval: Config.reconcileInterval,
                         repeats: true) { [weak self] _ in
      self?.reconcile()
      self?.checkLook()
      self?.armWatch()                     // re-arm if dirs appeared/moved
    }
    reap()
    Timer.scheduledTimer(withTimeInterval: Config.reaperInterval,
                         repeats: true) { [weak self] _ in self?.reap() }
    log("tabard up — herald=\(Config.heraldRoot) livery=\(Config.liveryRoot)")
  }

  func makePanel() {
    panel = NSPanel(contentRect: .zero,
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: true)
    panel.level = .statusBar               // above windows, below repose
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                .fullScreenAuxiliary, .ignoresCycle]
    panel.ignoresMouseEvents = true
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
  }

  // MARK: watchers (herald S1: watch the directory, reconcile by reading)

  func armWatch() {
    if tasksWatch == nil {
      tasksWatch = watch(path: Config.tasksDir) { [weak self] in
        self?.scheduleReconcile()
      } onGone: { [weak self] in self?.tasksWatch = nil }
    }
    if liveryWatch == nil {
      liveryWatch = watch(path: Config.liveryRoot) { [weak self] in
        self?.checkLook()
      } onGone: { [weak self] in self?.liveryWatch = nil }
    }
  }

  func watch(path: String, onEvent: @escaping () -> Void,
             onGone: @escaping () -> Void) -> DispatchSourceFileSystemObject? {
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else { return nil }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd, eventMask: [.write, .delete, .rename],
      queue: .main)
    source.setEventHandler {
      if env("TABARD_DEBUG") != nil { log("fs event \(path) mask=\(source.data.rawValue)") }
      if source.data.contains(.delete) || source.data.contains(.rename) {
        source.cancel()
        onGone()
      }
      onEvent()
    }
    source.setCancelHandler { close(fd) }
    source.resume()
    return source
  }

  func scheduleReconcile() {
    pendingReconcile?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.reconcile() }
    pendingReconcile = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Config.debounce,
                                  execute: work)
  }

  // MARK: reconcile + diff (transitions from snapshots, herald §5)

  func reconcile() {
    var merged: [String: TaskEntry] = [:]
    let panes = livePanes()
    for (id, item) in readTasks() {
      // merge-time pane eviction (herald §5): pane present ⇒ pane decides
      if let pane = item.entry.pane, let panes, !panes.contains(pane) {
        continue
      }
      merged[id] = item.entry
    }
    if env("TABARD_DEBUG") != nil {
      log("reconcile merged=\(merged.count) baseline=\(previous == nil)")
    }
    defer { previous = merged }
    guard let previous else { return }     // baseline established, no news

    let paused = FileManager.default.fileExists(atPath: Config.pauseFlag)
    let focused = focusedPanes()
    for (id, entry) in merged {
      let oldState = previous[id]?.state
      guard entry.state != oldState else { continue }  // seq alone never toasts
      guard entry.state == "waiting" || entry.state == "done" else { continue }
      if paused {                          // dropped, not queued — bar has it
        if env("TABARD_DEBUG") != nil { log("dropped (paused) \(id) → \(entry.state)") }
        continue
      }
      if let pane = entry.pane, focused.contains(pane) {
        if env("TABARD_DEBUG") != nil { log("suppressed (pane focused) \(id) → \(entry.state)") }
        continue
      }
      show(entry.state == "waiting" ? Toast.waiting(entry) : Toast.done(entry))
    }
  }

  func currentLookIdentity() -> String? {
    let link = Config.liveryRoot + "/current"
    guard let target = try? FileManager.default
      .destinationOfSymbolicLink(atPath: link) else { return nil }
    return target
  }

  func checkLook() {
    let identity = currentLookIdentity()
    guard identity != lookBaseline else { return }
    lookBaseline = identity
    theme = Theme.load()
    render()                               // retheme anything visible
    guard identity != nil,
          !FileManager.default.fileExists(atPath: Config.pauseFlag)
    else { return }
    show(Toast.look(theme.lookName))
  }

  // MARK: toast lifecycle

  func show(_ toast: Toast) {
    log("toast \(toast.kind) \(toast.id): \(toast.heading) — \(toast.body)")
    // coalesce: a repeat announcement replaces its predecessor in place
    if let index = visible.firstIndex(where: { $0.id == toast.id }) {
      visible[index] = toast
    } else if let index = queue.firstIndex(where: { $0.id == toast.id }) {
      queue[index] = toast
    } else if visible.count < Config.maxVisible {
      visible.append(toast)
    } else {
      queue.append(toast)
    }
    render()
    startDwell()
  }

  func startDwell() {
    guard dwellTimer == nil else { return }
    dwellTimer = Timer.scheduledTimer(withTimeInterval: 0.5,
                                      repeats: true) { [weak self] _ in
      self?.tick()
    }
  }

  func tick() {
    guard !visible.isEmpty else {
      dwellTimer?.invalidate(); dwellTimer = nil
      return
    }
    // countdown runs only while the user is active (GNOME's rule):
    // a toast fired while away waits for the return.
    guard idleSeconds() < Config.idleThreshold else { return }
    var changed = false
    for toast in visible { toast.remaining -= 0.5 }
    while let index = visible.firstIndex(where: { $0.remaining <= 0 }) {
      visible.remove(at: index)
      changed = true
    }
    while visible.count < Config.maxVisible, !queue.isEmpty {
      visible.append(queue.removeFirst())  // expiry was paused while queued
      changed = true
    }
    if changed { render() }
  }

  // active display = the pointer's screen; NSScreen.main resolves to the
  // primary display for an app that never takes key.
  func activeScreen() -> NSScreen? {
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
      ?? NSScreen.main
  }

  func idleSeconds() -> Double {
    let types: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown,
                                .rightMouseDown, .scrollWheel]
    return types.map {
      CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                              eventType: $0)
    }.min() ?? 0
  }

  // MARK: rendering

  func render() {
    guard let content = panel.contentView else { return }
    content.subviews.forEach { $0.removeFromSuperview() }
    guard !visible.isEmpty, let screen = activeScreen() else {
      panel.orderOut(nil)
      return
    }

    var chips: [NSView] = visible.map { ChipView(toast: $0, theme: theme) }
    if !queue.isEmpty {
      chips.append(OverflowChip(count: queue.count, theme: theme))
    }
    let gap: CGFloat = 8
    let totalHeight = chips.reduce(0) { $0 + $1.frame.height }
      + gap * CGFloat(chips.count - 1)

    let visibleFrame = screen.visibleFrame
    let originX = visibleFrame.maxX - Config.chipWidth - Config.margin
    let originY = visibleFrame.maxY - totalHeight - Config.margin
    panel.setFrame(NSRect(x: originX, y: originY,
                          width: Config.chipWidth, height: totalHeight),
                   display: false)

    var y = totalHeight
    for chip in chips {                    // newest on top
      y -= chip.frame.height
      chip.frame.origin = NSPoint(x: 0, y: y)
      content.addSubview(chip)
      y -= gap
    }
    panel.orderFrontRegardless()           // never key, never activate
  }

  // MARK: reaper (herald SPEC §5 v1.2 — tabard is the designated reaper)

  func reap() {
    let panes = livePanes()
    var evictable: Set<String> = []
    for (_, item) in readTasks() {
      let entry = item.entry
      if let pane = entry.pane {
        if let panes, !panes.contains(pane) { evictable.insert(item.path) }
      } else if let pid = entry.pid {
        if !pidAlive(pid) { evictable.insert(item.path) }
      }
      // neither pane nor pid: exempt — never aged out by time alone
    }
    let now = Date()
    for path in evictable {
      if let first = reapCandidates[path] {
        if now.timeIntervalSince(first) >= Config.reaperGrace {
          try? FileManager.default.removeItem(atPath: path)
          reapCandidates.removeValue(forKey: path)
          log("reaped \(path)")
        }
      } else {
        reapCandidates[path] = now
      }
    }
    reapCandidates = reapCandidates.filter { evictable.contains($0.key) }
  }
}

// MARK: - verbs

func agentInstalled() -> Bool {
  FileManager.default.fileExists(atPath: Config.plistPath)
}

func installAgent() {
  let binary = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
  // launchd runs the sh wrapper when present: it rebuilds a cleaned or
  // stale binary before exec'ing, where a pinned build/ path would leave
  // KeepAlive thrashing a missing file.
  let wrapper = binary.deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("tabard")
  let program = FileManager.default.isExecutableFile(atPath: wrapper.path)
    ? wrapper.path : binary.path
  let plist = """
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0"><dict>
    <key>Label</key><string>\(Config.label)</string>
    <key>ProgramArguments</key><array>
      <string>\(program)</string>
      <string>run</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>\(Config.logPath)</string>
    <key>StandardErrorPath</key><string>\(Config.logPath)</string>
  </dict></plist>
  """
  try? FileManager.default.createDirectory(
    atPath: Config.stateDir, withIntermediateDirectories: true)
  try? FileManager.default.createDirectory(
    atPath: (Config.plistPath as NSString).deletingLastPathComponent,
    withIntermediateDirectories: true)
  try? plist.write(toFile: Config.plistPath, atomically: true, encoding: .utf8)
  _ = runTool(["launchctl", "bootstrap", "gui/\(getuid())", Config.plistPath])
  print("agent installed and loaded: \(Config.plistPath)")
}

func uninstallAgent() {
  _ = runTool(["launchctl", "bootout", "gui/\(getuid())/\(Config.label)"])
  try? FileManager.default.removeItem(atPath: Config.plistPath)
  print("agent removed")
}

func status() {
  let paused = FileManager.default.fileExists(atPath: Config.pauseFlag)
  let tasks = readTasks()
  print("tabard — the herald's garment")
  print("paused: \(paused)")
  print("agent: \(agentInstalled() ? "installed" : "none")")
  print("herald: \(Config.tasksDir) (\(tasks.count) task files)")
  print("log: \(Config.logPath)")
}

let verb = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "run"
switch verb {
case "run":
  let app = NSApplication.shared
  app.setActivationPolicy(.accessory)
  let agent = Tabard()
  app.delegate = agent
  app.run()
case "pause":
  try? FileManager.default.createDirectory(
    atPath: Config.stateDir, withIntermediateDirectories: true)
  FileManager.default.createFile(atPath: Config.pauseFlag, contents: nil)
  print("paused (toasts dropped; the bar still carries state)")
case "resume":
  try? FileManager.default.removeItem(atPath: Config.pauseFlag)
  print("resumed")
case "status":
  status()
case "install-agent":
  installAgent()
case "uninstall-agent":
  uninstallAgent()
default:
  print("usage: tabard [run|pause|resume|status|install-agent|uninstall-agent]")
  exit(2)
}
