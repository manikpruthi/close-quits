import AppKit
import ApplicationServices
import os

/// Decisions are logged for troubleshooting (notice level is kept on disk):
/// `log show --last 10m --debug --predicate 'subsystem == "com.manikpruthi.closequits"'`
private let log = Logger(subsystem: "com.manikpruthi.closequits", category: "detector")

/// Apps whose windows always close normally (never quit).
private let excludedBundleIDs: Set<String> = [
    // Finder owns the desktop; quitting it is never wanted.
    "com.apple.finder",
    // QuickShare-Mac owns its Send window lifecycle (transfers, PIN
    // confirmation, QR wake); never quit it on close.
    "tools.macexplorer.quickshare",
]

// Private SkyLight calls, resolved at runtime, used only to tell windows that
// live on another Space (which the Accessibility API does not list) apart from
// hidden windows. Some apps (e.g. Activity Monitor) keep a closed window around
// ordered-out but still assigned to the current Space, so only windows on a
// Space that no display is showing count. If any call is unavailable we fall
// back to AX only.
private typealias CGSMainConnectionIDFn = @convention(c) () -> Int32
private typealias CGSCopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
private typealias CGSCopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
private let skyLight = dlopen(nil, RTLD_NOW)
private let cgsMainConnectionID = dlsym(skyLight, "CGSMainConnectionID")
    .map { unsafeBitCast($0, to: CGSMainConnectionIDFn.self) }
private let cgsCopySpacesForWindows = dlsym(skyLight, "CGSCopySpacesForWindows")
    .map { unsafeBitCast($0, to: CGSCopySpacesForWindowsFn.self) }
private let cgsCopyManagedDisplaySpaces = dlsym(skyLight, "CGSCopyManagedDisplaySpaces")
    .map { unsafeBitCast($0, to: CGSCopyManagedDisplaySpacesFn.self) }
private let allSpacesMask: Int32 = 7

/// Watches clicks and quits an app once the click on its close button has
/// actually closed its last window. All Accessibility work runs on a private
/// serial queue so the event tap never blocks system-wide mouse input; all
/// mutable state is confined to that queue.
final class CloseDetector: @unchecked Sendable {
    private struct Candidate: @unchecked Sendable {
        let pid: pid_t
        let window: AXUIElement
    }

    /// What identifies an app's leftover processes once it has exited: its
    /// bundle, and its resource coalition. Every process an app launches stays
    /// in its coalition even after detaching (e.g. `git fsmonitor--daemon`
    /// started by an editor), and LaunchServices keeps showing the app as
    /// running in the Dock while any of them live.
    private struct Leftovers: Sendable {
        let bundlePath: String?
        let coalition: UInt64?
    }

    private let queue = DispatchQueue(label: "com.manikpruthi.closequits.detector", qos: .userInitiated)
    private let systemWide = AXUIElementCreateSystemWide()
    private var pending: Candidate?

    private static let pollInterval: TimeInterval = 0.1
    private static let pollAttempts = 15
    /// How long a quitting app gets to exit on its own before it is forced.
    private static let quitCheckInterval: TimeInterval = 0.5
    private static let quitCheckAttempts = 10
    /// How long leftover helper processes get after SIGTERM before SIGKILL.
    private static let helperKillDelay: TimeInterval = 2

    init() {
        // Bound every AX round-trip so a hung app can't stall detection.
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
    }

    func mouseDown(at location: CGPoint) {
        queue.async { self.pending = self.candidate(at: location) }
    }

    func mouseUp() {
        queue.async {
            guard let candidate = self.pending else { return }
            self.pending = nil
            self.confirmClosed(candidate, attempt: 0)
        }
    }

    // MARK: - Detection (on queue)

