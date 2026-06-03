//
//  TalkieApp.swift
//  Talkie
//
//  Menu bar app entry point
//

import SwiftUI

@main
struct TalkieApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            // Replace the default "Settings…" command so Cmd+, opens our custom settings
            // window (via AppDelegate) instead of the empty SwiftUI Settings scene, which
            // otherwise pops a blank window.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
