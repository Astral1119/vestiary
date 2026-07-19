// tabard — the herald's garment. Vestiary's OSD agent: floats brief
// announcements (task attention, task completion, look changes) on the
// theme contract's inverse-polarity roles (contract SPEC §2.5). Herald
// subscriber under the SPEC §4 conformance rules; also the host's
// designated reaper (herald SPEC §5, v1.2).
//
// Verbs: run (default) | pause | resume | status | install-agent |
// uninstall-agent. Env: TABARD_HERALD_ROOT, LIVERY_RUNTIME (contract
// §2.1 reserved override), TABARD_REAPER_GRACE / TABARD_REAPER_INTERVAL /
// TABARD_DIGEST_COLLECT / TABARD_DIGEST_RETOAST / TABARD_DWELL_DONE /
// TABARD_DWELL_WAITING / TABARD_IDLE_THRESHOLD (seconds; testing).
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
  static let attendHook = env("TABARD_ATTEND_HOOK")
    ?? home + "/.config/tabard/attend-hook"
  static var pauseFlag: String { stateDir + "/paused" }
  static var logPath: String { stateDir + "/tabard.log" }
  static let label = "local.vestiary.tabard"
  static var plistPath: String { home + "/Library/LaunchAgents/\(label).plist" }

  static let dwellDone = Double(env("TABARD_DWELL_DONE") ?? "") ?? 5
  static let dwellWaiting = Double(env("TABARD_DWELL_WAITING") ?? "") ?? 10
  // grouped-burst digesting (TABARD-DESIGN §12; constants are the
  // Alertmanager group_wait / group_interval defaults)
  static let digestCollect = Double(env("TABARD_DIGEST_COLLECT") ?? "") ?? 30
  static let digestReToast = Double(env("TABARD_DIGEST_RETOAST") ?? "") ?? 300
  static let maxVisible = 3
  // countdown holds while user away
  static let idleThreshold = Double(env("TABARD_IDLE_THRESHOLD") ?? "") ?? 30
  static let debounce: Double = 0.08        // herald S5: 50-100ms
  static let reconcileInterval: Double = 30 // belt for missed events
  static let reaperGrace = Double(env("TABARD_REAPER_GRACE") ?? "") ?? 60
  static let reaperInterval = Double(env("TABARD_REAPER_INTERVAL") ?? "") ?? 300
  // events log (the host's designated recorder)
  static let heraldLogRoot = env("TABARD_HERALD_LOG_ROOT")
    ?? home + "/.local/state/herald"
  static var eventsPath: String { heraldLogRoot + "/events.jsonl" }
  static let eventRetention =
    (Double(env("TABARD_EVENT_RETENTION_DAYS") ?? "") ?? 30) * 86400
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
  var group: String?
  var pane: String?
  var space: Int?
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
      group: payload["group"] as? String,
      pane: tmux?["pane"] as? String,
      space: focus?["space"] as? Int,
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

// MARK: - events recorder (tabard is the host's designated recorder:
// sole writer of the herald events log; best-effort by doctrine)

final class Recorder {
  static let formatter = ISO8601DateFormatter()
  private var fd: Int32 = -1
  private let path: String

