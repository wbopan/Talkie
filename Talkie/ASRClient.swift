//
//  ASRClient.swift
//  Seedling
//
//  WebSocket client for Seed ASR API with binary protocol
//

import Foundation

// MARK: - Protocol Encoding/Decoding

/// Binary protocol packet builder
enum BinaryProtocol {
    /// Build full request packet (initial connection)
    nonisolated static func buildFullRequest(config: ASRConfig, sequence: Int32 = 1) -> Data? {
        let header = ProtocolHeader(
            messageType: .full,
            flags: ProtocolHeader.MessageTypeFlags.posSequence,
            compression: .gzip  // Now using proper GZIP compression
        )
        let jsonPayload = config.toFullRequestJSON()

        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonPayload),
              let compressedPayload = jsonData.gzipCompressed() else {
            log(.error, "Failed to create/compress JSON payload")
            return nil
        }

        var packet = Data()
        packet.append(header.encode())
        packet.appendInt32BE(sequence)
        packet.appendUInt32BE(UInt32(compressedPayload.count))
        packet.append(compressedPayload)

        log(.debug, "Full request: JSON=\(jsonData.count)B → GZIP=\(compressedPayload.count)B")

        return packet
    }

    /// Build audio-only request packet
    nonisolated static func buildAudioRequest(audioData: Data, sequence: Int32, isFinal: Bool = false) -> Data? {
        // Use NEG_WITH_SEQUENCE for final packet, POS_SEQUENCE for regular packets
        let flags = isFinal ? ProtocolHeader.MessageTypeFlags.negWithSequence : ProtocolHeader.MessageTypeFlags.posSequence

        let header = ProtocolHeader(
            messageType: .audio,
            flags: flags,
            compression: .gzip  // Now using proper GZIP compression
        )

        guard let compressedAudio = audioData.gzipCompressed() else {
            log(.error, "Failed to compress audio data")
            return nil
        }

        var packet = Data()
        packet.append(header.encode())

        // If final packet, send negative sequence number
        let sequenceValue = isFinal ? -sequence : sequence
        packet.appendInt32BE(sequenceValue)
        packet.appendUInt32BE(UInt32(compressedAudio.count))
        packet.append(compressedAudio)

        return packet
    }

    /// Parse response packet (matches Python reference implementation)
    nonisolated static func parseResponse(data: Data) -> ASRResult? {
        // Validate minimum packet size (header)
        guard data.count >= 4 else {
            log(.error, "Response packet too small: \(data.count) bytes")
            return nil
        }

        // Parse header bytes
        let headerSize = Int(data[0] & 0x0f)
        let messageType = (data[1] >> 4) & 0x0f
        let messageTypeSpecificFlags = data[1] & 0x0f
        let compressionType = data[2] & 0x0f

        var offset = headerSize * 4  // Skip header

        // Check flags and read sequence if present (bit 0x01)
        var sequence: Int32 = 0
        if (messageTypeSpecificFlags & 0x01) != 0 {
            guard let seq = data.readInt32BE(at: offset) else {
                log(.error, "Failed to read sequence")
                return nil
            }
            sequence = seq
            offset += 4
        }

        // Check if last package (bit 0x02)
        let isLastPackage = (messageTypeSpecificFlags & 0x02) != 0

        // Skip 4 bytes if flag 0x04 is set
        if (messageTypeSpecificFlags & 0x04) != 0 {
            offset += 4
        }

        var code = 0
        var payloadSize: UInt32 = 0

        // Handle different message types
        if messageType == 0b1001 {  // SERVER_FULL_RESPONSE
            guard let size = data.readUInt32BE(at: offset) else {
                log(.error, "Failed to read payload size")
                return nil
            }
            payloadSize = size
            offset += 4
        } else if messageType == 0b1111 {  // SERVER_ERROR_RESPONSE
            guard let errorCode = data.readInt32BE(at: offset) else {
                log(.error, "Failed to read error code")
                return nil
            }
            code = Int(errorCode)
            offset += 4

            guard let size = data.readUInt32BE(at: offset) else {
                log(.error, "Failed to read payload size")
                return nil
            }
            payloadSize = size
            offset += 4
        } else {
            log(.error, "Unknown message type: \(messageType)")
            return nil
        }

        // Extract payload
        let payloadEnd = offset + Int(payloadSize)
        guard payloadEnd <= data.count else {
            log(.error, "Payload size mismatch: expected \(payloadSize), available \(data.count - offset)")
            return nil
        }

        var payload = data[offset..<payloadEnd]

        // Return early if no payload
        if payload.isEmpty {
            log(.debug, "Empty payload response - seq:\(sequence) code:\(code) final:\(isLastPackage)")
            return ASRResult(
                text: "",
                isLastPackage: isLastPackage,
                sequence: Int(sequence),
                code: code,
                message: code != 0 ? "Error \(code)" : ""
            )
        }

        // Decompress if needed (compression type 1 = gzip)
        if compressionType == 0b0001 {
            guard let decompressed = payload.gzipDecompressed() else {
                log(.error, "Failed to decompress gzip payload")
                return nil
            }
            payload = decompressed
        }

        // Parse JSON payload
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            log(.error, "Failed to parse JSON payload")
            return nil
        }

        // Extract fields from JSON
        if let jsonCode = json["code"] as? Int {
            code = jsonCode
        }
        let message = json["message"] as? String ?? (code != 0 ? "Error \(code)" : "")

        // Extract text from result (matches actual server JSON structure)
        var text = ""
        if let result = json["result"] as? [String: Any] {
            text = result["text"] as? String ?? ""
        }

        log(.debug, "ASR Response - seq:\(sequence) code:\(code) text:[\(text)] final:\(isLastPackage)")

        return ASRResult(
            text: text,
            isLastPackage: isLastPackage,
            sequence: Int(sequence),
            code: code,
            message: message
        )
    }
}

