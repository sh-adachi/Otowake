import AppKit
import OtowakeCore
import SwiftUI

@main
enum OtowakeApp {
    @MainActor static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--smoke-test") {
            do { print(try AudioDiagnostics.smokeTest(outputUIDs: Array(CommandLine.arguments.dropFirst(index + 1)))) }
            catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--diagnose") {
            do { print(try AudioDiagnostics.inventory()) } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "音分け")
        let openItem = NSMenuItem(title: "音分けを開く", action: #selector(showWindow), keyEquivalent: "o")
        openItem.target = self
        applicationMenu.addItem(openItem)
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "音分けを終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem); NSApp.mainMenu = mainMenu
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "音分け：アプリ別の音声出力")
        item.button?.image?.isTemplate = true
        item.button?.target = self; item.button?.action = #selector(togglePopover)
        item.button?.toolTip = "音分け — アプリごとの音量と出力先"
        statusItem = item
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: mixer())
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.model.audio.suspend(true) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.model.audio.suspend(false) }
        })
        model.start()
        if !model.preferences.enabled || CommandLine.arguments.contains("--show-window") { showWindow() }
    }
    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    private func mixer() -> MixerView { MixerView(model: model, openWindow: { [weak self] in self?.showWindow() }) }
    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY); NSApp.activate(ignoringOtherApps: true) }
    }
    @objc private func showWindow() {
        popover.performClose(nil)
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 448, height: 620),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "音分け — Otowake"
            window.contentViewController = NSHostingController(rootView: mixer())
            window.isReleasedWhenClosed = false; window.center(); self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
