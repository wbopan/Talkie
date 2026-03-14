//
//  Utilities.swift
//  Seedling
//
//  Core utilities, models, extensions, and constants
//

import Foundation
import Compression
import zlib
import Combine
import AppKit
import OSLog
import KeyboardShortcuts

// MARK: - Constants

enum ASRConstants: Sendable {
    static nonisolated let apiURL = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
    static nonisolated let sampleRate: Double = 16000
    static nonisolated let channels: UInt32 = 1
    static nonisolated let segmentDuration: TimeInterval = 0.2 // 200ms
    static nonisolated let segmentSampleCount = Int(sampleRate * segmentDuration) // 3200 samples
    static nonisolated let bytesPerSample = 2 // int16
    static nonisolated let segmentByteSize = segmentSampleCount * bytesPerSample // 6400 bytes
    static nonisolated let shutdownTimeout: TimeInterval = 1.5
    static nonisolated let resourceID = "volc.seedasr.sauc.duration"
}

// MARK: - Models

/// ASR configuration
struct ASRConfig: Sendable {
    let appKey: String
    let accessKey: String
    let resourceID: String
    let language: String
    let format: String
    let sampleRate: Int
    let bits: Int
    let contextLines: [String]

    init(
        appKey: String,
        accessKey: String,
        resourceID: String = ASRConstants.resourceID,
        language: String = "zh-CN",
        format: String = "pcm",
        sampleRate: Int = Int(ASRConstants.sampleRate),
        bits: Int = 16,
        contextLines: [String] = []
    ) {
        self.appKey = appKey
        self.accessKey = accessKey
        self.resourceID = resourceID
        self.language = language
        self.format = format
        self.sampleRate = sampleRate
        self.bits = bits
        self.contextLines = contextLines
    }

    /// Generate full JSON payload for initial request (matches Python reference)
    nonisolated func toFullRequestJSON() -> [String: Any] {
        var request: [String: Any] = [
            "model_name": "bigmodel",
            "enable_itn": true,
            "enable_punc": true,
            "enable_ddc": true,
            "show_utterances": true,
            "enable_nonstream": true,
            "end_window_size": 1000  // Trigger second pass after 1s silence
        ]

        // Add dialog context under corpus.context (per API documentation)
        if !contextLines.isEmpty {
            // Use dialog context format - combine all lines as context
            let contextText = contextLines.joined(separator: " ")
            let contextDict: [String: Any] = [
                "context_type": "dialog_ctx",
                "context_data": [["text": contextText]]
            ]
            if let contextData = try? JSONSerialization.data(withJSONObject: contextDict),
               let contextString = String(data: contextData, encoding: .utf8) {
                request["corpus"] = ["context": contextString]
                log(.debug, "ASR: including dialog context (\(contextText.count) chars)")
            }
        }

        return [
            "user": [
                "uid": "seedling_user"
            ],
            "audio": [
                "format": "pcm",
                "codec": "raw",
                "rate": sampleRate,
                "bits": bits,
                "channel": 1
            ],
            "request": request
        ]
    }
}

/// ASR result from server
struct ASRResult: Sendable {
    let text: String
    let isLastPackage: Bool
    let sequence: Int
    let code: Int
    let message: String

    nonisolated var isSuccess: Bool {
        code == 0 || code == 1000
    }

    nonisolated init(text: String = "", isLastPackage: Bool = false, sequence: Int = 0, code: Int = 0, message: String = "") {
        self.text = text
        self.isLastPackage = isLastPackage
        self.sequence = sequence
        self.code = code
        self.message = message
    }
}

/// Recording session result
struct RecordingSession {
    let text: String
    let duration: TimeInterval
    let timestamp: Date

    init(text: String, duration: TimeInterval, timestamp: Date = Date()) {
        self.text = text
        self.duration = duration
        self.timestamp = timestamp
    }
}

/// Glass tint style for the floating window
enum GlassTintStyle: String, Codable, CaseIterable {
    case clear
    case accent
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case pink

