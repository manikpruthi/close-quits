import AppKit
import ApplicationServices

nonisolated(unsafe) var gEventTap: CFMachPort?

@MainActor
final class CloseQuitManager {
    static let shared = CloseQuitManager()
    private(set) var enabled = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let defaults = UserDefaults.standard
    private let enabledKey = "closeQuitsEnabled"

    func setEnabled(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: enabledKey)
        if value {
            startTap()
        } else {
            stopTap()
        }
    }

    func startIfTrusted() {
        if AXIsProcessTrusted() {
            let stored = defaults.object(forKey: enabledKey) as? Bool
            setEnabled(stored ?? true)
        } else {
            fputs("DEBUG not trusted\n", stderr)
        }
    }

    private func startTap() {
        guard eventTap == nil else { return }
        guard AXIsProcessTrusted() else { return }

        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = gEventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if type == .leftMouseDown {
                CloseQuitManager.handleMouseDown(event: event)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback, userInfo: nil) else { return }
        eventTap = tap
        gEventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
        gEventTap = nil
    }

    nonisolated static func handleMouseDown(event: CGEvent) {
        let location = event.location
        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(system, Float(location.x), Float(location.y), &element)
        guard result == .success, let el = element else { return }
        guard isCloseButton(el) else { return }
        guard let clickedWindow = containingWindow(of: el) else { return }

        var pid: pid_t = 0
        guard AXUIElementGetPid(el, &pid) == .success else { return }
        if pid == getpid() { return }

        if let app = NSRunningApplication(processIdentifier: pid),
           app.bundleIdentifier == "com.apple.finder" { return }

        // Only act on the app's main window; auxiliary windows (Quick Look
        // previews, panels, popovers, ...) must just close normally.
        let appElement = AXUIElementCreateApplication(pid)
        var mainWindowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainWindowRef) == .success,
           let mainWindow = mainWindowRef {
            if !CFEqual(mainWindow, clickedWindow) { return }
        }

        // Only quit when this is the app's last window.
        if windowCount(for: pid) > 1 { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSRunningApplication(processIdentifier: pid)?.terminate()
        }
    }

    nonisolated static func windowCount(for pid: pid_t) -> Int {
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return 0 }
        return windows.count
    }

    nonisolated static func containingWindow(of element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<12 {
            guard let el = current else { return nil }
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
            if let role = roleRef as? String, role == (kAXWindowRole as String) {
                return el
            }
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parent = parentRef else { return nil }
            current = unsafeDowncast(parent, to: AXUIElement.self)
        }
        return nil
    }

    nonisolated static func isCloseButton(_ element: AXUIElement) -> Bool {
        // Only consider elements that live inside a window.
        guard let window = containingWindow(of: element) else { return false }

        // Strongest check: the window's own close button (kAXCloseButtonAttribute).
        var cbRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &cbRef) == .success,
           let cb = cbRef {
            if CFEqual(cb, element) { return true }
        }

        // Standard window close buttons expose the close subrole.
        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        if let subrole = subroleRef as? String, subrole == (kAXCloseButtonSubrole as String) {
            return true
        }

        return false
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "CloseQuits")
        }
        CloseQuitManager.shared.startIfTrusted()
        rebuildMenu()
    }

    func rebuildMenu() {
        let menu = NSMenu()
        let trusted = AXIsProcessTrusted()
        let accessItem = NSMenuItem(
            title: trusted ? "Accessibility: Granted" : "Grant Accessibility Access…",
            action: #selector(grantAccess),
            keyEquivalent: ""
        )
        accessItem.target = self
        menu.addItem(accessItem)
        menu.addItem(.separator())

        let enabled = CloseQuitManager.shared.enabled
        let toggle = NSMenuItem(
            title: enabled ? "Disable Quit-on-Close" : "Enable Quit-on-Close",
            action: #selector(toggleEnabled),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit CloseQuits", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc func grantAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        rebuildMenu()
    }

    @objc func toggleEnabled() {
        CloseQuitManager.shared.setEnabled(!CloseQuitManager.shared.enabled)
        rebuildMenu()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
