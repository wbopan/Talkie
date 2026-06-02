//
//  SettingsWindow.swift
//  Seedling
//
//  Settings panel with API configuration and hotkey recorder
//

import Cocoa
import SwiftUI
import LaunchAtLogin
import KeyboardShortcuts

// MARK: - Settings Window Controller

class SettingsWindowController: NSWindowController, NSWindowDelegate {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 550, height: 400)

        let contentView = SettingsView()
        window.contentView = NSHostingView(rootView: contentView)

        self.init(window: window)
        window.delegate = self
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Settings Pane

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, api, context, controls, about

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general:  return "General"
        case .api:      return "API"
        case .context:  return "Context"
        case .controls: return "Controls"
        case .about:    return "About"
        }
    }

    var icon: String {
        switch self {
        case .general:  return "gearshape.fill"
        case .api:      return "key.fill"
        case .context:  return "text.bubble.fill"
        case .controls: return "command"
        case .about:    return "info.circle.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .general:  return .gray
        case .api:      return .orange
        case .context:  return .blue
        case .controls: return .pink
        case .about:    return .purple
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var selectedPane: SettingsPane = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selectedPane) { pane in
                Label {
                    Text(pane.label)
                } icon: {
                    Image(systemName: pane.icon)
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(pane.iconColor.gradient)
                        )
                }
                .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .onDisappear {
            TranscriptionViewModel.shared.updateConfig(settings: settings)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedPane {
        case .general:
            GeneralSettingsTab(settings: settings)
        case .api:
            APISettingsTab(settings: settings)
        case .context:
            ContextSettingsTab(settings: settings)
        case .controls:
            ControlsSettingsTab(settings: settings)
        case .about:
            AboutTab()
        }
    }
}

// MARK: - API Settings Tab

struct APISettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                TextField("App Key:", text: $settings.appKey)
                    .textFieldStyle(.roundedBorder)

                SecureField("Access Key:", text: $settings.accessKey)
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("Seed ASR Credentials")
                    .font(.headline)
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("How to get credentials:")
                        .fontWeight(.medium)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. Open the Volcengine Speech Console")
                        Text("2. Select \"旧版控制台\" (Legacy Console) in the upper left")
                        Text("3. Navigate to \"语音识别大模型\" → \"流式语音识别大模型\"")
                        Text("4. Copy your App ID and Access Token")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)

                    Button {
                        if let url = URL(string: "https://console.volcengine.com/speech/app") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.up.right.square")
                            Text("Open Volcengine Console")
                        }
                    }
                    .buttonStyle(.link)
                }
            } header: {
                Text("Setup Guide")
                    .font(.headline)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Context Settings Tab

struct ContextSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Provide persistent context that always applies. This has priority over auto-captured content.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextEditor(text: $settings.context)
                        .font(.system(.body))
                        .frame(height: 100)
                        .scrollContentBackground(.hidden)
                        .background(Color(NSColor.textBackgroundColor).opacity(0.5))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )

                    // Character count
                    HStack {
                        Spacer()
                        Text("\(settings.context.count) / \(settings.maxContextLength)")
                            .font(.caption2)
                            .foregroundColor(settings.context.count > settings.maxContextLength ? .red : .secondary)
                    }
                }
            } header: {
                Text("User Context")
                    .font(.headline)
            }

            ContextCaptureSection(settings: settings)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Context Capture Section