    var displayName: String {
        switch self {
        case .clear:  return "Clear"
        case .accent: return "Accent Color"
        case .red:    return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green:  return "Green"
        case .blue:   return "Blue"
        case .purple: return "Purple"
        case .pink:   return "Pink"
        }
    }
}

/// Window position mode
enum WindowPositionMode: String, Codable, CaseIterable {
    case rememberLast = "remember_last"
    case nearMouse = "near_mouse"
    case topCenter = "top_center"
    case bottomCenter = "bottom_center"

    var displayName: String {
        switch self {
        case .rememberLast: return "Remember Last Position"
        case .nearMouse: return "Near Mouse Cursor"
        case .topCenter: return "Top of Screen"
        case .bottomCenter: return "Bottom of Screen"
        }
    }

}

/// HTTP API response
struct APIResponse: Codable {
    let status: String
    let text: String?
    let duration: Double?
    let message: String?

    init(status: String, text: String? = nil, duration: Double? = nil, message: String? = nil) {
        self.status = status
        self.text = text
        self.duration = duration
        self.message = message
    }

    func toJSON() -> Data? {
        try? JSONEncoder().encode(self)
    }
}

// MARK: - Binary Protocol Header

/// Binary protocol header (4 bytes)
/// [Version:4bits|HeaderSize:4bits][MessageType:4bits|Flags:4bits][Serialization:4bits|Compression:4bits][Reserved:8bits]
struct ProtocolHeader {
    static let size = 4

    // Byte 0: Version (4 bits) | Header Size (4 bits)
    let version: UInt8 = 0b0001  // Version 1
    let headerSize: UInt8 = 0b0001  // Header size = 1 (meaning 4 bytes)

    // Byte 1: Message Type (4 bits) | Flags (4 bits)
    enum MessageType: UInt8 {
        case full = 0b0001              // Full request with JSON payload
        case audio = 0b0010             // Audio-only request
        case serverFull = 0b1001        // Server full response
        case serverError = 0b1111       // Server error response
    }
    let messageType: MessageType
    let flags: UInt8  // Message type specific flags

    // Message type specific flags (matches Python reference)
    enum MessageTypeFlags: Sendable {
        static nonisolated let noSequence: UInt8 = 0b0000
        static nonisolated let posSequence: UInt8 = 0b0001       // Positive sequence number present
        static nonisolated let negSequence: UInt8 = 0b0010       // Negative sequence (final packet)
        static nonisolated let negWithSequence: UInt8 = 0b0011   // Both flags set
    }

    // Byte 2: Serialization (4 bits) | Compression (4 bits)
    enum Serialization: UInt8 {
        case json = 0b0001
    }
    enum Compression: UInt8 {
        case none = 0b0000
        case gzip = 0b0001
    }
    let serialization: Serialization = .json
    let compression: Compression  // Compression type for this message

    // Byte 3: Reserved
    let reserved: UInt8 = 0x00

    nonisolated init(messageType: MessageType, flags: UInt8 = 0b0000, compression: Compression = .gzip) {
        self.messageType = messageType
        self.flags = flags
        self.compression = compression
    }

    nonisolated func encode() -> Data {
        var data = Data(capacity: 4)

        // Byte 0: [Version:4|HeaderSize:4]
        let byte0 = (version << 4) | headerSize
        data.append(byte0)

        // Byte 1: [MessageType:4|Flags:4]
        let byte1 = (messageType.rawValue << 4) | flags
        data.append(byte1)

        // Byte 2: [Serialization:4|Compression:4]
        let byte2 = (serialization.rawValue << 4) | compression.rawValue
        data.append(byte2)

        // Byte 3: Reserved
        data.append(reserved)

        return data
    }

    nonisolated static func decode(from data: Data) -> ProtocolHeader? {
        guard data.count >= 4 else { return nil }

        let byte1 = data[1]
        let messageTypeRaw = (byte1 >> 4) & 0x0F

        guard let messageType = MessageType(rawValue: messageTypeRaw) else {
            return nil
        }

        return ProtocolHeader(messageType: messageType)
    }
}

// MARK: - Data Extensions

