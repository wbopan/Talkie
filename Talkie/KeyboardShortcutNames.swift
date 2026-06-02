//
//  KeyboardShortcutNames.swift
//  Seedling
//
//  Defines global keyboard shortcut names using KeyboardShortcuts library
//

import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleWindow = Self("toggleWindow", default: .init(.v, modifiers: [.command, .option]))
}
