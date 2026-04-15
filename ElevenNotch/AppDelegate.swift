//
//  AppDelegate.swift
//  ElevenNotch
//
//  Created by Janusz Polowczyk on 26/03/2026.
//

import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {

    var isFirstOpen = false
    var mainWindowController: NotchWindowController?
    var timer: Timer?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(rebuildApplicationWindows),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        NSApp.setActivationPolicy(.accessory)

        _ = EventMonitors.shared
        let timer = Timer.scheduledTimer(
            withTimeInterval: 1,
            repeats: true) { [weak self] _ in
                self?.determinePIDMatch()
                self?.makeKeyAndVisibleIfNeeded()
            }
        self.timer = timer

        rebuildApplicationWindows()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func findScreenFit() -> NSScreen? {
        if let screen = NSScreen.builtIn, screen.notchSize != .zero {
            return screen
        }
        return .main
    }

    @objc func rebuildApplicationWindows() {
        defer { isFirstOpen = false }
        if let mainWindowController {
            mainWindowController.destroy()
        }
        mainWindowController = nil
        guard let mainScreen = findScreenFit() else { return }
        mainWindowController = .init(screen: mainScreen)

        if isFirstOpen {
            mainWindowController?.openAfterCreate = true
        }
    }

    func determinePIDMatch() {
        let pid = String(NSRunningApplication.current.processIdentifier)
        let content = (try? String(contentsOf: pidFile, encoding: .utf8)) ?? ""
        guard pid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            NSApp.terminate(nil)
            return
        }
    }

    func makeKeyAndVisibleIfNeeded() {
        guard let controller = mainWindowController,
              let window = controller.window,
              let viewModel = controller.viewModel,
              viewModel.status == .opened else {
            return
              }
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard let controller = mainWindowController,
              let viewModel = controller.viewModel else {
            return true
        }
        viewModel.openNotch(.click)
        return true
    }
}