extension Data {
    /// Append Int32 in big-endian format
    nonisolated mutating func appendInt32BE(_ value: Int32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { buffer in
            self.append(contentsOf: buffer)
        }
    }

    /// Append UInt32 in big-endian format
    nonisolated mutating func appendUInt32BE(_ value: UInt32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { buffer in
            self.append(contentsOf: buffer)
        }
    }

    /// Append UInt32 in little-endian format
    nonisolated mutating func appendUInt32LE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { buffer in
            self.append(contentsOf: buffer)
        }
    }

    /// Read Int32 from big-endian format
    nonisolated func readInt32BE(at offset: Int) -> Int32? {
        guard offset + 4 <= count else { return nil }
        let bytes = self[offset..<offset+4]
        return bytes.withUnsafeBytes { buffer in
            buffer.load(as: Int32.self).bigEndian
        }
    }

    /// Read UInt32 from big-endian format
    nonisolated func readUInt32BE(at offset: Int) -> UInt32? {
        guard offset + 4 <= count else { return nil }
        let bytes = self[offset..<offset+4]
        return bytes.withUnsafeBytes { buffer in
            buffer.load(as: UInt32.self).bigEndian
        }
    }

    /// GZIP compress data using zlib (RFC 1952 compliant)
    nonisolated func gzipCompressed() -> Data? {
        return self.withUnsafeBytes { (sourcePtr: UnsafeRawBufferPointer) -> Data? in
            guard let baseAddress = sourcePtr.baseAddress else { return nil }

            // Allocate z_stream
            var stream = z_stream()

            // Initialize for compression with GZIP format
            // windowBits = 15 (max) + 16 (GZIP format)
            let windowBits: Int32 = 15 + 16
            var status = deflateInit2_(
                &stream,
                Z_DEFAULT_COMPRESSION,
                Z_DEFLATED,
                windowBits,
                8,  // memLevel
                Z_DEFAULT_STRATEGY,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            )

            guard status == Z_OK else { return nil }
            defer { deflateEnd(&stream) }

            // Set input
            stream.avail_in = uInt(self.count)
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: baseAddress.assumingMemoryBound(to: Bytef.self))

            // Prepare output buffer
            let chunkSize = 16384
            var outputData = Data()
            var outputBuffer = [UInt8](repeating: 0, count: chunkSize)

            repeat {
                outputBuffer.withUnsafeMutableBufferPointer { bufferPtr in
                    stream.avail_out = uInt(chunkSize)
                    stream.next_out = bufferPtr.baseAddress

                    status = deflate(&stream, Z_FINISH)
                }

                guard status >= 0 else { return nil }

                let bytesWritten = chunkSize - Int(stream.avail_out)
                if bytesWritten > 0 {
                    outputData.append(outputBuffer, count: bytesWritten)
                }

            } while status != Z_STREAM_END

            return outputData
        }
    }

    /// GZIP decompress data using zlib
    nonisolated func gzipDecompressed() -> Data? {
        return self.withUnsafeBytes { (sourcePtr: UnsafeRawBufferPointer) -> Data? in
            guard let baseAddress = sourcePtr.baseAddress else { return nil }

            // Allocate z_stream
            var stream = z_stream()

            // Initialize for decompression with GZIP format
            // windowBits = 15 (max) + 16 (GZIP format)
            let windowBits: Int32 = 15 + 16
            var status = inflateInit2_(
                &stream,
                windowBits,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            )

            guard status == Z_OK else { return nil }
            defer { inflateEnd(&stream) }

            // Set input
            stream.avail_in = uInt(self.count)
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: baseAddress.assumingMemoryBound(to: Bytef.self))

            // Prepare output buffer
            let chunkSize = 16384
            var outputData = Data()
            var outputBuffer = [UInt8](repeating: 0, count: chunkSize)

            repeat {
                outputBuffer.withUnsafeMutableBufferPointer { bufferPtr in
                    stream.avail_out = uInt(chunkSize)
                    stream.next_out = bufferPtr.baseAddress

                    status = inflate(&stream, Z_NO_FLUSH)
                }

                guard status >= 0 || status == Z_BUF_ERROR else { return nil }

                let bytesWritten = chunkSize - Int(stream.avail_out)
                if bytesWritten > 0 {
                    outputData.append(outputBuffer, count: bytesWritten)
                }

                if status == Z_STREAM_END { break }

            } while stream.avail_out == 0

            return outputData
        }
    }
}

