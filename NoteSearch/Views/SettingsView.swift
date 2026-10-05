import SwiftUI
import AppKit
import ServiceManagement

enum SettingsValidator {
    static func isForbiddenRoot(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        return path == "/"
            || path == home
            || path == home + "/Library"
            || path.hasPrefix(home + "/Library/")
    }

    static let binaryExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "svg",
        "mp4", "mov", "zip", "tar", "gz"
    ]
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case root, window, exclusions, extensions, index

    var id: String { rawValue }

    var title: String {
        switch self {
        case .root: return "Каталог"
        case .window: return "Окно"
        case .exclusions: return "Исключения"
        case .extensions: return "Типы файлов"
        case .index: return "Индекс"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var tab: SettingsTab = .root
    @State private var needsReindex = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(SettingsTab.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Divider()

            Group {
                switch tab {
                case .root:
                    RootSettingsView()
                case .window:
                    WindowSettingsView()
                case .exclusions:
                    ExclusionsSettingsView(needsReindex: $needsReindex)
                case .extensions:
                    ExtensionsSettingsView(needsReindex: $needsReindex)
                case .index:
                    IndexSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if needsReindex {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Настройки изменены. Чтобы они применились к индексу, переиндексируйте.")
                        .font(.system(size: 12))
                    Spacer()
                    Button("Переиндексировать") {
                        needsReindex = false
                        appState.reindex()
                    }
                    .disabled(appState.isIndexing)
                }
                .padding(10)
                .background(Color.orange.opacity(0.12))
            }
        }
        .frame(width: 620, height: 540)
    }
}

// MARK: - Каталог

struct RootSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var rootPath = IndexService.shared.rootURL().path
    @State private var pendingURL: URL?
    @State private var showConfirm = false
    @State private var errorText: String?

    var body: some View {
        Form {
            Section("Индексируемый каталог") {
                Text(rootPath)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack {
                    Button("Изменить…") { chooseFolder() }
                        .disabled(appState.isIndexing)
                    Button("Открыть в Finder") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: rootPath))
                    }
                }
                if let errorText {
                    Text(errorText).foregroundColor(.red).font(.system(size: 12))
                }
            }

            Section("Запуск") {
                LaunchAtLoginToggle()
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Заменить индекс?",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("Заменить", role: .destructive) {
                if let url = pendingURL {
                    rootPath = url.path
                    appState.changeRoot(to: url)
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Текущий индекс будет удалён, для каталога «\(pendingURL?.path ?? "")» создастся новый.")
        }
    }

    private func chooseFolder() {
        errorText = nil
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Выбрать"
        panel.directoryURL = URL(fileURLWithPath: rootPath)

        guard panel.runModal() == .OK, let url = panel.url else { return }

        if SettingsValidator.isForbiddenRoot(url.path) {
            errorText = "Нельзя индексировать «/», домашнюю папку и ~/Library. Выберите рабочий каталог с заметками."
            return
        }
        if url.path == rootPath { return }

        pendingURL = url
        showConfirm = true
    }
}

struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled
    @State private var errorText: String?

    var body: some View {
        LoginItemSettingsView()
    }
}

// MARK: - Исключения

struct ExclusionsSettingsView: View {
    @Binding var needsReindex: Bool
    @State private var entries: [String] = IndexService.shared.excludedEntries
    @State private var selection: String?
    @State private var newEntry = ""
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Папки исключаются по имени (например node_modules) или по полному пути.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            List(selection: $selection) {
                ForEach(entries, id: \.self) { entry in
                    HStack {
                        Image(systemName: entry.hasPrefix("/") ? "folder" : "tag")
                            .foregroundColor(.secondary)
                        Text(entry)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .tag(entry)
                }
            }
            .frame(minHeight: 180)

            HStack {
                TextField("Имя папки или путь", text: $newEntry)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add(newEntry) }
                Button("Добавить") { add(newEntry) }
                    .disabled(newEntry.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack {
                Button("Выбрать папку…") { pickFolder() }
                Button("Удалить") { removeSelected() }
                    .disabled(selection == nil)
                Spacer()
                Button("Сбросить по умолчанию") {
                    entries = IndexService.defaultExclusions
                    selection = nil
                    save()
                }
            }

            if let errorText {
                Text(errorText).foregroundColor(.red).font(.system(size: 12))
            }
        }
        .padding()
    }

    private func normalize(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        value = (value as NSString).expandingTildeInPath
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        if value.contains("/") && !value.hasPrefix("/") {
            value = IndexService.shared.rootURL().path + "/" + value
        }
        return value
    }

