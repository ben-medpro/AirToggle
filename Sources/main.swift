//
//  AirToggle — a tiny menu bar app that flips your AirPods between
//  Noise Cancellation and Transparency with one global keyboard shortcut.
//
//  How it works: macOS gives third-party apps no API for AirPods listening
//  modes (the old IOBluetooth `listeningMode` is inert on macOS 26+, and the
//  AVRouting / CoreBluetooth paths need Apple-only entitlements). So AirToggle
//  does what you would do by hand, only faster: it drives Control Center's
//  Sound menu through the Accessibility API, reads which mode is checked,
//  presses the other one, and closes the menu again. It needs the
//  Accessibility permission (System Settings › Privacy & Security).
//

import Cocoa
import Carbon
import ApplicationServices
import UniformTypeIdentifiers
import ServiceManagement

// MARK: - Logging

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/AirToggle.log")
    static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()
    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile(); handle.write(data); try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
        FileHandle.standardError.write(line.data(using: .utf8)!)
    }
}

// MARK: - Listening modes

enum ListeningMode: CaseIterable {
    case off, noiseCancellation, transparency, adaptive

    var title: String {
        switch self {
        case .off: return "Off"
        case .noiseCancellation: return "Noise Cancellation"
        case .transparency: return "Transparency"
        case .adaptive: return "Adaptive"
        }
    }

    /// SF Symbol candidates, first available wins (older systems lack some names).
    var symbolCandidates: [String] {
        switch self {
        case .off: return ["ear.slash", "speaker.slash"]
        case .noiseCancellation: return ["ear.fill", "airpodspro"]
        case .transparency: return ["ear.badge.waveform", "ear"]
        case .adaptive: return ["ear.and.waveform", "ear"]
        }
    }

    var symbolName: String {
        symbolCandidates.first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil } ?? "ear"
    }

    /// Labels Control Center uses for this mode (English UI).
    var uiLabels: [String] {
        switch self {
        case .off: return ["Off"]
        case .noiseCancellation: return ["Noise Cancellation", "Noise Cancelling", "Active Noise Cancellation"]
        case .transparency: return ["Transparency"]
        case .adaptive: return ["Adaptive", "Adaptive Audio"]
        }
    }

    /// Modes the shortcut rotates through, in this fixed order. Stored as titles in UserDefaults.
    static let cycleOrder: [ListeningMode] = [.noiseCancellation, .transparency, .adaptive, .off]
    private static let cycleKey = "cycleModes"

    static var cycle: [ListeningMode] {
        get {
            let titles = UserDefaults.standard.stringArray(forKey: cycleKey) ?? []
            let modes = cycleOrder.filter { titles.contains($0.title) }
            return modes.count >= 2 ? modes : [.noiseCancellation, .transparency]
        }
        set {
            let modes = cycleOrder.filter { newValue.contains($0) }
            UserDefaults.standard.set(modes.map { $0.title }, forKey: cycleKey)
        }
    }

    /// The mode after `current` in the configured cycle, limited to modes the device offers.
    static func next(after current: ListeningMode?, offered: [ListeningMode]) -> ListeningMode? {
        let ring = cycle.filter { offered.contains($0) }
        guard !ring.isEmpty else { return nil }
        guard let current, let index = ring.firstIndex(of: current) else { return ring[0] }
        return ring[(index + 1) % ring.count]
    }

    static func matching(label: String) -> ListeningMode? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return allCases.first { $0.uiLabels.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame } }
    }
}

// MARK: - Accessibility helpers