// MARK: - Logging

/// Log levels for categorizing log messages
enum LogLevel {
    case debug, info, warning, error

    nonisolated var prefix: String {
        switch self {
        case .debug:   return "\u{001B}[36m[DEBUG]\u{001B}[0m"   // Cyan
        case .info:    return "\u{001B}[32m[INFO]\u{001B}[0m"    // Green
        case .warning: return "\u{001B}[33m[WARN]\u{001B}[0m"    // Yellow
        case .error:   return "\u{001B}[31m[ERROR]\u{001B}[0m"   // Red
        }
    }
}

/// Logger extensions with categorized loggers for different subsystems
extension Logger {
    private static nonisolated let subsystem = Bundle.main.bundleIdentifier ?? "com.wenbopan.seedling"

    /// Logger for audio recording and processing
    static nonisolated let audio = Logger(subsystem: subsystem, category: "Audio")

    /// Logger for ASR (Automatic Speech Recognition) operations
    static nonisolated let asr = Logger(subsystem: subsystem, category: "ASR")

    /// Logger for UI and window management
    static nonisolated let ui = Logger(subsystem: subsystem, category: "UI")

    /// Logger for network/WebSocket operations
    static nonisolated let network = Logger(subsystem: subsystem, category: "Network")

    /// Logger for hotkey and system events
    static nonisolated let hotkey = Logger(subsystem: subsystem, category: "Hotkey")

    /// Logger for general/uncategorized logs
    static nonisolated let general = Logger(subsystem: subsystem, category: "General")

    /// Logger for accessibility-related operations
    static nonisolated let accessibility = Logger(subsystem: subsystem, category: "Accessibility")
}

/// Unified logging function using Apple's OSLog framework
///
/// This function provides backward compatibility while using the modern Logger API.
/// Logs are integrated with macOS Console.app and can be filtered by subsystem and category.
///
/// Usage:
/// ```swift
/// log(.info, "Starting transcription session...")
/// log(.error, "Failed to connect: \(error)")
/// log(.debug, "Audio buffer size: \(bufferSize) bytes")
/// ```
///
/// To view logs in Console.app:
/// 1. Open Console.app
/// 2. Filter by process: "Seedling"
/// 3. Filter by subsystem: "com.wenbopan.seedling"
///
/// To view logs in terminal:
/// ```bash
/// log stream --predicate 'subsystem == "com.wenbopan.seedling"'
/// log stream --predicate 'subsystem == "com.wenbopan.seedling" AND category == "ASR"'
/// ```
nonisolated func log(_ level: LogLevel, _ message: String, file: String = #file, line: Int = #line) {
    let filename = (file as NSString).lastPathComponent
    let logger = Logger.general

    // Format the message with file and line information
    let formattedMessage = "\(filename):\(line) - \(message)"

    switch level {
    case .debug:
        logger.debug("\(formattedMessage, privacy: .public)")
    case .info:
        logger.info("\(formattedMessage, privacy: .public)")
    case .warning:
        logger.warning("\(formattedMessage, privacy: .public)")
    case .error:
        logger.error("\(formattedMessage, privacy: .public)")
    }

    // Also print to console for development convenience
    #if DEBUG
    print("\(level.prefix) \(formattedMessage)")
    #endif
}

// MARK: - Helper Extensions

extension Date {
    var timestamp: TimeInterval {
        return timeIntervalSince1970
    }
}

extension String {
    var isNotEmpty: Bool {
        !isEmpty
    }

    /// Remove trailing punctuation (both full-width and half-width)
    /// Full-width: 。！？；：，、
    /// Half-width: . ! ? ; : ,
    func removingTrailingPunctuation() -> String {
        let punctuation: Set<Character> = [
            "。", "！", "？", "；", "：", "，", "、",  // Full-width
            ".", "!", "?", ";", ":", ","              // Half-width
        ]

        var result = self
        while let lastChar = result.last, punctuation.contains(lastChar) {
            result.removeLast()
        }
        return result
    }
}