    private func add(_ raw: String) {
        errorText = nil
        guard let value = normalize(raw) else { return }

        if value.hasPrefix("/") {
            let root = IndexService.shared.rootURL().path
            guard value.hasPrefix(root + "/") else {
                errorText = "Путь должен находиться внутри индексируемого каталога."
                return
            }
        }
        guard !entries.contains(value) else {
            errorText = "Такое исключение уже есть."
            return
        }

        entries.append(value)
        newEntry = ""
        save()
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Исключить"
        panel.directoryURL = IndexService.shared.rootURL()

        if panel.runModal() == .OK, let url = panel.url {
            add(url.path)
        }
    }

    private func removeSelected() {
        guard let selection else { return }
        entries.removeAll { $0 == selection }
        self.selection = nil
        save()
    }

    private func save() {
        IndexService.shared.setExcludedEntries(entries)
        needsReindex = true
    }
}

// MARK: - Типы файлов

struct ExtensionsSettingsView: View {
    @Binding var needsReindex: Bool
    @State private var extensions: [String] = IndexService.shared.supportedExtensions
    @State private var selection: String?
    @State private var newExtension = ""
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Расширения файлов, которые попадают в индекс (без учёта регистра).")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            List(selection: $selection) {
                ForEach(extensions, id: \.self) { ext in
                    Text(".\(ext)").tag(ext)
                }
            }
            .frame(minHeight: 180)

            HStack {
                TextField("Например: log", text: $newExtension)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add() }
                Button("Добавить") { add() }
                    .disabled(newExtension.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack {
                Button("Удалить") {
                    if let selection {
                        extensions.removeAll { $0 == selection }
                        self.selection = nil
                        save()
                    }
                }
                .disabled(selection == nil)
                Spacer()
                Button("Сбросить по умолчанию") {
                    extensions = IndexService.defaultExtensions
                    selection = nil
                    save()
                }
            }

            if let errorText {
                Text(errorText).foregroundColor(.red).font(.system(size: 12))
            }
        }
        .padding()
    }

    private func add() {
        errorText = nil
        var value = newExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if value.hasPrefix(".") { value.removeFirst() }
        guard !value.isEmpty else { return }

        guard value.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            errorText = "Расширение может содержать только буквы и цифры."
            return
        }
        guard !SettingsValidator.binaryExtensions.contains(value) else {
            errorText = "Эти форматы не индексируются (изображения, видео, архивы)."
            return
        }
        guard !extensions.contains(value) else {
            errorText = "Такое расширение уже есть."
            return
        }

        extensions.append(value)
        newExtension = ""
        save()
    }

    private func save() {
        IndexService.shared.setSupportedExtensions(extensions)
        needsReindex = true
    }
}

// MARK: - Индекс

