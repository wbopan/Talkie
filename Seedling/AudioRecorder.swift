//
//  AudioRecorder.swift
//  Seedling
//
//  Audio capture service for real-time transcription
//

import AVFoundation
import Foundation
import CoreAudio
import AudioToolbox
import Accelerate

// MARK: - HAL AudioUnit Callback Context

/// Bridge object for passing state to the C-compatible HAL render callback.
/// Accessed from the real-time audio thread — marked @unchecked Sendable because
/// all properties are immutable after initialization.
final class HALCaptureContext: @unchecked Sendable {
    let audioUnit: AudioUnit
    let format: AVAudioFormat
    let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation

    nonisolated init(audioUnit: AudioUnit, format: AVAudioFormat, continuation: AsyncStream<AVAudioPCMBuffer>.Continuation) {
        self.audioUnit = audioUnit
        self.format = format
        self.continuation = continuation
    }
}

/// Audio recorder for capturing microphone input and streaming to ASR
actor AudioRecorder {
    // MARK: - Properties

    private var audioEngine: AVAudioEngine?
    private var halAudioUnit: AudioUnit?
    private var halCaptureContext: HALCaptureContext?
    private var audioConverter: AVAudioConverter?
    private var converterConfigured = false
    private var isRecording = false
    private var audioCallback: ((Data) -> Void)?
    private var audioLevelCallback: (([Float]) -> Void)?
    private var segmentBuffer = Data()

    // FFT properties for frequency band analysis
    private let fftSize = 2048
    private let fftLog2n: vDSP_Length = 11  // log2(2048)
    private var fftSetup: FFTSetup?
    private var hanningWindow: [Float] = []
    // Per-band adaptive noise floor (tracks ambient noise level)
    private var noiseFloor: [Float] = [Float](repeating: 0, count: 5)
    // Reusable FFT buffers (avoid per-frame allocation)
    private var fftInputBuffer: [Float] = []
    private var fftRealBuffer: [Float] = []
    private var fftImagBuffer: [Float] = []
    private var fftMagnitudes: [Float] = []
    // Accumulation buffer for small audio chunks (HAL path delivers < fftSize frames)
    private var fftAccumBuffer: [Int16] = []

    /// Audio processing Task to prevent Task explosion
    private var processingTask: Task<Void, Never>?
    /// Audio buffer channel for backpressure control
    private var audioBufferChannel: AsyncStream<AVAudioPCMBuffer>.Continuation?

    // Target audio format: 16kHz, 16-bit, mono PCM
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: ASRConstants.sampleRate,
        channels: ASRConstants.channels,
        interleaved: true
    )!

    // MARK: - Lifecycle

    /// Start recording audio
    /// - Parameters:
    ///   - callback: Called with audio data segments
    ///   - levelCallback: Called with audio level for visualization
    ///   - selectedMicrophoneUID: UID of the selected microphone (empty for system default)
    func startRecording(
        callback: @escaping (Data) -> Void,
        levelCallback: (([Float]) -> Void)? = nil,
        selectedMicrophoneUID: String = ""
    ) throws {
        guard !isRecording else {
            log(.warning, "Already recording")
            return
        }

        log(.info, "Starting audio recording...")

        self.audioCallback = callback
        self.audioLevelCallback = levelCallback
        self.segmentBuffer.removeAll()
        self.audioConverter = nil
        self.converterConfigured = false

        // Initialize FFT
        let halfSize = fftSize / 2
        fftSetup = vDSP_create_fftsetup(fftLog2n, FFTRadix(kFFTRadix2))
        hanningWindow = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hanningWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        noiseFloor = [Float](repeating: 0, count: 5)
        // Pre-allocate reusable buffers
        fftInputBuffer = [Float](repeating: 0, count: fftSize)
        fftRealBuffer = [Float](repeating: 0, count: halfSize)
        fftImagBuffer = [Float](repeating: 0, count: halfSize)
        fftMagnitudes = [Float](repeating: 0, count: halfSize)
        fftAccumBuffer = []

        // Route to the appropriate capture backend
        if !selectedMicrophoneUID.isEmpty,
           let deviceID = AudioDeviceManager.lookupDeviceID(forUID: selectedMicrophoneUID) {
            // Specific device: use standalone HAL AudioUnit (bypasses AVAudioEngine
            // graph issues that occur when changing the device after initialization)
            try startWithHALUnit(deviceID: deviceID, uid: selectedMicrophoneUID)
        } else {
            // System default: use AVAudioEngine (simpler, works reliably)
            try startWithEngine()
        }

        isRecording = true
        log(.info, "Audio recording started")
    }

    /// Stop recording audio
    func stopRecording() {
        guard isRecording else {
            log(.info, "Audio recorder already stopped")
            return
        }

        log(.info, "Stopping audio recording...")

        isRecording = false

        // Stop capture backends FIRST (before tearing down the pipeline)
        // so no new buffers arrive on a finished continuation.

        // Stop HAL AudioUnit if used
        if let au = halAudioUnit {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            halAudioUnit = nil
            halCaptureContext = nil  // Safe: AudioUnit is stopped, no more callbacks
            log(.info, "HAL AudioUnit stopped")
        }

        // Stop AVAudioEngine if used
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
            log(.info, "AVAudioEngine stopped")
        }

        // Now tear down the processing pipeline
        audioBufferChannel?.finish()
        audioBufferChannel = nil
        processingTask?.cancel()
        processingTask = nil

        audioConverter = nil
        converterConfigured = false

        // Send any remaining buffered data
        if !segmentBuffer.isEmpty {
            log(.info, "Flushing final buffer: \(segmentBuffer.count) bytes")
            audioCallback?(segmentBuffer)
            segmentBuffer.removeAll()
        }

        audioCallback = nil
        audioLevelCallback = nil

        // Clean up FFT
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
            fftSetup = nil
        }
        hanningWindow = []
        fftInputBuffer = []
        fftRealBuffer = []
        fftImagBuffer = []
        fftMagnitudes = []
        fftAccumBuffer = []

        log(.info, "Audio recording stopped")
    }

    // MARK: - Capture Backends

    /// Start capture using AVAudioEngine (system default device)
    private func startWithEngine() throws {
        let engine = AVAudioEngine()
        self.audioEngine = engine

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        log(.info, "Engine input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch")

        let bufferSize = AVAudioFrameCount(inputFormat.sampleRate * ASRConstants.segmentDuration)

        setupProcessingPipeline()

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            self?.audioBufferChannel?.yield(buffer)
        }

        engine.prepare()
        try engine.start()

        log(.info, "AVAudioEngine started with system default device")
    }

    /// Start capture using a standalone HAL AudioUnit (specific device).
    /// This bypasses AVAudioEngine entirely, avoiding the internal graph format
    /// corruption that occurs when changing the device via AudioUnitSetProperty
    /// on AVAudioEngine's input node.
    private func startWithHALUnit(deviceID: AudioDeviceID, uid: String) throws {
        // 1. Find HAL Output audio component
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else {
            log(.error, "HAL Output audio component not found")
            throw AudioRecorderError.recordingFailed
        }

        var audioUnit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &audioUnit)
        guard status == noErr, let au = audioUnit else {
            log(.error, "Failed to create HAL AudioUnit: \(status)")
            throw AudioRecorderError.recordingFailed
        }

        // 2. Enable input on element 1
        var enableIO: UInt32 = 1
        status = AudioUnitSetProperty(
            au, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input, 1,
            &enableIO, UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            log(.error, "Failed to enable HAL input: \(status)")
            AudioComponentInstanceDispose(au)
            throw AudioRecorderError.recordingFailed
        }

        // 3. Disable output on element 0 (we don't play audio)
        var disableIO: UInt32 = 0
        status = AudioUnitSetProperty(
            au, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output, 0,
            &disableIO, UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            log(.error, "Failed to disable HAL output: \(status)")
            AudioComponentInstanceDispose(au)
            throw AudioRecorderError.recordingFailed
        }

        // 4. Set the capture device
        var deviceIDVar = deviceID
        status = AudioUnitSetProperty(
            au, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &deviceIDVar, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            log(.error, "Failed to set HAL device \(deviceID): \(status)")
            AudioComponentInstanceDispose(au)
            throw AudioRecorderError.recordingFailed
        }
        log(.info, "HAL device set: \(uid) (deviceID=\(deviceID))")

        // 5. Get the device's native input format
        var hwASBD = AudioStreamBasicDescription()
        var hwASBDSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let hwStatus = AudioUnitGetProperty(
            au, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 1,
            &hwASBD, &hwASBDSize
        )
        guard hwStatus == noErr, hwASBD.mSampleRate > 0 else {
            log(.error, "Failed to get HAL hardware format: \(hwStatus)")
            AudioComponentInstanceDispose(au)
            throw AudioRecorderError.recordingFailed
        }
        log(.info, "HAL hardware format: \(hwASBD.mSampleRate)Hz, \(hwASBD.mChannelsPerFrame)ch, \(hwASBD.mBitsPerChannel)bit")

        // 6. Set output format: mono float32 at device sample rate
        //    The HAL unit will do the channel mixing internally
        var outputASBD = AudioStreamBasicDescription(
            mSampleRate: hwASBD.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        status = AudioUnitSetProperty(
            au, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output, 1,
            &outputASBD, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            log(.error, "Failed to set HAL output format: \(status)")
            AudioComponentInstanceDispose(au)
            throw AudioRecorderError.recordingFailed
        }
        log(.info, "HAL output format: \(outputASBD.mSampleRate)Hz, 1ch, float32")

        // 6b. Set device buffer size large enough for FFT (2048 frames at 16kHz
        //     = ~6144 frames at 48kHz). Use the same duration as AVAudioEngine path.
        var desiredFrames = UInt32(hwASBD.mSampleRate * ASRConstants.segmentDuration)
        var bufferSizeAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let bsStatus = AudioObjectSetPropertyData(
            deviceID, &bufferSizeAddr, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &desiredFrames
        )
        if bsStatus == noErr {
            log(.info, "HAL buffer size set to \(desiredFrames) frames")
        } else {
            log(.warning, "Failed to set HAL buffer size (status: \(bsStatus)), waveform may not animate")
        }

        // Also tell the audio unit the max frames it may receive per slice
        AudioUnitSetProperty(
            au, kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global, 0,
            &desiredFrames, UInt32(MemoryLayout<UInt32>.size)
        )

        // 7. Create AVAudioFormat for the processing pipeline
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: outputASBD.mSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            AudioComponentInstanceDispose(au)
            throw AudioRecorderError.conversionFailed
        }

        // 8. Set up processing pipeline (AsyncStream + processing Task)
        setupProcessingPipeline()

        // 9. Set up render callback
        guard let continuation = audioBufferChannel else {
            log(.error, "Failed to set up audio processing pipeline")
            AudioComponentInstanceDispose(au)
            throw AudioRecorderError.recordingFailed
        }
        let context = HALCaptureContext(
            audioUnit: au, format: format, continuation: continuation
        )
        self.halCaptureContext = context

        var callbackStruct = AURenderCallbackStruct(
            inputProc: { (inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData) -> OSStatus in
                let ctx = Unmanaged<HALCaptureContext>.fromOpaque(inRefCon).takeUnretainedValue()
                guard let buffer = AVAudioPCMBuffer(pcmFormat: ctx.format, frameCapacity: inNumberFrames) else {
                    return kAudioUnitErr_FailedInitialization
                }
                buffer.frameLength = inNumberFrames
                let status = AudioUnitRender(ctx.audioUnit, ioActionFlags, inTimeStamp, 1, inNumberFrames, buffer.mutableAudioBufferList)
                guard status == noErr else { return status }
                ctx.continuation.yield(buffer)
                return noErr
            },
            inputProcRefCon: Unmanaged.passUnretained(context).toOpaque()
        )
        status = AudioUnitSetProperty(
            au, kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global, 0,
            &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else {
            log(.error, "Failed to set HAL input callback: \(status)")
            AudioComponentInstanceDispose(au)
            throw AudioRecorderError.recordingFailed
        }

        // 10. Initialize and start
        status = AudioUnitInitialize(au)
        guard status == noErr else {
            log(.error, "Failed to initialize HAL AudioUnit: \(status)")
            AudioComponentInstanceDispose(au)
            throw AudioRecorderError.recordingFailed
        }

        status = AudioOutputUnitStart(au)
        guard status == noErr else {
            log(.error, "Failed to start HAL AudioUnit: \(status)")
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            throw AudioRecorderError.recordingFailed
        }

        self.halAudioUnit = au
        log(.info, "HAL AudioUnit started successfully")
    }

    /// Set up the shared AsyncStream processing pipeline
    private func setupProcessingPipeline() {
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(5)
        )
        self.audioBufferChannel = continuation

        processingTask = Task { [weak self] in
            for await buffer in stream {
                guard let self = self else { break }
                guard await self.isRecording else { break }
                await self.processAudioBuffer(buffer)
            }
        }
    }

    // MARK: - Audio Processing

    /// Compute 5 frequency band levels from PCM samples using real FFT (vDSP_fft_zrip)
    /// Returns normalized levels [0..1] for speech-focused frequency bands
    private func computeFrequencyBands(_ samples: UnsafeMutablePointer<Int16>, frameCount: Int) -> [Float] {
        let bandCount = 5
        let halfSize = fftSize / 2
        guard let setup = fftSetup, frameCount >= fftSize else {
            return [Float](repeating: 0, count: bandCount)
        }

        // Convert Int16 -> Float using vDSP (vectorized, ~10x faster than Swift loop)
        vDSP_vflt16(samples, 1, &fftInputBuffer, 1, vDSP_Length(fftSize))
        var divisor = Float(Int16.max)
        vDSP_vsdiv(fftInputBuffer, 1, &divisor, &fftInputBuffer, 1, vDSP_Length(fftSize))

        // Apply Hanning window
        vDSP_vmul(fftInputBuffer, 1, hanningWindow, 1, &fftInputBuffer, 1, vDSP_Length(fftSize))

        // Pack real data into split complex format for vDSP_fft_zrip
        // zrip interprets the input as interleaved: [real[0], imag[0], real[1], imag[1], ...]
        fftInputBuffer.withUnsafeMutableBufferPointer { buf in
            var splitComplex = DSPSplitComplex(
                realp: buf.baseAddress!,
                imagp: buf.baseAddress! + 1
            )
            vDSP_ctoz(
                UnsafePointer<DSPComplex>(OpaquePointer(buf.baseAddress!)),
                2,
                &splitComplex,
                1,
                vDSP_Length(halfSize)
            )
        }

        // Execute real-to-complex FFT in-place using split complex layout
        fftRealBuffer.withUnsafeMutableBufferPointer { realBuf in
            fftImagBuffer.withUnsafeMutableBufferPointer { imagBuf in
                // Copy packed data into split buffers
                fftInputBuffer.withUnsafeBufferPointer { inputBuf in
                    for i in 0..<halfSize {
                        realBuf[i] = inputBuf[2 * i]
                        imagBuf[i] = inputBuf[2 * i + 1]
                    }
                }

                var splitComplex = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                vDSP_fft_zrip(setup, &splitComplex, 1, fftLog2n, FFTDirection(FFT_FORWARD))

                // Compute magnitudes squared into reusable buffer
                vDSP_zvmags(&splitComplex, 1, &fftMagnitudes, 1, vDSP_Length(halfSize))
            }
        }

        // 5 speech-focused frequency bands for 16kHz sample rate
        // Bin resolution = 16000/2048 ≈ 7.8125 Hz/bin
        // Human speech energy is concentrated in 85-3500 Hz
        // Band 0: 85-250 Hz   (bins 11-32)   - Fundamental frequency (F0)
        // Band 1: 250-500 Hz  (bins 32-64)   - First formant (F1), vowel openness
        // Band 2: 500-1200 Hz (bins 64-154)  - F1/F2 crossover, vowel identity
        // Band 3: 1200-3000 Hz (bins 154-384) - F2/F3, consonant clarity
        // Band 4: 3000-8000 Hz (bins 384-1024) - Fricatives, sibilants (s/f/sh)
        let bandRanges: [(Int, Int)] = [
            (11, 32), (32, 64), (64, 154), (154, 384), (384, min(halfSize, 1024))
        ]

        // Dynamic range above noise floor for normalization
        // Compact range to make quiet speech visible
        let dynamicRangeDB: Float = 10.0

        var levels = [Float](repeating: 0, count: bandCount)
        fftMagnitudes.withUnsafeBufferPointer { buf in
            for (i, range) in bandRanges.enumerated() {
                let lo = min(range.0, halfSize)
                let hi = min(range.1, halfSize)
                guard hi > lo else { continue }

                // Average magnitude in this band
                var sum: Float = 0
                vDSP_sve(buf.baseAddress! + lo, 1, &sum, vDSP_Length(hi - lo))
                let avgMag = sum / Float(hi - lo)

                // Convert to dB
                let db = 10.0 * log10f(max(avgMag, 1e-10))

                // Adaptive noise floor tracking per band:
                // - Downward: fast exponential tracking (settles in ~5 frames)
                //   Avoids locking to transient minimums unlike instant snap-down
                // - Upward within 10dB: slow tracking for ambient drift
                // - Upward >10dB: speech energy, don't update floor
                let delta = db - noiseFloor[i]
                if delta < 0 {
                    noiseFloor[i] += delta * 0.3
                } else if delta < 10.0 {
                    noiseFloor[i] += delta * 0.02
                }

                // Normalize: only show energy above noise floor + margin
                // 3dB margin absorbs ambient noise while staying sensitive to quiet speech
                let aboveNoise = db - (noiseFloor[i] + 3.0)
                let linear = max(0, min(1, aboveNoise / dynamicRangeDB))
                // Compressive curve: boost quiet levels, preserve loud levels
                levels[i] = powf(linear, 0.5)
            }
        }

        return levels
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isRecording else { return }

        // Lazy converter setup from actual buffer format (first buffer only)
        if !converterConfigured {
            let bufferFormat = buffer.format
            log(.info, "Actual buffer format: \(bufferFormat.sampleRate)Hz, \(bufferFormat.channelCount)ch, frames=\(buffer.frameLength)")

            let needsConversion = bufferFormat.sampleRate != targetFormat.sampleRate
                || bufferFormat.commonFormat != targetFormat.commonFormat
                || bufferFormat.channelCount != targetFormat.channelCount

            if needsConversion {
                if let converter = AVAudioConverter(from: bufferFormat, to: targetFormat) {
                    self.audioConverter = converter
                    log(.info, "Audio converter created: \(bufferFormat.sampleRate)Hz \(bufferFormat.channelCount)ch → \(targetFormat.sampleRate)Hz \(targetFormat.channelCount)ch")
                } else {
                    log(.error, "Failed to create audio converter from \(bufferFormat) to \(targetFormat)")
                    return
                }
            } else {
                self.audioConverter = nil
                log(.info, "No audio conversion needed")
            }
            converterConfigured = true
        }

        // Convert audio if needed
        let convertedBuffer: AVAudioPCMBuffer
        if let converter = audioConverter {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: AVAudioFrameCount(
                    Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate
                )
            ) else {
                log(.error, "Failed to create output buffer")
                return
            }

            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

            if let error = error {
                log(.error, "Audio conversion error: \(error)")
                return
            }

            convertedBuffer = outputBuffer
        } else {
            convertedBuffer = buffer
        }

        // Convert buffer to Data (16-bit PCM)
        guard let channelData = convertedBuffer.int16ChannelData else {
            log(.error, "Failed to get channel data")
            return
        }

        let frameLength = Int(convertedBuffer.frameLength)

        // Accumulate samples for FFT (HAL path may deliver small buffers < fftSize)
        let newSamples = UnsafeBufferPointer(start: channelData[0], count: frameLength)
        fftAccumBuffer.append(contentsOf: newSamples)

        // Compute frequency bands via FFT for waveform visualization
        // Use the latest fftSize samples from the accumulation buffer
        let bands: [Float]
        if fftAccumBuffer.count >= fftSize {
            let startIndex = fftAccumBuffer.count - fftSize
            bands = fftAccumBuffer.withUnsafeMutableBufferPointer { buf in
                computeFrequencyBands(buf.baseAddress! + startIndex, frameCount: fftSize)
            }
            // Keep only the latest fftSize samples to bound memory
            if fftAccumBuffer.count > fftSize * 2 {
                fftAccumBuffer.removeFirst(fftAccumBuffer.count - fftSize)
            }
        } else {
            bands = [Float](repeating: 0, count: 5)
        }

        if let levelCallback = audioLevelCallback {
            Task { @MainActor in
                levelCallback(bands)
            }
        }

        let data = Data(bytes: channelData[0], count: frameLength * ASRConstants.bytesPerSample)

        // Add to segment buffer
        segmentBuffer.append(data)

        // Send complete segments
        while segmentBuffer.count >= ASRConstants.segmentByteSize {
            let segment = segmentBuffer.prefix(ASRConstants.segmentByteSize)
            audioCallback?(segment)
            segmentBuffer.removeFirst(ASRConstants.segmentByteSize)

            log(.debug, "Sent audio segment: \(segment.count) bytes")
        }
    }
}

// MARK: - Error Types

enum AudioRecorderError: Error, LocalizedError {
    case conversionFailed
    case recordingFailed
    case notRecording

    var errorDescription: String? {
        switch self {
        case .conversionFailed:
            return "Failed to create audio converter"
        case .recordingFailed:
            return "Failed to start recording"
        case .notRecording:
            return "Not currently recording"
        }
    }
}
