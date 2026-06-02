//
//  ContextProcessor.swift
//  Seedling
//
//  Processes captured context text for ASR - cleans and truncates from the end
//

import Foundation
import OSLog

// MARK: - Models

/// Result of context processing
struct ProcessedContext: Sendable {
    /// The processed text
    let text: String

    /// Original text length before processing
    let originalLength: Int
}

// MARK: - Context Processor

/// Processes captured text context for ASR
/// Cleans the text and takes the last N characters (most recent content is most relevant)
actor ContextProcessor {
    static let shared = ContextProcessor()

    private let logger = Logger.accessibility

    private init() {}

    /// Process text: clean and take last maxLength characters
    /// - Parameters:
    ///   - text: The raw text to process
    ///   - maxLength: Maximum length of output text (takes from the end)
    /// - Returns: ProcessedContext with cleaned and truncated text
    func process(text: String, maxLength: Int) async -> ProcessedContext {
        let originalLength = text.count
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")

        // Create debug session directory
        let sessionDir = createDebugSessionDir(timestamp: timestamp)

        // Handle empty text
        guard !text.isEmpty else {
            return ProcessedContext(text: "", originalLength: 0)
        }

        // Write input
        writeDebugFile(dir: sessionDir, name: "1_input.txt", content: """
            ═══════════════════════════════════════════════════════════════
            INPUT
            ═══════════════════════════════════════════════════════════════
            Length: \(originalLength) chars
            Max Output: \(maxLength) chars

            ───────────────────────────────────────────────────────────────
            RAW TEXT:
            ───────────────────────────────────────────────────────────────
            \(text)
            """)

        // Step 1: Clean text
        let cleanedText = cleanText(text)

        writeDebugFile(dir: sessionDir, name: "2_cleaned.txt", content: """
            ═══════════════════════════════════════════════════════════════
            CLEANED
            ═══════════════════════════════════════════════════════════════
            Original: \(originalLength) chars
            After cleaning: \(cleanedText.count) chars
            Removed: \(originalLength - cleanedText.count) chars

            ───────────────────────────────────────────────────────────────
            CLEANED TEXT:
            ───────────────────────────────────────────────────────────────
            \(cleanedText)
            """)

        // Step 2: Take last maxLength characters (most recent content)
        let outputText: String
        if cleanedText.count <= maxLength {
            outputText = cleanedText
        } else {
            // Take from the end
            let startIndex = cleanedText.index(cleanedText.endIndex, offsetBy: -maxLength)
            outputText = String(cleanedText[startIndex...])
        }

        writeDebugFile(dir: sessionDir, name: "3_output.txt", content: """
            ═══════════════════════════════════════════════════════════════
            OUTPUT (last \(maxLength) chars)
            ═══════════════════════════════════════════════════════════════
            Input: \(originalLength) chars
            Cleaned: \(cleanedText.count) chars
            Output: \(outputText.count) chars
            Strategy: Take from end (most recent content)

            ───────────────────────────────────────────────────────────────
            OUTPUT TEXT:
            ───────────────────────────────────────────────────────────────
            \(outputText)
            """)

        logger.info("Context processed: \(originalLength) -> \(outputText.count) chars (from end)")
        print("[ContextProcessor] \(originalLength) -> \(outputText.count) chars, saved to: \(sessionDir?.path ?? "nil")")

        return ProcessedContext(
            text: outputText,
            originalLength: originalLength
        )
    }

    // MARK: - Debug Helpers

    private func createDebugSessionDir(timestamp: String) -> URL? {
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Seedling", isDirectory: true)
            .appendingPathComponent("context_\(timestamp)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
            return baseDir
        } catch {
            logger.error("Failed to create debug dir: \(error.localizedDescription)")
            return nil
        }
    }

    private func writeDebugFile(dir: URL?, name: String, content: String) {
        guard let dir = dir else { return }
        let fileURL = dir.appendingPathComponent(name)
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to write \(name): \(error.localizedDescription)")
        }
    }

    // MARK: - Private Methods

    /// Clean text:
    /// 1. Trim trailing spaces from each line
    /// 2. Normalize consecutive newlines (3+ -> 2)
    /// 3. Remove special characters (emoji, symbols)
    private func cleanText(_ text: String) -> String {
        // Step 1: Trim trailing spaces from each line
        let lines = text.components(separatedBy: "\n")
        let trimmedLines = lines.map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }

        // Step 2: Join and normalize consecutive newlines (3+ -> 2)
        let joined = trimmedLines.joined(separator: "\n")
        let normalized = joined.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)

        // Step 3: Remove special characters (emoji, symbols)
        var result = ""
        result.reserveCapacity(normalized.count)

        for scalar in normalized.unicodeScalars {
            let category = scalar.properties.generalCategory

            switch category {
            case .otherSymbol,          // Emoji, misc symbols
                 .modifierSymbol,       // Modifier symbols
                 .privateUse,           // Private use area
                 .surrogate,            // Surrogates
                 .unassigned:           // Unassigned
                continue
            default:
                result.append(Character(scalar))
            }
        }

        return result
    }
}
