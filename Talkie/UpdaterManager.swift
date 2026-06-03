//
//  UpdaterManager.swift
//  Talkie
//
//  Shared wrapper around Sparkle's updater so both the menu bar item and the
//  About settings tab can trigger "Check for Updates" from one place.
//

import Foundation
import Combine
import Sparkle

@MainActor
final class UpdaterManager: ObservableObject {
    static let shared = UpdaterManager()

    /// The Sparkle controller. `startingUpdater: true` begins automatic background
    /// checks per the Info.plist (SUEnableAutomaticChecks / SUFeedURL).
    let controller: SPUStandardUpdaterController

    /// Whether a manual update check can be started right now (false while one is in
    /// flight). Drives the enabled state of the "Check for Updates" controls.
    @Published var canCheckForUpdates = false

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// Start a user-initiated update check (shows Sparkle's UI).
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
