//
//  FloatingWindow.swift
//  Talkie
//
//  Floating transcription window with auto-start recording
//

import Cocoa
import SwiftUI
import OSLog

// MARK: - Floating Window Controller

class FloatingWindowController: NSWindowController {
    private let viewModel = TranscriptionViewModel.shared
    private let settings = AppSettings.shared
    private var previousActiveApp: NSRunningApplication?
    private let logger = Logger.ui

    private let capsuleHeight: CGFloat = 40

    /// Calculate window position based on the selected mode
    static func calculateWindowPosition(mode: WindowPositionMode, windowSize: NSSize, settings: AppSettings) -> NSPoint {
        log(.info, "Calculating window position for mode: \(mode.rawValue)")

        guard let screen = NSScreen.main else {
            log(.warning, "No main screen available, using default position")
            return NSPoint(x: 100, y: 100)
        }

        let visibleFrame = screen.visibleFrame
        log(.debug, "Screen visible frame: \(String(describing: visibleFrame))")

        switch mode {
        case .rememberLast:
            // Try to load saved position, fallback to center
            if let savedPosition = settings.getSavedWindowPosition() {
                log(.info, "Using saved window position: \(String(describing: savedPosition))")
                return savedPosition
            }
            // Center the window
            let x = visibleFrame.origin.x + (visibleFrame.width - windowSize.width) / 2
            let y = visibleFrame.origin.y + (visibleFrame.height - windowSize.height) / 2
            let position = NSPoint(x: x, y: y)
            log(.info, "No saved position, centering window at: \(String(describing: position))")
            return position

        case .nearMouse:
            // Get mouse position and offset slightly
            let mouseLocation = NSEvent.mouseLocation
            let offset: CGFloat = 20
            let margin: CGFloat = 10

            var x = mouseLocation.x + offset
            var y = mouseLocation.y - offset

            // Boundary check: keep window within screen with margin
            if x + windowSize.width + margin > visibleFrame.maxX {
                x = mouseLocation.x - offset - windowSize.width
            }
            if x < visibleFrame.minX + margin {
                x = visibleFrame.minX + margin
            }

            if y < visibleFrame.minY + margin {
                y = mouseLocation.y + offset
            }
            if y + windowSize.height + margin > visibleFrame.maxY {
                y = visibleFrame.maxY - windowSize.height - margin
            }

            let position = NSPoint(x: x, y: y)
            log(.info, "Positioning near mouse at: \(String(describing: position)) (mouse: \(String(describing: mouseLocation)))")
            return position

        case .topCenter:
            // Horizontal center, near top with configurable margin
            let x = visibleFrame.origin.x + (visibleFrame.width - windowSize.width) / 2
            let y = visibleFrame.maxY - windowSize.height - settings.screenEdgeMargin
            let position = NSPoint(x: x, y: y)
            log(.info, "Positioning at top center: \(String(describing: position))")
            return position

        case .bottomCenter:
            // Horizontal center, near bottom with configurable margin
            let x = visibleFrame.origin.x + (visibleFrame.width - windowSize.width) / 2
            let y = visibleFrame.minY + settings.screenEdgeMargin
            let position = NSPoint(x: x, y: y)
            log(.info, "Positioning at bottom center: \(String(describing: position))")
            return position
        }
    }

    convenience init() {
        log(.debug, "FloatingWindowController init() starting")

        let capsuleHeight: CGFloat = 40

        // Create floating window (circle initial size, non-activating)
        let window = FloatingWindow(
            contentRect: NSRect(x: 0, y: 0, width: capsuleHeight, height: capsuleHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        log(.debug, "FloatingWindow created")

        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false

        // Ensure window is visible
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.alphaValue = 1.0

        log(.debug, "Window properties set")

        // Create SwiftUI view - Liquid Glass effect is applied in SwiftUI
        let contentView = FloatingTranscriptionView()
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.autoresizingMask = [.width, .height]

        // Make hosting view fully transparent for Liquid Glass to work properly
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        window.contentView = hostingView

        // Clear backgrounds after adding to window (needed for proper layer setup)
        DispatchQueue.main.async {
            clearBackgrounds(hostingView)
        }

        log(.debug, "Content view set with Liquid Glass effect")

        // Restore saved position
        if let savedPosition = AppSettings.shared.getSavedWindowPosition() {
            window.setFrameOrigin(savedPosition)
            log(.debug, "Restored position to \(savedPosition)")
        } else {
            window.center()
            log(.debug, "Centered window")
        }

        self.init(window: window)

        log(.debug, "FloatingWindowController init() completed")

        // Save position when window moves
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.saveWindowPosition()
        }

        // Stop recording when window becomes hidden (defense-in-depth)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            self.ensureRecordingStopped()
        }
    }

