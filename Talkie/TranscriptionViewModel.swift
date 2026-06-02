//
//  TranscriptionViewModel.swift
//  Seedling
//
//  View model coordinating recording and transcription
//

import Foundation
import SwiftUI
import AVFoundation
import Combine
import AppKit  // For NSPasteboard

/// View model for managing transcription state and coordinating services
@MainActor
class TranscriptionViewModel: ObservableObject {
    // MARK: - Singleton

    static let shared = TranscriptionViewModel()

    // MARK: - Published Properties

    @Published var transcribedText = ""
    @Published var errorMessage: String?
    @Published var statusMessage = "Ready"
    @Published var audioLevels: [Float] = [0, 0, 0, 0, 0]
    @Published var capturedContextText: String = ""  // For UI display (read-only)
    @Published var capturedContextSource: String = ""  // App name for display

    private let levelSmoothingFactor: Float = 0.3

    // MARK: - Private Properties

    /// Recording lifecycle state
    private enum RecordingState {
        case idle           // Not recording
        case connecting     // ASR connection in progress
        case recording      // Fully recording (both ASR + audio)
        case stopping       // Cleanup in progress
    }

    private var recordingState: RecordingState = .idle
    private var recordingTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var audioActuallyStarted = false  // Track if audio recording was actually started
    private var preConnectionAudioBuffer: [Data] = []
    private var preConnectionBufferSize = 0  // Track total bytes for cap enforcement
    private var isASRConnected = false
    private let maxBufferBytes = Int(ASRConstants.sampleRate) * ASRConstants.bytesPerSample * 5

    private let audioRecorder = AudioRecorder()
    private let asrClient = ASRClient()
    private var recordingStartTime: Date?
    private var currentConfig: ASRConfig?
    private var capturedContext: CapturedTextContext?

    /// Computed property for backward compatibility
    var isRecording: Bool {
        recordingState == .recording || recordingState == .connecting
    }

    /// Check if we're in the connecting phase
    var isConnecting: Bool {
        recordingState == .connecting
    }

    /// Check if we're processing (waiting for final result)
    var isProcessing: Bool {
        recordingState == .stopping
    }

    // MARK: - Initialization

    private init() {
        // Private initializer for singleton
        updateConfig(settings: AppSettings.shared)
    }

    // MARK: - Public Methods

    /// Update ASR configuration from settings
    func updateConfig(settings: AppSettings) {
        var mergedContext = ""

        // Step 1: Add user context first (has priority)
        let userContext = settings.context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !userContext.isEmpty {
            mergedContext = userContext
            log(.debug, "updateConfig: User context: \(userContext.count) chars")
        }

        // Step 2: Add auto-captured context if enabled and space available
        if settings.contextCaptureEnabled,
           let captured = capturedContext,
           captured.hasContent {

            let maxLength = settings.maxContextLength
            let remainingSpace = maxLength - mergedContext.count

            if remainingSpace > 0 {
                let separator = mergedContext.isEmpty ? "" : "\n\n---\n\n"
                let availableForCapture = remainingSpace - separator.count

                if availableForCapture > 0 {
                    let capturedText = captured.text
                    // Truncate from beginning if needed (keep most recent at end)
                    let truncatedCapture = capturedText.count <= availableForCapture
                        ? capturedText
                        : String(capturedText.suffix(availableForCapture))

                    mergedContext += separator + truncatedCapture
                    log(.debug, "updateConfig: Auto-captured: \(capturedText.count) -> \(truncatedCapture.count) chars")
                }
            }
        }

        // Build contextLines
        var contextLines: [String] = []
        if !mergedContext.isEmpty {
            contextLines = [mergedContext]
            log(.info, "updateConfig: Final merged context: \(mergedContext.count) chars")
        } else {
            log(.debug, "updateConfig: No context (empty)")
        }

        currentConfig = ASRConfig(
            appKey: settings.appKey,
            accessKey: settings.accessKey,
            resourceID: settings.resourceID,
            language: "zh-CN",
            contextLines: contextLines
        )
    }

    /// Set captured context from another application
    /// Note: This only sets the in-memory capturedContext, not AppSettings.context
    /// AppSettings.context is for user-configured static context (e.g., industry terms)
    func setCapturedContext(_ context: CapturedTextContext?) {
        capturedContext = context
        if let context = context {
            capturedContextText = context.text
            capturedContextSource = context.applicationName
            log(.info, "setCapturedContext: \(context.text.count) chars from \(context.applicationName)")
            log(.debug, "Context preview: \(context.text.prefix(100))...")
        } else {
            capturedContextText = ""
            capturedContextSource = ""
            log(.debug, "setCapturedContext: Clearing context (nil)")
        }
        // Update config to include the new context (or exclude if nil)
        updateConfig(settings: AppSettings.shared)
    }