  init(path: String = Config.eventsPath) {
    self.path = path
    try? FileManager.default.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent,
      withIntermediateDirectories: true)
    prune()
    fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    // the generation header: declares a possible gap and stamps the
    // schema — everything until the next marker is this recorder run
    append("rebaselined", ["schema": "events/1", "producer": "tabard"])
  }

  func stateChanged(_ entry: TaskEntry, from: String?) {
    var fields = context(entry)
    if let from { fields["from"] = from }   // absent on first observation
    fields["to"] = entry.state
    if entry.state == "waiting", let attention = entry.attention {
      fields["attention"] = attention
    }
    append("state-changed", fields)
  }

  func attentionRequested(_ entry: TaskEntry) {
    var fields = context(entry)
    if let attention = entry.attention { fields["attention"] = attention }
    append("attention-requested", fields)
  }

  func finished(_ entry: TaskEntry) {
    var fields = context(entry)
    if let outcome = entry.outcome { fields["outcome"] = outcome }
    append("finished", fields)
  }

  func reaped(_ entry: TaskEntry) {
    append("reaped", ["id": entry.id, "kind": entry.kind])
  }

  func dismissed(chip id: String) {
    // digest chips carry group identity; every other chip carries its id
    for prefix in ["digest:done:", "digest:waiting:"] where id.hasPrefix(prefix) {
      append("dismissed", ["group": String(id.dropFirst(prefix.count))])
      return
    }
    append("dismissed", ["id": id])
  }

  private func context(_ entry: TaskEntry) -> [String: Any] {
    var fields: [String: Any] = ["id": entry.id, "kind": entry.kind,
                                 "title": entry.title]
    if let group = entry.group { fields["group"] = group }
    return fields
  }

  // recorder-supported, not recorder-critical: any failure drops the
  // line and never touches toasting. One write per line (O_APPEND).
  private func append(_ event: String, _ fields: [String: Any]) {
    guard fd >= 0 else { return }
    var line: [String: Any] = ["ts": Self.formatter.string(from: Date()),
                               "event": event]
    line.merge(fields) { current, _ in current }
    guard var data = try? JSONSerialization.data(withJSONObject: line,
                                                 options: [.sortedKeys])
    else { return }
    data.append(0x0a)
    data.withUnsafeBytes { _ = write(fd, $0.baseAddress, data.count) }
  }

  // 30-day age-out at startup, temp + rename. Unparseable lines (torn
  // final line from a crash) are dropped here; readers skip them.
  private func prune() {
    guard let data = FileManager.default.contents(atPath: path),
          let text = String(data: data, encoding: .utf8) else { return }
    let cutoff = Date().addingTimeInterval(-Config.eventRetention)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    let kept = lines.filter { line in
      guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
            let dict = json as? [String: Any],
            let ts = dict["ts"] as? String,
            let date = Self.formatter.date(from: ts) else { return false }
      return date >= cutoff
    }
    guard kept.count != lines.count else { return }
    let tmp = (path as NSString).deletingLastPathComponent
      + "/.events.\(getpid()).tmp"
    let out = kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
    guard (try? out.write(toFile: tmp, atomically: false, encoding: .utf8))
      != nil else { return }
    rename(tmp, path)
  }
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