    override func showWindow(_ sender: Any?) {
        log(.debug, "FloatingWindowController.showWindow() called")

        // Capture the currently active app BEFORE we activate
        previousActiveApp = NSWorkspace.shared.frontmostApplication
        if let app = previousActiveApp {
            log(.debug, "Captured previous active app: \(app.localizedName ?? "Unknown")")
        }

        guard let window = window else {
            log(.error, "Window is nil in showWindow")
            return
        }

        // Reset window to circle size (left edge anchored)
        let circleSize = NSSize(width: capsuleHeight, height: capsuleHeight)
        let currentOrigin = window.frame.origin
        window.setFrame(NSRect(origin: currentOrigin, size: circleSize), display: false)
        log(.debug, "Reset window to circle size: \(circleSize)")

        // Recalculate window position based on current mode (except for rememberLast)
        let mode = settings.windowPositionMode
        if mode != .rememberLast {
            let position = Self.calculateWindowPosition(mode: mode, windowSize: window.frame.size, settings: settings)
            window.setFrameOrigin(position)
            log(.debug, "Repositioned window using mode \(mode.rawValue) at \(String(describing: position))")
        }

        log(.debug, "Window exists, frame: \(window.frame)")

        // Show window without stealing focus (non-activating panel)
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window.animator().alphaValue = 1
        }
        log(.debug, "orderFrontRegardless called (non-activating)")

        log(.info, "Window shown - frame: \(window.frame), isVisible: \(window.isVisible)")

        // Start recording immediately so audio capture and the waveform come alive at
        // once. Context capture is injected into startRecording (it runs after audio
        // has started, before the ASR connect) so a slow or blocked capture can never
        // leave the window open with no recording — while still feeding the ASR config.
        if !viewModel.isRecording {
            viewModel.startRecording(prepareContext: { [weak self] in
                await self?.captureAndApplyContext()
            })
        }

        // Notify SwiftUI view to adjust window size (fixes size issue after empty-text close)
        NotificationCenter.default.post(name: .floatingWindowDidShow, object: nil)