    private func candidate(at location: CGPoint) -> Candidate? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(location.x), Float(location.y), &hit) == .success,
              let element = hit else { return nil }

        // Cheap rejection first: one round-trip for role + subrole.
        let attrs = [kAXRoleAttribute, kAXSubroleAttribute] as CFArray
        var valuesRef: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attrs, [], &valuesRef) == .success,
              let values = valuesRef as? [Any], values.count == 2 else { return nil }
        let isCloseSubrole = (values[1] as? String) == (kAXCloseButtonSubrole as String)
        guard isCloseSubrole || (values[0] as? String) == (kAXButtonRole as String) else { return nil }

        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid != getpid() else { return nil }
        if let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
           excludedBundleIDs.contains(bundleID) {
            log.debug("pid \(pid): excluded app \(bundleID, privacy: .public)")
            return nil
        }

        guard let window = Self.containingWindow(of: element) else {
            log.debug("pid \(pid): close button has no window")
            return nil
        }
        if !isCloseSubrole {
            // Plain button: accept only if it is the window's own close button.
            guard let closeButton = Self.attribute(window, kAXCloseButtonAttribute),
                  CFEqual(closeButton, element) else { return nil }
        }

        // Only act on the app's main window; auxiliary windows (Quick Look
        // previews, panels, popovers, ...) must just close normally.
        let app = AXUIElementCreateApplication(pid)
        if let mainWindow = Self.attribute(app, kAXMainWindowAttribute), !CFEqual(mainWindow, window) {
            log.debug("pid \(pid): not the main window")
            return nil
        }

        // Early out when other windows will obviously remain.
        if let count = Self.openWindowCount(for: pid), count > 1 {
            log.debug("pid \(pid): \(count) windows open, not the last one")
            return nil
        }

        log.notice("pid \(pid): close button on last window pressed")
        return Candidate(pid: pid, window: window)
    }

    /// After mouse-up, poll briefly until the app has no windows left. If the
    /// close was cancelled (dragged off the button, "Save?" sheet, ...) the
    /// window stays and the app is left alone.
    private func confirmClosed(_ candidate: Candidate, attempt: Int) {
        guard let running = NSRunningApplication(processIdentifier: candidate.pid), !running.isTerminated else { return }

        let count = Self.openWindowCount(for: candidate.pid, closing: candidate.window)
        if count == 0 {
            log.notice("pid \(candidate.pid): no windows left, quitting")
            quit(candidate)
            return
        }

        guard attempt + 1 < Self.pollAttempts else {
            log.notice("pid \(candidate.pid): still \(count.map(String.init) ?? "unknown", privacy: .public) windows, leaving it running")
            return
        }
        queue.asyncAfter(deadline: .now() + Self.pollInterval) {
            self.confirmClosed(candidate, attempt: attempt + 1)
        }
    }

    // MARK: - Quitting (on queue)

    /// Asks the app to quit, then makes sure it and every process running from
    /// its bundle (helpers, agents, XPC services) are really gone.
    private func quit(_ candidate: Candidate) {
        let pid = candidate.pid
        // Capture these while the app is alive; they can't be read afterwards.
        let bundlePath = NSRunningApplication(processIdentifier: pid)?.bundleURL?.resolvingSymlinksInPath().path
        let leftovers = Leftovers(
            bundlePath: bundlePath,
            coalition: Self.exclusiveCoalition(of: pid, bundlePath: bundlePath)
        )
        DispatchQueue.main.async {
            NSRunningApplication(processIdentifier: pid)?.terminate()
        }
        queue.asyncAfter(deadline: .now() + Self.quitCheckInterval) {
            self.enforceQuit(candidate, leftovers: leftovers, attempt: 0)
        }
    }

    private func enforceQuit(_ candidate: Candidate, leftovers: Leftovers, attempt: Int) {
        let pid = candidate.pid
        let stillRunning = NSRunningApplication(processIdentifier: pid).map { !$0.isTerminated } ?? false
        guard stillRunning else {
            killLeftovers(leftovers)
            return
        }
        if attempt + 1 < Self.quitCheckAttempts {
            queue.asyncAfter(deadline: .now() + Self.quitCheckInterval) {
                self.enforceQuit(candidate, leftovers: leftovers, attempt: attempt + 1)
            }
            return
        }
        // The app ignored or stalled the quit. If it is showing a window (a
        // quit confirmation, "Review changes", ...) the user is being asked
        // something, so leave it alone; otherwise it is lingering in the
        // background and gets force-quit. The closed window doesn't count:
        // apps that hide it instead of closing it still list it over AX.
        guard Self.openWindowCount(for: pid, closing: candidate.window) == 0 else {
            log.notice("pid \(pid): ignored quit but is showing a window, leaving it")
            return
        }
        log.notice("pid \(pid): ignored quit with no windows, force-quitting")
        DispatchQueue.main.async {
            NSRunningApplication(processIdentifier: pid)?.forceTerminate()
        }
        queue.asyncAfter(deadline: .now() + Self.quitCheckInterval) {
            self.killLeftovers(leftovers)
        }
    }

    /// SIGTERM, then SIGKILL, every process of ours left behind by the quit
    /// app: anything running from inside its bundle or still in its coalition.
    private func killLeftovers(_ leftovers: Leftovers) {
        let pids = Self.processes(matching: leftovers)
        guard !pids.isEmpty else { return }
        log.notice("""
            terminating \(pids.count) leftover processes of \(leftovers.bundlePath ?? "?", privacy: .public) \
            (coalition \(leftovers.coalition.map(String.init) ?? "none", privacy: .public))
            """)
        pids.forEach { kill($0, SIGTERM) }
        queue.asyncAfter(deadline: .now() + Self.helperKillDelay) {
            // Re-resolve so a reused pid is never killed.
            Self.processes(matching: leftovers).filter(pids.contains).forEach { kill($0, SIGKILL) }
        }
    }

    private static func processes(matching leftovers: Leftovers) -> [pid_t] {
        let prefix = leftovers.bundlePath.flatMap { $0.hasSuffix(".app") ? $0 + "/" : nil }
        guard prefix != nil || leftovers.coalition != nil else { return [] }
        var path = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let me = getpid()
        return allPIDs().filter { pid in
            guard pid > 1, pid != me else { return false }
            // Coalition members with a controlling terminal are the user's
            // own shell sessions in an app that hosts terminals (a `nohup`
            // job in VS Code, say), not background work the app spawned.
            if let coalition = leftovers.coalition, coalitionID(of: pid) == coalition, !hasControllingTerminal(pid) {
                return true
            }
            guard let prefix else { return false }
            let length = Int(proc_pidpath(pid, &path, UInt32(path.count)))
            return length > 0 && String(decoding: path.prefix(length), as: UTF8.self).hasPrefix(prefix)
        }
    }

    private static func hasControllingTerminal(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return true }
        return info.pbi_flags & UInt32(PROC_FLAG_CONTROLT) != 0
    }

    private static func allPIDs() -> [pid_t] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        return Array(pids.prefix(max(0, min(count, capacity))))
    }

    /// The process's resource coalition, via the kernel's
    /// `proc_pidinfo(PROC_PIDCOALITIONINFO)` (not in the public SDK; the
    /// result is `struct proc_pidcoalitioninfo`, five UInt64s).
    private static func coalitionID(of pid: pid_t) -> UInt64? {
        var info = [UInt64](repeating: 0, count: 5)
        let size = Int32(info.count * MemoryLayout<UInt64>.size)
        guard proc_pidinfo(pid, 20, 0, &info, size) == size, info[0] != 0 else { return nil }
        return info[0]
    }

    /// The app's coalition, but only if no other user-facing app shares it.
    /// An app started straight from a shell shares the terminal's coalition,
    /// and sweeping that would kill unrelated work. Background-only processes
    /// (XPC services run on the app's behalf, Electron's "<App> Helper.app")
    /// and anything nested in the app's own bundle don't count.
    private static func exclusiveCoalition(of pid: pid_t, bundlePath: String?) -> UInt64? {
        guard let coalition = coalitionID(of: pid), coalition > 1, coalition != coalitionID(of: getpid()) else {
            return nil
        }
        let nestedPrefix = bundlePath.map { $0 + "/" }
        let sharedWith = NSWorkspace.shared.runningApplications.first { other in
            guard other.processIdentifier != pid, other.activationPolicy != .prohibited,
                  coalitionID(of: other.processIdentifier) == coalition else { return false }
            let otherPath = other.bundleURL?.resolvingSymlinksInPath().path
            return !(nestedPrefix.map { otherPath?.hasPrefix($0) ?? false } ?? false)
        }
        if let sharedWith {
            log.notice("pid \(pid): coalition \(coalition) shared with \(sharedWith.bundleIdentifier ?? "?", privacy: .public), not sweeping it")
            return nil
        }
        return coalition
    }

    // MARK: - AX / CG helpers

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    /// Windows the user can still see or get back to, or nil if unknown:
    /// on-screen windows that actually overlap a display, windows open on a
    /// Space no display is showing, and minimized windows. Hidden windows an
    /// app keeps around after "closing" them (ordered out, or parked
    /// off-screen) are ignored, even if the app still lists them over AX.
    ///
    /// Stage Manager keeps a thumbnail of such hidden windows in its strip,
    /// and CG reports the app's window at that thumbnail's frame. A strip
    /// window therefore only counts while AX lists an open window for it (a
    /// real window parked in another stage) other than `closing`, the window
    /// whose close button was clicked: apps that hide instead of closing
    /// (e.g. Electron apps) keep listing that one.
    private static func openWindowCount(for pid: pid_t, closing: AXUIElement? = nil) -> Int? {
        guard let ax = axWindowCounts(AXUIElementCreateApplication(pid), ignoring: closing) else {
            log.debug("pid \(pid): AX window list unavailable")
            return nil
        }
        let cg = cgWindowCounts(for: pid)
        let unaccounted = max(0, ax.open - cg.visible)
        log.debug("""
            pid \(pid): AX open \(ax.open) minimized \(ax.minimized); \
            CG visible \(cg.visible) strip \(cg.stageStrip) other-space \(cg.otherSpace)
            """)
        return ax.minimized + cg.visible + cg.otherSpace + min(cg.stageStrip, unaccounted)
    }

    private static func axWindowCounts(_ app: AXUIElement, ignoring closing: AXUIElement?) -> (open: Int, minimized: Int)? {
        var windowsRef: CFTypeRef?
        switch AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) {
        case .success:
            let windows = (windowsRef as? [AXUIElement] ?? []).filter { window in
                closing.map { !CFEqual($0, window) } ?? true
            }
            let minimized = windows.filter { attribute($0, kAXMinimizedAttribute) as? Bool == true }.count
            return (windows.count - minimized, minimized)
        case .noValue: return (0, 0)
        default: return nil
        }
    }

    private static func containingWindow(of element: AXUIElement) -> AXUIElement? {
        // Most elements expose their window directly.
        if let window = attribute(element, kAXWindowAttribute), CFGetTypeID(window) == AXUIElementGetTypeID() {
            return unsafeDowncast(window, to: AXUIElement.self)
        }
        var current = element
        for _ in 0..<12 {
            if (attribute(current, kAXRoleAttribute) as? String) == (kAXWindowRole as String) { return current }
            guard let parent = attribute(current, kAXParentAttribute) else { return nil }
            current = unsafeDowncast(parent, to: AXUIElement.self)
        }
        return nil
    }

    /// Standard-layer windows of `pid`: on screen over a display, shown as a
    /// Stage Manager strip thumbnail, or open on a Space no display is
    /// currently showing (another desktop).
    private static func cgWindowCounts(for pid: pid_t) -> (visible: Int, stageStrip: Int, otherSpace: Int) {
        var counts = (visible: 0, stageStrip: 0, otherSpace: 0)
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return counts }

        // Stage Manager draws a frame of its own exactly over each strip thumbnail.
        let windowManagerPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager")
            .map(\.processIdentifier))
        let stripFrames: [CGRect] = list.compactMap { info in
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, windowManagerPIDs.contains(owner),
                  info[kCGWindowIsOnscreen as String] as? Bool == true,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: boundsDict)
        }

        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)
        let displayBounds = displays.map(CGDisplayBounds)

        // Spaces lookup is optional: without SkyLight, off-screen windows don't count.
        var connection: Int32 = 0
        var visibleSpaces: Set<Int> = []
        if let mainConnection = cgsMainConnectionID, let displaySpaces = cgsCopyManagedDisplaySpaces {
            connection = mainConnection()
            let managed = displaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] ?? []
            visibleSpaces = Set(managed.compactMap {
                ($0["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int
            })
        }

        var visibleFrames: [CGRect] = []
        for info in list {
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid,
                  info[kCGWindowLayer as String] as? Int == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 50, bounds.height >= 50 else { continue }

            if info[kCGWindowIsOnscreen as String] as? Bool == true {
                if stripFrames.contains(where: { $0.equalTo(bounds) }) {
                    counts.stageStrip += 1
                } else if displayBounds.contains(where: { $0.intersects(bounds) }) {
                    visibleFrames.append(bounds)
                }
                continue
            }
            guard !visibleSpaces.isEmpty, let spacesFor = cgsCopySpacesForWindows,
                  let number = info[kCGWindowNumber as String] as? NSNumber,
                  let spaces = spacesFor(connection, allSpacesMask, [number] as CFArray)?.takeRetainedValue() as? [Int],
                  !spaces.isEmpty, visibleSpaces.isDisjoint(with: spaces) else { continue }
            counts.otherSpace += 1
        }

        // A window lying entirely inside another on-screen window of the same
        // app is part of it, not a window of its own: a full-screen window's
        // title bar/toolbar strip (shown while the pointer is at the top, so
        // always there when its close button is clicked) is a separate CG
        // window, as is a sheet. Identical frames count once.
        counts.visible = visibleFrames.enumerated().filter { index, frame in
            !visibleFrames.enumerated().contains { other, outer in
                other != index && outer.contains(frame) && (outer != frame || other < index)
            }
        }.count
        return counts
    }
}