struct AX {
    static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return result == .success ? value : nil
    }
    static func attributeResult(_ element: AXUIElement, _ name: String) -> (AXError, AnyObject?) {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (result, value)
    }
    static func attributeNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }
    static func elements(_ value: AnyObject?) -> [AXUIElement] {
        if let array = value as? [AXUIElement] { return array }
        if let value, CFGetTypeID(value) == AXUIElementGetTypeID() { return [value as! AXUIElement] }
        return []
    }
    static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }
    static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
    static func role(_ element: AXUIElement) -> String { string(element, kAXRoleAttribute) ?? "" }
    static func title(_ element: AXUIElement) -> String { string(element, kAXTitleAttribute) ?? "" }
    static func description(_ element: AXUIElement) -> String { string(element, kAXDescriptionAttribute) ?? "" }
    static func identifier(_ element: AXUIElement) -> String { string(element, "AXIdentifier") ?? "" }
    static func isSelected(_ element: AXUIElement) -> Bool {
        if let v = attribute(element, kAXValueAttribute) {
            if let n = v as? NSNumber { return n.intValue != 0 }
            if let s = v as? String { return s == "1" || s.caseInsensitiveCompare("selected") == .orderedSame }
        }
        if let sel = attribute(element, kAXSelectedAttribute) as? NSNumber { return sel.boolValue }
        return false
    }
    /// Every human-readable string attached to an element.
    static func labels(_ element: AXUIElement) -> [String] {
        var out = [title(element), description(element), identifier(element), string(element, kAXHelpAttribute) ?? ""]
        if let v = attribute(element, kAXValueAttribute) as? String { out.append(v) }
        return out.filter { !$0.isEmpty }
    }
    @discardableResult
    static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }
    /// Depth-first walk with a node budget; `visit` returns true to stop.
    static func walk(_ root: AXUIElement, maxNodes: Int = 5000, maxDepth: Int = 40, _ visit: (AXUIElement, Int) -> Bool) {
        var budget = maxNodes
        func go(_ el: AXUIElement, _ depth: Int) -> Bool {
            guard budget > 0, depth <= maxDepth else { return false }
            budget -= 1
            if visit(el, depth) { return true }
            for child in children(el) where go(child, depth + 1) { return true }
            return false
        }
        _ = go(root, 0)
    }
    static func dump(_ root: AXUIElement, maxNodes: Int = 400) -> String {
        var lines: [String] = []
        walk(root, maxNodes: maxNodes) { el, depth in
            let value = attribute(el, kAXValueAttribute).map { "\($0)" } ?? ""
            lines.append(String(repeating: "  ", count: depth) +
                         "\(role(el)) \(string(el, kAXSubroleAttribute) ?? "") title=\"\(title(el))\" desc=\"\(description(el))\" id=\"\(identifier(el))\" value=\"\(value.prefix(40))\"")
            return false
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Control Center engine

/// Drives Control Center's Sound menu to read and change the listening mode.
final class ControlCenterEngine {
    enum EngineError: LocalizedError {
        case notTrusted, controlCenterNotRunning, soundMenuNotFound, modesNotFound, pressFailed

        var errorDescription: String? {
            switch self {
            case .notTrusted: return "Accessibility access required"
            case .controlCenterNotRunning: return "Control Center isn't running"
            case .soundMenuNotFound: return "Couldn't find the Sound menu"
            case .modesNotFound: return "No noise control found — are AirPods the output?"
            case .pressFailed: return "Couldn't press the mode button"
            }
        }
    }

    struct ModeControl {
        let element: AXUIElement
        let mode: ListeningMode
        let isSelected: Bool
    }

    struct Snapshot {
        let controls: [ModeControl]
        var current: ListeningMode? { controls.first { $0.isSelected }?.mode }
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    private var lastDump = Date.distantPast

    /// Processes that can host the menu bar extras and their popovers. macOS 26+ splits
    /// this across Control Center and MenuBarAgent, so we look at all of them.
    static let hostProcessNames = ["ControlCenter", "MenuBarAgent", "SystemUIServer"]

    /// A "host" is an accessibility app element for one of those processes.
    private func hosts() throws -> [(name: String, element: AXUIElement)] {
        let running = NSWorkspace.shared.runningApplications
        var result: [(String, AXUIElement)] = []
        for name in ControlCenterEngine.hostProcessNames {
            for app in running where app.executableURL?.lastPathComponent == name {
                let element = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(element, 2.0)
                result.append((name, element))
            }
        }
        guard !result.isEmpty else { throw EngineError.controlCenterNotRunning }
        return result
    }

    private func controlCenter() throws -> AXUIElement {
        // Kept for callers that only need "some" host element; windows are searched across all hosts.
        try hosts()[0].element
    }

    private func menuBars(of app: AXUIElement) -> [AXUIElement] {
        var bars: [AXUIElement] = []
        for name in ["AXExtrasMenuBar", kAXMenuBarAttribute, "AXMenuBars"] {
            bars.append(contentsOf: AX.elements(AX.attribute(app, name)))
        }
        bars.append(contentsOf: AX.children(app).filter { AX.role($0) == kAXMenuBarRole })
        return bars
    }

    /// Menu bar items (Sound, Wi‑Fi, Control Center, …). On macOS 26+ each item sits inside an
    /// AXGroup hosting view under MenuBarAgent's extras menu bar, so walk a few levels down.
    private func menuBarItems(of app: AXUIElement) -> [AXUIElement] {
        var items: [AXUIElement] = []
        var roots = menuBars(of: app)
        if roots.isEmpty { roots = AX.children(app) }
        for root in roots {
            AX.walk(root, maxNodes: 400, maxDepth: 4) { el, _ in
                if AX.role(el) == kAXMenuBarItemRole { items.append(el) }
                return false
            }
        }
        return items
    }

    private func allMenuBarItems() -> [AXUIElement] {
        ((try? hosts()) ?? []).flatMap { menuBarItems(of: $0.element) }
    }

    private func menuBarItem(of app: AXUIElement, matching needles: [String]) -> AXUIElement? {
        allMenuBarItems().first { item in
            let labels = AX.labels(item).map { $0.lowercased() }
            return needles.contains { needle in labels.contains { $0.contains(needle) } }
        }
    }

    private func findModeControls(in app: AXUIElement) -> [ModeControl] {
        let windows = openWindows(of: app)
        var candidates: [(AXUIElement, ListeningMode, AXUIElement?)] = []   // element, mode, parent
        for window in windows {
            var parents: [Int: AXUIElement] = [:]
            AX.walk(window) { el, depth in
                parents[depth] = el
                let role = AX.role(el)
                guard role == kAXCheckBoxRole || role == kAXRadioButtonRole || role == kAXButtonRole
                        || role == kAXMenuItemRole || role == kAXStaticTextRole || role == "AXToggle" else { return false }
                for label in AX.labels(el) {
                    if let mode = ListeningMode.matching(label: label) {
                        candidates.append((el, mode, depth > 0 ? parents[depth - 1] : nil))
                        break
                    }
                }
                return false
            }
        }
        // Anchor on the two modes that only appear in the noise-control group,
        // then keep everything that shares their parent so a stray "Off" elsewhere is ignored.
        guard let anchor = candidates.first(where: { $0.1 == .noiseCancellation || $0.1 == .transparency }) else { return [] }
        let anchorParent = anchor.2
        var seen = Set<ListeningMode>()
        var controls: [ModeControl] = []
        for (el, mode, parent) in candidates {
            let sameGroup = (parent == nil && anchorParent == nil) || (parent != nil && anchorParent != nil && CFEqual(parent, anchorParent))
            guard sameGroup || mode == .noiseCancellation || mode == .transparency, !seen.contains(mode) else { continue }
            seen.insert(mode)
            controls.append(ModeControl(element: el, mode: mode, isSelected: AX.isSelected(el)))
        }
        return controls
    }

    private func waitForModeControls(in app: AXUIElement, timeout: TimeInterval) -> [ModeControl] {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let controls = findModeControls(in: app)
            if !controls.isEmpty { return controls }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return []
    }

    private func openWindows(of app: AXUIElement) -> [AXUIElement] {
        var windows: [AXUIElement] = []
        for host in (try? hosts()) ?? [] {
            windows.append(contentsOf: AX.elements(AX.attribute(host.element, kAXWindowsAttribute)))
            // Popovers are sometimes only reachable through the focused element or the app's children.
            windows.append(contentsOf: AX.children(host.element).filter { AX.role($0) == kAXWindowRole || AX.role($0) == "AXPopover" })
        }
        return windows
    }

    private func closeMenus(of app: AXUIElement, using item: AXUIElement?) {
        guard !openWindows(of: app).isEmpty else { return }
        // Pressing the menu bar item again collapses its popover; Escape is the fallback.
        if let item { AX.press(item) }
        Thread.sleep(forTimeInterval: 0.12)
        if !openWindows(of: app).isEmpty {
            for keyDown in [true, false] {
                CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: keyDown)?.post(tap: .cghidEventTap)
            }
        }
    }

    /// Some layouts tuck noise control under the AirPods row; press it to reveal the controls.
    private func revealAirPodsRow(in app: AXUIElement) -> Bool {
        var row: AXUIElement?
        for window in openWindows(of: app) where row == nil {
            AX.walk(window) { el, _ in
                let labels = AX.labels(el).map { $0.lowercased() }
                if labels.contains(where: { $0.contains("airpods") || $0.contains("beats") }),
                   [kAXButtonRole, kAXCheckBoxRole, kAXStaticTextRole, kAXDisclosureTriangleRole, kAXGroupRole, kAXRadioButtonRole].contains(AX.role(el)) {
                    row = el; return true
                }
                return false
            }
        }
        guard let row else { return false }
        return AX.press(row)
    }

    /// Opens the Sound menu (or Control Center → Sound), returns the mode controls and the item used to open it.
    private func openNoiseControls() throws -> (AXUIElement, [ModeControl], AXUIElement?) {
        guard ControlCenterEngine.isTrusted else { throw EngineError.notTrusted }
        let app = try controlCenter()

        // Already open? (e.g. user has the menu showing)
        let existing = findModeControls(in: app)
        if !existing.isEmpty { return (app, existing, nil) }

        if let sound = menuBarItem(of: app, matching: ["sound", "menuextra.sound", "volume"]) {
            AX.press(sound)
            var controls = waitForModeControls(in: app, timeout: 1.2)
            if controls.isEmpty, revealAirPodsRow(in: app) {
                controls = waitForModeControls(in: app, timeout: 1.5)
            }
            if !controls.isEmpty { return (app, controls, sound) }
            logTreeIfNeeded(app, reason: "Sound menu opened but no listening-mode controls were found")
            closeMenus(of: app, using: sound)
            throw EngineError.modesNotFound
        }

        // Sound item hidden from the menu bar: go through the main Control Center item.
        guard let cc = menuBarItem(of: app, matching: ["control center", "controlcenter"]) else {
            throw EngineError.soundMenuNotFound
        }
        AX.press(cc)
        Thread.sleep(forTimeInterval: 0.35)
        var controls = waitForModeControls(in: app, timeout: 0.5)
        if controls.isEmpty {
            // Press the "Sound" header/row to open the Sound detail view.
            let windows = openWindows(of: app)
            var soundRow: AXUIElement?
            for window in windows where soundRow == nil {
                AX.walk(window) { el, _ in
                    if AX.labels(el).contains(where: { $0.caseInsensitiveCompare("Sound") == .orderedSame }),
                       [kAXButtonRole, kAXStaticTextRole, kAXGroupRole, kAXCheckBoxRole].contains(AX.role(el)) {
                        soundRow = el; return true
                    }
                    return false
                }
            }
            if let soundRow { AX.press(soundRow) }
            controls = waitForModeControls(in: app, timeout: 1.2)
            if controls.isEmpty, revealAirPodsRow(in: app) {
                controls = waitForModeControls(in: app, timeout: 1.5)
            }
        }
        if controls.isEmpty {
            logTreeIfNeeded(app, reason: "Control Center opened but no listening-mode controls were found")
            closeMenus(of: app, using: cc)
            throw EngineError.modesNotFound
        }
        return (app, controls, cc)
    }

    /// Reads the current mode without changing it.
    func currentMode() throws -> ListeningMode? {
        let (app, controls, item) = try openNoiseControls()
        defer { closeMenus(of: app, using: item) }
        return Snapshot(controls: controls).current
    }

    /// Switches to `mode` (or, when nil, to the "other" of NC/Transparency). Returns the resulting mode.
    func apply(_ requested: ListeningMode?) throws -> (from: ListeningMode?, to: ListeningMode) {
        let (app, controls, item) = try openNoiseControls()
        defer { closeMenus(of: app, using: item) }
        let snapshot = Snapshot(controls: controls)
        let current = snapshot.current
        let offered = controls.map { $0.mode }
        guard let target = requested ?? ListeningMode.next(after: current, offered: offered),
              let control = controls.first(where: { $0.mode == target }) else {
            Log.write("Requested mode \(requested?.title ?? "(cycle)") not offered; available: \(offered.map { $0.title })")
            throw EngineError.modesNotFound
        }
        if control.isSelected { return (current, target) }
        var pressed = AX.press(control.element)
        if !pressed, let parent = AX.attribute(control.element, kAXParentAttribute) {
            pressed = AX.press(parent as! AXUIElement)
        }
        guard pressed else { throw EngineError.pressFailed }
        Thread.sleep(forTimeInterval: 0.1)
        return (current, target)
    }

    func dumpTree() -> String {
        guard ControlCenterEngine.isTrusted else { return "(Accessibility not granted)" }
        guard let hosts = try? hosts() else { return "(no menu bar host process running)" }
        var out = ""
        for host in hosts {
            out += "== \(host.name)\n"
            out += "   attributes: \(AX.attributeNames(host.element))\n"
            for name in ["AXExtrasMenuBar", kAXMenuBarAttribute, kAXChildrenAttribute, kAXWindowsAttribute, kAXFocusedUIElementAttribute] {
                let (err, value) = AX.attributeResult(host.element, name)
                let count = AX.elements(value).count
                out += "   \(name): error=\(err.rawValue) count=\(count)\n"
            }
            for bar in menuBars(of: host.element) {
                out += "   menu bar \(AX.role(bar)) items:\n"
                for item in AX.children(bar) { out += "      \(AX.role(item)) \(AX.labels(item))\n" }
            }
            for child in AX.children(host.element) {
                out += "   child tree:\n" + AX.dump(child, maxNodes: 150).split(separator: "\n").map { "      " + $0 }.joined(separator: "\n") + "\n"
            }
            let windows = AX.elements(AX.attribute(host.element, kAXWindowsAttribute))
            out += "   windows: \(windows.count)\n"
            for w in windows { out += AX.dump(w, maxNodes: 600) + "\n" }
        }
        return out
    }

    private func logTreeIfNeeded(_ app: AXUIElement, reason: String) {
        guard Date().timeIntervalSince(lastDump) > 60 else { return }
        lastDump = Date()
        Log.write("\(reason). Control Center tree:\n" + dumpTree())
    }
}

// MARK: - Keyboard shortcut model

struct Shortcut: Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let `default` = Shortcut(keyCode: 0 /* A */, carbonModifiers: UInt32(controlKey | optionKey))

    private static let keyCodeKey = "shortcutKeyCode"
    private static let modifiersKey = "shortcutModifiers"

    static func load() -> Shortcut {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: keyCodeKey) != nil else { return .default }
        return Shortcut(keyCode: UInt32(defaults.integer(forKey: keyCodeKey)),
                        carbonModifiers: UInt32(defaults.integer(forKey: modifiersKey)))
    }

    func save() {
        UserDefaults.standard.set(Int(keyCode), forKey: Shortcut.keyCodeKey)
        UserDefaults.standard.set(Int(carbonModifiers), forKey: Shortcut.modifiersKey)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: keyCodeKey)
        UserDefaults.standard.removeObject(forKey: modifiersKey)
    }

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        var mods: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        carbonModifiers = mods
    }

    var cocoaModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    var isFunctionKey: Bool { Shortcut.functionKeyCodes.contains(keyCode) }

    /// A shortcut must include ⌃, ⌥ or ⌘ unless it is a bare function key.
    var isUsable: Bool {
        isFunctionKey || carbonModifiers & UInt32(cmdKey | optionKey | controlKey) != 0
    }

    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyLabel
    }

    /// Key equivalent string for showing the shortcut in the menu.
    var keyEquivalent: String {
        if let special = Shortcut.specialKeyEquivalents[keyCode] { return special }
        return keyLabel.lowercased()
    }

    private static let functionKeyCodes: Set<UInt32> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    private static let specialKeyNames: [UInt32: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 53: "⎋", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ]

    private static let specialKeyEquivalents: [UInt32: String] = [
        122: fkey(NSF1FunctionKey), 120: fkey(NSF2FunctionKey), 99: fkey(NSF3FunctionKey), 118: fkey(NSF4FunctionKey),
        96: fkey(NSF5FunctionKey), 97: fkey(NSF6FunctionKey), 98: fkey(NSF7FunctionKey), 100: fkey(NSF8FunctionKey),
        101: fkey(NSF9FunctionKey), 109: fkey(NSF10FunctionKey), 103: fkey(NSF11FunctionKey), 111: fkey(NSF12FunctionKey),
        49: " ", 36: "\r", 48: "\t", 51: fkey(NSBackspaceCharacter), 53: "\u{1B}", 117: fkey(NSDeleteFunctionKey),
        123: fkey(NSLeftArrowFunctionKey), 124: fkey(NSRightArrowFunctionKey),
        125: fkey(NSDownArrowFunctionKey), 126: fkey(NSUpArrowFunctionKey),
    ]

    private static func fkey(_ code: Int) -> String {
        String(utf16CodeUnits: [unichar(code)], count: 1)
    }

    var keyLabel: String { Shortcut.keyLabel(for: keyCode) }

    // The Carbon text-input APIs used to name a key must run on the main thread (macOS asserts
    // otherwise). AppKit can rebuild our menu on a background thread when an accessibility client
    // inspects it, so labels are computed on the main thread once and served from a cache after that.
    private static var labelCache: [UInt32: String] = [:]
    private static let labelLock = NSLock()

    /// US-layout names used only if a label is requested off the main thread before it was cached.
    private static let fallbackLabels: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
        13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I",
        35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
        47: ".", 50: "`",
    ]

    static func keyLabel(for keyCode: UInt32) -> String {
        if let name = specialKeyNames[keyCode] { return name }
        labelLock.lock()
        let cached = labelCache[keyCode]
        labelLock.unlock()
        if let cached { return cached }
        guard Thread.isMainThread else { return fallbackLabels[keyCode] ?? "Key \(keyCode)" }
        let label = computeKeyLabelOnMainThread(keyCode) ?? fallbackLabels[keyCode] ?? "Key \(keyCode)"
        labelLock.lock()
        labelCache[keyCode] = label
        labelLock.unlock()
        return label
    }

    /// Warm the cache for a shortcut (call on the main thread).
    static func primeLabel(for shortcut: Shortcut) { _ = keyLabel(for: shortcut.keyCode) }

    private static func computeKeyLabelOnMainThread(_ keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = unsafeBitCast(layoutPointer, to: CFData.self)
        let layout = unsafeBitCast(CFDataGetBytePtr(layoutData), to: UnsafePointer<UCKeyboardLayout>.self)
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                    UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysMask),
                                    &deadKeyState, chars.count, &length, &chars)
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