        log(.info, "Floating window shown")
    }

    /// Capture and process auto-context from the previously-active app, then apply it to
    /// the view model. Invoked by `startRecording` AFTER audio capture has begun, so the
    /// capture (which may run synchronous AppleScript/AX against another app) can no
    /// longer block recording from starting. Capture logic itself is unchanged.
    @MainActor
    private func captureAndApplyContext() async {
        let rawContext = performSynchronousCapture()
        if let raw = rawContext {
            logger.debug("Processing context from \(raw.applicationName): \(raw.text.count) chars")
            let processed = await ContextProcessor.shared.process(
                text: raw.text,
                maxLength: settings.maxContextLength
            )

            let processedContext = CapturedTextContext(
                text: processed.text,
                documentPath: raw.documentPath,
                applicationName: raw.applicationName,
                bundleIdentifier: raw.bundleIdentifier,
                capturedAt: raw.capturedAt
            )

            viewModel.setCapturedContext(processedContext)
            logger.info("Context set, processed: \(processed.originalLength) -> \(processed.text.count) chars")
        } else {
            // Clear previous context to avoid using stale data
            logger.debug("No rawContext, clearing previous context")
            viewModel.setCapturedContext(nil)
        }
    }

    func hideWindow() {
        // Stop recording when window hides
        ensureRecordingStopped()

        window?.orderOut(nil)
        log(.info, "Floating window hidden, recording stopped")
    }

    private func ensureRecordingStopped() {
        // Always stop recording when window becomes hidden, regardless of how it was hidden
        Task { @MainActor in
            if viewModel.isRecording {
                log(.debug, "Stopping recording due to window hide")
                viewModel.stopRecording()
            }
        }
    }

    private func saveWindowPosition() {
        guard let window = window else { return }
        settings.saveWindowPosition(window.frame.origin)
    }

    /// Synchronously capture raw context from the previously focused application
    /// Returns the raw context without processing (processing is done in showWindow's Task)
    private func performSynchronousCapture() -> CapturedTextContext? {
        guard settings.contextCaptureEnabled else {
            log(.debug, "Context capture disabled")
            return nil
        }

        // Log the current frontmost app at the moment of capture
        let currentFrontmost = NSWorkspace.shared.frontmostApplication
        log(.debug, "performSynchronousCapture - frontmost app: \(currentFrontmost?.localizedName ?? "nil")")

        // Check accessibility permission
        guard AccessibilityTextCapture.shared.checkPermission(prompt: false) else {
            log(.warning, "Accessibility permission not granted for context capture")
            return nil
        }

        // Use the previously captured app info if available (more reliable for browsers)
        // This avoids timing issues where the focused app changes during capture
        if let prevApp = previousActiveApp,
           let bundleId = prevApp.bundleIdentifier,
           let appName = prevApp.localizedName {
            log(.debug, "Using previousActiveApp for capture: \(appName) (\(bundleId))")
            if let context = AccessibilityTextCapture.shared.captureFromApp(bundleId: bundleId, appName: appName) {
                if let path = context.documentPath {
                    let filename = (path as NSString).lastPathComponent
                    log(.info, "Captured \(context.text.count) chars from \(context.applicationName) [\(filename)]")
                } else {
                    log(.info, "Captured \(context.text.count) chars from \(context.applicationName)")
                }
                return context
            }
        } else {
            // Fall back to generic capture if no previous app info
            if let context = AccessibilityTextCapture.shared.captureFromFocusedApp() {
                if let path = context.documentPath {
                    let filename = (path as NSString).lastPathComponent
                    log(.info, "Captured \(context.text.count) chars from \(context.applicationName) [\(filename)]")
                } else {
                    log(.info, "Captured \(context.text.count) chars from \(context.applicationName)")
                }
                return context
            }
        }

        log(.info, "No context captured from previous app")
        return nil
    }

    /// Finish recording, copy to clipboard, auto-paste, and dismiss the window
    func finishRecordingAndDismiss() {
        Task { @MainActor in
            let success = await viewModel.finishRecordingAndCopy()
            if success {
                performAutoPasteIfEnabled()
            }
            hideWindow()
        }
    }

    func performAutoPasteIfEnabled() {
        guard settings.autoPasteAfterClose else { return }
        guard !viewModel.transcribedText.isEmpty else { return }

        log(.info, "Performing auto-paste (previous app stays active)")

        // Brief delay for pasteboard to settle, then simulate Cmd+V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.simulatePasteKeystroke()
        }
    }

    private func simulatePasteKeystroke() {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            log(.error, "Failed to create CGEventSource for paste")
            return
        }

        // Key code for 'V' is 9
        let vKeyCode: CGKeyCode = 9

        // Create key down event with Cmd modifier
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true) else {
            log(.error, "Failed to create key down event")
            return
        }
        keyDown.flags = .maskCommand

        // Create key up event with Cmd modifier
        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            log(.error, "Failed to create key up event")
            return
        }
        keyUp.flags = .maskCommand

        // Post events
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        log(.info, "Auto-paste keystroke simulated (Cmd+V)")
    }
}

// MARK: - Floating Window Class

/// A non-activating panel that never steals focus from other applications
class FloatingWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Waveform View

struct WaveformView: View {
    let audioLevels: [Float]
    var compact: Bool = false
    private let barCount = 5

    // Arc-shaped scale: bars inscribe a circle, center tallest, edges shortest
    private let arcScale: [CGFloat] = [0.6, 0.92, 1.0, 0.92, 0.6]

    var body: some View {
        HStack(spacing: compact ? 2 : 3) {
            ForEach(0..<barCount, id: \.self) { index in
                WaveformBar(level: barLevel(for: index), compact: compact)
            }
        }
        .frame(height: compact ? 21 : 36)
    }

    private func barLevel(for index: Int) -> CGFloat {
        let minHeight: CGFloat = 0.15
        let level = index < audioLevels.count ? audioLevels[index] : 0
        let scale = index < arcScale.count ? arcScale[index] : 1.0
        return max(minHeight * scale, CGFloat(level) * scale)
    }
}

