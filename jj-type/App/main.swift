//
//  main.swift
//  jj-type
//
//  Explicit entry point (Iter6): the @main AppKit bootstrap proved broken on
//  this macOS 26.0 beta / Xcode 26.1 toolchain (delegate never instantiated,
//  process idled) — main.swift bypasses that machinery entirely and is decisive.
//  Top-level code is nonisolated; bridge to the main actor for AppKit setup.
//

import AppKit

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
