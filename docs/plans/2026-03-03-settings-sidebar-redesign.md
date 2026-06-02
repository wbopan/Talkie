# Settings Sidebar Redesign Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the tabbed settings UI with a modern macOS sidebar + content layout using `NavigationSplitView` with auto-save.

**Architecture:** Single-file rewrite of `SettingsWindow.swift`. The `SettingsView` root view switches from `TabView` to `NavigationSplitView` with a sidebar enum-driven list. All temp state variables are removed; settings bind directly to `AppSettings.shared`. The window controller is updated for opaque background and larger size.

**Tech Stack:** SwiftUI `NavigationSplitView`, macOS 15+

---

### Task 1: Update SettingsWindowController for sidebar layout

**Files:**
- Modify: `Talkie/SettingsWindow.swift:14-43` (SettingsWindowController)

**Step 1: Update window configuration**

Replace the current `SettingsWindowController.convenience init()` with:

```swift
class SettingsWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Settings"
        window.center()
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 700, height: 500))
        window.minSize = NSSize(width: 550, height: 400)

        let contentView = SettingsView()
        window.contentView = NSHostingView(rootView: contentView)

        self.init(window: window)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
    }
}
```

Key changes: removed `titlebarAppearsTransparent`, `isOpaque = false`, `backgroundColor = .clear`, `fullSizeContentView`. Added `.miniaturizable`, `.resizable`. Increased size to 700x500.

**Step 2: Build and verify**

Run: `./build.sh`
Expected: Compiles successfully

**Step 3: Commit**

```
feat: update settings window controller for sidebar layout
```

---

### Task 2: Add sidebar navigation enum and rewrite SettingsView

**Files:**
- Modify: `Talkie/SettingsWindow.swift:45-129` (SettingsView)

**Step 1: Add SettingsPane enum above SettingsView**

```swift
enum SettingsPane: String, CaseIterable, Identifiable {
    case api
    case context
    case controls
    case about

    var id: String { rawValue }

    var label: String {
        switch self {
        case .api: return "API"
        case .context: return "Context"
        case .controls: return "Controls"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .api: return "key.fill"
        case .context: return "text.bubble"
        case .controls: return "command"
        case .about: return "info.circle"
        }
    }
}
```

**Step 2: Rewrite SettingsView to use NavigationSplitView**

Replace the entire `SettingsView` with:

```swift
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var selectedPane: SettingsPane = .api

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selectedPane) { pane in
                Label(pane.label, systemImage: pane.icon)
                    .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedPane {
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
```

Note: the temp state variables (`tempAppKey`, `tempAccessKey`, `tempContext`), `saveSettings()`, `closeWindow()`, and the bottom button bar are all removed.

**Step 3: Build and verify**

Run: `./build.sh`
Expected: Compile errors in `APISettingsTab` and `ContextSettingsTab` (they still expect `@Binding` params). This is expected — fixed in next task.

**Step 4: Commit**

```
feat: add sidebar navigation with NavigationSplitView
```

---

### Task 3: Update APISettingsTab to bind directly to AppSettings

**Files:**
- Modify: `Talkie/SettingsWindow.swift:131-184` (APISettingsTab)

**Step 1: Rewrite APISettingsTab**

Replace the struct to take `ObservedObject` settings instead of `@Binding`:

```swift
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
```

Note: removed `.scrollContentBackground(.hidden)` since we now use the standard window background.

**Step 2: Build and verify**

Run: `./build.sh`
Expected: May still have errors in ContextSettingsTab — fixed next.

**Step 3: Commit**

```
refactor: bind APISettingsTab directly to AppSettings
```

---

### Task 4: Update ContextSettingsTab to bind directly to AppSettings

**Files:**
- Modify: `Talkie/SettingsWindow.swift:186-229` (ContextSettingsTab)

**Step 1: Rewrite ContextSettingsTab**

Replace the struct to use `@ObservedObject` instead of `@Binding var context`:

```swift
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
```

Note: removed `.scrollContentBackground(.hidden)` for standard window background.

**Step 2: Also remove `.scrollContentBackground(.hidden)` from ControlsSettingsTab**

In `ControlsSettingsTab`, remove the `.scrollContentBackground(.hidden)` modifier from the `Form`.

**Step 3: Build and verify**

Run: `./build.sh`
Expected: Compiles and runs successfully

**Step 4: Commit**

```
refactor: bind ContextSettingsTab directly to AppSettings
```

---

### Task 5: Update SettingsView onChange handler and update config on edit

**Files:**
- Modify: `Talkie/SettingsWindow.swift` (SettingsView)

**Step 1: Add config update on settings change**

Since we removed the explicit `saveSettings()` call that ran `viewModel.updateConfig(settings:)`, we need to ensure the view model config stays in sync. Add an `onChange` to the `NavigationSplitView` detail view:

```swift
// Inside SettingsView body, add to the NavigationSplitView:
.onChange(of: settings.appKey) { _, _ in updateConfig() }
.onChange(of: settings.accessKey) { _, _ in updateConfig() }
.onChange(of: settings.context) { _, _ in updateConfig() }
```

And add a helper:

```swift
private func updateConfig() {
    TranscriptionViewModel.shared.updateConfig(settings: settings)
}
```

**Step 2: Build and verify**

Run: `./build.sh`
Expected: Compiles successfully

**Step 3: Manual test**

Open the app, open Settings. Verify:
- Sidebar shows 4 items with icons
- Clicking each item switches the detail pane
- Editing API keys auto-saves (close and reopen to verify)
- Context text area works
- Controls tab works as before
- About tab displays correctly

**Step 4: Commit**

```
feat: complete settings sidebar redesign with auto-save
```

---

### Task 6: Update Preview

**Files:**
- Modify: `Talkie/SettingsWindow.swift` (bottom Preview section)

**Step 1: Update the preview**

```swift
#Preview {
    SettingsView()
        .frame(width: 700, height: 500)
}
```

**Step 2: Build**

Run: `./build.sh`
Expected: Clean build

**Step 3: Commit**

```
chore: update settings preview dimensions
```