struct WaveformBar: View {
    let level: CGFloat
    var compact: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: compact ? 1 : 1.5)
            .fill(Color.primary.opacity(0.8))
            .frame(width: compact ? 2.5 : 3, height: max(compact ? 3 : 4, level * (compact ? 18 : 30)))
            .animation(.easeInOut(duration: 0.12), value: level)
    }
}

// MARK: - Floating Transcription View (Capsule)

struct FloatingTranscriptionView: View {
    @ObservedObject private var viewModel = TranscriptionViewModel.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var isHovering = false
    @State private var displayedText = ""
    @State private var typewriterTimer: Timer?
    @State private var currentMaxWidth: CGFloat = 0
    @State private var reachedMaxWidth = false

    private let capsuleHeight: CGFloat = 40
    private let maxCapsuleWidth: CGFloat = 400
    private let waveformZoneWidth: CGFloat = 28
    private let submitZoneWidth: CGFloat = 28
    private let horizontalPadding: CGFloat = 6
    private let typewriterInterval: TimeInterval = 0.03

    private var glassTintColor: Color? {
        switch settings.glassTintStyle {
        case .clear:  return nil
        case .accent: return .accentColor
        case .red:    return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green:  return .green
        case .blue:   return .blue
        case .purple: return .purple
        case .pink:   return .pink
        }
    }

    private var hasText: Bool {
        !displayedText.isEmpty
    }

    private var showSubmit: Bool {
        !viewModel.transcribedText.isEmpty && viewModel.isRecording
    }

    /// Left edge of content area (after waveform + divider)
    private var contentLeading: CGFloat {
        horizontalPadding + waveformZoneWidth + 1
    }

