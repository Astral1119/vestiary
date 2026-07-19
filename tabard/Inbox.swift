import AppKit

// MARK: - inbox model

enum InboxTier: String { case waiting, activity }

struct InboxEvent {
  let seq: Int
  let date: Date
  let thread: String
  let project: String
  let threadName: String
  let label: String
  let tier: InboxTier
}

struct InboxThread {
  let id: String
  let project: String
  let name: String
  let members: [TaskEntry]
  let events: [InboxEvent]
  let live: Bool
  let waiting: Bool
  let unread: [InboxEvent]
  let tier: InboxTier?

  var lastSeq: Int { events.last?.seq ?? 0 }
}

struct InboxProject {
  let name: String
  let threads: [InboxThread]
}

final class InboxModel {
  private(set) var events: [InboxEvent] = []
  private(set) var tasks: [String: TaskEntry] = [:]
  private(set) var cursors: [String: Int] = [:]
  private let writesEnabled: Bool
  private var seenWork: DispatchWorkItem?
  private var lastBadge: (needsYou: Bool, unread: Bool)?
  var onChange: (() -> Void)?

  init(loadTasks: Bool = false, writesEnabled: Bool = true) {
    self.writesEnabled = writesEnabled
    loadSeen()
    loadEvents()
    if loadTasks {
      tasks = readTasks().mapValues { $0.entry }
    }
    refreshBadge()
  }

  static func cursorCount() -> Int {
    guard let data = FileManager.default.contents(atPath: Config.seenPath),
          let json = try? JSONSerialization.jsonObject(with: data),
          let root = json as? [String: Any] else { return 0 }
    return root.values.filter {
      ($0 as? [String: Any])?["readThrough"] as? Int != nil
    }.count
  }

  static func waitingLabel(_ attention: String?) -> String {
    let reasons = ["permission": "permission wanted", "input": "input wanted",
                   "sandbox": "sandbox approval", "dialog": "dialog open",
                   "idle_prompt": "idle at prompt"]
    return reasons[attention ?? ""] ?? attention ?? "waiting"
  }

  private func event(from dict: [String: Any], position: Int) -> InboxEvent? {
    guard let kind = dict["event"] as? String,
          let id = dict["id"] as? String,
          let stamp = dict["ts"] as? String,
          let date = Recorder.formatter.date(from: stamp) else { return nil }
    let tier: InboxTier
    let label: String
    if kind == "state-changed", dict["to"] as? String == "waiting" {
      tier = .waiting
      label = Self.waitingLabel(dict["attention"] as? String)
    } else if kind == "attention-requested" {
      tier = .waiting
      label = Self.waitingLabel(dict["attention"] as? String)
    } else if kind == "finished" {
      tier = .activity
      switch dict["outcome"] as? String {
      case "failure": label = "failed"
      case "stopped": label = "stopped"
      default: label = "finished"
      }
    } else {
      return nil
    }
    let group = dict["group"] as? String
    let title = dict["title"] as? String ?? id
    return InboxEvent(seq: dict["seq"] as? Int ?? position,
                      date: date, thread: group ?? id, project: title,
                      threadName: group ?? title, label: label, tier: tier)
  }

  private func loadEvents() {
    guard let data = FileManager.default.contents(atPath: Config.eventsPath),
          let text = String(data: data, encoding: .utf8) else { return }
    events = text.split(separator: "\n", omittingEmptySubsequences: true)
      .enumerated().compactMap { index, line in
        guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
              let dict = json as? [String: Any] else { return nil }
        return event(from: dict, position: index + 1)
      }.filter { Date().timeIntervalSince($0.date) < Config.eventRetention }
      .sorted { $0.seq < $1.seq }
  }

  private func loadSeen() {
    guard let data = FileManager.default.contents(atPath: Config.seenPath),
          let json = try? JSONSerialization.jsonObject(with: data),
          let root = json as? [String: Any] else { return }
    for (thread, value) in root {
      guard let item = value as? [String: Any],
            let cursor = item["readThrough"] as? Int else { continue }
      cursors[thread] = cursor
    }
  }

