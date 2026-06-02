# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Talkie is a macOS application for real-time speech-to-text transcription using the Seed ASR API. It features a native SwiftUI interface and implements the Seed ASR binary WebSocket protocol for streaming audio transcription.

## Build Commands

```bash
./build.sh          # Build (Debug) and see logs
./release.sh        # Build (Release) and install to /Applications
```

**Gotcha**: `build.sh` may report success even when compilation fails (it checks for `.app` existence, which persists from previous successful builds). To verify a real build, check for `BUILD SUCCEEDED` in the xcodebuild output.

## Project Structure

```
Talkie/
├── TalkieApp.swift               # App entry point
├── AppDelegate.swift               # Menu bar app coordinator, global hotkey, push-to-talk
├── ContentView.swift               # Main settings/status UI
├── FloatingWindow.swift            # Capsule-shaped floating transcription panel (Liquid Glass)
├── SettingsWindow.swift            # Settings window with sidebar navigation
├── TranscriptionViewModel.swift    # View model coordinator
├── ASRClient.swift                 # WebSocket ASR client (Seed ASR binary protocol)
├── AudioRecorder.swift             # Audio capture with FFT level analysis
├── AccessibilityTextCapture.swift  # AX API context capture from other apps
├── ContextProcessor.swift          # Context text cleaning/truncation
├── DocumentContentReader.swift     # File content reading for context
├── AudioDeviceManager.swift        # Input device enumeration
├── KeyboardShortcutNames.swift     # KeyboardShortcuts library bindings
└── Utilities.swift                 # Models, constants, extensions
```

## Xcode Project

Uses folder-based file membership (no pbxproj references). Adding or deleting `.swift` files in `Talkie/` automatically includes/excludes them from the build.

## Logging System

Use the global `log()` function defined in `Utilities.swift`. This outputs to stderr so logs appear in the terminal when running the app.

```swift
log(.debug, "Payload compressed: \(size) bytes")
log(.info, "Connecting to Seed ASR...")
log(.warning, "Connection retry attempt \(count)")
log(.error, "Failed to connect: \(error)")
```

**Log levels**:
- **`.debug`** - Detailed debugging information
- **`.info`** - Important state changes and milestones
- **`.warning`** - Potential issues that don't break functionality
- **`.error`** - Critical errors that prevent functionality

**Conventions**: Use plain text without emojis. Format as "Action/State: details". Keep messages concise and include relevant metrics.

## Creating Worktrees

To create a worktree, put the worktree in .claude/worktrees