// MARK: - NSView Helpers

/// Recursively clear backgrounds on NSView hierarchy for Liquid Glass rendering
func clearBackgrounds(_ view: NSView) {
    view.wantsLayer = true
    view.layer?.backgroundColor = .clear
    for subview in view.subviews {
        clearBackgrounds(subview)
    }
}

extension NSEvent.ModifierFlags {
    /// Convert NSEvent.ModifierFlags to Carbon modifier bitmask
    var carbonModifiers: UInt32 {
        var modifiers: UInt32 = 0
        if contains(.command) { modifiers |= UInt32(cmdKey) }
        if contains(.option) { modifiers |= UInt32(optionKey) }
        if contains(.shift) { modifiers |= UInt32(shiftKey) }
        if contains(.control) { modifiers |= UInt32(controlKey) }
        return modifiers
    }
}

// MARK: - UserDefaults Keys

enum UserDefaultsKeys {
    static let appKey = "Seedling.AppKey"
    static let accessKey = "Seedling.AccessKey"
    static let resourceID = "Seedling.ResourceID"
    static let httpPort = "Seedling.HTTPPort"
    static let globalHotkeyKeyCode = "Seedling.GlobalHotkeyKeyCode"
    static let globalHotkeyModifiers = "Seedling.GlobalHotkeyModifiers"
    static let rememberWindowPosition = "Seedling.RememberWindowPosition"
    static let windowPositionMode = "Seedling.WindowPositionMode"
    static let windowPositionX = "Seedling.WindowPositionX"
    static let windowPositionY = "Seedling.WindowPositionY"
    static let autoPasteAfterClose = "Seedling.AutoPasteAfterClose"
    static let removeTrailingPunctuation = "Seedling.RemoveTrailingPunctuation"

    // Long-press modifier key settings
    static let longPressConfig = "Seedling.LongPressEnabled" // stores full LongPressConfig JSON
    static let longPressModifierKey = "Seedling.LongPressModifierKey"
    static let longPressMinDuration = "Seedling.LongPressMinDuration"
    static let context = "Seedling.Context"

    // Context capture settings
    static let contextCaptureEnabled = "Seedling.ContextCaptureEnabled"
    static let maxContextLength = "Seedling.MaxContextLength"

    // Microphone selection
    static let selectedMicrophoneUID = "Seedling.SelectedMicrophoneUID"

    // Appearance
    static let glassTintStyle = "Seedling.GlassTintStyle"
    static let screenEdgeMargin = "Seedling.ScreenEdgeMargin"
    static let showMenuBarIcon = "Seedling.ShowMenuBarIcon"

    static let defaultPort = 18888
    static let defaultMaxContextLength = 2000
    static let defaultScreenEdgeMargin: CGFloat = 160
}

// MARK: - Long-Press Modifier Key

/// Available modifier keys for long-press activation
enum LongPressModifierKey: String, Codable, CaseIterable {
    // "Any side" variants (original)
    case option
    case command
    case control
    case shift
    case fn
    case space

    // Side-specific variants
    case leftOption
    case rightOption
    case leftCommand
    case rightCommand
    case leftControl
    case rightControl
    case leftShift
    case rightShift

    var displayName: String {
        switch self {
        case .option:       return "Option"
        case .leftOption:   return "Left Option"
        case .rightOption:  return "Right Option"
        case .command:      return "Command"
        case .leftCommand:  return "Left Command"
        case .rightCommand: return "Right Command"
        case .control:      return "Control"
        case .leftControl:  return "Left Control"
        case .rightControl: return "Right Control"
        case .shift:        return "Shift"
        case .leftShift:    return "Left Shift"
        case .rightShift:   return "Right Shift"
        case .fn:           return "Fn"
        case .space:        return "Space"
        }
    }