/// Owns the event tap. Passed to the C callback through `userInfo`.
final class EventTap: @unchecked Sendable {
    let detector = CloseDetector()
    fileprivate var port: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var isRunning: Bool { port.map(CFMachPortIsValid) ?? false }

    func start() {
        if port != nil, !isRunning { stop() }
        guard port == nil else { return }

        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue) | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<EventTap>.fromOpaque(userInfo).takeUnretainedValue()
            switch type {
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                if let port = tap.port { CGEvent.tapEnable(tap: port, enable: true) }
            case .leftMouseDown:
                tap.detector.mouseDown(at: event.location)
            case .leftMouseUp:
                tap.detector.mouseUp()
            default:
                break
            }
            return Unmanaged.passUnretained(event)
        }

        // An active tap (not .listenOnly): listen-only taps need the separate
        // Input Monitoring permission and silently receive nothing without it.
        // The callback only hands off to the detector's queue, so it returns
        // immediately and never holds up input.
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        self.port = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        runLoopSource = nil
        port = nil
    }
}

@MainActor
final class CloseQuitManager {
    static let shared = CloseQuitManager()
    private let tap = EventTap()
    private let defaults = UserDefaults.standard
    private let enabledKey = "closeQuitsEnabled"

    /// The user's preference; the tap runs only when this is on and
    /// Accessibility is granted.
    var enabled: Bool {
        get { defaults.object(forKey: enabledKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: enabledKey)
            refresh()
        }
    }

