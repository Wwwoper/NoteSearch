import SwiftUI
import AppKit

final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    static let shared = PanelController()

    private var panel: SearchPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        let p = panel ?? makePanel()
        panel = p
        position(p)
        p.orderFrontRegardless()
        p.makeKey()
        AppState.shared.focusSearch()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func windowDidResignKey(_ notification: Notification) {
        let hideOnBlur = UserDefaults.standard.object(forKey: AppSettings.hideOnBlurKey) as? Bool ?? true
        guard hideOnBlur else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self, let p = self.panel, p.isVisible, !p.isKeyWindow else { return }
            self.hide()
        }
    }

    private func makePanel() -> SearchPanel {
        let p = SearchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
            styleMask: [.titled, .fullSizeContentView, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .utilityWindow
        p.minSize = NSSize(width: 900, height: 560)
        p.delegate = self

        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            p.standardWindowButton(button)?.isHidden = true
        }

        p.contentView = NSHostingView(
            rootView: ContentView().environmentObject(AppState.shared)
        )
        return p
    }

    private func position(_ p: NSPanel) {
        guard !p.isVisible else { return }

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else {
            p.center()
            return
        }

        let size = p.frame.size
        let x = area.midX - size.width / 2
        let y = area.maxY - size.height - area.height * 0.12
        p.setFrameOrigin(NSPoint(x: x, y: max(area.minY, y)))
    }
}

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(
                rootView: SettingsView().environmentObject(AppState.shared)
            )
            let w = NSWindow(contentViewController: hosting)
            w.title = "Настройки NoteSearch"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }

        PanelController.shared.hide()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.applyActivationPolicy()
        AppSettings.applyTheme()
        _ = AppState.shared

        GlobalHotkeyHandler.shared.onTrigger = {
            PanelController.shared.toggle()
        }
        GlobalHotkeyHandler.shared.start()

        let showOnLaunch = UserDefaults.standard.object(forKey: AppSettings.showOnLaunchKey) as? Bool ?? true
        if showOnLaunch {
            PanelController.shared.show()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        PanelController.shared.show()
        return false
    }
}

struct MenuBarContent: View {
    @AppStorage(AppSettings.hotkeyLabelKey) private var hotkeyLabel = ""

    var body: some View {
        let _ = hotkeyLabel

        Button("Открыть поиск  \(HotkeyConfig.load().displayString)") {
            PanelController.shared.show()
        }
        Button("Настройки…") {
            SettingsWindowController.shared.show()
        }
        Divider()
        Button("Переиндексировать") {
            AppState.shared.reindex()
        }
        Divider()
        Button("Выйти из NoteSearch") {
            NSApp.terminate(nil)
        }
    }
}

@main
struct NoteSearchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(AppSettings.showMenuBarKey) private var showMenuBarIcon = true

    var body: some Scene {
        MenuBarExtra("NoteSearch", systemImage: "magnifyingglass", isInserted: $showMenuBarIcon) {
            MenuBarContent()
        }
    }
}
