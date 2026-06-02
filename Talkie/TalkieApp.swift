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
    }
}
