//
//  AccessibilityTextCapture.swift
//  Seedling
//
//  Captures text content from other applications using macOS Accessibility API
//  with browser support via AppleScript + JavaScript
//

import Foundation
import AppKit
import ApplicationServices
import OSLog

// MARK: - Captured Text Context

/// Holds captured text and metadata from another application
struct CapturedTextContext: Sendable {
    /// The captured text content
    let text: String

    /// Document path if available (e.g., from editors)
    let documentPath: String?

    /// Name of the source application
    let applicationName: String

    /// Bundle identifier of the source application
    let bundleIdentifier: String?

    /// Timestamp when the context was captured
    let capturedAt: Date

    /// Whether any text was actually captured
    var hasContent: Bool {
        !text.isEmpty
    }

    /// Truncate text to a maximum length
    func truncated(to maxLength: Int) -> CapturedTextContext {
        guard text.count > maxLength else { return self }

        let truncatedText = String(text.prefix(maxLength))
        return CapturedTextContext(
            text: truncatedText,
            documentPath: documentPath,
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            capturedAt: capturedAt
        )
    }
}

// MARK: - Browser Type

private enum BrowserType {
    case safari
    case chrome  // Chrome, Edge, Arc use same AppleScript API
}

// MARK: - Accessibility Text Capture

/// Service for capturing text from other applications via Accessibility API
/// with special handling for browsers using AppleScript + JavaScript
class AccessibilityTextCapture {
    static let shared = AccessibilityTextCapture()

    /// Map of browser bundle IDs to their types
    private let browsers: [String: BrowserType] = [
        // Safari
        "com.apple.Safari": .safari,

        // Chrome 系列
        "com.google.Chrome": .chrome,
        "com.google.Chrome.canary": .chrome,

        // Microsoft Edge
        "com.microsoft.edgemac": .chrome,

        // Arc
        "company.thebrowser.Browser": .chrome,

        // Brave
        "com.brave.Browser": .chrome,

        // Opera
        "com.operasoftware.Opera": .chrome,
        "com.operasoftware.OperaGX": .chrome,

        // Vivaldi
        "com.vivaldi.Vivaldi": .chrome,

        // Chromium
        "org.chromium.Chromium": .chrome,

        // DuckDuckGo
        "com.duckduckgo.macos.browser": .chrome,

        // Sidekick
        "com.pushplaylabs.sidekick": .chrome

        // Note: Dia (company.thebrowser.dia) is NOT supported
        // It doesn't expose Chrome's AppleScript API ("Expected end of line but found class name")
        // and returns 0 chars via Accessibility API
    ]

    // MARK: - Fallback Configuration

    /// 文件内容与 Accessibility 文本长度比值阈值
    /// 如果文件内容超过此倍数，优先使用文件
    private let filePreferenceRatio: Double = 3.0

    /// 最小"足够"文本长度
    /// 低于此值时，始终尝试文件回退
    private let minAdequateTextLength: Int = 100

    private init() {}

    // MARK: - Permission Checking

