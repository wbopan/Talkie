//
//  AppDelegate.swift
//  Talkie
//
//  Core app coordinator for menu bar app with global hotkey
//

import Cocoa
import SwiftUI
import Carbon
import OSLog
import KeyboardShortcuts

class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Properties

    private var statusItem: NSStatusItem!
    private var floatingWindowController: FloatingWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var modifierKeyMonitor: ModifierKeyMonitor?
    private let viewModel = TranscriptionViewModel.shared
    private let settings = AppSettings.shared

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set activation policy to accessory (no dock icon)
        NSApp.setActivationPolicy(.accessory)

        // Setup menu bar icon (respects user preference)
        if settings.showMenuBarIcon {
            setupStatusItem()
        }

        // Setup global hotkey
        setupHotkey()

        // Setup Push to Talk modifier key monitor
        setupDoubleTapHoldMonitor()

        // Observe hotkey changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHotkeyChanged),
            name: .globalHotkeyChanged,
            object: nil
        )

        // Observe long-press config changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLongPressConfigChanged),
            name: .longPressConfigChanged,
            object: nil
        )

        // Observe menu bar icon visibility changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMenuBarIconVisibilityChanged),
            name: .menuBarIconVisibilityChanged,
            object: nil
        )

        // Override the system Settings/Preferences menu item (Cmd+,)
        DispatchQueue.main.async { [weak self] in
            self?.overrideSettingsMenuItem()

            // If menu bar icon is hidden, open settings so the user has a way to interact
            if self?.settings.showMenuBarIcon == false {
                self?.openSettings()
            }
        }

        log(.info, "Talkie menu bar app launched")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Cleanup long-press monitor
        modifierKeyMonitor?.stop()
    }

    // MARK: - Status Bar Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(named: "MenuBarIcon")
            button.image?.isTemplate = true
        }

        // Create menu
        let menu = NSMenu()

        let openItem = NSMenuItem(title: "Open Talkie", action: #selector(showWindow), keyEquivalent: "")
        openItem.image = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)
        menu.addItem(openItem)
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    /// Replace the SwiftUI-generated Settings menu item with our own that opens our custom settings window.
    private func overrideSettingsMenuItem() {
        guard let appMenu = NSApp.mainMenu?.item(at: 0)?.submenu else { return }
        for (index, item) in appMenu.items.enumerated() {
            if item.keyEquivalent == "," {
                let newItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
                newItem.keyEquivalentModifierMask = .command
                newItem.target = self
                appMenu.removeItem(at: index)
                appMenu.insertItem(newItem, at: index)
                break
            }
        }
    }

    // MARK: - Global Hotkey Setup

    private func setupHotkey() {
        // Migrate legacy settings on first run
        AppSettings.migrateHotkeyIfNeeded()

        KeyboardShortcuts.onKeyUp(for: .toggleWindow) { [weak self] in
            Task { @MainActor in
                self?.toggleWindow()
            }
        }

        log(.info, "Global hotkey registered via KeyboardShortcuts")
    }

    @objc private func handleHotkeyChanged() {
        // KeyboardShortcuts handles changes automatically
        log(.info, "Global hotkey setting changed")
    }

    // MARK: - Push to Talk Modifier Key Setup

    private func setupDoubleTapHoldMonitor() {
        // Stop existing monitor if any
        modifierKeyMonitor?.stop()
        modifierKeyMonitor = nil

        let config = settings.longPressConfig
        guard config.enabled else {
            log(.info, "Push to Talk is disabled")
            return
        }

        log(.info, "Setting up Push to Talk monitor for \(config.modifierKey.displayName) key (requireDoubleTap: \(config.requireDoubleTap))")

        modifierKeyMonitor = ModifierKeyMonitor(
            modifierKey: config.modifierKey,
            minimumDuration: config.minimumPressDuration,
            requireDoubleTap: config.requireDoubleTap,
            onActivate: { [weak self] in
                Task { @MainActor in
                    self?.handleDoubleTapHoldActivate()
                }
            },
            onRelease: { [weak self] in
                Task { @MainActor in
                    self?.handleDoubleTapHoldRelease()
                }
            }
        )

        modifierKeyMonitor?.start()
        log(.info, "Push to Talk monitor started for \(config.modifierKey.symbol) key")
    }

    @objc private func handleLongPressConfigChanged() {
        log(.info, "Push to Talk config changed, updating monitor...")
        setupDoubleTapHoldMonitor()
    }

    @objc private func handleMenuBarIconVisibilityChanged() {
        if settings.showMenuBarIcon {
            if statusItem == nil {
                setupStatusItem()
            }
            statusItem.isVisible = true
        } else {
            statusItem?.isVisible = false
        }
        log(.info, "Menu bar icon visibility changed: \(settings.showMenuBarIcon)")
    }

    @MainActor
    private func handleDoubleTapHoldActivate() {
        log(.info, "Push to Talk activated, showing window and starting recording")
        showWindow()
    }

    @MainActor
    private func handleDoubleTapHoldRelease() {
        guard let controller = floatingWindowController,
              controller.window?.isVisible == true else {
            log(.debug, "No visible window, ignoring release")
            return
        }

        log(.info, "Push to Talk released, triggering finish recording")
        controller.finishRecordingAndDismiss()
    }

    // MARK: - Window Management

    @MainActor
    @objc private func showWindow() {
        if floatingWindowController == nil {
            floatingWindowController = FloatingWindowController()
        }
        floatingWindowController?.showWindow(nil)
    }

    @MainActor
    @objc private func toggleWindow() {
        if let controller = floatingWindowController, controller.window?.isVisible == true {
            controller.hideWindow()
        } else {
            showWindow()
        }
    }

    @MainActor
    @objc private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
            // Observe this specific window closing
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(settingsWindowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: settingsWindowController?.window
            )
        }
        NSApp.setActivationPolicy(.regular)
        settingsWindowController?.showWindow(nil)
        NSApp.activate()
    }

    @objc private func settingsWindowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Modifier Key Monitor