// MARK: - Global hotkey (Carbon)

final class HotKeyManager {
    static let shared = HotKeyManager()
    var onPress: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let signature: OSType = 0x4154_4F47 // 'ATOG'

    private init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { HotKeyManager.shared.onPress?() }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
    }

    @discardableResult
    func register(_ shortcut: Shortcut) -> Bool {
        unregister()
        let hotKeyID = EventHotKeyID(signature: signature, id: 1)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            Log.write("Failed to register hotkey \(shortcut.displayString): OSStatus \(status)")
            hotKeyRef = nil
            return false
        }
        Log.write("Registered global shortcut \(shortcut.displayString)")
        return true
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
    }
}

// MARK: - HUD

final class HUD {
    static let shared = HUD()
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    func show(symbol: String, text: String) {
        hideWorkItem?.cancel()
        let panel = self.panel ?? makePanel()
        self.panel = panel

        guard let content = panel.contentView as? NSVisualEffectView,
              let imageView = content.subviews.first as? NSImageView,
              let label = content.subviews.last as? NSTextField else { return }

        let config = NSImage.SymbolConfiguration(pointSize: 34, weight: .regular)
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)?
            .withSymbolConfiguration(config)
        label.stringValue = text

        // Size the panel to fit the text (within the screen).
        let textWidth = (text as NSString).size(withAttributes: [.font: label.font ?? .systemFont(ofSize: 16)]).width
        let screenWidth = NSScreen.main?.visibleFrame.width ?? 800
        let width = min(max(250, ceil(textWidth) + 96), screenWidth - 40)
        var frame = panel.frame
        frame.size.width = width
        panel.setFrame(frame, display: false)
        content.frame = NSRect(origin: .zero, size: frame.size)
        label.frame = NSRect(x: 68, y: 20, width: width - 84, height: 24)

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - width / 2, y: visible.maxY - frame.height - 24))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.invalidateShadow()

        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                panel.animator().alphaValue = 0
            }, completionHandler: {
                if self?.hideWorkItem?.isCancelled == false { panel.orderOut(nil) }
            })
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }

    private func makePanel() -> NSPanel {
        let size = NSSize(width: 250, height: 64)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        // A mask image (not a layer corner radius) is what makes the material, its border and
        // the window shadow all follow the rounded shape.
        let radius: CGFloat = 18
        let mask = NSImage(size: NSSize(width: radius * 2 + 1, height: radius * 2 + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        effect.maskImage = mask

        let imageView = NSImageView(frame: NSRect(x: 16, y: 12, width: 40, height: 40))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.contentTintColor = .labelColor

        let label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 68, y: 20, width: size.width - 84, height: 24)
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail

        effect.addSubview(imageView)
        effect.addSubview(label)
        panel.contentView = effect
        return panel
    }
}