struct IndexSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var lastIndexed: Date?
    @State private var sizeText = "—"
    @State private var showClearConfirm = false

    var body: some View {
        Form {
            Section("Статистика") {
                LabeledContent("Документов", value: "\(appState.indexedFileCount)")
                LabeledContent(
                    "Последняя индексация",
                    value: lastIndexed.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—"
                )
                LabeledContent("Размер индекса", value: sizeText)
                LabeledContent("Состояние", value: appState.indexingProgress)
            }

            Section {
                HStack {
                    Button("Переиндексировать") { appState.reindex() }
                        .disabled(appState.isIndexing)
                    Button("Очистить индекс", role: .destructive) { showClearConfirm = true }
                        .disabled(appState.isIndexing)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
        .onChange(of: appState.isIndexing) { _, _ in refresh() }
        .onChange(of: appState.indexedFileCount) { _, _ in refresh() }
        .confirmationDialog(
            "Очистить индекс?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Очистить", role: .destructive) {
                appState.clearIndex()
                refresh()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Все проиндексированные документы будут удалены. Файлы на диске не затрагиваются.")
        }
    }

    private func refresh() {
        lastIndexed = IndexService.shared.lastIndexedDate
        sizeText = ByteCountFormatter.string(
            fromByteCount: IndexService.shared.indexSizeBytes(),
            countStyle: .file
        )
    }
}

// MARK: - Окно и горячая клавиша

struct WindowSettingsView: View {
    @AppStorage(AppSettings.showMenuBarKey) private var showMenuBar = true
    @AppStorage(AppSettings.showDockKey) private var showDock = true
    @AppStorage(AppSettings.hideOnBlurKey) private var hideOnBlur = true
    @AppStorage(AppSettings.showOnLaunchKey) private var showOnLaunch = true
    @AppStorage(AppSettings.themeKey) private var theme = AppTheme.system.rawValue

    var body: some View {
        Form {
            Section("Оформление") {
                Picker("Тема", selection: $theme) {
                    ForEach(AppTheme.allCases) { item in
                        Text(item.title).tag(item.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: theme) { _, _ in
                    AppSettings.applyTheme()
                }
            }

            Section("Глобальное сочетание") {
                HotkeyRecorderView()
            }

            Section("Окно поиска") {
                Toggle("Скрывать при потере фокуса", isOn: $hideOnBlur)
                Toggle("Показывать при запуске приложения", isOn: $showOnLaunch)
            }

            Section("Значки") {
                Toggle("Значок в строке меню", isOn: $showMenuBar)
                    .disabled(showMenuBar && !showDock)
                Toggle("Значок в Dock", isOn: $showDock)
                    .disabled(showDock && !showMenuBar)
                    .onChange(of: showDock) { _, _ in
                        AppSettings.applyActivationPolicy()
                    }
                Text("Должен остаться хотя бы один значок, чтобы приложение можно было закрыть.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct HotkeyRecorderView: View {
    @State private var config = HotkeyConfig.load()
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(isRecording ? "Нажмите сочетание…" : config.displayString) {
                    if isRecording {
                        stopRecording(restore: true)
                    } else {
                        startRecording()
                    }
                }
                .frame(minWidth: 170)

                Button("Сбросить") {
                    apply(HotkeyConfig.standard)
                }
                .disabled(isRecording || config == HotkeyConfig.standard)
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundColor(isError ? .red : .secondary)
            }

            Text("Нужен хотя бы ⌘ или ⌃. Esc отменяет запись.")
                .font(.caption)
                .foregroundColor(.secondary)

            Text("⌘⌥Space по умолчанию занято системой («Показать окно поиска Finder»). Отключите его в настройках клавиатуры или запишите другое сочетание, например ⌃⌥⌘Space.")
                .font(.caption)
                .foregroundColor(.secondary)

            Button("Открыть настройки клавиатуры") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .onDisappear {
            if isRecording { stopRecording(restore: true) }
        }
    }

    private func startRecording() {
        GlobalHotkeyHandler.shared.suspend()
        isRecording = true
        message = nil

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stopRecording(restore: Bool) {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false

        if restore {
            GlobalHotkeyHandler.shared.apply(config)
        }
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 {
            stopRecording(restore: true)
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let candidate = HotkeyConfig(
            keyCode: UInt32(event.keyCode),
            modifiers: HotkeyConfig.carbonModifiers(from: flags),
            label: HotkeyConfig.label(for: event)
        )

        guard candidate.hasRequiredModifier else {
            message = "Добавьте ⌘ или ⌃ к сочетанию."
            isError = true
            return
        }

        stopRecording(restore: false)
        apply(candidate)
    }

    private func apply(_ new: HotkeyConfig) {
        let status = GlobalHotkeyHandler.shared.apply(new)

        if status == 0 {
            new.save()
            config = new
            message = "Сохранено: \(new.displayString)"
            isError = false
        } else {
            GlobalHotkeyHandler.shared.apply(config)
            message = GlobalHotkeyHandler.shared.describe(status)
            isError = true
        }
    }
}

// MARK: - Запуск при входе

struct LoginItemSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var state = AppSettings.currentLoginItemState()
    @State private var errorMessage: String?
    @State private var isUpdating = false

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { state.isRequested },
            set: { updateLoginItem(enabled: $0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Запускать вместе с macOS", isOn: isEnabled)
                .disabled(isUpdating)

            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .foregroundColor(iconColor)

                Text("Статус: \(state.title)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                if isUpdating {
                    ProgressView()
                        .scaleEffect(0.65)
                }
            }

            if let details = state.details {
                Text(details)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if state == .requiresApproval || state == .notFound {
                Button("Открыть Login Items") {
                    AppSettings.openLoginItemsSettings()
                }
                .font(.system(size: 12))
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Обновить статус") {
                refresh()
            }
            .font(.system(size: 12))
            .disabled(isUpdating)
        }
        .onAppear {
            refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refresh()
            }
        }
    }

    private var iconName: String {
        switch state {
        case .enabled:
            return "checkmark.circle.fill"
        case .notRegistered:
            return "circle"
        case .requiresApproval:
            return "exclamationmark.triangle.fill"
        case .notFound:
            return "xmark.circle.fill"
        case .unknown:
            return "questionmark.circle"
        }
    }

    private var iconColor: Color {
        switch state {
        case .enabled:
            return .green
        case .notRegistered:
            return .secondary
        case .requiresApproval:
            return .orange
        case .notFound:
            return .red
        case .unknown:
            return .secondary
        }
    }

    private func refresh() {
        state = AppSettings.currentLoginItemState()
        errorMessage = nil
    }

    private func updateLoginItem(enabled: Bool) {
        isUpdating = true
        errorMessage = nil

        do {
            try AppSettings.setLaunchAtLogin(enabled)
            state = AppSettings.currentLoginItemState()
        } catch {
            state = AppSettings.currentLoginItemState()
            errorMessage = error.localizedDescription
        }

        isUpdating = false
    }
}