    var symbol: String {
        switch self {
        case .option, .leftOption, .rightOption:       return "⌥"
        case .command, .leftCommand, .rightCommand:    return "⌘"
        case .control, .leftControl, .rightControl:    return "⌃"
        case .shift, .leftShift, .rightShift:          return "⇧"
        case .fn:                                      return "fn"
        case .space:                                   return "␣"
        }
    }

    /// The NSEvent.ModifierFlags corresponding to this key
    var modifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .option, .leftOption, .rightOption:       return .option
        case .command, .leftCommand, .rightCommand:    return .command
        case .control, .leftControl, .rightControl:    return .control
        case .shift, .leftShift, .rightShift:          return .shift
        case .fn:                                      return .function
        case .space:                                   return []  // Not a modifier key
        }
    }

    /// Physical key codes for this modifier key.
    /// "Any" variants include both left and right key codes;
    /// side-specific variants include only one.
    var keyCodes: Set<UInt16> {
        switch self {
        case .option:       return [58, 61]   // left + right option
        case .leftOption:   return [58]
        case .rightOption:  return [61]
        case .command:      return [55, 54]   // left + right command
        case .leftCommand:  return [55]
        case .rightCommand: return [54]
        case .control:      return [59, 62]   // left + right control
        case .leftControl:  return [59]
        case .rightControl: return [62]
        case .shift:        return [56, 60]   // left + right shift
        case .leftShift:    return [56]
        case .rightShift:   return [60]
        case .fn:           return [63]
        case .space:        return [49]
        }
    }

    /// Whether this key is a regular key (not a modifier) requiring keyDown/keyUp monitoring
    var isRegularKey: Bool {
        switch self {
        case .space: return true
        default:     return false
        }
    }

    /// Whether this variant is side-specific (left or right only)
    var isSideSpecific: Bool {
        switch self {
        case .option, .command, .control, .shift, .fn, .space:
            return false
        case .leftOption, .rightOption,
             .leftCommand, .rightCommand,
             .leftControl, .rightControl,
             .leftShift, .rightShift:
            return true
        }
    }
}

/// Configuration for long-press modifier key activation
struct LongPressConfig: Codable, Equatable {
    var enabled: Bool
    var modifierKey: LongPressModifierKey
    var minimumPressDuration: TimeInterval
    var requireDoubleTap: Bool

    static let `default` = LongPressConfig(
        enabled: true,
        modifierKey: .rightShift,
        minimumPressDuration: 0.15,
        requireDoubleTap: false
    )
}

// MARK: - Hotkey Configuration

struct HotkeyConfig: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    // Default: Option+Command+V
    static let `default` = HotkeyConfig(
        keyCode: 9,  // V key
        modifiers: UInt32(optionKey | cmdKey)
    )

    // Unset hotkey (no binding)
    static let unset = HotkeyConfig(
        keyCode: 0,
        modifiers: 0
    )

    var isUnset: Bool {
        keyCode == 0 && modifiers == 0
    }

}

// Carbon key modifier constants
private let controlKey: Int = 1 << 12
private let optionKey: Int = 1 << 11
private let shiftKey: Int = 1 << 9
private let cmdKey: Int = 1 << 8

// MARK: - App Settings