struct ContextCaptureSection: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var viewModel = TranscriptionViewModel.shared
    @State private var hasAccessibilityPermission = false

    var body: some View {
        Section {
            Toggle("Enable context capture", isOn: $settings.contextCaptureEnabled.animation())
                .onChange(of: settings.contextCaptureEnabled) { _, newValue in
                    if newValue {
                        _ = AccessibilityTextCapture.shared.checkPermission(prompt: true)
                        updateAccessibilityStatus()
                    }
                }

            if settings.contextCaptureEnabled {
                // Accessibility permission status
                HStack {
                    Image(systemName: hasAccessibilityPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(hasAccessibilityPermission ? .green : .orange)

                    Text(hasAccessibilityPermission ? "Accessibility permission granted" : "Accessibility permission required")
                        .font(.caption)

                    Spacer()

                    if !hasAccessibilityPermission {
                        Button("Open Settings") {
                            openAccessibilitySettings()
                        }
                        .font(.caption)
                    }
                }

                HStack {
                    Text("Max context length:")

                    Spacer()

                    Picker("", selection: $settings.maxContextLength) {
                        Text("500").tag(500)
                        Text("1000").tag(1000)
                        Text("2000").tag(2000)
                        Text("5000").tag(5000)
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }

                // Read-only auto-captured context display
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Auto-captured Context")
                            .font(.caption)
                            .fontWeight(.medium)
                        if !viewModel.capturedContextSource.isEmpty {
                            Text("from \(viewModel.capturedContextSource)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text("\(viewModel.capturedContextText.count) chars")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    if viewModel.capturedContextText.isEmpty {
                        Text("No context captured yet. Use the shortcut to activate and capture context from another app.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .italic()
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(NSColor.textBackgroundColor).opacity(0.3))
                            .cornerRadius(6)
                    } else {
                        // Read-only text display
                        ScrollView {
                            Text(viewModel.capturedContextText)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 120)
                        .padding(8)
                        .background(Color(NSColor.textBackgroundColor).opacity(0.3))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                    }
                }
            }
        } header: {
            Text("Auto Context Capture")
                .font(.headline)
        } footer: {
            Text("When enabled, text from the previous application is captured on each activation and appended after your user context (up to the max length limit).")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .onAppear {
            updateAccessibilityStatus()
        }
    }

    private func updateAccessibilityStatus() {
        hasAccessibilityPermission = AccessibilityTextCapture.shared.checkPermission(prompt: false)
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - General Settings Tab

struct GeneralSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var deviceManager = AudioDeviceManager.shared

    var body: some View {
        Form {
            Section {
                LaunchAtLogin.Toggle("Launch at login")
                Toggle("Show menu bar icon", isOn: $settings.showMenuBarIcon)
                if !settings.showMenuBarIcon {
                    Text("Open Seedling from Applications or Spotlight to access settings.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("General")
                    .font(.headline)
            }

            Section {
                Picker("Microphone:", selection: $settings.selectedMicrophoneUID) {
                    Text("System Default").tag("")
                    ForEach(deviceManager.inputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
            } header: {
                Text("Microphone")
                    .font(.headline)
            } footer: {
                Text("Changes take effect on next recording.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Picker("Glass tint:", selection: $settings.glassTintStyle) {
                    ForEach(GlassTintStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }

                Picker("Window position:", selection: $settings.windowPositionMode) {
                    ForEach(WindowPositionMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                if settings.windowPositionMode == .topCenter || settings.windowPositionMode == .bottomCenter {
                    HStack {
                        Text("Edge margin:")

                        Slider(
                            value: $settings.screenEdgeMargin,
                            in: 20...200,
                            step: 10
                        )

                        Text("\(Int(settings.screenEdgeMargin))pt")
                            .frame(width: 45)
                            .monospacedDigit()
                    }
                }
            } header: {
                Text("Appearance")
                    .font(.headline)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Controls Settings Tab

struct ControlsSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Shortcut:")
                        .fixedSize()
                    Spacer()
                    KeyboardShortcuts.Recorder("", name: .toggleWindow)
                        .fixedSize()
                }
            } header: {
                Text("Global Shortcut")
                    .font(.headline)
            } footer: {
                Text("Show or hide the transcription window")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            PushToTalkSection(settings: settings)

            Section {
                Toggle("Auto-paste after finish", isOn: $settings.autoPasteAfterClose)
                Toggle("Remove trailing punctuation", isOn: $settings.removeTrailingPunctuation)
            } header: {
                Text("Behavior")
                    .font(.headline)
            } footer: {
                Text("Automatically paste transcribed text into the previous application when using the finish action. Remove trailing punctuation removes both full-width and half-width punctuation marks from the end of the transcribed text.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Push to Talk Section

struct PushToTalkSection: View {
    @ObservedObject var settings: AppSettings
    @State private var hasAccessibilityPermission = false

    var body: some View {
        Section {
            Toggle("Enable Push to Talk", isOn: configBinding(\.enabled, onSet: { newValue in
                if newValue {
                    _ = ModifierKeyMonitor.checkAccessibilityPermission(prompt: true)
                    updateAccessibilityStatus()
                }
            }))

            if settings.longPressConfig.enabled {
                // Accessibility permission status
                HStack {
                    Image(systemName: hasAccessibilityPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(hasAccessibilityPermission ? .green : .orange)

                    Text(hasAccessibilityPermission ? "Accessibility permission granted" : "Accessibility permission required")
                        .font(.caption)

                    Spacer()

                    if !hasAccessibilityPermission {
                        Button("Open Settings") {
                            openAccessibilitySettings()
                        }
                        .font(.caption)
                    }
                }

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

                HStack {
                    Text("Hold duration:")

                    Slider(
                        value: configBinding(\.minimumPressDuration),
                        in: 0.1...1.0,
                        step: 0.1
                    )

                    Text(String(format: "%.1fs", settings.longPressConfig.minimumPressDuration))
                        .frame(width: 40)
                        .monospacedDigit()
                }

                Toggle("Require double-tap", isOn: configBinding(\.requireDoubleTap))
            }
        } header: {
            Text("Push to Talk")
                .font(.headline)
        } footer: {
            Text("Hold a modifier key to start dictation. Release to finish and auto-paste. When double-tap is required, tap the key once first, then hold. Requires Accessibility permission.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .onAppear {
            updateAccessibilityStatus()
        }
    }

    /// Create a binding to a LongPressConfig property with optional side effect
    private func configBinding<T>(_ keyPath: WritableKeyPath<LongPressConfig, T>, onSet: ((T) -> Void)? = nil) -> Binding<T> {
        Binding(
            get: { settings.longPressConfig[keyPath: keyPath] },
            set: { newValue in
                var config = settings.longPressConfig
                config[keyPath: keyPath] = newValue
                settings.longPressConfig = config
                onSet?(newValue)
            }
        )
    }

    private func updateAccessibilityStatus() {
        hasAccessibilityPermission = ModifierKeyMonitor.checkAccessibilityPermission(prompt: false)
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - About Tab

struct AboutTab: View {
    private let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Seedling"
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image("AboutIcon")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
                .foregroundStyle(Color.accentColor)

            Text(appName)
                .font(.title)
                .fontWeight(.semibold)

            Text("Version \(appVersion)")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("Real-time speech-to-text transcription using the Seed ASR API")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    SettingsView()
        .frame(width: 700, height: 500)
}
