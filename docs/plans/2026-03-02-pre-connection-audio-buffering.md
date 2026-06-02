# Pre-connection Audio Buffering Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Allow audio recording to start immediately when the user presses record, buffering audio data until the WebSocket connection is established, then flushing the buffer.

**Architecture:** Add a pre-connection audio buffer in TranscriptionViewModel. Start audio recording and ASR connection concurrently instead of sequentially. Audio callback stores data in buffer when not connected, sends directly when connected. On connection success, flush buffer before switching to streaming mode.

**Tech Stack:** Swift, SwiftUI, AVFoundation (existing stack, no new dependencies)

---

### Task 1: Add buffer properties to TranscriptionViewModel

**Files:**
- Modify: `Talkie/TranscriptionViewModel.swift:44-45`

**Step 1: Add properties after `audioActuallyStarted`**

```swift
private var preConnectionAudioBuffer: [Data] = []
private var preConnectionBufferSize = 0  // Track total bytes for cap enforcement
private var isASRConnected = false
private let maxBufferBytes = 160_000  // 5 seconds at 16kHz/16-bit/mono
```

**Step 2: Build to verify no compilation errors**

Run: `./build.sh`
Expected: Build succeeds

**Step 3: Commit**

---

### Task 2: Modify sendAudioToASR to support buffering

**Files:**
- Modify: `Talkie/TranscriptionViewModel.swift` — method `sendAudioToASR()` (line ~462)

**Step 1: Replace `sendAudioToASR` with buffering version**

Current code:
```swift
private func sendAudioToASR(_ audioData: Data) async {
    guard isRecording else { return }

    do {
        try await asrClient.sendAudioData(audioData)
    } catch {
        log(.error, "Failed to send audio: \(error)")
        errorMessage = "Audio streaming error: \(error.localizedDescription)"
    }
}
```

New code:
```swift
private func sendAudioToASR(_ audioData: Data) async {
    guard isRecording else { return }

    if isASRConnected {
        // Connected — send directly
        do {
            try await asrClient.sendAudioData(audioData)
        } catch {
            log(.error, "Failed to send audio: \(error)")
            errorMessage = "Audio streaming error: \(error.localizedDescription)"
        }
    } else {
        // Not connected yet — buffer the data
        preConnectionAudioBuffer.append(audioData)
        preConnectionBufferSize += audioData.count

        // Enforce 5-second cap: drop oldest segments
        while preConnectionBufferSize > maxBufferBytes, !preConnectionAudioBuffer.isEmpty {
            let removed = preConnectionAudioBuffer.removeFirst()
            preConnectionBufferSize -= removed.count
        }

        log(.debug, "Buffered audio: \(audioData.count)B, total: \(preConnectionBufferSize)B (\(preConnectionAudioBuffer.count) segments)")
    }
}
```

**Step 2: Build to verify**

Run: `./build.sh`
Expected: Build succeeds

**Step 3: Commit**

---

### Task 3: Add flushAudioBuffer method

**Files:**
- Modify: `Talkie/TranscriptionViewModel.swift` — add new method near `sendAudioToASR`

**Step 1: Add flushAudioBuffer after sendAudioToASR**

```swift
/// Flush pre-connection audio buffer to ASR
private func flushAudioBuffer() async {
    let segments = preConnectionAudioBuffer
    let totalBytes = preConnectionBufferSize
    preConnectionAudioBuffer.removeAll()
    preConnectionBufferSize = 0

    guard !segments.isEmpty else { return }

    log(.info, "Flushing audio buffer: \(segments.count) segments, \(totalBytes) bytes")

    for segment in segments {
        do {
            try await asrClient.sendAudioData(segment)
        } catch {
            log(.error, "Failed to flush buffered audio: \(error)")
            break
        }
    }

    log(.info, "Audio buffer flushed")
}
```

**Step 2: Build to verify**

Run: `./build.sh`
Expected: Build succeeds

**Step 3: Commit**

---

### Task 4: Restructure startRecording to run audio and connection concurrently

**Files:**
- Modify: `Talkie/TranscriptionViewModel.swift` — method `startRecording()` (line ~155)

**Step 1: Modify the async task body inside startRecording**

The key change: after mic permission is granted, start audio recording FIRST (its callback will buffer data), then connect to ASR, then set `isASRConnected = true` and flush.

Replace the section from `// Start listening to ASR results` through `recordingState = .recording` with:

```swift
// Reset buffer state
isASRConnected = false
preConnectionAudioBuffer.removeAll()
preConnectionBufferSize = 0

// Start audio recording FIRST (data will be buffered until ASR connects)
try await audioRecorder.startRecording(
    callback: { [weak self] audioData in
        Task {
            await self?.sendAudioToASR(audioData)
        }
    },
    levelCallback: { [weak self] levels in
        self?.updateAudioLevels(levels)
    },
    selectedMicrophoneUID: AppSettings.shared.selectedMicrophoneUID
)

// Mark that audio recording was actually started
audioActuallyStarted = true
statusMessage = "Connecting..."

// Check for cancellation before connecting
try Task.checkCancellation()

// Connect to ASR service (audio is being buffered in the meantime)
try await asrClient.connect(config: config)
statusMessage = "Connected"

// Check for cancellation after connecting
try Task.checkCancellation()

// Start listening to ASR results
Task {
    await listenToASRResults()
}

// Mark connected and flush buffered audio
isASRConnected = true
await flushAudioBuffer()

// Check state after setup — stopRecording() may have been called during flush
guard recordingState == .connecting else {
    log(.info, "State changed during setup (\(recordingState)), stopTask will handle cleanup")
    return
}

// Transition to recording state
recordingState = .recording
statusMessage = "Recording..."
log(.info, "Transcription session started")
```

This replaces lines 228-268 of the current `startRecording()`. The full request packet, mic permission, and cancellation checks before this section remain unchanged.

**Step 2: Build to verify**

Run: `./build.sh`
Expected: Build succeeds

**Step 3: Commit**

---

### Task 5: Clean up buffer state on stop and error paths

**Files:**
- Modify: `Talkie/TranscriptionViewModel.swift`

**Step 1: Reset buffer in stopRecording's stopTask closure**

In the `stopTask = Task { ... }` block inside `stopRecording()`, add buffer cleanup alongside the existing `audioActuallyStarted = false` reset (around line 353):

```swift
// Reset buffer state
isASRConnected = false
preConnectionAudioBuffer.removeAll()
preConnectionBufferSize = 0
```

**Step 2: Reset buffer in performCleanup**

In `performCleanup()`, add the same reset:

```swift
isASRConnected = false
preConnectionAudioBuffer.removeAll()
preConnectionBufferSize = 0
```

**Step 3: Reset buffer in error/cancellation catch blocks**

In the `catch is CancellationError` and `catch` blocks of `startRecording()`, add:

```swift
isASRConnected = false
preConnectionAudioBuffer.removeAll()
preConnectionBufferSize = 0
```

**Step 4: Build to verify**

Run: `./build.sh`
Expected: Build succeeds

**Step 5: Commit**

---

### Task 6: Manual integration test

**Step 1: Build and run**

Run: `./build.sh`
Expected: App launches, UI appears

**Step 2: Test normal recording flow**

1. Click record — should see "Connecting..." with audio level animation immediately
2. Connection establishes — should see "Recording..."
3. Speak and verify transcription works
4. Stop recording — should see final result

**Step 3: Test rapid start/stop**

1. Click record then immediately stop — should not crash
2. Click record, wait for connection, stop — should work normally

**Step 4: Final commit with all changes**
