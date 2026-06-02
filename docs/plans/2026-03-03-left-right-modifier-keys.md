# Left/Right Modifier Key Distinction Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Allow Push to Talk to distinguish between left and right modifier keys, so users can bind to e.g. "Right Option" without needing double-tap.

**Architecture:** Extend the `LongPressModifierKey` enum with left/right variants, add keyCode-based detection in `ModifierKeyMonitor`, and flatten all options in the settings Picker.

**Tech Stack:** Swift, AppKit (NSEvent.keyCode, flagsChanged events), SwiftUI settings UI

---

### Task 1: Extend `LongPressModifierKey` Enum

**Files:**
- Modify: `Talkie/Utilities.swift:592-629` (the `LongPressModifierKey` enum)

**Step 1: Add left/right cases and update computed properties**

Add 8 new cases to the enum. Update `displayName`, `symbol`, and `modifierFlag`. Add two new computed properties: `keyCodes` and `isSideSpecific`.

```swift
enum LongPressModifierKey: String, Codable, CaseIterable {
    case option
    case leftOption
    case rightOption
    case command
    case leftCommand
    case rightCommand
    case control
    case leftControl
    case rightControl
    case shift
    case leftShift
    case rightShift
    case fn

    var displayName: String {
        switch self {
        case .option: return "Option (Any)"
        case .leftOption: return "Left Option"
        case .rightOption: return "Right Option"
        case .command: return "Command (Any)"
        case .leftCommand: return "Left Command"
        case .rightCommand: return "Right Command"
        case .control: return "Control (Any)"
        case .leftControl: return "Left Control"
        case .rightControl: return "Right Control"
        case .shift: return "Shift (Any)"
        case .leftShift: return "Left Shift"
        case .rightShift: return "Right Shift"
        case .fn: return "Fn"
        }
    }

    var symbol: String {
        switch self {
        case .option, .leftOption, .rightOption: return "⌥"
        case .command, .leftCommand, .rightCommand: return "⌘"
        case .control, .leftControl, .rightControl: return "⌃"
        case .shift, .leftShift, .rightShift: return "⇧"
        case .fn: return "fn"
        }
    }

    /// The NSEvent.ModifierFlags corresponding to this key
    var modifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .option, .leftOption, .rightOption: return .option
        case .command, .leftCommand, .rightCommand: return .command
        case .control, .leftControl, .rightControl: return .control
        case .shift, .leftShift, .rightShift: return .shift
        case .fn: return .function
        }
    }

    /// The physical key codes that match this modifier key
    /// Side-specific variants have one code; "any" variants have two
    var keyCodes: Set<UInt16> {
        switch self {
        case .option: return [58, 61]
        case .leftOption: return [58]
        case .rightOption: return [61]
        case .command: return [55, 54]
        case .leftCommand: return [55]
        case .rightCommand: return [54]
        case .control: return [59, 62]
        case .leftControl: return [59]
        case .rightControl: return [62]
        case .shift: return [56, 60]
        case .leftShift: return [56]
        case .rightShift: return [60]
        case .fn: return [63]
        }
    }

    /// Whether this is a side-specific variant (left or right)
    var isSideSpecific: Bool {
        switch self {
        case .leftOption, .rightOption,
             .leftCommand, .rightCommand,
             .leftControl, .rightControl,
             .leftShift, .rightShift:
            return true
        default:
            return false
        }
    }
}
```

**Step 2: Build to verify compilation**

Run: `./build.sh`
Expected: Build succeeds with no errors.

**Step 3: Commit**

```
feat: extend LongPressModifierKey with left/right variants
```

---

### Task 2: Update `ModifierKeyMonitor` to Use keyCode

**Files:**
- Modify: `Talkie/AppDelegate.swift:212-477` (the `ModifierKeyMonitor` class)

**Step 1: Add `lastMatchedKeyCode` state and update `resetState`**

Add a stored property to track the keyCode of the key that started activation:

```swift
// Add to the State section (after secondPressTime):
private var lastMatchedKeyCode: UInt16?
```

In `resetState()`, add:
```swift
lastMatchedKeyCode = nil
```