    /// Start recording and transcription
    func startRecording() {
        log(.info, "startRecording() called, current state: \(recordingState)")

        // Log the current config's context for debugging
        if let config = currentConfig {
            let contextPreview = config.contextLines.first?.prefix(50) ?? "(empty)"
            log(.debug, "Current config context: \(config.contextLines.count) lines, first: \(contextPreview)...")
        } else {
            log(.warning, "currentConfig is nil!")
        }

        // If currently stopping, wait for it to complete before starting
        if recordingState == .stopping {
            log(.info, "Currently stopping, will wait for completion before starting")
        }

        // Cancel any existing recording task
        recordingTask?.cancel()

        // Set connecting state IMMEDIATELY (before any async work)
        recordingState = .connecting
        audioActuallyStarted = false  // Reset flag

        // Clear previous state
        transcribedText = ""
        errorMessage = nil
        statusMessage = "Connecting..."
        recordingStartTime = Date()

        // Store Task reference for cancellation
        recordingTask = Task {
            do {
                // Wait for any in-progress stop operation to complete
                if let pendingStop = stopTask {
                    log(.debug, "Waiting for previous stop operation to complete...")
                    await pendingStop.value
                    stopTask = nil  // Clear the completed stop task
                    log(.debug, "Previous stop operation completed")
                }

                // Double-check we're still in connecting state (could have been cancelled while waiting)
                guard recordingState == .connecting else {
                    log(.info, "Recording state changed while waiting, aborting start")
                    return
                }

                // Check for cancellation before starting
                try Task.checkCancellation()

                // Ensure we have a valid config
                guard let config = currentConfig else {
                    errorMessage = "API credentials not configured. Open Settings to add them."
                    await performCleanup()
                    recordingState = .idle
                    return
                }

                // Request microphone permission
                let granted = await requestMicrophonePermission()
                guard granted else {
                    errorMessage = "Microphone permission denied. Please enable it in Settings."
                    await performCleanup()
                    recordingState = .idle
                    return
                }

                log(.info, "Starting transcription session...")

                // Reset buffer state
                isASRConnected = false
                preConnectionAudioBuffer.removeAll()
                preConnectionBufferSize = 0

                // Start audio recording FIRST (callback will buffer via sendAudioToASR)
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

                // Connect to ASR service
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

                // Check state after flush - stopRecording() may have been called
                // during the flush, changing state to .stopping
                guard recordingState == .connecting else {
                    log(.info, "State changed during setup (\(recordingState)), stopTask will handle cleanup")
                    return
                }

                // Only set .recording after audio and ASR are both ready
                recordingState = .recording
                statusMessage = "Recording..."
                log(.info, "Transcription session started")

            } catch is CancellationError {
                // User-initiated cancellation - silent cleanup, no error message
                log(.info, "Recording start cancelled by user, state: \(recordingState)")
                // Only clean up if no newer operation has taken over.
                // .stopping = stopRecording() is handling cleanup
                // .connecting = a newer startRecording() has already started
                if recordingState != .stopping && recordingState != .connecting {
                    await performCleanup()
                    recordingState = .idle
                    statusMessage = "Ready"
                }
            } catch {
                // Actual errors - show error message
                log(.error, "Start recording error: \(error), state: \(recordingState)")
                if recordingState != .stopping && recordingState != .connecting {
                    errorMessage = "Failed to start recording: \(error.localizedDescription)"
                    statusMessage = "Error"
                    await performCleanup()
                    recordingState = .idle
                }
            }
        }
    }

    /// Stop recording and wait for final transcription
    func stopRecording() {
        log(.info, "stopRecording() called, current state: \(recordingState)")

        // Prevent re-entry
        guard recordingState != .stopping && recordingState != .idle else {
            log(.info, "stopRecording() called but already stopping or idle, ignoring")
            return
        }

        let previousState = recordingState
        recordingState = .stopping
        statusMessage = "Stopping..."

        log(.info, "Stopping transcription session (previous state: \(previousState))...")

        // Cancel recording task if still running
        recordingTask?.cancel()
        recordingTask = nil

        // Store stop task so startRecording can wait for it
        stopTask = Task {
            // Always stop audio recording - it's idempotent (has guard isRecording)
            // and handles the race where audio starts between flag capture and Task execution
            await audioRecorder.stopRecording()

            // Handle ASR cleanup based on previous state
            if previousState == .recording {
                // Full recording was active - send final packet and wait for result
                do {
                    try await asrClient.sendFinalPacket()

                    // Wait for final result
                    statusMessage = "Processing..."
                    await asrClient.waitForFinalResult()

                    // Disconnect
                    await asrClient.disconnect()

                    // Calculate duration
                    if let startTime = recordingStartTime {
                        let duration = Date().timeIntervalSince(startTime)
                        statusMessage = "Completed (\(String(format: "%.1f", duration))s)"
                    } else {
                        statusMessage = "Completed"
                    }

                    log(.info, "Transcription session stopped")

                } catch {
                    errorMessage = "Failed to stop recording: \(error.localizedDescription)"
                    statusMessage = "Error"
                    log(.error, "Stop recording error: \(error)")
                }
            } else if previousState == .connecting {
                // Still connecting - just disconnect without sending final packet
                log(.info, "Stopping during connection phase - disconnecting only")
                await asrClient.disconnect()
                statusMessage = "Ready"
            }

            // Only reset state if a newer startRecording() hasn't already taken over.
            // A newer startRecording() sets recordingState = .connecting synchronously
            // before this stopTask finishes, so check before clobbering.
            if recordingState == .stopping {
                recordingState = .idle
                audioActuallyStarted = false
                isASRConnected = false
                preConnectionAudioBuffer.removeAll()
                preConnectionBufferSize = 0
                audioLevels = [0, 0, 0, 0, 0]
            }
        }
    }