/// Monitors global modifier key press/release events for Push to Talk activation.
/// Requires Accessibility permission to work.
///
/// When requireDoubleTap is true:
///   idle → firstPressDown → waitingForSecondPress → secondPressHeld → activated
/// When requireDoubleTap is false:
///   idle → secondPressHeld → activated
class ModifierKeyMonitor {
    // MARK: - State Machine

    private enum State: CustomStringConvertible {
        case idle
        case firstPressDown
        case waitingForSecondPress
        case secondPressHeld
        case activated

        var description: String {
            switch self {
            case .idle: return "idle"
            case .firstPressDown: return "firstPressDown"
            case .waitingForSecondPress: return "waitingForSecondPress"
            case .secondPressHeld: return "secondPressHeld"
            case .activated: return "activated"
            }
        }
    }

    // MARK: - Configuration

    private let modifierKey: LongPressModifierKey
    private let minimumDuration: TimeInterval  // Time to hold on second press before activation
    private let requireDoubleTap: Bool
    private let onActivate: () -> Void
    private let onRelease: () -> Void

    // Double-tap timing constants
    private let doubleTapInterval: TimeInterval = 0.3  // Max time between taps
    private let firstTapMaxDuration: TimeInterval = 0.25  // Max duration for first tap

    // MARK: - State

    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var state: State = .idle
    private var firstPressTime: Date?
    private var firstReleaseTime: Date?
    private var secondPressTime: Date?
    private var doubleTapTimeoutWorkItem: DispatchWorkItem?
    private var lastMatchedKeyCode: UInt16?
    /// Buffered keyDown event to replay if space is released quickly (not PTT)
    private var bufferedKeyDownEvent: CGEvent?

    private let logger = Logger.hotkey

    init(modifierKey: LongPressModifierKey,
         minimumDuration: TimeInterval,
         requireDoubleTap: Bool = false,
         onActivate: @escaping () -> Void,
         onRelease: @escaping () -> Void) {
        self.modifierKey = modifierKey
        self.minimumDuration = minimumDuration
        self.requireDoubleTap = requireDoubleTap
        self.onActivate = onActivate
        self.onRelease = onRelease
    }

    deinit {
        stop()
    }