**Step 2: Update `handleFlagsChanged` to check keyCode**

Replace the current target-pressed check logic. Instead of only checking `flags.contains(targetFlag)`, also verify `event.keyCode` matches the configured modifier's `keyCodes`.

The key insight: when a modifier is **pressed**, `event.keyCode` is the key being pressed and `flags` will contain it. When a modifier is **released**, `event.keyCode` is the key being released and `flags` will NOT contain it.

Replace the detection logic at the top of `handleFlagsChanged`:

```swift
private func handleFlagsChanged(_ event: NSEvent, source: String) {
    let flags = event.modifierFlags
    let keyCode = event.keyCode

    // Check if the event's keyCode matches our target modifier
    let isTargetKeyCode = modifierKey.keyCodes.contains(keyCode)

    // Check if the target modifier flag is currently held
    let targetFlag = modifierKey.modifierFlag
    let isTargetFlagActive = flags.contains(targetFlag)

    // Determine press/release:
    // - Press: keyCode matches AND flag is active
    // - Release: keyCode matches AND flag is NOT active
    let isTargetPressed = isTargetKeyCode && isTargetFlagActive
    let isTargetReleased = isTargetKeyCode && !isTargetFlagActive

    // Ignore events for keys we don't care about
    guard isTargetPressed || isTargetReleased else { return }

    // Check if other modifiers are also pressed (abort if combo)
    let otherModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]
        .filter { $0 != targetFlag }
        .reduce(NSEvent.ModifierFlags()) { $0.union($1) }
    let hasOtherModifiers = !flags.intersection(otherModifiers).isEmpty

    logger.debug("[\(source)] flagsChanged: keyCode=\(keyCode), pressed=\(isTargetPressed), otherMods=\(hasOtherModifiers), state=\(self.state.description)")

    if hasOtherModifiers {
        if state != .idle {
            logger.debug("[\(source)] Other modifier detected, resetting state")
            resetState()
        }
        return
    }

    // State machine transitions — replace all occurrences of `isTargetPressed` checks
    // with the new `isTargetPressed` / `!isTargetPressed` (now `isTargetReleased`)
    switch state {
    case .idle:
        if isTargetPressed {
            lastMatchedKeyCode = keyCode
            if requireDoubleTap {
                logger.debug("[\(source)] First press detected")
                state = .firstPressDown
                firstPressTime = Date()
            } else {
                logger.debug("[\(source)] Press detected, waiting for hold")
                state = .secondPressHeld
                secondPressTime = Date()
                DispatchQueue.main.asyncAfter(deadline: .now() + minimumDuration) { [weak self] in
                    self?.checkActivation()
                }
            }
        }

    case .firstPressDown:
        if isTargetReleased {
            guard let pressTime = firstPressTime else {
                resetState()
                return
            }
            let pressDuration = Date().timeIntervalSince(pressTime)
            if pressDuration <= firstTapMaxDuration {
                logger.debug("[\(source)] First tap completed (duration: \(String(format: "%.2f", pressDuration))s), waiting for second press")
                state = .waitingForSecondPress
                firstReleaseTime = Date()
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self = self, self.state == .waitingForSecondPress else { return }
                    self.logger.debug("Double-tap timeout, resetting state")
                    self.resetState()
                }
                doubleTapTimeoutWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapInterval, execute: workItem)
            } else {
                logger.debug("[\(source)] First press held too long (\(String(format: "%.2f", pressDuration))s), resetting")
                resetState()
            }
        }

    case .waitingForSecondPress:
        if isTargetPressed {
            guard let releaseTime = firstReleaseTime else {
                resetState()
                return
            }
            let timeSinceRelease = Date().timeIntervalSince(releaseTime)
            if timeSinceRelease <= doubleTapInterval {
                logger.debug("[\(source)] Second press detected (interval: \(String(format: "%.2f", timeSinceRelease))s), waiting for hold")
                state = .secondPressHeld
                secondPressTime = Date()
                lastMatchedKeyCode = keyCode
                doubleTapTimeoutWorkItem?.cancel()
                doubleTapTimeoutWorkItem = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + minimumDuration) { [weak self] in
                    self?.checkActivation()
                }
            } else {
                logger.debug("[\(source)] Second press too slow, treating as new first press")
                resetState()
                state = .firstPressDown
                firstPressTime = Date()
                lastMatchedKeyCode = keyCode
            }
        }

    case .secondPressHeld:
        if isTargetReleased {
            let pressDuration = secondPressTime.map { Date().timeIntervalSince($0) } ?? 0
            logger.debug("[\(source)] Second press released before activation (duration: \(String(format: "%.2f", pressDuration))s)")
            resetState()
        }

    case .activated:
        if isTargetReleased {
            logger.info("[\(source)] Push to Talk release detected, triggering callback")
            onRelease()
            resetState()
        }
    }
}
```