    /// Check if accessibility permission is granted
    /// - Parameter prompt: If true, shows system prompt to request permission
    /// - Returns: true if permission is granted
    func checkPermission(prompt: Bool = false) -> Bool {
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            return AXIsProcessTrustedWithOptions(options as CFDictionary)
        } else {
            // Pass nil instead of empty dictionary to avoid crash
            return AXIsProcessTrustedWithOptions(nil)
        }
    }

    // MARK: - Text Capture

    /// Capture text from a known application (used when we already know the app info)
    /// This is more reliable for browsers since it doesn't depend on AX API to get the focused app
    /// - Parameters:
    ///   - bundleId: The bundle identifier of the application
    ///   - appName: The name of the application
    /// - Returns: CapturedTextContext with the captured text, or nil if capture failed
    func captureFromApp(bundleId: String, appName: String) -> CapturedTextContext? {
        log(.info, "Starting text capture from known app: \(appName) (\(bundleId))")

        // Check if this is a browser - use AppleScript + JavaScript for page content
        // This is tried FIRST before any AX API calls to avoid timing issues
        if let browserType = browsers[bundleId] {
            let browserTypeName = browserType == .safari ? "Safari" : "Chromium"
            log(.info, "Detected browser: \(appName) (type: \(browserTypeName))")
            if let text = captureFromBrowser(bundleId: bundleId, type: browserType),
               !text.isEmpty {
                log(.info, "Browser capture success: \(text.count) chars via AppleScript+JS")
                return CapturedTextContext(
                    text: text,
                    documentPath: nil,
                    applicationName: appName,
                    bundleIdentifier: bundleId,
                    capturedAt: Date()
                )
            }
            log(.warning, "AppleScript capture failed for browser, falling back to AX API")
        }

        // Fall back to the general capture method
        return captureFromFocusedApp()
    }

    /// Capture text from the currently focused application
    /// - Returns: CapturedTextContext with the captured text, or nil if capture failed
    func captureFromFocusedApp() -> CapturedTextContext? {
        log(.info, "Starting text capture from focused app")

        // Check permission first
        guard checkPermission(prompt: false) else {
            log(.warning, "Accessibility permission not granted")
            return nil
        }

        // Get system-wide accessibility element
        let systemWide = AXUIElementCreateSystemWide()

        // Get focused application
        var focusedAppRef: CFTypeRef?
        let appResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &focusedAppRef
        )

        guard appResult == .success,
              let focusedApp = focusedAppRef else {
            log(.warning, "Failed to get focused application: \(appResult.rawValue)")
            return nil
        }

        let appElement = focusedApp as! AXUIElement

        // Get application info
        let appInfo = getApplicationInfo(from: appElement)
        log(.info, "Capturing from: \(appInfo.name) (\(appInfo.bundleID ?? "unknown"))")

        // Check if this is a browser - use AppleScript + JavaScript for page content
        if let bundleId = appInfo.bundleID,
           let browserType = browsers[bundleId] {
            let browserTypeName = browserType == .safari ? "Safari" : "Chromium"
            log(.info, "Detected browser: \(appInfo.name) (type: \(browserTypeName))")
            if let text = captureFromBrowser(bundleId: bundleId, type: browserType),
               !text.isEmpty {
                log(.info, "Browser capture success: \(text.count) chars via AppleScript+JS")
                return CapturedTextContext(
                    text: text,
                    documentPath: nil,
                    applicationName: appInfo.name,
                    bundleIdentifier: bundleId,
                    capturedAt: Date()
                )
            }
            log(.warning, "AppleScript capture failed, falling back to Accessibility API")
        }

        // Non-browser apps or browser fallback: use Accessibility API
        let accessibilityText = captureText(from: appElement)
        log(.info, "Accessibility API captured \(accessibilityText.count) chars")

        // Try to get document path
        let documentPath = getDocumentPath(from: appElement)
        if let path = documentPath {
            log(.debug, "Document path found: \(path)")
        } else {
            log(.debug, "No document path available")
        }

        // Smart fallback logic: compare accessibility text with file content
        var finalText = accessibilityText
        var usedSource = "accessibility"

        if let path = documentPath {
            // Always try to read file content for comparison
            log(.info, "Attempting file read for comparison: \(path)")

            // Capture maxLength before Task to avoid MainActor deadlock
            let maxLength = AppSettings.shared.maxContextLength

            // Synchronous read since this method is synchronous
            let semaphore = DispatchSemaphore(value: 0)
            var fileContent: String?
            Task.detached {
                fileContent = await DocumentContentReader.shared.readContent(
                    from: path,
                    maxLength: maxLength
                )
                semaphore.signal()
            }
            semaphore.wait()

            if let content = fileContent {
                log(.info, "File read success: \(content.count) chars from \(path)")

                // Decide which source to use
                let shouldPreferFile: Bool
                let reason: String

                if accessibilityText.isEmpty {
                    shouldPreferFile = true
                    reason = "accessibility text is empty"
                } else if accessibilityText.count < minAdequateTextLength {
                    shouldPreferFile = true
                    reason = "accessibility text too short (\(accessibilityText.count) < \(minAdequateTextLength))"
                } else if Double(content.count) > Double(accessibilityText.count) * filePreferenceRatio {
                    shouldPreferFile = true
                    reason = "file is \(String(format: "%.1fx", Double(content.count) / Double(accessibilityText.count))) longer"
                } else {
                    shouldPreferFile = false
                    reason = "accessibility text is adequate (\(accessibilityText.count) chars)"
                }

                if shouldPreferFile {
                    log(.info, "Using FILE content: \(reason)")
                    finalText = content
                    usedSource = "file"
                } else {
                    log(.info, "Using ACCESSIBILITY content: \(reason)")
                }
            } else {
                log(.debug, "File read failed or unsupported type: \(path)")
            }
        }

        if finalText.isEmpty {
            log(.info, "No text captured from \(appInfo.name)")
            return nil
        }

        log(.info, "Final result: \(finalText.count) chars from \(usedSource) [\(appInfo.name)]")

        return CapturedTextContext(
            text: finalText,
            documentPath: documentPath,
            applicationName: appInfo.name,
            bundleIdentifier: appInfo.bundleID,
            capturedAt: Date()
        )
    }

    // MARK: - Browser Capture

    /// Capture entire page content from a browser using AppleScript + JavaScript
    /// - Parameters:
    ///   - bundleId: The browser's bundle identifier
    ///   - type: The browser type (Safari or Chrome-like)
    /// - Returns: The page text content, or nil if capture failed
    private func captureFromBrowser(bundleId: String, type: BrowserType) -> String? {
        // JavaScript to clone body, remove script/style/noscript elements, and return pure text
        let js = "(function(){var c=document.body.cloneNode(true);c.querySelectorAll('script,style,noscript').forEach(function(e){e.remove()});return c.innerText})()"

        let script: String
        switch type {
        case .safari:
            script = """
            tell application id "\(bundleId)"
                do JavaScript "\(js)" in document 1
            end tell
            """
        case .chrome:
            script = """
            tell application id "\(bundleId)"
                tell active tab of front window
                    execute javascript "\(js)"
                end tell
            end tell
            """
        }

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script),
           let result = appleScript.executeAndReturnError(&error).stringValue {
            return result
        }

        if let error = error {
            log(.warning, "AppleScript error for \(bundleId): \(error)")
        }

        return nil
    }

    // MARK: - Private Methods

    /// Get application name and bundle identifier
    private func getApplicationInfo(from appElement: AXUIElement) -> (name: String, bundleID: String?) {
        var titleRef: CFTypeRef?
        var name = "Unknown"

        if AXUIElementCopyAttributeValue(appElement, kAXTitleAttribute as CFString, &titleRef) == .success,
           let title = titleRef as? String {
            name = title
        }

        // Try to get bundle identifier from PID
        var pid: pid_t = 0
        if AXUIElementGetPid(appElement, &pid) == .success {
            if let app = NSRunningApplication(processIdentifier: pid) {
                if let bundleID = app.bundleIdentifier {
                    return (app.localizedName ?? name, bundleID)
                }
            }
        }

        return (name, nil)
    }

    /// Capture text from the focused element or window
    private func captureText(from appElement: AXUIElement) -> String {
        // First, try to get focused UI element
        var focusedElementRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        ) == .success {
            let focusedElement = focusedElementRef as! AXUIElement

            // Try to get value from focused element (works for text fields, editors)
            if let text = getTextValue(from: focusedElement) {
                log(.debug, "Got text from focused element")
                return text
            }

            // Try to get selected text
            if let selectedText = getSelectedText(from: focusedElement), !selectedText.isEmpty {
                log(.debug, "Got selected text from focused element")
                return selectedText
            }
        }

        // If no focused element text, try to get text from the focused window
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowRef
        ) == .success {
            let windowElement = windowRef as! AXUIElement

            // Try to find text areas in the window
            if let text = findTextInChildren(of: windowElement, maxDepth: 5) {
                log(.debug, "Got text from window children")
                return text
            }
        }

        return ""
    }

    /// Get text value from an element
    private func getTextValue(from element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
           let value = valueRef as? String {
            return value
        }
        return nil
    }

    /// Get selected text from an element
    private func getSelectedText(from element: AXUIElement) -> String? {
        var selectedTextRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedTextRef) == .success,
           let selectedText = selectedTextRef as? String {
            return selectedText
        }
        return nil
    }

    /// Recursively search for text content in child elements
    private func findTextInChildren(of element: AXUIElement, maxDepth: Int) -> String? {
        guard maxDepth > 0 else { return nil }

        // Try to get value from this element
        if let text = getTextValue(from: element), !text.isEmpty {
            return text
        }

        // Get children
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return nil
        }

        // Search children for text content
        for child in children {
            // Check role to prioritize text areas
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef) == .success,
               let role = roleRef as? String {

                // Prioritize text-related roles
                if role == kAXTextAreaRole as String ||
                   role == kAXTextFieldRole as String ||
                   role == kAXStaticTextRole as String {
                    if let text = getTextValue(from: child), !text.isEmpty {
                        return text
                    }
                }
            }

            // Recursively search
            if let text = findTextInChildren(of: child, maxDepth: maxDepth - 1) {
                return text
            }
        }

        return nil
    }

    /// Get document path from the application
    private func getDocumentPath(from appElement: AXUIElement) -> String? {
        // Try focused window first
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowRef
        ) == .success {
            let windowElement = windowRef as! AXUIElement

            // Try document attribute
            var documentRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(windowElement, kAXDocumentAttribute as CFString, &documentRef) == .success,
               let document = documentRef as? String {
                // Convert file:// URL to path
                if document.hasPrefix("file://") {
                    return URL(string: document)?.path
                }
                return document
            }
        }

        return nil
    }
}
