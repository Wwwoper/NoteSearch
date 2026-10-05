import Foundation
import AppKit
import Carbon.HIToolbox
import ServiceManagement

enum AppSettings {
    static let showMenuBarKey = "showMenuBarIcon"
    static let showDockKey = "showDockIcon"
    static let hideOnBlurKey = "hidePanelOnBlur"
    static let showOnLaunchKey = "showPanelOnLaunch"
    static let hotkeyKeyCodeKey = "hotkeyKeyCode"
    static let hotkeyModifiersKey = "hotkeyModifiers"
    static let hotkeyLabelKey = "hotkeyLabel"

    @MainActor
    static func applyActivationPolicy() {
        let showDock = UserDefaults.standard.object(forKey: showDockKey) as? Bool ?? true
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
    }
}

struct HotkeyConfig: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String

    static let standard = HotkeyConfig(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(cmdKey | optionKey),
        label: "Space"
    )

    var displayString: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + label
    }

    static func load() -> HotkeyConfig {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: AppSettings.hotkeyKeyCodeKey) != nil,
              let label = defaults.string(forKey: AppSettings.hotkeyLabelKey) else {
            return .standard
        }
        return HotkeyConfig(
            keyCode: UInt32(defaults.integer(forKey: AppSettings.hotkeyKeyCodeKey)),
            modifiers: UInt32(defaults.integer(forKey: AppSettings.hotkeyModifiersKey)),
            label: label
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(Int(keyCode), forKey: AppSettings.hotkeyKeyCodeKey)
        defaults.set(Int(modifiers), forKey: AppSettings.hotkeyModifiersKey)
        defaults.set(label, forKey: AppSettings.hotkeyLabelKey)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    var hasRequiredModifier: Bool {
        modifiers & UInt32(cmdKey | controlKey) != 0
    }

    static func label(for event: NSEvent) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab",
            kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
            kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
            kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"
        ]
        if let name = special[Int(event.keyCode)] { return name }
        let chars = event.charactersIgnoringModifiers ?? ""
        return chars.isEmpty ? "Key\(event.keyCode)" : chars.uppercased()
    }
}

final class GlobalHotkeyHandler {
    static let shared = GlobalHotkeyHandler()

    var onTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private init() {}

    func start() {
        installHandlerIfNeeded()
        let status = apply(HotkeyConfig.load())
        if status != noErr {
            print("Хоткей: \(describe(status))")
        }
    }

    @discardableResult
    func apply(_ config: HotkeyConfig) -> OSStatus {
        installHandlerIfNeeded()
        unregisterKey()

        let signature = "NTSR".utf8.reduce(OSType(0)) { ($0 << 8) + OSType($1) }
        let hotKeyID = EventHotKeyID(signature: signature, id: 1)
        var ref: EventHotKeyRef?

        let status = RegisterEventHotKey(
            config.keyCode,
            config.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRef = ref
        }
        return status
    }

    func suspend() {
        unregisterKey()
    }

    func describe(_ status: OSStatus) -> String {
        if status == noErr { return "Готово" }
        if status == OSStatus(eventHotKeyExistsErr) {
            return "Сочетание уже занято другим приложением"
        }
        return "Не удалось зарегистрировать сочетание (код \(status))"
    }

    private func unregisterKey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                DispatchQueue.main.async {
                    GlobalHotkeyHandler.shared.onTrigger?()
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &handlerRef
        )
    }
}

// MARK: - Тема оформления

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Системная"
        case .light: return "Светлая"
        case .dark: return "Тёмная"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    static var current: AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: AppSettings.themeKey) ?? "") ?? .system
    }
}

extension AppSettings {
    static let themeKey = "appTheme"

    @MainActor
    static func applyTheme() {
        NSApp.appearance = AppTheme.current.appearance
    }
}
// MARK: - Login Items

import ServiceManagement

enum LoginItemState: Equatable {
    case enabled
    case notRegistered
    case requiresApproval
    case notFound
    case unknown

    var title: String {
        switch self {
        case .enabled:
            return "Включено"
        case .notRegistered:
            return "Выключено"
        case .requiresApproval:
            return "Требуется подтверждение"
        case .notFound:
            return "Недоступно для этой сборки"
        case .unknown:
            return "Неизвестный статус"
        }
    }

    var details: String? {
        switch self {
        case .enabled:
            return "NoteSearch будет запускаться при входе в macOS."
        case .notRegistered:
            return "Автоматический запуск выключен."
        case .requiresApproval:
            return "macOS требует подтверждения. Откройте Login Items и разрешите NoteSearch."
        case .notFound:
            return "macOS не может зарегистрировать текущую сборку. Это нормально для запуска из DerivedData или неподписанного приложения. Установите Release-версию в /Applications и повторите попытку."
        case .unknown:
            return "macOS вернула неизвестное состояние Login Items."
        }
    }

    var isRequested: Bool {
        self == .enabled || self == .requiresApproval
    }
}

extension AppSettings {
    static func currentLoginItemState() -> LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .notRegistered
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .unknown
        }
    }

    static func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openLoginItemsSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        ) else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}