// MARK: - ASR Client Actor

/// Thread-safe WebSocket client for Seed ASR
actor ASRClient {
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var resultContinuation: AsyncStream<ASRResult>.Continuation?
    private var sequence: Int32 = 1
    private var isConnected = false
    private var receivedFinalResult = false
    private var finalResultContinuation: CheckedContinuation<Void, Never>?

    // MARK: - Connection Management

    /// Connect to Seed ASR WebSocket
    func connect(config: ASRConfig) async throws {
        // If a previous session exists, clean it up first to ensure proper state reset
        if session != nil {
            log(.info, "Previous session exists, cleaning up before reconnect...")
            await disconnect()
        }

        // Explicitly reset sequence number to ensure new session starts from 1
        sequence = 1

        guard !isConnected else {
            log(.warning, "Already connected")
            return
        }

        log(.info, "Connecting to Seed ASR...")

        // Create URL
        guard let url = URL(string: ASRConstants.apiURL) else {
            throw ASRError.invalidURL
        }

        // Create request with auth headers
        var request = URLRequest(url: url)
        request.setValue(config.resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(config.accessKey, forHTTPHeaderField: "X-Api-Access-Key")
        request.setValue(config.appKey, forHTTPHeaderField: "X-Api-App-Key")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")

        // Create session and WebSocket task
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 30
        session = URLSession(configuration: sessionConfig)

        webSocketTask = session?.webSocketTask(with: request)
        webSocketTask?.resume()

        // Send full request packet
        guard let fullRequestPacket = BinaryProtocol.buildFullRequest(config: config, sequence: sequence) else {
            throw ASRError.protocolError("Failed to build full request")
        }

        try await sendBinaryMessage(fullRequestPacket)
        sequence += 1

        isConnected = true
        receivedFinalResult = false
        finalResultContinuation = nil

        // Start receiving responses
        Task {
            await startReceivingMessages()
        }

        log(.info, "Connected to Seed ASR")
    }

    /// Disconnect from WebSocket
    func disconnect() async {
        log(.info, "Disconnecting from Seed ASR (isConnected=\(isConnected))...")

        // Always execute cleanup, even if isConnected is already false
        // This ensures resources are released in all cases
        isConnected = false
        receivedFinalResult = false
        finalResultContinuation?.resume()
        finalResultContinuation = nil
        resultContinuation?.finish()
        resultContinuation = nil

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil

        sequence = 1

        log(.info, "Disconnected from Seed ASR")
    }

    // MARK: - Audio Streaming

    /// Send audio data to ASR
    func sendAudioData(_ audioData: Data) async throws {
        guard isConnected else {
            throw ASRError.notConnected
        }

        guard let audioPacket = BinaryProtocol.buildAudioRequest(
            audioData: audioData,
            sequence: sequence,
            isFinal: false
        ) else {
            throw ASRError.protocolError("Failed to build audio packet")
        }

        try await sendBinaryMessage(audioPacket)
        sequence += 1
    }

    /// Send final audio packet to signal end of stream
    func sendFinalPacket() async throws {
        guard isConnected else {
            throw ASRError.notConnected
        }

        log(.info, "Sending final packet...")

        // Send empty audio with negative sequence to signal end
        let emptyAudio = Data()
        guard let finalPacket = BinaryProtocol.buildAudioRequest(
            audioData: emptyAudio,
            sequence: sequence,
            isFinal: true
        ) else {
            throw ASRError.protocolError("Failed to build final packet")
        }

        try await sendBinaryMessage(finalPacket)
        log(.info, "Final packet sent")
    }

    /// Wait for final result with timeout (1.5 seconds)
    func waitForFinalResult(timeout: TimeInterval = 1.5) async {
        log(.info, "Waiting for final result (timeout: \(timeout)s)...")

        if receivedFinalResult {
            log(.info, "Final result already received")
            return
        }

        // Schedule timeout to resume continuation if server doesn't respond in time
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.timeoutFinalResultWait()
        }

        // Suspend until signaled by handleReceivedData, disconnect, or timeout.
        // The closure runs synchronously on the actor before suspension,
        // so there is no race with handleReceivedData.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if receivedFinalResult {
                continuation.resume()
            } else {
                finalResultContinuation = continuation
            }
        }

        timeoutTask.cancel()
        finalResultContinuation = nil
    }

    /// Resume the final-result continuation on timeout
    private func timeoutFinalResultWait() {
        guard finalResultContinuation != nil else { return }
        log(.info, "Wait timeout reached")
        finalResultContinuation?.resume()
        finalResultContinuation = nil
    }

    // MARK: - Result Stream

    /// Get AsyncStream of ASR results
    func resultStream() -> AsyncStream<ASRResult> {
        AsyncStream { continuation in
            self.resultContinuation = continuation
        }
    }

    // MARK: - Private Methods

    private func sendBinaryMessage(_ data: Data) async throws {
        guard let task = webSocketTask else {
            throw ASRError.notConnected
        }

        let message = URLSessionWebSocketTask.Message.data(data)
        try await task.send(message)
    }

    private func startReceivingMessages() async {
        while isConnected {
            do {
                guard let task = webSocketTask else { break }

                let message = try await task.receive()

                switch message {
                case .data(let data):
                    await handleReceivedData(data)

                case .string(let text):
                    log(.warning, "Received unexpected text message: \(text)")

                @unknown default:
                    log(.warning, "Received unknown message type")
                }

            } catch {
                // Check if still connected (error might be from disconnect)
                if isConnected {
                    log(.error, "WebSocket receive error: \(error)")
                    // Reset connection state to allow reconnection
                    isConnected = false
                    resultContinuation?.finish()
                }
                break
            }
        }

        log(.info, "Stopped receiving messages, isConnected=\(isConnected)")
    }

    private func handleReceivedData(_ data: Data) async {
        guard let result = BinaryProtocol.parseResponse(data: data) else {
            log(.error, "Failed to parse response")
            return
        }

        // Check for errors
        if !result.isSuccess {
            log(.error, "ASR error - code:\(result.code) message:\(result.message)")
        }

        // Emit result to stream FIRST (fixes race condition)
        resultContinuation?.yield(result)

        // THEN mark completion and wake up waiter
        if result.isLastPackage {
            log(.info, "Received final result")
            receivedFinalResult = true
            finalResultContinuation?.resume()
            finalResultContinuation = nil
        }
    }
}

// MARK: - Error Types

enum ASRError: Error, LocalizedError {
    case invalidURL
    case notConnected
    case protocolError(String)
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid ASR API URL"
        case .notConnected:
            return "Not connected to ASR service"
        case .protocolError(let msg):
            return "Protocol error: \(msg)"
        case .connectionFailed(let msg):
            return "Connection failed: \(msg)"
        }
    }
}
