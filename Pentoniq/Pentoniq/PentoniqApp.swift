//
//  PentoniqApp.swift
//  Pentoniq
//
//  Created by John Penner on 2026-10-15.
//
//  Milestone 99: the host app is a one-window test bench, so the default menu items that do nothing
//  here are removed:
//    - File > New Window                          (gone)
//    - File > Close                               (now quits the app)
//    - View > Show Tab Bar / Show All Tabs        (gone)
//    - Window > Show Previous / Next Tab, Move Tab to New Window, Merge All Windows   (gone)
//    - the whole Help menu                        (gone)
//  The red close button in the title bar quits the app too.
//
//  Menu items are matched by their ACTION, not their title, so this works in every language.

import SwiftUI
import AppKit

@MainActor
final class PentoniqAppDelegate: NSObject, NSApplicationDelegate {

    /// Menu actions that mean nothing in a one-window app.
    private static let removedActions: Set<Selector> = [
        NSSelectorFromString("newWindowForTab:"),        // File > New Window
        NSSelectorFromString("toggleTabBar:"),           // View > Show Tab Bar
        NSSelectorFromString("toggleTabOverview:"),      // View > Show All Tabs
        NSSelectorFromString("selectPreviousTab:"),      // Window > Show Previous Tab
        NSSelectorFromString("selectNextTab:"),          // Window > Show Next Tab
        NSSelectorFromString("moveTabToNewWindow:"),     // Window > Move Tab to New Window
        NSSelectorFromString("mergeAllWindows:")         // Window > Merge All Windows
    ]

    func applicationWillFinishLaunching(_ notification: Notification) {
        // No window tabbing at all.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        trimMenus()
        // SwiftUI finishes building its menus a moment later, and may refresh them when the app is
        // activated or a window becomes key, so tidy again then.
        Task { @MainActor [weak self] in self?.trimMenus() }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(menusMayHaveChanged(_:)),
                           name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(menusMayHaveChanged(_:)),
                           name: NSWindow.didBecomeKeyNotification, object: nil)
    }

    /// The red close button closes the only window, and that quits the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc private func menusMayHaveChanged(_ notification: Notification) {
        trimMenus()
    }

    // MARK: Menus

    private func trimMenus() {
        guard let mainMenu = NSApp.mainMenu else { return }

        // HELP: remove the whole menu.
        if let help = NSApp.helpMenu,
           let item = mainMenu.items.first(where: { $0.submenu === help }) {
            mainMenu.removeItem(item)
        }

        for item in mainMenu.items {
            if let submenu = item.submenu { prune(submenu) }
        }
    }

    /// Removes the unwanted items from `menu` (and its submenus), and turns Close into Quit.
    private func prune(_ menu: NSMenu) {
        var removedAny = false
        for item in menu.items.reversed() {
            if let action = item.action {
                if PentoniqAppDelegate.removedActions.contains(action) {
                    menu.removeItem(item)
                    removedAny = true
                    continue
                }
                if action == #selector(NSWindow.performClose(_:)) {
                    // File > Close: quit the app instead (the shortcut, Command-W, goes with it).
                    item.action = #selector(NSApplication.terminate(_:))
                    item.target = NSApp
                }
            }
            if let submenu = item.submenu { prune(submenu) }
        }
        if removedAny { tidySeparators(menu) }
    }

    /// Takes out separators left at the top, at the bottom, or doubled up after items were removed.
    private func tidySeparators(_ menu: NSMenu) {
        var previousWasSeparator = true
        for item in menu.items {
            if item.isSeparatorItem {
                if previousWasSeparator { menu.removeItem(item) } else { previousWasSeparator = true }
            } else if !item.isHidden {
                previousWasSeparator = false
            }
        }
        if let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
    }
}

@main
struct PentoniqApp: App {
    @NSApplicationDelegateAdaptor(PentoniqAppDelegate.self) private var appDelegate
    @StateObject private var hostModel = AudioUnitHostModel()

    var body: some Scene {
        // One window, never more: a Window scene has no New Window and no tabs of its own.
        Window("Pentoniq", id: "main") {
            ContentView(hostModel: hostModel)
        }
        // Starts large enough for a 1080p display; the window can be resized freely
        // and the synth panel scales to fit it.
        .defaultSize(width: 1500, height: 900)
        .windowResizability(.contentMinSize)   // window may grow without limit
        .commands {
            CommandGroup(replacing: .newItem) { }    // belt and braces: no File > New items
            CommandGroup(replacing: .help) { }       // empties the Help menu (the delegate removes the menu itself)
        }
    }
}