// MARK: - Shortcut recorder window

final class ShortcutRecorder: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var monitor: Any?
    private var completion: ((Shortcut?) -> Void)?

    func begin(current: Shortcut, completion: @escaping (Shortcut?) -> Void) {
        self.completion = completion

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 130),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Change Shortcut"
        panel.isFloatingPanel = true
        panel.delegate = self
        panel.center()

        let content = NSView(frame: panel.contentView!.bounds)
        let heading = NSTextField(labelWithString: "Press the new keyboard shortcut")
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        heading.alignment = .center
        heading.frame = NSRect(x: 20, y: 80, width: 320, height: 22)

        let detail = NSTextField(wrappingLabelWithString:
            "Include ⌃, ⌥ or ⌘ (or use a function key).\nCurrent: \(current.displayString)   •   Esc to cancel")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.frame = NSRect(x: 20, y: 24, width: 320, height: 44)

        content.addSubview(heading)
        content.addSubview(detail)
        panel.contentView = content
        self.panel = panel

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { self.finish(nil); return nil } // Escape
            let shortcut = Shortcut(event: event)
            if shortcut.isUsable {
                self.finish(shortcut)
            } else {
                NSSound.beep()
                detail.stringValue = "That needs a modifier key. Include ⌃, ⌥ or ⌘ (or use a function key).\nEsc to cancel"
            }
            return nil
        }

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if completion != nil { finish(nil) }
    }

    private func finish(_ shortcut: Shortcut?) {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        let done = completion
        completion = nil
        panel?.delegate = nil
        panel?.close()
        panel = nil
        done?(shortcut)
    }
}