**Step 3: Update `checkActivation` to use stored keyCode**

The current `checkActivation` checks `NSEvent.modifierFlags` which can't distinguish left/right. For side-specific keys, we rely on the stored `lastMatchedKeyCode` plus the modifier flag still being active:

```swift
private func checkActivation() {
    guard state == .secondPressHeld,
          let pressTime = secondPressTime,
          Date().timeIntervalSince(pressTime) >= minimumDuration else {
        return
    }

    // Verify modifier flag is still active
    let currentFlags = NSEvent.modifierFlags
    guard currentFlags.contains(modifierKey.modifierFlag) else {
        logger.debug("Modifier released before activation")
        resetState()
        return
    }

    // Activate
    logger.info("Push to Talk hold threshold reached, activating")
    state = .activated
    onActivate()
}
```

Note: `checkActivation` no longer needs keyCode verification — if the modifier flag is still held AND we matched the correct keyCode on press (stored in `lastMatchedKeyCode`), the activation is valid. The release event will correctly use keyCode to detect when specifically our key is released.

**Step 4: Build to verify compilation**

Run: `./build.sh`
Expected: Build succeeds.

**Step 5: Commit**

```
feat: use keyCode in ModifierKeyMonitor for left/right detection
```

---

### Task 3: Update Settings UI

**Files:**
- Modify: `Talkie/SettingsWindow.swift:404-493` (the `PushToTalkSection`)

**Step 1: Update Picker and auto-disable double-tap**

In the Picker for modifier key, the existing code iterates `LongPressModifierKey.allCases` — this will automatically include the new cases. Update the display format and add auto-disable logic for double-tap:

```swift
Picker("Modifier key:", selection: configBinding(\.modifierKey, onSet: { newKey in
    // Auto-disable double-tap for side-specific keys
    if newKey.isSideSpecific && settings.longPressConfig.requireDoubleTap {
        var config = settings.longPressConfig
        config.requireDoubleTap = false
        settings.longPressConfig = config
    }
})) {
    ForEach(LongPressModifierKey.allCases, id: \.self) { key in
        Text("\(key.symbol) \(key.displayName)").tag(key)
    }
}
```

**Step 2: Conditionally hide double-tap toggle**

Replace the current double-tap toggle:

```swift
// Only show double-tap toggle for non-side-specific keys
if !settings.longPressConfig.modifierKey.isSideSpecific {
    Toggle("Require double-tap", isOn: configBinding(\.requireDoubleTap))
}
```

**Step 3: Build and verify**

Run: `./build.sh`
Expected: Build succeeds. Settings UI shows all 13 modifier key options. Selecting a side-specific key hides the double-tap toggle.

**Step 4: Commit**

```
feat: update Push to Talk settings UI for left/right modifier keys
```

---

### Task 4: Manual Testing & Polish

**Step 1: Build and launch**

Run: `./build.sh`

**Step 2: Test matrix**

Verify each scenario works:

1. Select "Right Option" → hold right Option → activates
2. Select "Right Option" → hold left Option → does NOT activate
3. Select "Option (Any)" → hold either Option → activates
4. Select "Right Command" → double-tap toggle is hidden
5. Select "Shift (Any)" → double-tap toggle is visible
6. Upgrade path: existing config with `"shift"` still loads correctly

**Step 3: Commit any fixes**

```
fix: polish left/right modifier key detection
```