// "already looking at it" = any pane of the displayed window of an
// attached session. pane_active alone marks one pane per window,
// including windows nobody has on screen.
func visiblePanes() -> Set<String> {
  guard let output = runTool(["tmux", "list-panes", "-a",
                              "-f", "#{&&:#{window_active},#{session_attached}}",
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
  let dwell: Double
  var remaining: Double

  init(id: String, kind: ToastKind, glyph: String, heading: String,
       body: String, dwell: Double) {
    self.id = id; self.kind = kind; self.glyph = glyph
    self.heading = heading; self.body = body; self.dwell = dwell
    self.remaining = dwell
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

  // digest toasts (TABARD-DESIGN §12): one chip per group per tier;
  // outcome counts never disappear into the total.
  static func doneDigest(group: String, counts: [String: Int]) -> Toast {
    let total = counts.values.reduce(0, +)
    let failed = counts["failure"] ?? 0
    let stopped = counts["stopped"] ?? 0
    var body = "\(total) finished"
    if failed > 0 { body += " · \(failed) failed" }
    if stopped > 0 { body += " · \(stopped) stopped" }
    return Toast(id: "digest:done:" + group, kind: .done,
                 glyph: failed > 0 ? "✕" : "✓",
                 heading: group, body: body, dwell: Config.dwellDone)
  }

  static func waitingDigest(group: String, count: Int,
                            reason: String?) -> Toast {
    var body = count == 1 ? "1 blocked" : "\(count) blocked"
    if let reason { body += " · " + reason }
    return Toast(id: "digest:waiting:" + group, kind: .waiting, glyph: "✳",
                 heading: group, body: body, dwell: Config.dwellWaiting)
  }
}

// Per-group digest state. Done completions collect before the first
// annunciation and re-annunciate at most every digestReToast afterwards
// (the Alertmanager group_wait/group_interval shape); waiting is
// annunciated immediately and only ever merges in place.
final class GroupDigest {
  var doneCounts: [String: Int] = [:]
  var collectTimer: Timer?
  var retoastTimer: Timer?
  var lastToastAt: Date?
  var lastEventAt = Date()
  var waitingIds: Set<String> = []
  var lastWaitingReason: String?
  var pane: String?          // last seen member pane, for suppression
}

// MARK: - chip rendering

final class ChipView: NSView {
  private let toast: Toast
  private let theme: Theme
  private let attend: (String) -> Void
  private let dismiss: (String) -> Void

  init(toast: Toast, theme: Theme, held: Bool,
       attend: @escaping (String) -> Void,
       dismiss: @escaping (String) -> Void) {
    self.toast = toast
    self.theme = theme
    self.attend = attend
    self.dismiss = dismiss
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = theme.chipBG.cgColor
    layer?.cornerRadius = 10
    layer?.masksToBounds = true            // keeps the bar inside the corners

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

    // countdown bar: Core Animation drains it linearly so the sweep is
    // smooth between dwell ticks; a held chip gets a static bar instead
    let bar = CALayer()
    bar.backgroundColor = theme.chipAccent.withAlphaComponent(0.45).cgColor
    bar.anchorPoint = .zero
    bar.position = .zero
    let fraction = max(0, min(1, toast.remaining / toast.dwell))
    bar.bounds = CGRect(x: 0, y: 0,
                        width: Config.chipWidth * fraction, height: 2)
    layer?.addSublayer(bar)
    if !held, toast.remaining > 0 {
      let drain = CABasicAnimation(keyPath: "bounds.size.width")
      drain.fromValue = Config.chipWidth * fraction
      drain.toValue = 0
      drain.duration = toast.remaining
      drain.timingFunction = CAMediaTimingFunction(name: .linear)
      bar.bounds.size.width = 0
      bar.add(drain, forKey: "drain")
    }
  }

  override func mouseDown(with event: NSEvent) {
    // left-click = attend via the operator hook; eaten when no hook is installed
    if case .look = toast.kind { return }
    attend(toast.id)
  }

  override func otherMouseDown(with event: NSEvent) {
    if event.buttonNumber == 2 { dismiss(toast.id) }
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

  override func mouseDown(with event: NSEvent) {}
  override func rightMouseDown(with event: NSEvent) {}
  override func otherMouseDown(with event: NSEvent) {}

  required init?(coder: NSCoder) { fatalError() }
}

// MARK: - the agent

final class Tabard: NSObject, NSApplicationDelegate {
  var panel: NSPanel!
  var theme = Theme.load()
  let recorder = Recorder()
  var previous: [String: TaskEntry]?      // nil until the baseline read
  var visible: [Toast] = []
  var queue: [Toast] = []                 // expiry paused until shown
  var lookBaseline: String?
  var dwellTimer: Timer?
  var heldLast = false
  var groups: [String: GroupDigest] = [:]
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
      self?.sweepGroups()
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
    panel.ignoresMouseEvents = false
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
    guard let previous else {              // baseline established, no news
      seedGroupBaseline(merged)
      return
    }

    let paused = FileManager.default.fileExists(atPath: Config.pauseFlag)
    let onScreen = visiblePanes()
    for (id, entry) in merged {
      let oldEntry = previous[id]
      let oldState = oldEntry?.state
      // record before the annunciation guards: the archive keeps
      // transitions that pause, suppression, and digesting never toast
      if entry.state != oldState {
        if entry.state == "done" {
          recorder.finished(entry)
        } else {
          recorder.stateChanged(entry, from: oldState)
        }
      } else if entry.state == "waiting", entry.attention != nil,
                entry.attention != oldEntry?.attention {
        recorder.attentionRequested(entry)
      }
      guard entry.state != oldState else { continue }  // seq alone never toasts
      guard entry.state == "waiting" || entry.state == "done" else { continue }
      if let group = entry.group {
        // grouped transitions ride the digest path (§12): done collects,
        // waiting is reconciled set-wise below. Pause/suppression are
        // checked at annunciation time, not per arrival.
        if entry.state == "done" { groupedDone(group: group, entry: entry) }
        continue
      }
      if paused {                          // dropped, not queued — bar has it
        if env("TABARD_DEBUG") != nil { log("dropped (paused) \(id) → \(entry.state)") }
        continue
      }
      if let pane = entry.pane, onScreen.contains(pane) {
        if env("TABARD_DEBUG") != nil { log("suppressed (pane visible) \(id) → \(entry.state)") }
        continue
      }
      show(entry.state == "waiting" ? Toast.waiting(entry) : Toast.done(entry))
    }
    reconcileGroupWaiting(merged, paused: paused, onScreen: onScreen)
  }

  // MARK: grouped-burst digesting (TABARD-DESIGN §12)

  func digest(for group: String) -> GroupDigest {
    if let existing = groups[group] { return existing }
    let fresh = GroupDigest()
    groups[group] = fresh
    return fresh
  }

  func seedGroupBaseline(_ merged: [String: TaskEntry]) {
    for entry in merged.values {
      guard let group = entry.group, entry.state == "waiting" else { continue }
      let state = digest(for: group)
      state.waitingIds.insert(entry.id)
      if let pane = entry.pane { state.pane = pane }
      if let reason = entry.attention { state.lastWaitingReason = reason }
    }
  }

  func groupedDone(group: String, entry: TaskEntry) {
    let state = digest(for: group)
    state.doneCounts[entry.outcome ?? "finished", default: 0] += 1
    state.lastEventAt = Date()
    if let pane = entry.pane { state.pane = pane }
    if chipShowing("digest:done:" + group) {
      // visible chip updates in place; the rolling window re-anchors
      state.lastToastAt = Date()
      show(Toast.doneDigest(group: group, counts: state.doneCounts))
    } else if let last = state.lastToastAt {
      // already annunciated this wave: at most one re-toast per interval
      if state.retoastTimer == nil {
        let delay = max(0.5,
          Config.digestReToast - Date().timeIntervalSince(last))
        state.retoastTimer = Timer.scheduledTimer(
          withTimeInterval: delay, repeats: false) { [weak self] _ in
          self?.fireDoneDigest(group)
        }
      }
    } else if state.collectTimer == nil {
      // first arrivals collect so a burst annunciates once
      state.collectTimer = Timer.scheduledTimer(
        withTimeInterval: Config.digestCollect, repeats: false) { [weak self] _ in
        self?.fireDoneDigest(group)
      }
    }
  }

  func fireDoneDigest(_ group: String) {
    guard let state = groups[group] else { return }
    state.collectTimer?.invalidate(); state.collectTimer = nil
    state.retoastTimer?.invalidate(); state.retoastTimer = nil
    state.lastToastAt = Date()
    if FileManager.default.fileExists(atPath: Config.pauseFlag) {
      if env("TABARD_DEBUG") != nil { log("dropped (paused) digest done \(group)") }
      return
    }
    if let pane = state.pane, visiblePanes().contains(pane) {
      if env("TABARD_DEBUG") != nil { log("suppressed (pane visible) digest done \(group)") }
      return
    }
    show(Toast.doneDigest(group: group, counts: state.doneCounts))
  }

  // Waiting digests are reconciled against the merged set, not per
  // transition: rows join AND leave (attended, finished) and the chip
  // must track both directions. Waiting never sits in a collector —
  // the first member annunciates immediately, later ones merge in
  // place; tiers never share a chip.
  func reconcileGroupWaiting(_ merged: [String: TaskEntry],
                             paused: Bool, onScreen: Set<String>) {
    var current: [String: Set<String>] = [:]
    for entry in merged.values {
      guard let group = entry.group, entry.state == "waiting" else { continue }
      current[group, default: []].insert(entry.id)
      let state = digest(for: group)
      if let reason = entry.attention { state.lastWaitingReason = reason }
      if let pane = entry.pane { state.pane = pane }
    }
    for (group, ids) in current {
      let state = digest(for: group)
      let added = !ids.subtracting(state.waitingIds).isEmpty
      let changed = ids != state.waitingIds
      state.waitingIds = ids
      state.lastEventAt = Date()
      let chipId = "digest:waiting:" + group
      if chipShowing(chipId) {
        if changed {
          show(Toast.waitingDigest(group: group, count: ids.count,
                                   reason: state.lastWaitingReason))
        }
      } else if added {
        if paused {
          if env("TABARD_DEBUG") != nil { log("dropped (paused) digest waiting \(group)") }
        } else if let pane = state.pane, onScreen.contains(pane) {
          if env("TABARD_DEBUG") != nil { log("suppressed (pane visible) digest waiting \(group)") }
        } else {
          show(Toast.waitingDigest(group: group, count: ids.count,
                                   reason: state.lastWaitingReason))
        }
      }
    }
    for (group, state) in groups
    where current[group] == nil && !state.waitingIds.isEmpty {
      state.waitingIds = []
      dismissChip("digest:waiting:" + group)
    }
  }

  func chipShowing(_ id: String) -> Bool {
    visible.contains { $0.id == id } || queue.contains { $0.id == id }
  }

  func dismissChip(_ id: String) {
    var changed = false
    if let index = visible.firstIndex(where: { $0.id == id }) {
      visible.remove(at: index); changed = true
    }
    if let index = queue.firstIndex(where: { $0.id == id }) {
      queue.remove(at: index); changed = true
    }
    if changed { render() }
  }

  func userDismiss(_ id: String) {
    if env("TABARD_DEBUG") != nil { log("dismissed (middle-click) \(id)") }
    recorder.dismissed(chip: id)
    dismissChip(id)
  }

  func userAttend(_ id: String) {
    let pane: String?
    let space: Int?
    let group: String?
    let digestPrefixes = ["digest:done:", "digest:waiting:"]
    if let prefix = digestPrefixes.first(where: { id.hasPrefix($0) }) {
      let digestGroup = String(id.dropFirst(prefix.count))
      pane = groups[digestGroup]?.pane
      space = nil
      group = digestGroup
    } else {
      let entry = previous?[id]
      pane = entry?.pane
      space = entry?.space
      group = entry?.group
    }

    guard FileManager.default.isExecutableFile(atPath: Config.attendHook)
    else {
      if env("TABARD_DEBUG") != nil { log("attend ignored (no hook) \(id)") }
      return
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: Config.attendHook)
    process.arguments = [id]
    var environment = ProcessInfo.processInfo.environment
    environment["TABARD_PANE"] = pane
    environment["TABARD_SPACE"] = space.map(String.init)
    environment["TABARD_GROUP"] = group
    process.environment = environment
    process.terminationHandler = { _ in }
    do {
      try process.run()
      if env("TABARD_DEBUG") != nil { log("attended \(id)") }
      dismissChip(id)
    } catch {
      if env("TABARD_DEBUG") != nil { log("attend launch failed \(id)") }
    }
  }

  // a wave's state retires once nothing references it and the rolling
  // window has passed — the next swarm starts its counts fresh
  func sweepGroups() {
    let now = Date()
    for (group, state) in groups {
      guard state.collectTimer == nil, state.retoastTimer == nil,
            state.waitingIds.isEmpty,
            !chipShowing("digest:done:" + group),
            !chipShowing("digest:waiting:" + group),
            now.timeIntervalSince(state.lastEventAt) > Config.digestReToast
      else { continue }
      groups.removeValue(forKey: group)
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
    // countdown holds while the user is away (GNOME's rule) or hovering
    // (the survey interlock); a transition re-renders so the bars freeze
    // and restart in step with the dwell.
    let held = dwellHeld()
    if held != heldLast {
      heldLast = held
      if env("TABARD_DEBUG") != nil {
        log(held ? "dwell held" : "dwell resumed")
      }
      render()
    }
    guard !held else { return }
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

  func dwellHeld() -> Bool {
    idleSeconds() >= Config.idleThreshold
      || (panel.isVisible && panel.frame.contains(NSEvent.mouseLocation))
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

    let held = dwellHeld()
    var chips: [NSView] = visible.map { toast in
      ChipView(
        toast: toast, theme: theme, held: held,
        attend: { [weak self] id in self?.userAttend(id) },
        dismiss: { [weak self] id in self?.userDismiss(id) })
    }
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
    var evictable: [String: TaskEntry] = [:]   // path → entry
    for (_, item) in readTasks() {
      let entry = item.entry
      if let pane = entry.pane {
        if let panes, !panes.contains(pane) { evictable[item.path] = entry }
      } else if let pid = entry.pid {
        if !pidAlive(pid) { evictable[item.path] = entry }
      }
      // neither pane nor pid: exempt — never aged out by time alone
    }
    let now = Date()
    for (path, entry) in evictable {
      if let first = reapCandidates[path] {
        if now.timeIntervalSince(first) >= Config.reaperGrace {
          if (try? FileManager.default.removeItem(atPath: path)) != nil {
            recorder.reaped(entry)
            log("reaped \(path)")
          }
          reapCandidates.removeValue(forKey: path)
        }
      } else {
        reapCandidates[path] = now
      }
    }
    reapCandidates = reapCandidates.filter { evictable[$0.key] != nil }
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
  print("events: \(Config.eventsPath)")
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