    var isActive: Bool { tap.isRunning }

    /// Starts or stops the tap to match the preference and current trust.
    func refresh() {
        if enabled && AXIsProcessTrusted() {
            tap.start()
        } else {
            tap.stop()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var trustTimer: Timer?
    private var lastTrusted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "CloseQuits")

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        lastTrusted = AXIsProcessTrusted()
        refresh()

        // Accessibility can be granted or revoked while we run; pick it up
        // without a relaunch.
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let delegate = NSApp.delegate as? AppDelegate else { return }
                delegate.checkTrust()
            }
        }
    }

    private func checkTrust() {
        let trusted = AXIsProcessTrusted()
        // Also recover if macOS invalidated the tap behind our back.
        if trusted != lastTrusted || (trusted && CloseQuitManager.shared.enabled && !CloseQuitManager.shared.isActive) {
            lastTrusted = trusted
            refresh()
        }
    }

    private func refresh() {
        CloseQuitManager.shared.refresh()
        statusItem.button?.appearsDisabled = !CloseQuitManager.shared.isActive
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let trusted = AXIsProcessTrusted()
        let accessItem = NSMenuItem(
            title: trusted ? "Accessibility: Granted" : "Grant Accessibility Access…",
            action: trusted ? nil : #selector(grantAccess),
            keyEquivalent: ""
        )
        accessItem.target = self
        accessItem.isEnabled = !trusted
        menu.addItem(accessItem)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Quit on Close", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = CloseQuitManager.shared.enabled ? .on : .off
        toggle.isEnabled = trusted
        menu.addItem(toggle)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit CloseQuits", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func grantAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @objc func toggleEnabled() {
        CloseQuitManager.shared.enabled.toggle()
        refresh()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