  func record(_ dict: [String: Any]) {
    if let item = event(from: dict, position: 0),
       Date().timeIntervalSince(item.date) < Config.eventRetention {
      events.append(item)
      events.sort { $0.seq < $1.seq }
      changed()
    }
  }

  func setTasks(_ merged: [String: TaskEntry]) {
    guard !sameTasks(tasks, merged) else { return }
    tasks = merged
    changed()
  }

  private func sameTasks(_ lhs: [String: TaskEntry],
                         _ rhs: [String: TaskEntry]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    for (id, left) in lhs {
      guard let right = rhs[id], left.state == right.state,
            left.outcome == right.outcome, left.attention == right.attention,
            left.group == right.group, left.title == right.title,
            left.pane == right.pane, left.space == right.space else { return false }
    }
    return true
  }

  func threads() -> [InboxThread] {
    var ids = Set(events.map { $0.thread })
    ids.formUnion(tasks.values.map { $0.group ?? $0.id })
    return ids.compactMap { id in
      let members = tasks.values.filter { ($0.group ?? $0.id) == id }
        .sorted { $0.id < $1.id }
      let threadEvents = events.filter { $0.thread == id }
      guard !members.isEmpty || !threadEvents.isEmpty else { return nil }
      let sampleTask = members.first
      let sampleEvent = threadEvents.last
      let project = sampleTask?.title ?? sampleEvent?.project ?? id
      let name = sampleTask?.group ?? sampleTask?.title
        ?? sampleEvent?.threadName ?? id
      let cursor = cursors[id] ?? 0
      let unread = threadEvents.filter { $0.seq > cursor }
      let waiting = members.contains { $0.state == "waiting" }
      let tier: InboxTier?
      if waiting && unread.contains(where: { $0.tier == .waiting }) {
        tier = .waiting
      } else if !unread.isEmpty {
        tier = .activity
      } else {
        tier = nil
      }
      return InboxThread(id: id, project: project, name: name,
                         members: members, events: threadEvents,
                         live: !members.isEmpty, waiting: waiting,
                         unread: unread, tier: tier)
    }.sorted { $0.id < $1.id }
  }

