//
//  SeedlingApp.swift
//  Seedling
//
//  Menu bar app entry point
//

import SwiftUI

@main
struct SeedlingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
