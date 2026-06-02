//
//  DocumentContentReader.swift
//  Seedling
//
//  Reads text content from document files when Accessibility API cannot capture text
//

import Foundation

/// Reads document content from file system as fallback when Accessibility API fails
actor DocumentContentReader {
    static let shared = DocumentContentReader()

    /// Maximum characters to read from file
    private let maxFileCharacters: Int = 10_000

    /// Maximum file size to read (1 MB limit for plain text)
    private let maxFileSize: Int = 1 * 1024 * 1024

    /// Bytes to sample for text detection
    private let sampleSize: Int = 8192

    private init() {}

    // MARK: - Public API

    /// Read content from a document path
    /// - Parameters:
    ///   - path: The file path to read
    ///   - maxLength: Maximum content length to return (truncates from beginning, keeps end)
    /// - Returns: File content string, or nil if file cannot be read
    func readContent(from path: String, maxLength: Int) async -> String? {
        let filename = URL(fileURLWithPath: path).lastPathComponent
        log(.debug, "Attempting to read document: \(filename)")

        // Security checks
        guard isPathValid(path) else {
            log(.debug, "Path validation failed: \(path)")
            return nil
        }

        // Check if file is plain text by content
        guard isPlainTextFile(path) else {
            log(.debug, "File is not plain text: \(filename)")
            return nil
        }

        // Use the smaller of maxLength and maxFileCharacters
        let effectiveMaxLength = min(maxLength, maxFileCharacters)

        // Read file content
        guard let content = readFileContent(from: path, maxLength: effectiveMaxLength) else {
            log(.warning, "Failed to read file content: \(filename)")
            return nil
        }

        log(.info, "Read \(content.count) chars from \(filename)")
        return content
    }

    // MARK: - Private Methods

    /// Validate path for security
    private func isPathValid(_ path: String) -> Bool {
        // Must be absolute path
        guard path.hasPrefix("/") else { return false }

        // Prevent path traversal
        guard !path.contains("..") else { return false }

        // Check if file exists and is readable
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
        guard !isDirectory.boolValue else { return false }
        guard fileManager.isReadableFile(atPath: path) else { return false }

        return true
    }

    /// Check if file is plain text by reading its content
    private func isPlainTextFile(_ path: String) -> Bool {
        guard let fileHandle = FileHandle(forReadingAtPath: path) else {
            return false
        }

        defer { try? fileHandle.close() }

        // Read first N bytes to check
        guard let data = try? fileHandle.read(upToCount: sampleSize),
              !data.isEmpty else {
            return false
        }

        // Check for null bytes (strong indicator of binary)
        if data.contains(0x00) {
            log(.debug, "File contains null bytes, likely binary")
            return false
        }

        // Must be valid UTF-8
        guard String(data: data, encoding: .utf8) != nil else {
            log(.debug, "File is not valid UTF-8")
            return false
        }

        return true
    }

    /// Read file content (up to maxLength characters from end)
    private func readFileContent(from path: String, maxLength: Int) -> String? {
        guard let fileHandle = FileHandle(forReadingAtPath: path) else {
            return nil
        }

        defer { try? fileHandle.close() }

        do {
            let fileSize = try fileHandle.seekToEnd()

            // Check file size limit
            guard fileSize <= UInt64(maxFileSize) else {
                log(.debug, "File too large: \(fileSize) bytes, skipping")
                return nil
            }

            // Read from end if file is large, accounting for multi-byte chars
            let bytesToRead = min(UInt64(maxLength * 4), fileSize)
            let startPosition = fileSize - bytesToRead

            try fileHandle.seek(toOffset: startPosition)

            guard let data = try fileHandle.readToEnd() else {
                return nil
            }

            // Decode as UTF-8
            guard let text = String(data: data, encoding: .utf8) else {
                return nil
            }

            // If we started mid-file, skip to first complete line
            var result = text
            if startPosition > 0, let newlineIndex = result.firstIndex(of: "\n") {
                result = String(result[result.index(after: newlineIndex)...])
            }

            // Truncate to maxLength if needed (keep end)
            return result.count > maxLength ? String(result.suffix(maxLength)) : result

        } catch {
            return nil
        }
    }
}