  func projects() -> [InboxProject] {
    Dictionary(grouping: threads(), by: { $0.project }).map {
      InboxProject(name: $0.key, threads: $0.value)
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  func markRead(_ thread: String, through seq: Int) {
    let old = cursors[thread] ?? 0
    guard seq > old else { return }
    cursors[thread] = seq
    cursorChanged()
  }

  func markRead(_ positions: [String: Int]) {
    var changed = false
    for (thread, seq) in positions where seq > (cursors[thread] ?? 0) {
      cursors[thread] = seq
      changed = true
    }
    if changed { cursorChanged() }
  }

  func attend(_ thread: String) {
    guard let latest = threads().first(where: { $0.id == thread })?.events.last
    else { return }
    markRead(thread, through: latest.seq)
  }

  func markAllRead() {
    var changed = false
    for thread in threads() where thread.lastSeq > (cursors[thread.id] ?? 0) {
      cursors[thread.id] = thread.lastSeq
      changed = true
    }
    if changed { cursorChanged() }
  }

  func markUnread(_ thread: String) {
    guard let last = threads().first(where: { $0.id == thread })?.events.last
    else { return }
    let value = last.seq - 1
    guard cursors[thread] != value else { return }
    cursors[thread] = value
    cursorChanged()
  }

  func paneVisible(tasks merged: [String: TaskEntry], panes: Set<String>) {
    var changed = false
    for entry in merged.values {
      guard let pane = entry.pane, panes.contains(pane) else { continue }
      let thread = entry.group ?? entry.id
      guard let last = threads().first(where: { $0.id == thread })?.events.last,
            last.seq > (cursors[thread] ?? 0) else { continue }
      cursors[thread] = last.seq
      changed = true
      if env("TABARD_DEBUG") != nil { log("read (pane visible) \(thread)") }
    }
    if changed { cursorChanged() }
  }

  func sweep() {
    let oldEvents = events
    events.removeAll { Date().timeIntervalSince($0.date) >= Config.eventRetention }
    let retained = Set(events.map { $0.thread })
    let live = Set(tasks.values.map { $0.group ?? $0.id })
    let stale = cursors.keys.filter { !retained.contains($0) && !live.contains($0) }
    for thread in stale { cursors.removeValue(forKey: thread) }
    if !stale.isEmpty { scheduleSeenWrite() }
    if events.count != oldEvents.count || !stale.isEmpty { changed() }
    else { refreshBadge() }
  }

  private func cursorChanged() {
    scheduleSeenWrite()
    changed()
  }

  private func changed() {
    refreshBadge()
    onChange?()
  }

  private func scheduleSeenWrite() {
    guard writesEnabled else { return }
    seenWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.writeSeen() }
    seenWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
  }

  private func writeSeen() {
    let object = cursors.mapValues { ["readThrough": $0] }
    atomicWrite(object, path: Config.seenPath, prefix: "seen")
  }

  private func refreshBadge() {
    let all = threads()
    let value = (needsYou: all.contains { $0.tier == .waiting },
                 unread: all.contains { !$0.unread.isEmpty })
    guard lastBadge?.needsYou != value.needsYou
      || lastBadge?.unread != value.unread else { return }
    lastBadge = value
    if writesEnabled {
      atomicWrite(["needsYou": value.needsYou, "unread": value.unread],
                  path: Config.badgePath, prefix: "badge")
    }
  }

  private func atomicWrite(_ object: Any, path: String, prefix: String) {
    guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                  options: [.sortedKeys])
    else { return }
    let directory = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: directory,
                                              withIntermediateDirectories: true)
    let tmp = directory + "/.\(prefix).\(getpid()).tmp"
    guard (try? data.write(to: URL(fileURLWithPath: tmp))) != nil else { return }
    rename(tmp, path)
  }

  func dumpData() -> Data? {
    let projected: [[String: Any]] = threads().map { thread in
      ["id": thread.id, "project": thread.project, "name": thread.name,
       "live": thread.live, "waiting": thread.waiting,
       "tier": thread.tier?.rawValue as Any,
       "unread": thread.unread.count, "lastSeq": thread.lastSeq]
    }
    let all = threads()
    let root: [String: Any] = [
      "threads": projected,
      "badge": ["needsYou": all.contains { $0.tier == .waiting },
                "unread": all.contains { !$0.unread.isEmpty }]
    ]
    return try? JSONSerialization.data(withJSONObject: root,
                                        options: [.sortedKeys])
  }
}

// MARK: - inbox views

final class InboxPanel: NSPanel {
  var handleKey: ((NSEvent) -> Bool)?

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func keyDown(with event: NSEvent) {
    if handleKey?(event) != true { super.keyDown(with: event) }
  }
}

class InboxClickView: NSView {
  var action: (() -> Void)?

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) { action?() }
}

final class InboxDocumentView: NSView {
  override var isFlipped: Bool { true }
}

private struct InboxRailItem {
  let channel: String?
  let tier: InboxTier?
}

final class InboxController: NSObject {
  let model: InboxModel
  private let panel: InboxPanel
  private let root = NSView()
  private let backdrop = NSVisualEffectView()
  private let header = NSView()
  private let footer = NSView()
  private let railScroll = NSScrollView()
  private let railDocument = InboxDocumentView()
  private let detailScroll = NSScrollView()
  private let detailDocument = InboxDocumentView()
  private var theme: Theme
  private var channel: String?
  private var railItems: [InboxRailItem] = []
  private var railRowFrames: [NSRect] = []
  private var detailObserver: NSObjectProtocol?
  var attend: ((String) -> Void)?

  var isOpen: Bool { panel.isVisible }