// MARK: - Menu bar layout repair

/// macOS 27 keeps every menu bar item's position in a layout store. A menu bar manager can leave
/// this app's entries parked off-screen; this removes them so MenuBarAgent places the item afresh.
enum MenuBarLayoutRepair {
    static let storeURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist")

    /// The store lives in a protected container. If direct access is denied, ask the user to pick the
    /// file in an Open dialog, which grants this app access to that one file (the same approach
    /// Bartender uses).
    private static func grantedStoreURL() -> URL? {
        if FileManager.default.isReadableFile(atPath: storeURL.path),
           (try? Data(contentsOf: storeURL)) != nil { return storeURL }
        let panel = NSOpenPanel()
        panel.title = "Allow AirToggle to reset its menu bar position"
        panel.message = "Select com.apple.MenuBar.plist and click Open. AirToggle removes only its own parked entries and keeps a backup."
        panel.prompt = "Open"
        panel.directoryURL = storeURL.deletingLastPathComponent()
        panel.allowedContentTypes = [.propertyList]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, url.lastPathComponent == "com.apple.MenuBar.plist" else { return nil }
        return url
    }

    /// Read-only: log every entry in the layout store (for diagnosing menu bar managers).
    static func dump() -> String {
        guard let storeURL = grantedStoreURL() else { return "Cancelled: no access to the menu bar layout store." }
        do {
            let data = try Data(contentsOf: storeURL)
            guard let root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
            else { return "Layout store has an unexpected format." }
            var lines: [String] = []
            for (section, value) in root {
                lines.append("[\(section)]")
                if let dict = value as? [String: Any] {
                    for key in dict.keys.sorted() { lines.append("  \(key) = \(dict[key]!)") }
                } else {
                    lines.append("  \(value)")
                }
            }
            return lines.joined(separator: "\n")
        } catch {
            return "Read failed: \(error.localizedDescription)"
        }
    }

    static func run() -> String {
        guard let storeURL = grantedStoreURL() else { return "Cancelled: no access to the menu bar layout store." }
        do {
            let data = try Data(contentsOf: storeURL)
            var format = PropertyListSerialization.PropertyListFormat.binary
            guard var root = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any],
                  var positions = root["TrailingItemPreferredPositions"] as? [String: Any]
            else { return "Layout store has an unexpected format; nothing changed." }

            let backup = Log.url.deletingLastPathComponent().appendingPathComponent("AirToggle-menubar-store-backup.plist")
            try data.write(to: backup)

            let ours = positions.keys.filter { $0.hasPrefix("status:AirToggle::") || $0.hasPrefix("status:dev.ben.AirToggle::") }
            guard !ours.isEmpty else { return "No AirToggle entries in the layout store; nothing to repair." }
            for key in ours { positions.removeValue(forKey: key) }
            root["TrailingItemPreferredPositions"] = positions
            let out = try PropertyListSerialization.data(fromPropertyList: root, format: format, options: 0)
            try out.write(to: storeURL, options: .atomic)

            // MenuBarAgent relaunches on its own and reads the store again. SIGKILL avoids it
            // flushing its stale in-memory copy over the file on the way out.
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            kill.arguments = ["-9", "MenuBarAgent"]
            try kill.run(); kill.waitUntilExit()
            return "Removed \(ours.count) parked entries (\(ours.joined(separator: ", "))). Backup: \(backup.path)"
        } catch {
            return "Repair failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Welcome / permission onboarding

/// Shown on launch until Accessibility access is granted. Polls so it can dismiss itself
/// the moment the user flips the switch in System Settings.
final class WelcomeWindowController: NSObject {
    private var window: NSWindow?
    private var timer: Timer?
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    var onGranted: (() -> Void)?

    func showIfNeeded(shortcut: Shortcut) {
        guard !ControlCenterEngine.isTrusted else { return }
        if window == nil { build(shortcut: shortcut) }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        guard ControlCenterEngine.isTrusted else { return }
        timer?.invalidate(); timer = nil
        statusLabel.stringValue = "Access granted. You're all set."
        statusLabel.textColor = .systemGreen
        onGranted?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.window?.close() }
    }

    private func build(shortcut: Shortcut) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Welcome to AirToggle"
        window.isReleasedWhenClosed = false

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let title = NSTextField(labelWithString: "One permission to set up")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString:
            "AirToggle switches your AirPods' listening mode by operating Control Center's Sound menu for you, " +
            "so macOS needs to allow it to control your Mac. This is the only permission it uses.\n\n" +
            "1. Click Open System Settings.\n" +
            "2. Turn on AirToggle in the list (the pane is called Accessibility, or Device Control and Data Access on newer macOS).\n" +
            "3. Come back here. This window closes by itself once access is granted.")
        body.preferredMaxLayoutWidth = 460

