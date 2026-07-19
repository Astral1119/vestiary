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
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

class InboxClickView: NSView {
  var action: (() -> Void)?

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) { action?() }
}

final class InboxRow: InboxClickView {
  let thread: String?
  let seq: Int?
  var dwellTimer: Timer?

  init(thread: String? = nil, seq: Int? = nil) {
    self.thread = thread
    self.seq = seq
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) { fatalError() }
}

final class InboxDocumentView: NSView {
  override var isFlipped: Bool { true }
}

final class InboxController: NSObject {
  let model: InboxModel
  private let panel: InboxPanel
  private let root = NSView()
  private let header = InboxDocumentView()
  private let scroll = NSScrollView()
  private let document = InboxDocumentView()
  private var theme: Theme
  private var tab = "channels"
  private var channel: String?
  private var messageRows: [Int: InboxRow] = [:]
  private weak var badgeLabel: NSTextField?
  private weak var channelHead: NSView?
  private weak var scrollbackLabel: NSView?
  private var liveViews: [NSView] = []
  private var newDivider: NSView?
  private var channelEmpty: NSView?
  private var clipObserver: NSObjectProtocol?
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
    panel.isOpaque = true
    panel.hasShadow = true
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.contentView.postsBoundsChangedNotifications = true
    scroll.documentView = document
    root.addSubview(header)
    root.addSubview(scroll)
    panel.contentView = root
    clipObserver = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification, object: scroll.contentView,
      queue: .main) { [weak self] _ in self?.evaluateDwell() }
    model.onChange = { [weak self] in self?.modelChanged() }
  }

  func toggle(screen: NSScreen?) {
    if isOpen { close(); return }
    guard let screen else { return }
    let height = min(640, screen.visibleFrame.height * 0.7)
    panel.setFrame(NSRect(x: screen.visibleFrame.maxX - 440 - Config.margin,
                          y: screen.visibleFrame.maxY - height - Config.margin,
                          width: 440, height: height), display: false)
    root.frame = NSRect(x: 0, y: 0, width: 440, height: height)
    header.frame = NSRect(x: 0, y: height - 92, width: 440, height: 92)
    scroll.frame = NSRect(x: 0, y: 0, width: 440, height: height - 92)
    channel = nil
    tab = "channels"
    render()
    panel.orderFrontRegardless()
  }

  func close() {
    cancelDwell()
    panel.orderOut(nil)
  }

  func retheme(_ theme: Theme) {
    self.theme = theme
    if isOpen { render(preserveScroll: true) }
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

  private func button(_ text: String, action: @escaping () -> Void) -> InboxClickView {
    let view = InboxClickView()
    view.action = action
    let field = label(text, size: 11, color: theme.inboxAccent)
    field.frame = NSRect(x: 0, y: 2, width: 110, height: 18)
    view.addSubview(field)
    return view
  }

  private func clear() {
    cancelDwell()
    document.subviews.forEach { $0.removeFromSuperview() }
    header.subviews.forEach { $0.removeFromSuperview() }
    messageRows.removeAll()
    liveViews.removeAll()
    newDivider = nil
    channelEmpty = nil
  }

  private func add(_ view: NSView, y: inout CGFloat, height: CGFloat,
                   inset: CGFloat = 14) {
    view.frame = NSRect(x: inset, y: y, width: 440 - inset * 2, height: height)
    document.addSubview(view)
    y += height
  }

  private func addHeader(_ view: NSView, y: inout CGFloat, height: CGFloat,
                         inset: CGFloat = 14) {
    view.frame = NSRect(x: inset, y: y, width: 440 - inset * 2, height: height)
    header.addSubview(view)
    y += height
  }

  private func render(preserveScroll: Bool = false) {
    let old = scroll.contentView.bounds.origin.y
    clear()
    panel.backgroundColor = theme.inboxBG
    document.wantsLayer = true
    document.layer?.backgroundColor = theme.inboxBG.cgColor
    var headerY: CGFloat = 10
    renderHeader(y: &headerY)
    var y: CGFloat = 8
    if tab == "activity" {
      renderFeed(y: &y)
    } else if let channel {
      renderChannel(channel, y: &y)
    } else {
      renderProjects(y: &y)
    }
    document.frame = NSRect(x: 0, y: 0, width: 440,
                            height: max(y + 12, scroll.contentSize.height))
    // a fresh view starts at the top; only in-place updates keep position
    scroll.contentView.scroll(to: NSPoint(x: 0, y: preserveScroll ? old : 0))
    scroll.reflectScrolledClipView(scroll.contentView)
  }

  private func renderHeader(y: inout CGFloat) {
    let header = NSView()
    let title = label("inbox", size: 18, display: true)
    title.frame = NSRect(x: 0, y: 0, width: 100, height: 24)
    header.addSubview(title)
    let threads = model.threads()
    let waiting = threads.filter { $0.tier == .waiting }.count
    let activity = threads.filter { $0.tier == .activity }.count
    let badges = label("\(waiting) need you   \(activity) new", size: 10,
      color: waiting + activity == 0 ? theme.inboxMuted : theme.inboxAccent)
    badges.frame = NSRect(x: 100, y: 3, width: 145, height: 18)
    header.addSubview(badges)
    badgeLabel = badges
    let all = button("mark all read") { [weak self] in self?.model.markAllRead() }
    all.frame = NSRect(x: 255, y: 0, width: 100, height: 22)
    header.addSubview(all)
    let close = button("✕") { [weak self] in self?.close() }
    close.frame = NSRect(x: 390, y: 0, width: 20, height: 22)
    header.addSubview(close)
    addHeader(header, y: &y, height: 28)

    let tabs = NSView()
    let channels = button(tab == "channels" ? "channels •" : "channels") {
      [weak self] in self?.switchTab("channels")
    }
    channels.frame = NSRect(x: 0, y: 0, width: 90, height: 22)
    tabs.addSubview(channels)
    let activityButton = button(tab == "activity" ? "activity •" : "activity") {
      [weak self] in self?.switchTab("activity")
    }
    activityButton.frame = NSRect(x: 100, y: 0, width: 90, height: 22)
    tabs.addSubview(activityButton)
    addHeader(tabs, y: &y, height: 24)
    let hint = tab == "channels"
      ? "stable alphabetical order — salience rides the badge, not the sort"
      : "unified feed, newest first — reads only on click, never on scroll"
    addHeader(label(hint, size: 10, color: theme.inboxMuted),
              y: &y, height: 24)
  }

  private func switchTab(_ value: String) {
    guard tab != value else { return }
    channel = nil
    tab = value
    render()
  }

  private func renderProjects(y: inout CGFloat) {
    let projects = model.projects()
    if projects.isEmpty {
      add(label("quiet.", color: theme.inboxMuted), y: &y, height: 36)
      return
    }
    for project in projects {
      let waiting = project.threads.filter { $0.tier == .waiting }.count
      let activity = project.threads.filter { $0.tier == .activity }.count
      let live = project.threads.filter { $0.live }.count
      var text = project.name
      if waiting > 0 { text += "   [\(waiting) need you]" }
      if activity > 0 { text += "   [\(activity) new]" }
      text += "   \(live) live"
      let row = InboxRow()
      row.action = { [weak self] in self?.enterChannel(project.name) }
      let field = label(text, size: 12,
        color: waiting + activity == 0 ? theme.inboxMuted : theme.inboxFG)
      field.frame = NSRect(x: 8, y: 10, width: 396, height: 20)
      row.addSubview(field)
      row.wantsLayer = true
      row.layer?.borderColor = theme.inboxOutline.cgColor
      row.layer?.borderWidth = 0.5
      add(row, y: &y, height: 40)
    }
  }

  private func enterChannel(_ name: String) {
    channel = name
    render()
    guard let first = model.events.first(where: {
      $0.project == name && $0.seq > (model.cursors[$0.thread] ?? 0)
    }), let row = messageRows[first.seq] else {
      evaluateDwell(); return
    }
    let target = max(0, row.frame.midY - scroll.contentSize.height / 2)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
    scroll.reflectScrolledClipView(scroll.contentView)
    evaluateDwell()
  }

  private func renderChannel(_ name: String, y: inout CGFloat) {
    let head = NSView()
    let back = button("←") { [weak self] in
      self?.channel = nil
      self?.render()
    }
    back.frame = NSRect(x: 0, y: 0, width: 24, height: 22)
    head.addSubview(back)
    let nameLabel = label(name, size: 15, display: true)
    nameLabel.frame = NSRect(x: 32, y: 0, width: 180, height: 22)
    head.addSubview(nameLabel)
    let copy = label("entering marked nothing — scroll or attend does",
                     size: 9.5, color: theme.inboxMuted)
    copy.frame = NSRect(x: 215, y: 1, width: 200, height: 18)
    head.addSubview(copy)
    add(head, y: &y, height: 30)
    channelHead = head
    let project = model.projects().first { $0.name == name }
    guard let project else {
      add(label("this channel's history aged out.", color: theme.inboxMuted),
          y: &y, height: 40)
      return
    }
    let live = project.threads.filter { $0.live }
    if !live.isEmpty {
      add(label("LIVE THREADS", size: 10, color: theme.inboxMuted),
          y: &y, height: 24)
      liveViews.append(document.subviews.last!)
      for thread in live {
        renderThread(thread, y: &y)
        liveViews.append(document.subviews.last!)
      }
    }
    let scrollLabel = label("SCROLLBACK", size: 10, color: theme.inboxMuted)
    add(scrollLabel, y: &y, height: 24)
    scrollbackLabel = scrollLabel
    let events = model.events.filter { $0.project == name }
    if events.isEmpty {
      let empty = label("no messages in the window.", color: theme.inboxMuted)
      add(empty, y: &y, height: 40)
      channelEmpty = empty
      return
    }
    var divider = false
    for event in events {
      let unread = event.seq > (model.cursors[event.thread] ?? 0)
      if unread && !divider {
        let view = label("NEW", size: 9, color: theme.inboxAccent)
        add(view, y: &y, height: 18)
        newDivider = view
        divider = true
      }
      let row = InboxRow(thread: event.thread, seq: event.seq)
      styleMessage(row, event: event, unread: unread)
      messageRows[event.seq] = row
      add(row, y: &y, height: 30)
    }
    DispatchQueue.main.async { [weak self] in self?.evaluateDwell() }
  }

  private func renderThread(_ thread: InboxThread, y: inout CGFloat) {
    let row = InboxRow(thread: thread.id)
    row.wantsLayer = true
    row.layer?.backgroundColor = theme.inboxBG.blended(
      withFraction: 0.06, of: theme.inboxAccent)?.cgColor
    let stripe = NSView(frame: NSRect(x: 0, y: 3, width: 3, height: 48))
    stripe.wantsLayer = true
    stripe.layer?.backgroundColor = (thread.waiting
      ? theme.inboxAccent : theme.inboxOutline).cgColor
    row.addSubview(stripe)
    let title = label(thread.name, size: 12, display: true)
    title.frame = NSRect(x: 10, y: 5, width: 180, height: 18)
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
    state.frame = NSRect(x: 10, y: 27, width: 230, height: 16)
    row.addSubview(state)
    let attendButton = button("attend") { [weak self] in self?.attend?(thread.id) }
    attendButton.frame = NSRect(x: 275, y: 15, width: 55, height: 22)
    row.addSubview(attendButton)
    if thread.unread.isEmpty {
      let unread = button("mark unread") { [weak self] in
        self?.model.markUnread(thread.id)
      }
      unread.frame = NSRect(x: 335, y: 15, width: 75, height: 22)
      row.addSubview(unread)
    }
    add(row, y: &y, height: 54)
  }

  private func styleMessage(_ row: InboxRow, event: InboxEvent, unread: Bool) {
    row.wantsLayer = true
    row.layer?.backgroundColor = unread
      ? theme.inboxAccent.withAlphaComponent(0.08).cgColor : theme.inboxBG.cgColor
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    let time = label("[\(formatter.string(from: event.date))]", size: 10,
                     color: theme.inboxMuted, mono: true)
    time.frame = NSRect(x: 4, y: 7, width: 48, height: 16)
    row.addSubview(time)
    let text = label("\(event.threadName)  \(event.label)", size: 11,
                     color: unread ? theme.inboxFG : theme.inboxMuted)
    text.frame = NSRect(x: 54, y: 6, width: 346, height: 18)
    row.addSubview(text)
  }

  private func renderFeed(y: inout CGFloat) {
    if model.events.isEmpty {
      add(label("quiet.", color: theme.inboxMuted), y: &y, height: 36)
      return
    }
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    for event in model.events.reversed() {
      let unread = event.seq > (model.cursors[event.thread] ?? 0)
      let suffix = event.tier == .waiting ? "   needs you" : ""
      let row = InboxRow(thread: event.thread, seq: event.seq)
      row.action = { [weak self] in self?.attend?(event.thread) }
      row.wantsLayer = true
      row.layer?.backgroundColor = unread
        ? theme.inboxAccent.withAlphaComponent(0.08).cgColor : theme.inboxBG.cgColor
      let time = label("[\(formatter.string(from: event.date))]", size: 10,
                       color: theme.inboxMuted, mono: true)
      time.frame = NSRect(x: 6, y: 8, width: 48, height: 18)
      row.addSubview(time)
      let field = label("\(event.project)  \(event.threadName) — "
        + "\(event.label)\(suffix)", size: 10.5,
                        color: unread ? theme.inboxFG : theme.inboxMuted)
      field.frame = NSRect(x: 56, y: 8, width: 350, height: 18)
      row.addSubview(field)
      add(row, y: &y, height: 34)
    }
  }

  private func modelChanged() {
    guard isOpen else { return }
    if let channel {
      syncChannel(channel)
    } else {
      render(preserveScroll: tab == "activity")
    }
  }

  private func syncChannel(_ name: String) {
    guard let head = channelHead, let scrollLabel = scrollbackLabel else {
      render(preserveScroll: true)
      return
    }
    let oldScroll = scroll.contentView.bounds.origin.y
    let projected = model.threads()
    let waiting = projected.filter { $0.tier == .waiting }.count
    let activity = projected.filter { $0.tier == .activity }.count
    badgeLabel?.stringValue = "\(waiting) need you   \(activity) new"
    badgeLabel?.textColor = waiting + activity == 0
      ? theme.inboxMuted : theme.inboxAccent

    for view in liveViews { view.removeFromSuperview() }
    liveViews.removeAll()
    var y = head.frame.maxY
    if let project = model.projects().first(where: { $0.name == name }) {
      let live = project.threads.filter { $0.live }
      if !live.isEmpty {
        let section = label("LIVE THREADS", size: 10, color: theme.inboxMuted)
        add(section, y: &y, height: 24)
        liveViews.append(section)
        for thread in live {
          renderThread(thread, y: &y)
          liveViews.append(document.subviews.last!)
        }
      }
    }
    scrollLabel.frame = NSRect(x: 14, y: y, width: 412, height: 24)
    y += 24

    let events = model.events.filter { $0.project == name }
    let retained = Set(events.map { $0.seq })
    for (seq, row) in messageRows where !retained.contains(seq) {
      row.dwellTimer?.invalidate()
      row.removeFromSuperview()
      messageRows.removeValue(forKey: seq)
    }
    if events.isEmpty {
      newDivider?.removeFromSuperview(); newDivider = nil
      let copy = model.projects().contains { $0.name == name }
        ? "no messages in the window." : "this channel's history aged out."
      if channelEmpty == nil {
        let empty = label(copy, color: theme.inboxMuted)
        document.addSubview(empty)
        channelEmpty = empty
      }
      (channelEmpty as? NSTextField)?.stringValue = copy
      channelEmpty?.frame = NSRect(x: 14, y: y, width: 412, height: 40)
      y += 40
    } else {
      channelEmpty?.removeFromSuperview(); channelEmpty = nil
      let firstUnread = events.first {
        $0.seq > (model.cursors[$0.thread] ?? 0)
      }?.seq
      if firstUnread != nil, newDivider == nil {
        let divider = label("NEW", size: 9, color: theme.inboxAccent)
        document.addSubview(divider)
        newDivider = divider
      } else if firstUnread == nil {
        newDivider?.removeFromSuperview(); newDivider = nil
      }
      for event in events {
        if event.seq == firstUnread, let divider = newDivider {
          divider.frame = NSRect(x: 14, y: y, width: 412, height: 18)
          y += 18
        }
        let unread = event.seq > (model.cursors[event.thread] ?? 0)
        let row: InboxRow
        if let existing = messageRows[event.seq] {
          row = existing
          row.subviews.forEach { $0.removeFromSuperview() }
          styleMessage(row, event: event, unread: unread)
        } else {
          row = InboxRow(thread: event.thread, seq: event.seq)
          styleMessage(row, event: event, unread: unread)
          messageRows[event.seq] = row
          document.addSubview(row)
        }
        row.frame = NSRect(x: 14, y: y, width: 412, height: 30)
        y += 30
      }
    }
    document.frame.size.height = max(y + 12, scroll.contentSize.height)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: oldScroll))
    scroll.reflectScrolledClipView(scroll.contentView)
    evaluateDwell()
  }

  private func evaluateDwell() {
    guard isOpen, channel != nil else { cancelDwell(); return }
    let viewport = scroll.contentView.documentVisibleRect
    for row in messageRows.values {
      guard let thread = row.thread, let seq = row.seq,
            seq > (model.cursors[thread] ?? 0) else {
        row.dwellTimer?.invalidate(); row.dwellTimer = nil
        continue
      }
      let intersection = row.frame.intersection(viewport)
      let visible = !intersection.isNull
        && intersection.height >= row.frame.height * 0.95
      if visible && row.dwellTimer == nil {
        row.dwellTimer = Timer.scheduledTimer(withTimeInterval: 0.7,
                                               repeats: false) {
          [weak self, weak row] _ in
          row?.dwellTimer = nil
          self?.model.markRead(thread, through: seq)
        }
      } else if !visible {
        row.dwellTimer?.invalidate(); row.dwellTimer = nil
      }
    }
  }

  private func cancelDwell() {
    for row in messageRows.values {
      row.dwellTimer?.invalidate(); row.dwellTimer = nil
    }
  }
}
