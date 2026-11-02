import AppKit
import ApplicationServices

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

    private let queue = DispatchQueue(label: "com.manikpruthi.closequits.detector", qos: .userInitiated)
    private let systemWide = AXUIElementCreateSystemWide()
    private var pending: Candidate?

    private static let pollInterval: TimeInterval = 0.1
    private static let pollAttempts = 15

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
           excludedBundleIDs.contains(bundleID) { return nil }

        guard let window = Self.containingWindow(of: element) else { return nil }
        if !isCloseSubrole {
            // Plain button: accept only if it is the window's own close button.
            guard let closeButton = Self.attribute(window, kAXCloseButtonAttribute),
                  CFEqual(closeButton, element) else { return nil }
        }

        // Only act on the app's main window; auxiliary windows (Quick Look
        // previews, panels, popovers, ...) must just close normally.
        let app = AXUIElementCreateApplication(pid)
        if let mainWindow = Self.attribute(app, kAXMainWindowAttribute), !CFEqual(mainWindow, window) { return nil }

        // Early out when other windows will obviously remain.
        if let count = Self.axWindowCount(app), count > 1 { return nil }

        return Candidate(pid: pid, window: window)
    }

    /// After mouse-up, poll briefly until the app has no windows left. If the
    /// close was cancelled (dragged off the button, "Save?" sheet, ...) the
    /// window stays and the app is left alone.
    private func confirmClosed(_ candidate: Candidate, attempt: Int) {
        guard let running = NSRunningApplication(processIdentifier: candidate.pid), !running.isTerminated else { return }

        if remainingWindows(for: candidate.pid) == 0 {
            let pid = candidate.pid
            DispatchQueue.main.async {
                NSRunningApplication(processIdentifier: pid)?.terminate()
            }
            return
        }

        guard attempt + 1 < Self.pollAttempts else { return }
        queue.asyncAfter(deadline: .now() + Self.pollInterval) {
            self.confirmClosed(candidate, attempt: attempt + 1)
        }
    }

    /// Windows the app still has across all Spaces, or nil if unknown.
    private func remainingWindows(for pid: pid_t) -> Int? {
        guard let axCount = Self.axWindowCount(AXUIElementCreateApplication(pid)) else { return nil }
        return axCount + Self.spaceBoundWindowCount(for: pid)
    }

    // MARK: - AX / CG helpers

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func axWindowCount(_ app: AXUIElement) -> Int? {
        var windowsRef: CFTypeRef?
        switch AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) {
        case .success: return (windowsRef as? [AXUIElement])?.count ?? 0
        case .noValue: return 0
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

    /// Standard-layer windows of `pid` that are open on a Space no display is
    /// currently showing (i.e. on another desktop, not merely hidden).
    private static func spaceBoundWindowCount(for pid: pid_t) -> Int {
        guard let mainConnection = cgsMainConnectionID, let spacesFor = cgsCopySpacesForWindows,
              let displaySpaces = cgsCopyManagedDisplaySpaces else { return 0 }
        let connection = mainConnection()
        guard let displays = displaySpaces(connection)?.takeRetainedValue() as? [[String: Any]],
              let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return 0 }
        let visibleSpaces = Set(displays.compactMap {
            ($0["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int
        })
        guard !visibleSpaces.isEmpty else { return 0 }
        return list.reduce(0) { count, info in
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid,
                  info[kCGWindowLayer as String] as? Int == 0,
                  (info[kCGWindowIsOnscreen as String] as? Bool) != true,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  bounds["Width"] ?? 0 >= 50, bounds["Height"] ?? 0 >= 50,
                  let number = info[kCGWindowNumber as String] as? NSNumber,
                  let spaces = spacesFor(connection, allSpacesMask, [number] as CFArray)?.takeRetainedValue() as? [Int],
                  !spaces.isEmpty, visibleSpaces.isDisjoint(with: spaces) else { return count }
            return count + 1
        }
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