        let open = NSButton(title: "Open System Settings", target: self, action: #selector(openSettings))
        open.keyEquivalent = "\r"
        let later = NSButton(title: "Later", target: self, action: #selector(close))
        let buttons = NSStackView(views: [NSView(), later, open])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        statusLabel.stringValue = "Waiting for access… Then press \(shortcut.displayString) to toggle."
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.preferredMaxLayoutWidth = 460

        let header = NSStackView(views: [icon, title])
        header.orientation = .horizontal
        header.spacing = 14

        let stack = NSStackView(views: [header, body, statusLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 520, height: stack.fittingSize.height + 40))
        self.window = window
    }

    @objc private func openSettings() {
        ControlCenterEngine.requestTrust()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func close() { timer?.invalidate(); timer = nil; window?.close() }
}

// MARK: - Settings window (reachable even when the menu bar icon is hidden)

final class SettingsWindowController: NSObject {
    private var window: NSWindow?
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let loginCheckbox = NSButton(checkboxWithTitle: "Launch at Login", target: nil, action: nil)
    private var cycleCheckboxes: [ListeningMode: NSButton] = [:]
    var onChangeShortcut: (() -> Void)?
    var onResetShortcut: (() -> Void)?
    var onToggleLogin: (() -> Void)?
    var onPickMode: ((ListeningMode) -> Void)?
    var onCycleChanged: (() -> Void)?

    func show(shortcut: Shortcut) {
        if window == nil { build() }
        refresh(shortcut: shortcut)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func refresh(shortcut: Shortcut) {
        shortcutLabel.stringValue = shortcut.displayString
        loginCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let cycle = ListeningMode.cycle
        for (mode, box) in cycleCheckboxes { box.state = cycle.contains(mode) ? .on : .off }
    }

    private func build() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "AirToggle"
        window.isReleasedWhenClosed = false

        let title = NSTextField(labelWithString: "AirToggle")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Toggle AirPods listening modes with one shortcut")
        subtitle.textColor = .secondaryLabelColor

        // Shortcut row
        shortcutLabel.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
        let change = NSButton(title: "Change…", target: self, action: #selector(changeShortcut))
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetShortcut))
        let shortcutRow = NSStackView(views: [NSTextField(labelWithString: "Global shortcut:"), shortcutLabel, NSView(), change, reset])
        shortcutRow.orientation = .horizontal
        shortcutRow.spacing = 8

        loginCheckbox.target = self
        loginCheckbox.action = #selector(toggleLogin)

        // Cycle row
        let cycleCaption = NSTextField(labelWithString: "Shortcut cycles through (pick at least two):")
        var boxes: [NSView] = []
        for mode in ListeningMode.cycleOrder {
            let box = NSButton(checkboxWithTitle: mode.title, target: self, action: #selector(cycleChanged(_:)))
            box.tag = ListeningMode.allCases.firstIndex(of: mode) ?? 0
            cycleCheckboxes[mode] = box
            boxes.append(box)
        }
        let cycleRow = NSStackView(views: boxes)
        cycleRow.orientation = .horizontal
        cycleRow.spacing = 14

        // Mode buttons
        let modesCaption = NSTextField(labelWithString: "Set mode now:")
        var buttons: [NSView] = []
        for mode in ListeningMode.cycleOrder {
            let button = NSButton(title: mode.title, target: self, action: #selector(pickMode(_:)))
            button.bezelStyle = .rounded
            button.tag = ListeningMode.allCases.firstIndex(of: mode) ?? 0
            buttons.append(button)
        }
        let modesRow = NSStackView(views: buttons)
        modesRow.orientation = .horizontal
        modesRow.spacing = 8

        let hint = NSTextField(labelWithString: "Tip: double-click AirToggle in Finder to reopen this window.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [title, subtitle, NSBox.separator(), shortcutRow, loginCheckbox,
                                        cycleCaption, cycleRow, modesCaption, modesRow, NSBox.separator(), hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(2, after: title)
        stack.setCustomSpacing(4, after: cycleCaption)
        stack.setCustomSpacing(4, after: modesCaption)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for row in [shortcutRow, cycleRow, modesRow] as [NSView] { row.translatesAutoresizingMaskIntoConstraints = false }

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            shortcutRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        for separator in stack.views.compactMap({ $0 as? NSBox }) {
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        let width = max(520, stack.fittingSize.width + 40)
        window.setContentSize(NSSize(width: width, height: stack.fittingSize.height + 40))
        self.window = window
    }

    @objc private func changeShortcut() { onChangeShortcut?() }
    @objc private func resetShortcut() { onResetShortcut?() }
    @objc private func toggleLogin() { onToggleLogin?() }
    @objc private func pickMode(_ sender: NSButton) { onPickMode?(ListeningMode.allCases[sender.tag]) }

    @objc private func cycleChanged(_ sender: NSButton) {
        let selected = cycleCheckboxes.filter { $0.value.state == .on }.map { $0.key }
        if selected.count < 2 {
            NSSound.beep()
            sender.state = .on
            return
        }
        ListeningMode.cycle = selected
        onCycleChanged?()
    }
}

extension NSBox {
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let toggleNotification = Notification.Name("dev.ben.AirToggle.toggle")
    static let setModeNotification = Notification.Name("dev.ben.AirToggle.setMode")
    static let dumpNotification = Notification.Name("dev.ben.AirToggle.dump")
    static let statusNotification = Notification.Name("dev.ben.AirToggle.status")
    static let settingsNotification = Notification.Name("dev.ben.AirToggle.settings")
    static let repairNotification = Notification.Name("dev.ben.AirToggle.repairMenuBar")
    static let storeDumpNotification = Notification.Name("dev.ben.AirToggle.dumpMenuBarStore")

    private var statusItem: NSStatusItem!
    private var shortcut = Shortcut.load()
    private let recorder = ShortcutRecorder()
    private let settings = SettingsWindowController()
    private let welcome = WelcomeWindowController()
    private let engine = ControlCenterEngine()
    private let queue = DispatchQueue(label: "dev.ben.AirToggle.engine")
    private var busy = false
    private var lastKnownMode: ListeningMode?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("AirToggle launched (pid \(ProcessInfo.processInfo.processIdentifier))")

        // A stable autosave name lets macOS (and menu bar managers such as Bartender) remember this
        // item's position. Bartender identifies items through the app's saved
        // "NSStatusItem Preferred Position <name>" preference, which macOS only writes after the item
        // has been dragged once, so seed it on first launch to give the item a stable identity.
        let positionKey = "NSStatusItem Preferred Position AirToggleItem"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(300.0, forKey: positionKey)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "AirToggleItem"
        if let image = NSImage(systemSymbolName: "ear.badge.waveform", accessibilityDescription: "AirToggle")
                        ?? NSImage(systemSymbolName: "airpodspro", accessibilityDescription: "AirToggle") {
            image.isTemplate = true
            statusItem.button?.image = image.withSymbolConfiguration(.init(pointSize: 15, weight: .medium)) ?? image
        } else {
            statusItem.button?.title = "AT"
        }
        statusItem.button?.setAccessibilityTitle("AirToggle")
        statusItem.button?.setAccessibilityLabel("AirToggle")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        Shortcut.primeLabel(for: shortcut)
        Shortcut.primeLabel(for: .default)
        HotKeyManager.shared.onPress = { [weak self] in self?.toggle() }
        HotKeyManager.shared.register(shortcut)

        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(handleToggleNotification), name: AppDelegate.toggleNotification, object: nil)
        center.addObserver(self, selector: #selector(handleSetModeNotification(_:)), name: AppDelegate.setModeNotification, object: nil)
        center.addObserver(self, selector: #selector(handleDumpNotification), name: AppDelegate.dumpNotification, object: nil)
        center.addObserver(self, selector: #selector(handleStatusNotification), name: AppDelegate.statusNotification, object: nil)
        center.addObserver(self, selector: #selector(showSettings), name: AppDelegate.settingsNotification, object: nil)
        center.addObserver(self, selector: #selector(repairMenuBar), name: AppDelegate.repairNotification, object: nil)
        center.addObserver(self, selector: #selector(dumpMenuBarStore), name: AppDelegate.storeDumpNotification, object: nil)

        settings.onChangeShortcut = { [weak self] in self?.changeShortcut() }
        settings.onResetShortcut = { [weak self] in self?.resetShortcut() }
        settings.onToggleLogin = { [weak self] in self?.toggleLaunchAtLogin() }
        settings.onPickMode = { [weak self] mode in self?.set(mode) }
        settings.onCycleChanged = { Log.write("Cycle is now \(ListeningMode.cycle.map { $0.title })") }

        if !ControlCenterEngine.isTrusted {
            Log.write("Accessibility access not granted yet; showing welcome window")
            welcome.onGranted = { [weak self] in
                guard let self else { return }
                Log.write("Accessibility access granted")
                self.updateStatusButton()
                HUD.shared.show(symbol: "checkmark.circle", text: "Ready — press \(self.shortcut.displayString)")
            }
            welcome.showIfNeeded(shortcut: shortcut)
        }
        updateStatusButton()
    }

    /// Double-clicking the app in Finder (or `open -a AirToggle`) while it is running opens Settings,
    /// so the app stays reachable even if a menu bar manager hides its icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    @objc func showSettings() { settings.show(shortcut: shortcut) }

    @objc func dumpMenuBarStore() {
        Log.write("Menu bar layout store:\n" + MenuBarLayoutRepair.dump())
    }

    @objc func repairMenuBar() {
        let result = MenuBarLayoutRepair.run()
        Log.write("Menu bar layout repair: \(result)")
        HUD.shared.show(symbol: result.hasPrefix("Removed") ? "checkmark.circle" : "exclamationmark.triangle",
                        text: result.hasPrefix("Removed") ? "Menu bar position reset" : "Repair failed — see log")
    }

    // MARK: Actions

    @objc private func handleToggleNotification() { toggle() }
    @objc private func handleStatusNotification() { readStatus() }

    @objc private func handleSetModeNotification(_ note: Notification) {
        guard let raw = note.userInfo?["mode"] as? String ?? note.object as? String else { return }
        if let mode = ListeningMode.allCases.first(where: { $0.title.lowercased().hasPrefix(raw.lowercased()) }) {
            set(mode)
        }
    }

    @objc private func handleDumpNotification() {
        let button = statusItem.button
        let window = button?.window
        let selfReport = """
        Own status item: isVisible=\(statusItem.isVisible) length=\(statusItem.length) \
        window=\(window.map { "frame=\($0.frame) visible=\($0.isVisible) onScreen=\($0.screen != nil) alpha=\($0.alphaValue) level=\($0.level.rawValue)" } ?? "nil") \
        buttonHidden=\(button?.isHidden ?? true) image=\(button?.image != nil) \
        prefs=\(UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("NSStatusItem") })
        """
        Log.write(selfReport)
        queue.async { [engine] in Log.write("Control Center tree dump:\n" + engine.dumpTree()) }
    }

    func toggle() { run(nil) }
    func set(_ mode: ListeningMode) { run(mode) }

    private func run(_ requested: ListeningMode?) {
        guard ControlCenterEngine.isTrusted else { return needsAccessibility() }
        guard !busy else { return }
        busy = true
        queue.async { [weak self, engine] in
            let outcome = Result { try engine.apply(requested) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                switch outcome {
                case .success(let (from, to)):
                    Log.write("\(requested == nil ? "Toggle" : "Set"): \(from?.title ?? "unknown") → \(to.title)")
                    self.lastKnownMode = to
                    HUD.shared.show(symbol: to.symbolName, text: to.title)
                case .failure(let error):
                    Log.write("Failed: \(error.localizedDescription)")
                    HUD.shared.show(symbol: "exclamationmark.triangle", text: error.localizedDescription)
                }
                self.updateStatusButton()
            }
        }
    }

    private func readStatus() {
        guard ControlCenterEngine.isTrusted else { return needsAccessibility() }
        guard !busy else { return }
        busy = true
        queue.async { [weak self, engine] in
            let outcome = Result { try engine.currentMode() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                switch outcome {
                case .success(let mode):
                    Log.write("Status: \(mode?.title ?? "unknown")")
                    self.lastKnownMode = mode
                    HUD.shared.show(symbol: mode?.symbolName ?? "questionmark", text: mode?.title ?? "Unknown mode")
                case .failure(let error):
                    Log.write("Status failed: \(error.localizedDescription)")
                    HUD.shared.show(symbol: "exclamationmark.triangle", text: error.localizedDescription)
                }
                self.updateStatusButton()
            }
        }
    }

    private func needsAccessibility() {
        Log.write("Action ignored: Accessibility access not granted")
        HUD.shared.show(symbol: "hand.raised", text: "Allow Accessibility for AirToggle")
        welcome.showIfNeeded(shortcut: shortcut)
    }

    private func updateStatusButton() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.updateStatusButton() }
            return
        }
        let trusted = ControlCenterEngine.isTrusted
        statusItem.button?.appearsDisabled = !trusted
        statusItem.button?.toolTip = trusted
            ? "AirToggle — \(lastKnownMode?.title ?? "press \(shortcut.displayString) to toggle")"
            : "AirToggle — needs Accessibility access"
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let trusted = ControlCenterEngine.isTrusted
        updateStatusButton()

        if !trusted {
            let warn = NSMenuItem(title: "Accessibility access required", action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
            let open = NSMenuItem(title: "Open Privacy & Security Settings…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
            menu.addItem(.separator())
        } else {
            let header = NSMenuItem(title: "AirPods: \(lastKnownMode?.title ?? "mode not read yet")", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
        }

        let cycleTitle = ListeningMode.cycle.map { $0.title }.joined(separator: " / ")
        let toggleItem = NSMenuItem(title: "Toggle: \(cycleTitle)",
                                    action: #selector(toggleFromMenu), keyEquivalent: shortcut.keyEquivalent)
        toggleItem.keyEquivalentModifierMask = shortcut.cocoaModifiers
        toggleItem.target = self
        toggleItem.isEnabled = trusted
        menu.addItem(toggleItem)
        menu.addItem(.separator())

        for candidate in [ListeningMode.noiseCancellation, .transparency, .adaptive, .off] {
            let item = NSMenuItem(title: candidate.title, action: #selector(setModeFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = candidate
            item.state = lastKnownMode == candidate ? .on : .off
            item.isEnabled = trusted
            item.image = NSImage(systemSymbolName: candidate.symbolName, accessibilityDescription: nil)
            menu.addItem(item)
        }
        let cycleItem = NSMenuItem(title: "Shortcut Cycles Through", action: nil, keyEquivalent: "")
        let cycleMenu = NSMenu()
        for candidate in ListeningMode.cycleOrder {
            let item = NSMenuItem(title: candidate.title, action: #selector(toggleCycleMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = candidate
            item.state = ListeningMode.cycle.contains(candidate) ? .on : .off
            cycleMenu.addItem(item)
        }
        cycleItem.submenu = cycleMenu
        menu.addItem(cycleItem)

        let status = NSMenuItem(title: "Read Current Mode", action: #selector(readStatusFromMenu), keyEquivalent: "")
        status.target = self
        status.isEnabled = trusted
        menu.addItem(status)
        menu.addItem(.separator())

        let shortcutItem = NSMenuItem(title: "Shortcut: \(shortcut.displayString)", action: nil, keyEquivalent: "")
        let shortcutMenu = NSMenu()
        let change = NSMenuItem(title: "Change Shortcut…", action: #selector(changeShortcut), keyEquivalent: "")
        change.target = self
        let reset = NSMenuItem(title: "Reset to \(Shortcut.default.displayString)", action: #selector(resetShortcut), keyEquivalent: "")
        reset.target = self
        reset.isEnabled = shortcut != .default
        shortcutMenu.addItem(change)
        shortcutMenu.addItem(reset)
        shortcutItem.submenu = shortcutMenu
        menu.addItem(shortcutItem)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let settingsItem = NSMenuItem(title: "Settings Window…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let repair = NSMenuItem(title: "Repair Menu Bar Position", action: #selector(repairMenuBar), keyEquivalent: "")
        repair.target = self
        repair.toolTip = "Clears parked positions for this app in macOS's menu bar layout store"
        menu.addItem(repair)

        let diag = NSMenuItem(title: "Write Diagnostics to Log", action: #selector(handleDumpNotification), keyEquivalent: "")
        diag.target = self
        diag.toolTip = Log.url.path
        menu.addItem(diag)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit AirToggle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func toggleFromMenu() { toggle() }
    @objc private func readStatusFromMenu() { readStatus() }

    @objc private func toggleCycleMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? ListeningMode else { return }
        var cycle = ListeningMode.cycle
        if cycle.contains(mode) {
            guard cycle.count > 2 else { NSSound.beep(); return }
            cycle.removeAll { $0 == mode }
        } else {
            cycle.append(mode)
        }
        ListeningMode.cycle = cycle
        Log.write("Cycle is now \(ListeningMode.cycle.map { $0.title })")
        settings.refresh(shortcut: shortcut)
    }

    @objc private func setModeFromMenu(_ sender: NSMenuItem) {
        if let mode = sender.representedObject as? ListeningMode { set(mode) }
    }

    @objc private func openAccessibilitySettings() {
        ControlCenterEngine.requestTrust()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func changeShortcut() {
        HotKeyManager.shared.unregister()
        recorder.begin(current: shortcut) { [weak self] newShortcut in
            guard let self else { return }
            if let newShortcut {
                self.shortcut = newShortcut
                newShortcut.save()
                Shortcut.primeLabel(for: newShortcut)
            }
            if !HotKeyManager.shared.register(self.shortcut) {
                HUD.shared.show(symbol: "exclamationmark.triangle", text: "Shortcut unavailable")
                self.shortcut = .default
                Shortcut.reset()
                HotKeyManager.shared.register(self.shortcut)
            } else if newShortcut != nil {
                HUD.shared.show(symbol: "keyboard", text: "Shortcut: \(self.shortcut.displayString)")
            }
            self.settings.refresh(shortcut: self.shortcut)
            self.updateStatusButton()
        }
    }

    @objc private func resetShortcut() {
        Shortcut.reset()
        shortcut = .default
        HotKeyManager.shared.register(shortcut)
        HUD.shared.show(symbol: "keyboard", text: "Shortcut: \(shortcut.displayString)")
        settings.refresh(shortcut: shortcut)
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
            Log.write("Launch at login is now \(service.status == .enabled ? "on" : "off")")
            settings.refresh(shortcut: shortcut)
        } catch {
            Log.write("Launch at login change failed: \(error)")
            HUD.shared.show(symbol: "exclamationmark.triangle", text: "Couldn't update login item")
        }
    }
}

// MARK: - Command line entry points

/// `AirToggle --toggle | --anc | --transparency | --adaptive | --off | --status | --dump`
/// Commands are forwarded to the running menu bar app (which holds the Accessibility permission).
func runCommandLine(_ args: [String]) -> Bool {
    guard let command = args.dropFirst().first(where: { $0.hasPrefix("--") }) else { return false }
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    let center = DistributedNotificationCenter.default()

    switch command {
    case "--toggle": center.post(name: AppDelegate.toggleNotification, object: nil)
    case "--status": center.post(name: AppDelegate.statusNotification, object: nil)
    case "--dump": center.post(name: AppDelegate.dumpNotification, object: nil)
    case "--settings": center.post(name: AppDelegate.settingsNotification, object: nil)
    case "--repair-menubar": center.post(name: AppDelegate.repairNotification, object: nil)
    case "--dump-menubar-store": center.post(name: AppDelegate.storeDumpNotification, object: nil)
    case "--anc": center.post(name: AppDelegate.setModeNotification, object: ListeningMode.noiseCancellation.title)
    case "--transparency": center.post(name: AppDelegate.setModeNotification, object: ListeningMode.transparency.title)
    case "--adaptive": center.post(name: AppDelegate.setModeNotification, object: ListeningMode.adaptive.title)
    case "--off": center.post(name: AppDelegate.setModeNotification, object: ListeningMode.off.title)
    default:
        print("Usage: AirToggle [--toggle | --anc | --transparency | --adaptive | --off | --status | --settings | --dump]")
        return true
    }
    if running {
        Thread.sleep(forTimeInterval: 0.2)   // let the notification deliver before exiting
        print("Sent \(command) to AirToggle. Results are logged to \(Log.url.path)")
    } else {
        print("AirToggle isn't running. Open the app first, then retry.")
    }
    return true
}

if runCommandLine(CommandLine.arguments) { exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