    /// Finish recording, wait for final result, and copy to clipboard
    func finishRecordingAndCopy() async -> Bool {
        guard recordingState == .recording || recordingState == .connecting else { return false }

        log(.info, "Finishing transcription with copy to clipboard (state: \(recordingState))...")
        statusMessage = "Finishing..."

        // If still connecting, wait for connection to complete before stopping
        if recordingState == .connecting {
            log(.info, "Still connecting, waiting for connection to complete...")
            if let task = recordingTask {
                await task.value
            }
            // Check if connection succeeded
            guard recordingState == .recording else {
                log(.warning, "Connection did not complete successfully (state: \(recordingState)), aborting finish")
                return false
            }
            log(.info, "Connection completed, proceeding with finish")
        }

        // Stop recording (reuse existing logic)
        stopRecording()

        // Wait for stop task to complete (includes waiting for final result and second-pass)
        if let pendingStop = stopTask {
            log(.debug, "Waiting for stop task...")
            await pendingStop.value
            log(.debug, "Stop task completed")
        }

        // Copy to clipboard if we have text
        guard !transcribedText.isEmpty else {
            log(.warning, "No text to copy to clipboard")
            return false
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let success = pasteboard.setString(transcribedText, forType: .string)

        if success {
            log(.info, "Transcribed text copied to clipboard (\(transcribedText.count) chars)")
            statusMessage = "Copied"
        } else {
            log(.error, "Failed to copy text to clipboard")
            errorMessage = "Failed to copy to clipboard"
        }

        return success
    }

    /// Toggle recording state
    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    // MARK: - Private Methods

    /// Request microphone permission
    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Cleanup helper - stops audio and disconnects ASR
    private func performCleanup() async {
        if audioActuallyStarted {
            await audioRecorder.stopRecording()
        }
        await asrClient.disconnect()
        audioActuallyStarted = false
        isASRConnected = false
        preConnectionAudioBuffer.removeAll()
        preConnectionBufferSize = 0
    }

    /// Update audio levels with per-band smoothing
    private func updateAudioLevels(_ newLevels: [Float]) {
        for i in 0..<min(newLevels.count, audioLevels.count) {
            audioLevels[i] = levelSmoothingFactor * newLevels[i] + (1 - levelSmoothingFactor) * audioLevels[i]
        }
    }

    /// Send audio data to ASR service (buffers if not yet connected)
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

    /// Flush pre-connection audio buffer to ASR
    private func flushAudioBuffer() async {
        let segments = preConnectionAudioBuffer
        let totalBytes = preConnectionBufferSize
        preConnectionAudioBuffer.removeAll()
        preConnectionBufferSize = 0

        guard !segments.isEmpty else { return }

        log(.info, "Flushing audio buffer: \(segments.count) segments, \(totalBytes) bytes")

        var flushedCount = 0
        for segment in segments {
            do {
                try await asrClient.sendAudioData(segment)
                flushedCount += 1
            } catch {
                log(.error, "Failed to flush buffered audio: \(error)")
                break
            }
        }

        log(.info, "Audio buffer flushed: \(flushedCount)/\(segments.count) segments sent")
    }

    /// Listen to ASR results and update UI
    private func listenToASRResults() async {
        for await result in await asrClient.resultStream() {
            // Check for errors
            if !result.isSuccess {
                errorMessage = "ASR error (\(result.code)): \(result.message)"
                log(.error, "ASR error - code:\(result.code) message:\(result.message)")

                // Stop recording on fatal errors to prevent AudioRecorder from spinning
                if recordingState == .recording {
                    log(.warning, "Stopping recording due to ASR error")
                    stopRecording()
                }
                return  // Exit the loop - connection is broken
            }

            // Update transcribed text
            if result.text.isNotEmpty {
                // Apply post-processing
                var processedText = result.text
                if AppSettings.shared.removeTrailingPunctuation {
                    processedText = processedText.removingTrailingPunctuation()
                    log(.debug, "Punctuation removed: '\(result.text)' -> '\(processedText)'")
                }

                // For both interim and final results, replace with the latest processed text
                transcribedText = processedText

                log(.debug, "Text updated: [\(processedText)] final:\(result.isLastPackage)")
            }

            // Update status for final result
            if result.isLastPackage {
                log(.info, "Final transcription result received")
            }
        }

        // Stream ended - check if this was unexpected (connection dropped)
        if recordingState == .recording {
            log(.warning, "ASR stream ended unexpectedly while recording")
            statusMessage = "Connection dropped"
            stopRecording()
        }
    }
}