    func start() {
        stop() // Ensure no duplicate monitors

        logger.info("Starting modifier key monitor for \(self.modifierKey.displayName) (requireDoubleTap: \(self.requireDoubleTap))")

        if modifierKey.isRegularKey {
            startRegularKeyMonitor()
        } else {
            startModifierKeyMonitor()
        }
    }

    /// Start monitors for modifier keys (flagsChanged events)
    private func startModifierKeyMonitor() {
        // Global monitor - captures events sent to OTHER applications
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event, source: "global")
        }

        // Local monitor - captures events sent to OUR application
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event, source: "local")
            return event
        }

        if globalEventMonitor == nil {
            logger.error("Failed to create global event monitor - check Accessibility permission")
        }
        if localEventMonitor == nil {
            logger.error("Failed to create local event monitor")
        }
    }

    /// Start CGEventTap for regular keys (space) — intercepts and can suppress key events
    private func startRegularKeyMonitor() {
        let targetKeyCode = modifierKey.keyCodes.first!

        // Store self as unmanaged pointer for the C callback
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<ModifierKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handleCGEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: refcon
        ) else {
            logger.error("Failed to create CGEventTap - check Accessibility permission")
            return
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        logger.info("CGEventTap started for keyCode \(targetKeyCode)")
    }

    /// Handle intercepted CGEvent for regular key PTT (returns nil to suppress, event to pass through)
    private func handleCGEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if it gets disabled by the system
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        guard modifierKey.keyCodes.contains(keyCode) else {
            return Unmanaged.passUnretained(event)
        }

        // Pass through if any modifier keys are held (e.g. Cmd+Space, Ctrl+Space)
        let flags = CGEventFlags(rawValue: event.flags.rawValue & (CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue))
        if flags.rawValue != 0 {
            return Unmanaged.passUnretained(event)
        }

        // Ignore auto-repeat keyDown events
        if type == .keyDown && isAutoRepeat {
            // If activated, suppress repeats; otherwise pass through
            return state == .activated ? nil : Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            handleRegularKeyPress(keyCode: keyCode, event: event)
            // Buffer the event — don't pass through yet
            // If released quickly, we'll replay it
            return nil
        } else if type == .keyUp {
            let shouldSuppress = handleRegularKeyRelease(keyCode: keyCode)
            return shouldSuppress ? nil : Unmanaged.passUnretained(event)
        }

        return Unmanaged.passUnretained(event)
    }

    /// Handle regular key press (keyDown)
    private func handleRegularKeyPress(keyCode: UInt16, event: CGEvent) {
        logger.debug("Regular key press: keyCode=\(keyCode), state=\(self.state.description)")

        switch state {
        case .idle:
            lastMatchedKeyCode = keyCode
            bufferedKeyDownEvent = event.copy()
            if requireDoubleTap {
                state = .firstPressDown
                firstPressTime = Date()
            } else {
                state = .secondPressHeld
                secondPressTime = Date()
                DispatchQueue.main.asyncAfter(deadline: .now() + minimumDuration) { [weak self] in
                    self?.checkActivation()
                }
            }

        case .waitingForSecondPress:
            lastMatchedKeyCode = keyCode
            bufferedKeyDownEvent = event.copy()
            guard let releaseTime = firstReleaseTime else {
                resetState()
                return
            }
            let timeSinceRelease = Date().timeIntervalSince(releaseTime)
            if timeSinceRelease <= doubleTapInterval {
                state = .secondPressHeld
                secondPressTime = Date()
                doubleTapTimeoutWorkItem?.cancel()
                doubleTapTimeoutWorkItem = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + minimumDuration) { [weak self] in
                    self?.checkActivation()
                }
            } else {
                resetState()
                lastMatchedKeyCode = keyCode
                bufferedKeyDownEvent = event.copy()
                state = .firstPressDown
                firstPressTime = Date()
            }

        default:
            break
        }
    }

    /// Handle regular key release (keyUp). Returns true if the keyUp should be suppressed.
    private func handleRegularKeyRelease(keyCode: UInt16) -> Bool {
        logger.debug("Regular key release: keyCode=\(keyCode), state=\(self.state.description)")

        switch state {
        case .firstPressDown:
            guard let pressTime = firstPressTime else {
                replayBufferedKeyDown()
                resetState()
                return false
            }
            let pressDuration = Date().timeIntervalSince(pressTime)
            if pressDuration <= firstTapMaxDuration {
                state = .waitingForSecondPress
                firstReleaseTime = Date()
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self = self, self.state == .waitingForSecondPress else { return }
                    self.logger.debug("Double-tap timeout, replaying buffered key and resetting")
                    self.replayBufferedKeyDown()
                    self.resetState()
                }
                doubleTapTimeoutWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapInterval, execute: workItem)
            } else {
                replayBufferedKeyDown()
                resetState()
            }
            return false  // Let keyUp through (or it was already suppressed with keyDown)

        case .secondPressHeld:
            // Released before activation
            replayBufferedKeyDown()
            resetState()
            return false

        case .activated:
            // PTT release
            logger.info("Push to Talk (space) release detected, triggering callback")
            onRelease()
            bufferedKeyDownEvent = nil
            resetState()
            return true  // Suppress the keyUp too

        default:
            return false
        }
    }

    /// Replay the buffered keyDown event so the character appears in the focused app
    private func replayBufferedKeyDown() {
        guard let event = bufferedKeyDownEvent else { return }
        event.post(tap: .cgAnnotatedSessionEventTap)
        bufferedKeyDownEvent = nil
    }

    func stop() {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
        doubleTapTimeoutWorkItem?.cancel()
        doubleTapTimeoutWorkItem = nil
        bufferedKeyDownEvent = nil
        logger.info("Modifier key monitor stopped")
        resetState()
    }

    private func resetState() {
        state = .idle
        firstPressTime = nil
        firstReleaseTime = nil
        secondPressTime = nil
        doubleTapTimeoutWorkItem?.cancel()
        doubleTapTimeoutWorkItem = nil
        lastMatchedKeyCode = nil
    }

    private func handleFlagsChanged(_ event: NSEvent, source: String) {
        let flags = event.modifierFlags
        let keyCode = event.keyCode

        // Determine if this event is for our target key using keyCode
        let isTargetKeyCode = modifierKey.keyCodes.contains(keyCode)
        let isTargetFlagActive = flags.contains(modifierKey.modifierFlag)

        // Press = our key's keyCode AND the modifier flag is now active
        let isTargetPressed = isTargetKeyCode && isTargetFlagActive
        // Release = our key's keyCode AND the modifier flag is now inactive
        let isTargetReleased = isTargetKeyCode && !isTargetFlagActive

        // If this event is not about our target key at all, ignore it
        if !isTargetPressed && !isTargetReleased {
            return
        }

        // Check for other modifiers (abort if combo)
        let targetFlag = modifierKey.modifierFlag
        let otherModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]
            .filter { $0 != targetFlag }
            .reduce(NSEvent.ModifierFlags()) { $0.union($1) }

        let hasOtherModifiers = !flags.intersection(otherModifiers).isEmpty

        logger.debug("[\(source)] flagsChanged: keyCode=\(keyCode), pressed=\(isTargetPressed), released=\(isTargetReleased), otherMods=\(hasOtherModifiers), state=\(self.state.description)")

        // If other modifiers are pressed, abort any pending activation
        if hasOtherModifiers {
            if state != .idle {
                logger.debug("[\(source)] Other modifier detected, resetting state")
                resetState()
            }
            return
        }

        // State machine transitions
        switch state {
        case .idle:
            if isTargetPressed {
                lastMatchedKeyCode = keyCode
                if requireDoubleTap {
                    // First press detected — wait for double-tap sequence
                    logger.debug("[\(source)] First press detected (keyCode: \(keyCode))")
                    state = .firstPressDown
                    firstPressTime = Date()
                } else {
                    // Simple hold mode — jump directly to hold detection
                    logger.debug("[\(source)] Press detected (keyCode: \(keyCode)), waiting for hold")
                    state = .secondPressHeld
                    secondPressTime = Date()

                    DispatchQueue.main.asyncAfter(deadline: .now() + minimumDuration) { [weak self] in
                        self?.checkActivation()
                    }
                }
            }

        case .firstPressDown:
            if isTargetReleased {
                // First release - check if it was quick enough
                guard let pressTime = firstPressTime else {
                    resetState()
                    return
                }

                let pressDuration = Date().timeIntervalSince(pressTime)
                if pressDuration <= firstTapMaxDuration {
                    // Quick tap - wait for second press
                    logger.debug("[\(source)] First tap completed (duration: \(String(format: "%.2f", pressDuration))s), waiting for second press")
                    state = .waitingForSecondPress
                    firstReleaseTime = Date()

                    // Start timeout for double-tap interval
                    let workItem = DispatchWorkItem { [weak self] in
                        guard let self = self, self.state == .waitingForSecondPress else { return }
                        self.logger.debug("Double-tap timeout, resetting state")
                        self.resetState()
                    }
                    doubleTapTimeoutWorkItem = workItem
                    DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapInterval, execute: workItem)
                } else {
                    // Held too long for first tap - this is not a double-tap attempt
                    logger.debug("[\(source)] First press held too long (\(String(format: "%.2f", pressDuration))s), resetting")
                    resetState()
                }
            }

        case .waitingForSecondPress:
            if isTargetPressed {
                lastMatchedKeyCode = keyCode
                // Second press detected
                guard let releaseTime = firstReleaseTime else {
                    resetState()
                    return
                }

                let timeSinceRelease = Date().timeIntervalSince(releaseTime)
                if timeSinceRelease <= doubleTapInterval {
                    // Within double-tap window - start hold detection
                    logger.debug("[\(source)] Second press detected (interval: \(String(format: "%.2f", timeSinceRelease))s), waiting for hold")
                    state = .secondPressHeld
                    secondPressTime = Date()
                    doubleTapTimeoutWorkItem?.cancel()
                    doubleTapTimeoutWorkItem = nil

                    // Schedule activation check after minimum duration
                    DispatchQueue.main.asyncAfter(deadline: .now() + minimumDuration) { [weak self] in
                        self?.checkActivation()
                    }
                } else {
                    // Too slow - treat as new first press
                    logger.debug("[\(source)] Second press too slow, treating as new first press")
                    resetState()
                    state = .firstPressDown
                    firstPressTime = Date()
                    lastMatchedKeyCode = keyCode
                }
            }

        case .secondPressHeld:
            if isTargetReleased {
                // Released before activation threshold
                let pressDuration = secondPressTime.map { Date().timeIntervalSince($0) } ?? 0
                logger.debug("[\(source)] Second press released before activation (duration: \(String(format: "%.2f", pressDuration))s)")
                resetState()
            }

        case .activated:
            if isTargetReleased {
                // Released after activation - trigger release callback
                logger.info("[\(source)] Push to Talk release detected, triggering callback")
                onRelease()
                resetState()
            }
        }
    }

    private func checkActivation() {
        // Verify we're still in secondPressHeld state and the key is still pressed
        guard state == .secondPressHeld,
              let pressTime = secondPressTime,
              Date().timeIntervalSince(pressTime) >= minimumDuration else {
            return
        }

        // For regular keys (space), we can't check modifier flags — trust the state machine
        // (if keyUp had arrived, state would have already been reset)
        if !modifierKey.isRegularKey {
            let currentFlags = NSEvent.modifierFlags
            guard currentFlags.contains(modifierKey.modifierFlag) else {
                logger.debug("Modifier released before activation")
                resetState()
                return
            }
        }

        // Activate — discard buffered keyDown so space isn't typed
        logger.info("Push to Talk hold threshold reached, activating")
        state = .activated
        bufferedKeyDownEvent = nil
        onActivate()
    }

    /// Check if Accessibility permission is granted
    static func checkAccessibilityPermission(prompt: Bool = false) -> Bool {
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            return AXIsProcessTrustedWithOptions(options as CFDictionary)
        } else {
            // Pass nil instead of empty dictionary to avoid crash
            return AXIsProcessTrustedWithOptions(nil)
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let globalHotkeyChanged = Notification.Name("globalHotkeyChanged")
    static let longPressConfigChanged = Notification.Name("longPressConfigChanged")
    static let menuBarIconVisibilityChanged = Notification.Name("menuBarIconVisibilityChanged")
}