class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var appKey: String {
        didSet { defaults.set(appKey, forKey: UserDefaultsKeys.appKey) }
    }

    @Published var accessKey: String {
        didSet { defaults.set(accessKey, forKey: UserDefaultsKeys.accessKey) }
    }

    var resourceID: String {
        ASRConstants.resourceID
    }

    @Published var globalHotkey: HotkeyConfig {
        didSet {
            defaults.set(globalHotkey.keyCode, forKey: UserDefaultsKeys.globalHotkeyKeyCode)
            defaults.set(globalHotkey.modifiers, forKey: UserDefaultsKeys.globalHotkeyModifiers)
            // Notify that hotkey has changed so AppDelegate can re-register
            NotificationCenter.default.post(name: .globalHotkeyChanged, object: nil)
        }
    }

    @Published var windowPositionMode: WindowPositionMode {
        didSet {
            if let encoded = try? JSONEncoder().encode(windowPositionMode) {
                defaults.set(encoded, forKey: UserDefaultsKeys.windowPositionMode)
            }
        }
    }

    @Published var autoPasteAfterClose: Bool {
        didSet { defaults.set(autoPasteAfterClose, forKey: UserDefaultsKeys.autoPasteAfterClose) }
    }

    @Published var removeTrailingPunctuation: Bool {
        didSet { defaults.set(removeTrailingPunctuation, forKey: UserDefaultsKeys.removeTrailingPunctuation) }
    }

    @Published var longPressConfig: LongPressConfig {
        didSet {
            if let encoded = try? JSONEncoder().encode(longPressConfig) {
                defaults.set(encoded, forKey: UserDefaultsKeys.longPressConfig)
            }
            // Notify that long-press config has changed
            NotificationCenter.default.post(name: .longPressConfigChanged, object: nil)
        }
    }

    @Published var context: String {
        didSet { defaults.set(context, forKey: UserDefaultsKeys.context) }
    }

    @Published var contextCaptureEnabled: Bool {
        didSet { defaults.set(contextCaptureEnabled, forKey: UserDefaultsKeys.contextCaptureEnabled) }
    }

    @Published var maxContextLength: Int {
        didSet { defaults.set(maxContextLength, forKey: UserDefaultsKeys.maxContextLength) }
    }

    @Published var selectedMicrophoneUID: String {
        didSet { defaults.set(selectedMicrophoneUID, forKey: UserDefaultsKeys.selectedMicrophoneUID) }
    }

    @Published var glassTintStyle: GlassTintStyle {
        didSet {
            if let encoded = try? JSONEncoder().encode(glassTintStyle) {
                defaults.set(encoded, forKey: UserDefaultsKeys.glassTintStyle)
            }
        }
    }

    @Published var screenEdgeMargin: CGFloat {
        didSet { defaults.set(Double(screenEdgeMargin), forKey: UserDefaultsKeys.screenEdgeMargin) }
    }

    @Published var showMenuBarIcon: Bool {
        didSet {
            defaults.set(showMenuBarIcon, forKey: UserDefaultsKeys.showMenuBarIcon)
            NotificationCenter.default.post(name: .menuBarIconVisibilityChanged, object: nil)
        }
    }

    private init() {
        // Load saved values or use defaults (from reference.py credentials)
        self.appKey = defaults.string(forKey: UserDefaultsKeys.appKey) ?? "3254061168"
        self.accessKey = defaults.string(forKey: UserDefaultsKeys.accessKey) ?? "1jFY86tc4aNrg-8K69dIM43HSjJ_jhyb"

        // Load hotkey config
        let keyCode = defaults.object(forKey: UserDefaultsKeys.globalHotkeyKeyCode) as? UInt32 ?? HotkeyConfig.default.keyCode
        let modifiers = defaults.object(forKey: UserDefaultsKeys.globalHotkeyModifiers) as? UInt32 ?? HotkeyConfig.default.modifiers
        self.globalHotkey = HotkeyConfig(keyCode: keyCode, modifiers: modifiers)

        // Load window position mode with migration from old boolean setting
        if let modeData = defaults.data(forKey: UserDefaultsKeys.windowPositionMode),
           let mode = try? JSONDecoder().decode(WindowPositionMode.self, from: modeData) {
            self.windowPositionMode = mode
        } else if let oldRememberPosition = defaults.object(forKey: UserDefaultsKeys.rememberWindowPosition) as? Bool {
            // Migrate from old boolean setting: true -> rememberLast, false -> topCenter
            let migratedMode: WindowPositionMode = oldRememberPosition ? .rememberLast : .topCenter
            self.windowPositionMode = migratedMode
            log(.info, "Migrated window position setting from boolean to mode: \(migratedMode.rawValue)")
            // Remove old key after migration
            defaults.removeObject(forKey: UserDefaultsKeys.rememberWindowPosition)
        } else {
            // Default to nearMouse for new installations
            self.windowPositionMode = .nearMouse
        }

        self.autoPasteAfterClose = defaults.object(forKey: UserDefaultsKeys.autoPasteAfterClose) as? Bool ?? true

        self.removeTrailingPunctuation = defaults.object(forKey: UserDefaultsKeys.removeTrailingPunctuation) as? Bool ?? true

        // Load long-press config
        if let configData = defaults.data(forKey: UserDefaultsKeys.longPressConfig),
           let config = try? JSONDecoder().decode(LongPressConfig.self, from: configData) {
            self.longPressConfig = config
        } else {
            self.longPressConfig = .default
        }

        // Load context
        self.context = defaults.string(forKey: UserDefaultsKeys.context) ?? ""

        // Load context capture settings
        self.contextCaptureEnabled = defaults.object(forKey: UserDefaultsKeys.contextCaptureEnabled) as? Bool ?? true
        self.maxContextLength = defaults.object(forKey: UserDefaultsKeys.maxContextLength) as? Int ?? UserDefaultsKeys.defaultMaxContextLength

        // Load microphone selection (empty string = system default)
        self.selectedMicrophoneUID = defaults.string(forKey: UserDefaultsKeys.selectedMicrophoneUID) ?? ""

        // Load appearance settings
        if let tintData = defaults.data(forKey: UserDefaultsKeys.glassTintStyle),
           let tint = try? JSONDecoder().decode(GlassTintStyle.self, from: tintData) {
            self.glassTintStyle = tint
        } else {
            self.glassTintStyle = .clear
        }
        self.showMenuBarIcon = defaults.object(forKey: UserDefaultsKeys.showMenuBarIcon) as? Bool ?? true

        self.screenEdgeMargin = CGFloat(defaults.double(forKey: UserDefaultsKeys.screenEdgeMargin))
        if self.screenEdgeMargin == 0 {
            self.screenEdgeMargin = UserDefaultsKeys.defaultScreenEdgeMargin
        }

        // Migrate: Remove deprecated resourceID setting
        if defaults.object(forKey: UserDefaultsKeys.resourceID) != nil {
            defaults.removeObject(forKey: UserDefaultsKeys.resourceID)
            log(.info, "Migrated: Removed deprecated resourceID from UserDefaults")
        }
    }

    func getSavedWindowPosition() -> NSPoint? {
        guard windowPositionMode == .rememberLast,
              let x = defaults.object(forKey: UserDefaultsKeys.windowPositionX) as? CGFloat,
              let y = defaults.object(forKey: UserDefaultsKeys.windowPositionY) as? CGFloat else {
            return nil
        }
        return NSPoint(x: x, y: y)
    }

    func saveWindowPosition(_ position: NSPoint) {
        guard windowPositionMode == .rememberLast else { return }
        defaults.set(position.x, forKey: UserDefaultsKeys.windowPositionX)
        defaults.set(position.y, forKey: UserDefaultsKeys.windowPositionY)
    }

    /// Migrate legacy Carbon hotkey settings to KeyboardShortcuts
    static func migrateHotkeyIfNeeded() {
        let defaults = UserDefaults.standard
        let migrationKey = "Seedling.HotkeyMigrationCompleted"

        guard !defaults.bool(forKey: migrationKey) else { return }

        if let keyCode = defaults.object(forKey: UserDefaultsKeys.globalHotkeyKeyCode) as? UInt32,
           let modifiers = defaults.object(forKey: UserDefaultsKeys.globalHotkeyModifiers) as? UInt32 {

            let key = KeyboardShortcuts.Key(rawValue: Int(keyCode))

            var mods: NSEvent.ModifierFlags = []
            if modifiers & UInt32(cmdKey) != 0 { mods.insert(.command) }
            if modifiers & UInt32(optionKey) != 0 { mods.insert(.option) }
            if modifiers & UInt32(shiftKey) != 0 { mods.insert(.shift) }
            if modifiers & UInt32(controlKey) != 0 { mods.insert(.control) }

            KeyboardShortcuts.setShortcut(.init(key, modifiers: mods), for: .toggleWindow)
            log(.info, "Migrated legacy hotkey to KeyboardShortcuts")
        }

        defaults.set(true, forKey: migrationKey)
    }

}