    var body: some View {
        Color.clear
            .overlay {
                // Waveform / close zone — use GeometryReader to pin position
                GeometryReader { geo in
                    leftZone
                        .frame(width: waveformZoneWidth, height: capsuleHeight)
                        .position(
                            x: horizontalPadding + waveformZoneWidth / 2,
                            y: geo.size.height / 2
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if isHovering {
                                closeWindow()
                            }
                        }
                }
            }
            .overlay(alignment: .leading) {
                // Divider + text + submit
                HStack(spacing: 0) {
                    // Divider
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(Color.primary.opacity(0.15))
                        .frame(width: 1, height: 16)

                    // Text area
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: reachedMaxWidth ? .trailing : .leading) {
                            Text(displayedText)
                                .font(.system(size: 14))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .clipped()
                        .padding(.horizontal, 6)

                    // Submit arrow
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: showSubmit ? 24 : 0, height: showSubmit ? 24 : 0)
                        .background(Circle().fill(Color.primary.opacity(0.1)))
                        .opacity(showSubmit ? 1 : 0)
                        .padding(.trailing, showSubmit ? horizontalPadding : 0)
                        .contentShape(Circle())
                        .onTapGesture {
                            finishRecording()
                        }
                }
                .padding(.leading, contentLeading)
                .opacity(hasText ? 1 : 0)
            }
        .frame(height: capsuleHeight)
        .frame(minWidth: capsuleHeight)
        .background {
            if let color = glassTintColor {
                Capsule().fill(color.opacity(0.85))
            }
        }
        .glassEffect(glassTintColor != nil ? .clear : .regular, in: Capsule())
        .clipShape(Capsule())
        .environment(\.colorScheme, glassTintColor != nil ? .dark : .light)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .animation(.easeInOut(duration: 0.2), value: hasText)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isRecording)
        .onAppear {
            DispatchQueue.main.async {
                adjustWindowSize()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .floatingWindowDidShow)) { _ in
            typewriterTimer?.invalidate()
            displayedText = ""
            currentMaxWidth = 0
            reachedMaxWidth = false
            DispatchQueue.main.async {
                adjustWindowSize()
            }
        }
        .onChange(of: viewModel.transcribedText) {
            startTypewriter()
        }
        .onChange(of: displayedText) {
            DispatchQueue.main.async {
                adjustWindowSize()
            }
        }
    }

    // MARK: - Left Zone (waveform / close)

    @ViewBuilder
    private var leftZone: some View {
        ZStack {
            // Waveform (visible when not hovering and recording)
            if viewModel.isRecording {
                WaveformView(audioLevels: viewModel.audioLevels, compact: true)
                    .opacity(isHovering ? 0 : 1)
            }

            // Processing spinner
            if viewModel.isProcessing {
                ProgressView()
                    .controlSize(.small)
                    .opacity(isHovering ? 0 : 1)
            }

            // Close icon (visible on hover)
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.secondary)
                .opacity(isHovering ? 1 : 0)
        }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
    }

    // MARK: - Window Size

    // MARK: - Typewriter Effect

    private func startTypewriter() {
        typewriterTimer?.invalidate()
        let target = viewModel.transcribedText

        // If target is shorter (ASR replaced text), snap immediately
        if target.count < displayedText.count || !target.hasPrefix(displayedText) {
            displayedText = target
            return
        }

        // Already caught up
        if displayedText == target { return }

        // Reveal characters one by one
        typewriterTimer = Timer.scheduledTimer(withTimeInterval: typewriterInterval, repeats: true) { [self] timer in
            let target = viewModel.transcribedText

            // Handle text replacement mid-typewriter
            if target.count < displayedText.count || !target.hasPrefix(displayedText) {
                displayedText = target
                timer.invalidate()
                return
            }

            if displayedText.count < target.count {
                let nextIndex = target.index(target.startIndex, offsetBy: displayedText.count)
                displayedText = String(target[...nextIndex])
            } else {
                timer.invalidate()
            }
        }
    }

    // MARK: - Window Size

    @State private var isAdjustingSize = false

    private func adjustWindowSize() {
        guard !isAdjustingSize else { return }
        guard let window = NSApp.windows.first(where: { $0 is FloatingWindow }) else { return }

        isAdjustingSize = true
        defer { isAdjustingSize = false }

        let text = displayedText

        let centerAnchored = {
            let mode = AppSettings.shared.windowPositionMode
            return mode == .topCenter || mode == .bottomCenter
        }()

        if text.isEmpty {
            let circleSize = capsuleHeight
            let currentFrame = window.frame
            let newX = centerAnchored
                ? currentFrame.midX - circleSize / 2
                : currentFrame.origin.x
            window.setFrame(NSRect(
                x: newX,
                y: currentFrame.origin.y,
                width: circleSize,
                height: circleSize
            ), display: false)
            return
        }

        // Capsule mode: calculate width based on text
        let font = NSFont.systemFont(ofSize: 14)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let attributedString = NSAttributedString(string: text, attributes: attributes)
        let textWidth = attributedString.size().width

        // divider (1) + padding around text (6+6)
        let fixedWidth = horizontalPadding + waveformZoneWidth + 1 + 6 + 6 + submitZoneWidth + horizontalPadding
        let desiredWidth = fixedWidth + textWidth
        let candidateWidth = min(max(desiredWidth, capsuleHeight + 60), maxCapsuleWidth)

        // Only grow, never shrink
        let finalWidth = max(candidateWidth, currentMaxWidth)
        guard finalWidth != window.frame.width else { return }
        currentMaxWidth = finalWidth

        if finalWidth >= maxCapsuleWidth && !reachedMaxWidth {
            reachedMaxWidth = true
        }

        let currentFrame = window.frame
        let newX = centerAnchored
            ? currentFrame.midX - finalWidth / 2
            : currentFrame.origin.x

        let newFrame = NSRect(
            x: newX,
            y: currentFrame.origin.y,
            width: finalWidth,
            height: capsuleHeight
        )

        // Use NSWindow's built-in animate to avoid re-entrant display cycle issues
        // with NSAnimationContext + window.animator().setFrame(display: true)
        window.setFrame(newFrame, display: false, animate: true)
    }

    private func findController() -> FloatingWindowController? {
        NSApp.windows
            .first(where: { $0 is FloatingWindow })?
            .windowController as? FloatingWindowController
    }

    private func closeWindow() {
        findController()?.hideWindow()
    }

    private func finishRecording() {
        findController()?.finishRecordingAndDismiss()
    }
}

#Preview {
    FloatingTranscriptionView()
        .frame(width: 400, height: 80)
}

// MARK: - Notification Extensions

extension Notification.Name {
    static let floatingWindowDidShow = Notification.Name("floatingWindowDidShow")
}