  init(model: InboxModel, theme: Theme) {
    self.model = model
    self.theme = theme
    panel = InboxPanel(contentRect: .zero,
                       styleMask: [.borderless, .nonactivatingPanel],
                       backing: .buffered, defer: true)
    super.init()
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                .fullScreenAuxiliary, .ignoresCycle]
    // the rounded root layer is the window shape; the panel itself is
    // clear (an opaque panel shows square corners behind the layer)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.handleKey = { [weak self] event in self?.handleKey(event) ?? false }
    // livery's backdrop recipe: behind-window blur under translucent color
    backdrop.material = .underPageBackground
    backdrop.blendingMode = .behindWindow
    backdrop.state = .active
    configure(railScroll, document: railDocument)
    configure(detailScroll, document: detailDocument)
    detailScroll.contentView.postsBoundsChangedNotifications = true
    root.addSubview(backdrop)
    root.addSubview(header)
    root.addSubview(footer)
    root.addSubview(railScroll)
    root.addSubview(detailScroll)
    panel.contentView = root
    detailObserver = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification,
      object: detailScroll.contentView, queue: .main) {
        [weak self] _ in self?.checkBottom()
      }
    model.onChange = { [weak self] in self?.modelChanged() }
  }

  private func configure(_ scroll: NSScrollView,
                         document: InboxDocumentView) {
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = false
    scroll.hasHorizontalScroller = false
    scroll.documentView = document
  }

  func open(screen: NSScreen?) {
    guard let screen else { return }
    let visible = screen.visibleFrame
    let width = min(880, visible.width * 0.62)
    let height = min(620, visible.height * 0.72)
    panel.setFrame(NSRect(x: visible.midX - width / 2,
                          y: visible.midY - height / 2,
                          width: width, height: height), display: false)
    layout(width: width, height: height)
    channel = defaultChannel()
    render()
    panel.makeKeyAndOrderFront(nil)
  }

  func close() {
    panel.orderOut(nil)
  }

  func retheme(_ theme: Theme) {
    self.theme = theme
    if isOpen { render(preserveRail: true, preserveDetail: true) }
  }

  private func layout(width: CGFloat, height: CGFloat) {
    root.frame = NSRect(x: 0, y: 0, width: width, height: height)
    root.wantsLayer = true
    root.layer?.cornerRadius = 16
    root.layer?.masksToBounds = true
    backdrop.frame = root.bounds
    header.frame = NSRect(x: 0, y: height - 52, width: width, height: 52)
    footer.frame = NSRect(x: 0, y: 0, width: width, height: 30)
    railScroll.frame = NSRect(x: 0, y: 30, width: 240, height: height - 82)
    detailScroll.frame = NSRect(x: 240, y: 30,
                                width: width - 240, height: height - 82)
  }

  private func label(_ text: String, size: CGFloat = 12,
                     color: NSColor? = nil, display: Bool = false,
                     mono: Bool = false) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    let family = mono ? theme.monoFamily : display
      ? theme.displayFamily : theme.uiFamily
    field.font = theme.font(family: family, size: size)
    field.textColor = color ?? theme.inboxFG
    field.lineBreakMode = .byTruncatingTail
    return field
  }

  private func hairline(frame: NSRect) -> NSView {
    let line = NSView(frame: frame)
    line.wantsLayer = true
    line.layer?.backgroundColor = theme.inboxOutline.cgColor
    return line
  }

  private func chip(key: String, word: String,
                    action: (() -> Void)? = nil) -> InboxClickView {
    let view = InboxClickView()
    view.action = action
    let keyLabel = label("[\(key)]", size: 10,
                         color: theme.inboxAccent, mono: true)
    keyLabel.sizeToFit()
    keyLabel.frame = NSRect(x: 0, y: 0,
                            width: ceil(keyLabel.frame.width) + 2, height: 16)
    view.addSubview(keyLabel)
    let wordLabel = label(word, size: 10, color: theme.inboxMuted)
    wordLabel.sizeToFit()
    wordLabel.frame = NSRect(x: keyLabel.frame.maxX + 4, y: 0,
                             width: ceil(wordLabel.frame.width) + 2, height: 16)
    view.addSubview(wordLabel)
    view.frame.size = NSSize(width: wordLabel.frame.maxX, height: 16)
    return view
  }

  private func sectionLabel(_ text: String) -> NSTextField {
    label(text, size: 9.5, color: theme.inboxMuted)
  }

  private func add(_ view: NSView, to document: NSView, y: inout CGFloat,
                   height: CGFloat, inset: CGFloat = 22) {
    view.frame = NSRect(x: inset, y: y,
                        width: document.frame.width - inset * 2, height: height)
    document.addSubview(view)
    y += height
  }

  private func render(preserveRail: Bool = false,
                      preserveDetail: Bool = false) {
    let railTop = railScroll.contentView.bounds.origin.y
    let detailTop = detailScroll.contentView.bounds.origin.y
    root.layer?.backgroundColor =
      theme.inboxBG.withAlphaComponent(0.90).cgColor
    renderHeader()
    renderFooter()
    renderRail()
    renderDetail()
    restore(railScroll, y: preserveRail ? railTop : 0)
    restore(detailScroll, y: preserveDetail ? detailTop : 0)
    DispatchQueue.main.async { [weak self] in self?.checkBottom() }
  }

  private func restore(_ scroll: NSScrollView, y: CGFloat) {
    let maximum = max(0, (scroll.documentView?.frame.height ?? 0)
      - scroll.contentSize.height)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: min(y, maximum)))
    scroll.reflectScrolledClipView(scroll.contentView)
  }

  private func renderHeader() {
    header.subviews.forEach { $0.removeFromSuperview() }
    let width = header.frame.width
    let breadcrumb = label("", size: 15, display: true)
    let segments = ["tabard", "inbox"] + (channel.map { [$0] } ?? [])
    let text = NSMutableAttributedString()
    for (index, segment) in segments.enumerated() {
      if index > 0 {
        text.append(NSAttributedString(string: " // ", attributes: [
          .foregroundColor: theme.inboxMuted]))
      }
      text.append(NSAttributedString(string: segment, attributes: [
        .foregroundColor: index == segments.count - 1
          ? theme.inboxFG : theme.inboxMuted]))
    }
    text.addAttribute(.font,
      value: theme.font(family: theme.displayFamily, size: 15),
      range: NSRange(location: 0, length: text.length))
    breadcrumb.attributedStringValue = text
    breadcrumb.frame = NSRect(x: 22, y: 16, width: width - 170, height: 20)
    header.addSubview(breadcrumb)
    let closeChip = chip(key: "esc", word: "close") {
      [weak self] in self?.close()
    }
    closeChip.frame.origin = NSPoint(x: width - closeChip.frame.width - 22,
                                     y: 18)
    header.addSubview(closeChip)
    header.addSubview(hairline(frame: NSRect(x: 0, y: 0,
                                             width: width, height: 0.5)))
  }

  private func renderFooter() {
    footer.subviews.forEach { $0.removeFromSuperview() }
    footer.addSubview(hairline(frame: NSRect(x: 0, y: 29.5,
                                             width: footer.frame.width,
                                             height: 0.5)))
    let legends = [("j/k", "channels"), ("enter", "attend"),
                   ("esc", "close")]
    var x: CGFloat = 22
    for (key, word) in legends {
      let item = chip(key: key, word: word)
      item.frame.origin = NSPoint(x: x, y: 7)
      footer.addSubview(item)
      x = item.frame.maxX + 18
    }
  }

  private func projectTier(_ project: InboxProject) -> InboxTier? {
    if project.threads.contains(where: { $0.tier == .waiting }) {
      return .waiting
    }
    if project.threads.contains(where: { $0.tier == .activity }) {
      return .activity
    }
    return nil
  }

  private func defaultChannel() -> String? {
    model.projects().first { projectTier($0) == .waiting }?.name
  }

  private func renderRail() {
    railDocument.subviews.forEach { $0.removeFromSuperview() }
    railDocument.frame = NSRect(x: 0, y: 0, width: 240,
                                height: railScroll.contentSize.height)
    let projects = model.projects()
    let sections: [(String, InboxTier?, [InboxProject])] = [
      ("NEEDS YOU", .waiting,
       projects.filter { projectTier($0) == .waiting }),
      ("NEW", .activity,
       projects.filter { projectTier($0) == .activity }),
      ("QUIET", nil, projects.filter { projectTier($0) == nil })
    ]
    railItems = [InboxRailItem(channel: nil, tier: nil)]
    for (_, tier, items) in sections {
      railItems += items.map { InboxRailItem(channel: $0.name, tier: tier) }
    }
    railRowFrames.removeAll()
    var y: CGFloat = 10
    renderRailRow(InboxRailItem(channel: nil, tier: nil), y: &y)
    y += 6
    let line = hairline(frame: .zero)
    add(line, to: railDocument, y: &y, height: 0.5, inset: 0)
    if projects.isEmpty {
      y += 14
      add(label("quiet.", color: theme.inboxMuted),
          to: railDocument, y: &y, height: 24)
    } else {
      for (title, tier, items) in sections where !items.isEmpty {
        y += 14
        add(sectionLabel(title), to: railDocument, y: &y, height: 20)
        for project in items {
          renderRailRow(InboxRailItem(channel: project.name, tier: tier), y: &y)
        }
      }
    }
    railDocument.frame.size.height = max(y + 12, railScroll.contentSize.height)
    railDocument.addSubview(hairline(frame: NSRect(x: 239.5, y: 0,
      width: 0.5, height: railDocument.frame.height)))
  }

  private func renderRailRow(_ item: InboxRailItem, y: inout CGFloat) {
    let selected = item.channel == channel
    let row = InboxClickView()
    row.action = { [weak self] in self?.select(item.channel) }
    row.wantsLayer = true
    row.layer?.backgroundColor = selected
      ? theme.inboxAccent.withAlphaComponent(0.10).cgColor
      : NSColor.clear.cgColor
    let name = item.channel ?? "activity"
    let nameColor = selected || item.channel == nil || item.tier != nil
      ? theme.inboxFG : theme.inboxMuted
    let field = label(name, size: 12, color: nameColor)
    field.frame = NSRect(x: 22, y: 7, width: 178, height: 18)
    row.addSubview(field)
    if let tier = item.tier {
      let dot = NSView(frame: NSRect(x: 210, y: 12.5, width: 7, height: 7))
      dot.wantsLayer = true
      dot.layer?.cornerRadius = 3.5
      dot.layer?.backgroundColor = theme.inboxAccent
        .withAlphaComponent(tier == .waiting ? 1 : 0.4).cgColor
      row.addSubview(dot)
    }
    row.frame = NSRect(x: 0, y: y, width: 239.5, height: 32)
    railRowFrames.append(row.frame)
    railDocument.addSubview(row)
    y += 32
  }

  private func renderDetail() {
    detailDocument.subviews.forEach { $0.removeFromSuperview() }
    detailDocument.frame = NSRect(x: 0, y: 0,
      width: detailScroll.contentSize.width, height: detailScroll.contentSize.height)
    var y: CGFloat = 22
    if let channel {
      renderChannel(channel, y: &y)
    } else {
      renderFeed(y: &y)
    }
    detailDocument.frame.size.height = max(y + 22, detailScroll.contentSize.height)
  }

  private func renderChannel(_ name: String, y: inout CGFloat) {
    guard let project = model.projects().first(where: { $0.name == name }) else {
      add(label("no messages in the window.", color: theme.inboxMuted),
          to: detailDocument, y: &y, height: 30)
      return
    }
    let active = project.threads.filter { thread in
      thread.members.contains { $0.state == "waiting" || $0.state == "working" }
    }
    if !active.isEmpty {
      add(sectionLabel("ACTIVE"), to: detailDocument, y: &y, height: 22)
      for thread in active { renderThread(thread, y: &y) }
    }
    if !active.isEmpty { y += 18 }
    add(sectionLabel("SCROLLBACK"), to: detailDocument, y: &y, height: 22)
    let allEvents = model.events.filter { $0.project == name }
    let events = Array(allEvents.suffix(50))
    if allEvents.count > 50 {
      add(label("↑ older history in the archive", size: 10.5,
                color: theme.inboxMuted),
          to: detailDocument, y: &y, height: 28)
    }
    if events.isEmpty {
      add(label("no messages in the window.", color: theme.inboxMuted),
          to: detailDocument, y: &y, height: 30)
      return
    }
    var divided = false
    for event in events {
      let unread = event.seq > (model.cursors[event.thread] ?? 0)
      if unread && !divided {
        add(label("NEW", size: 9, color: theme.inboxAccent),
            to: detailDocument, y: &y, height: 18)
        divided = true
      }
      let row = NSView()
      styleMessage(row, event: event, unread: unread)
      add(row, to: detailDocument, y: &y, height: 30)
    }
  }

  private func renderThread(_ thread: InboxThread, y: inout CGFloat) {
    let row = InboxClickView()
    row.action = { [weak self] in self?.attend?(thread.id) }
    row.wantsLayer = true
    row.layer?.backgroundColor = theme.inboxAccent.withAlphaComponent(0.06).cgColor
    let waiting = thread.members.contains { $0.state == "waiting" }
    let stripe = NSView(frame: NSRect(x: 0, y: 3, width: 3, height: 48))
    stripe.wantsLayer = true
    stripe.layer?.backgroundColor = (waiting
      ? theme.inboxAccent : theme.inboxOutline).cgColor
    row.addSubview(stripe)
    let title = label(thread.name, size: 12, display: true)
    title.frame = NSRect(x: 12, y: 6,
                         width: detailDocument.frame.width - 68, height: 18)
    row.addSubview(title)
    let state = label("", size: 10, color: theme.inboxMuted)
    let states = NSMutableAttributedString()
    for (index, member) in thread.members.enumerated() {
      if index > 0 { states.append(NSAttributedString(string: " · ")) }
      let word = member.state == "done" ? (member.outcome ?? "done")
        : member.state
      let color: NSColor
      if member.state == "waiting" { color = theme.inboxAccent }
      else if member.outcome == "failure" { color = .systemRed }
      else if member.state == "done" { color = .systemGreen }
      else { color = theme.inboxMuted }
      states.append(NSAttributedString(string: word,
        attributes: [.foregroundColor: color]))
    }
    if !thread.unread.isEmpty {
      states.append(NSAttributedString(string: " · \(thread.unread.count) new",
        attributes: [.foregroundColor: theme.inboxAccent]))
    }
    states.addAttribute(.font,
      value: theme.font(family: theme.uiFamily, size: 10),
      range: NSRange(location: 0, length: states.length))
    state.attributedStringValue = states
    state.frame = NSRect(x: 12, y: 29,
                         width: detailDocument.frame.width - 68, height: 16)
    row.addSubview(state)
    add(row, to: detailDocument, y: &y, height: 54)
  }

  private func styleMessage(_ row: NSView, event: InboxEvent, unread: Bool) {
    row.wantsLayer = true
    row.layer?.backgroundColor = unread
      ? theme.inboxAccent.withAlphaComponent(0.08).cgColor : NSColor.clear.cgColor
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    let time = label("[\(formatter.string(from: event.date))]", size: 10,
                     color: theme.inboxMuted, mono: true)
    time.frame = NSRect(x: 6, y: 7, width: 48, height: 16)
    row.addSubview(time)
    let text = label("\(event.threadName)  \(event.label)", size: 11,
                     color: unread ? theme.inboxFG : theme.inboxMuted)
    text.frame = NSRect(x: 58, y: 6,
                        width: detailDocument.frame.width - 108, height: 18)
    row.addSubview(text)
  }

  private func renderFeed(y: inout CGFloat) {
    let events = Array(model.events.suffix(50).reversed())
    if events.isEmpty {
      add(label("quiet.", color: theme.inboxMuted),
          to: detailDocument, y: &y, height: 30)
      return
    }
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    for event in events {
      let unread = event.seq > (model.cursors[event.thread] ?? 0)
      let suffix = event.tier == .waiting ? "   needs you" : ""
      let row = InboxClickView()
      row.action = { [weak self] in self?.attend?(event.thread) }
      row.wantsLayer = true
      row.layer?.backgroundColor = unread
        ? theme.inboxAccent.withAlphaComponent(0.08).cgColor : NSColor.clear.cgColor
      let time = label("[\(formatter.string(from: event.date))]", size: 10,
                       color: theme.inboxMuted, mono: true)
      time.frame = NSRect(x: 6, y: 8, width: 48, height: 18)
      row.addSubview(time)
      let field = label("\(event.project)  \(event.threadName) — "
        + "\(event.label)\(suffix)", size: 10.5,
        color: unread ? theme.inboxFG : theme.inboxMuted)
      field.frame = NSRect(x: 58, y: 8,
                           width: detailDocument.frame.width - 108, height: 18)
      row.addSubview(field)
      add(row, to: detailDocument, y: &y, height: 34)
    }
  }

  private func select(_ value: String?) {
    guard channel != value else { return }
    channel = value
    render(preserveRail: true)
    scrollRailSelectionIntoView()
  }

  private func scrollRailSelectionIntoView() {
    guard let index = railItems.firstIndex(where: { $0.channel == channel }),
          railRowFrames.indices.contains(index) else { return }
    let row = railRowFrames[index]
    let visible = railScroll.contentView.bounds
    var target = visible.origin.y
    if row.minY < visible.minY { target = row.minY }
    if row.maxY > visible.maxY { target = row.maxY - visible.height }
    restore(railScroll, y: target)
  }

  private func handleKey(_ event: NSEvent) -> Bool {
    switch event.keyCode {
    case 53:
      close()
      return true
    case 125:
      moveSelection(by: 1)
      return true
    case 126:
      moveSelection(by: -1)
      return true
    case 36, 76:
      attendSelected()
      return true
    default:
      let key = event.charactersIgnoringModifiers?.lowercased()
      if key == "j" { moveSelection(by: 1); return true }
      if key == "k" { moveSelection(by: -1); return true }
      return false
    }
  }

  private func moveSelection(by offset: Int) {
    guard !railItems.isEmpty else { return }
    let current = railItems.firstIndex { $0.channel == channel } ?? 0
    let target = min(max(current + offset, 0), railItems.count - 1)
    select(railItems[target].channel)
  }

  private func attendSelected() {
    guard let channel,
          let project = model.projects().first(where: { $0.name == channel })
    else { return }
    let candidate = project.threads.compactMap { thread -> (String, String)? in
      guard let member = thread.members.first(where: { $0.state == "waiting" })
      else { return nil }
      return (member.id, thread.id)
    }.min { $0.0 < $1.0 }
    if let candidate { attend?(candidate.1) }
  }

  private func modelChanged() {
    guard isOpen else { return }
    if let selected = channel,
       !model.projects().contains(where: { $0.name == selected }) {
      channel = defaultChannel()
    }
    render(preserveRail: true, preserveDetail: true)
  }

  private func checkBottom() {
    guard isOpen, let channel,
          let project = model.projects().first(where: { $0.name == channel })
    else { return }
    let visibleBottom = detailScroll.contentView.bounds.maxY
    let contentBottom = detailDocument.frame.height
    guard contentBottom - visibleBottom <= 8 else { return }
    model.markRead(Dictionary(uniqueKeysWithValues:
      project.threads.map { ($0.id, $0.lastSeq) }))
  }
}
