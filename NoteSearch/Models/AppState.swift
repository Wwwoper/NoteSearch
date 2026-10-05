import Foundation
import OSLog
import SwiftUI
import AppKit

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var searchQuery: String = "" {
        didSet {
            if searchQuery != oldValue { scheduleSearch() }
        }
    }
    @Published var searchResults: [SearchResult] = []
    @Published var selectedResult: SearchResult?
    @Published var isIndexing: Bool = false
    @Published var isSearching: Bool = false
    @Published var indexingProgress: String = "Требуется индексация"
    @Published var indexedFileCount: Int = 0
    @Published var showSettings: Bool = false
    @Published var focusTick: Int = 0

    let indexService: IndexService
    let searchService: SearchService

    private let watcher = FileWatcher()
    private var debounceTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0

    init() {
        indexService = IndexService.shared
        searchService = SearchService.shared

        if indexService.indexExists() {
            indexedFileCount = indexService.getDocumentCount()
            indexingProgress = "Готов к поиску"
            startWatching()
            reconcile()
        } else {
            reindex()
        }
    }

    var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var statusText: String {
        if isIndexing { return indexingProgress }
        let q = trimmedQuery
        if q.isEmpty { return "Введите запрос для поиска" }
        if q.count < 2 { return "Введите минимум 2 символа" }
        if searchResults.isEmpty {
            return isSearching ? "Поиск..." : "Ничего не найдено"
        }
        return "Найдено: \(searchResults.count) \(filesWord(searchResults.count))"
    }

    private func filesWord(_ n: Int) -> String {
        let m100 = n % 100
        let m10 = n % 10
        if m100 >= 11 && m100 <= 14 { return "файлов" }
        switch m10 {
        case 1: return "файл"
        case 2, 3, 4: return "файла"
        default: return "файлов"
        }
    }

    private func readyStatus(changed: Int, skipped: Int) -> String {
        var parts = ["Готов к поиску"]
        if changed > 0 { parts.append("обновлено: \(changed)") }
        if skipped > 0 { parts.append("пропущено: \(skipped)") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Поиск

    private func scheduleSearch() {
        debounceTask?.cancel()

        if trimmedQuery.count < 2 {
            performSearch()
            return
        }

        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.performSearch()
        }
    }

    func performSearch(preserveSelection: Bool = false) {
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration

        let query = trimmedQuery
        guard query.count >= 2 else {
            isSearching = false
            searchResults = []
            selectedResult = nil
            return
        }

        let previousPath = selectedResult?.fileURL.path
        let service = searchService
        isSearching = true

        searchTask = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) { () -> Result<[SearchResult], Error> in
                do {
                    return .success(try service.search(query: query))
                } catch {
                    return .failure(error)
                }
            }

            let outcome = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }

            guard let self, generation == self.searchGeneration else { return }

            switch outcome {
            case .success(let results):
                self.searchResults = results
            case .failure(let error):
                if error is CancellationError { return }
                AppLog.search.error("Ошибка поиска: \(error.localizedDescription, privacy: .public)")
                self.searchResults = []
            }

            self.isSearching = false

            if preserveSelection, let previousPath,
               let same = self.searchResults.first(where: { $0.fileURL.path == previousPath }) {
                self.selectedResult = same
            } else {
                self.selectedResult = self.searchResults.first
            }
        }
    }

    // MARK: - Индексация и наблюдение

    func reindex() {
        guard !isIndexing else { return }
        AppLog.index.info("Пользователь запустил полную переиндексацию")
        isIndexing = true
        indexingProgress = "Индексирование..."

        Task {
            do {
                let skipped = try await indexService.reindex { progress in
                    Task { @MainActor in
                        guard self.isIndexing else { return }
                        self.indexingProgress =
                            "Индексирование: \(progress.current) / \(progress.total) файлов"
                    }
                }
                isIndexing = false
                indexedFileCount = indexService.getDocumentCount()
                indexingProgress = readyStatus(changed: 0, skipped: skipped)
                startWatching()
            } catch {
                isIndexing = false
                indexingProgress = "Ошибка индексации"
            }
            performSearch()
        }
    }

    private func reconcile() {
        guard !isIndexing else { return }
        isIndexing = true
        indexingProgress = "Проверка изменений..."

        Task {
            let result = await indexService.reconcile { progress in
                Task { @MainActor in
                    guard self.isIndexing else { return }
                    self.indexingProgress =
                        "Обновление индекса: \(progress.current) / \(progress.total) файлов"
                }
            }
            isIndexing = false
            indexedFileCount = indexService.getDocumentCount()
            indexingProgress = readyStatus(changed: result.changed, skipped: result.skipped)

            if trimmedQuery.count >= 2 {
                performSearch(preserveSelection: true)
            }
        }
    }

    func changeRoot(to url: URL) {
        guard !isIndexing else { return }
        watcher.stop()
        AppLog.index.info("Изменён индексируемый каталог: \(url.path, privacy: .private)")
        UserDefaults.standard.set(url.path, forKey: IndexService.rootKey)
        searchResults = []
        selectedResult = nil
        reindex()
    }

    func clearIndex() {
        guard !isIndexing else { return }
        watcher.stop()
        AppLog.index.notice("Пользователь очистил индекс")
        indexService.clearIndex()
        indexedFileCount = 0
        indexingProgress = "Индекс очищен"
        searchResults = []
        selectedResult = nil
    }

    private func startWatching() {
        let service = indexService
        let path = service.rootURL().path
        watcher.start(path: path) { [weak self] events in
            let changed = service.applyChanges(events)
            if changed {
                Task { @MainActor in
                    self?.indexDidChange()
                }
            }
        }
    }

    private func indexDidChange() {
        AppLog.watch.debug("Индекс обновлён после события файловой системы")
        indexedFileCount = indexService.getDocumentCount()
        if trimmedQuery.count >= 2 {
            performSearch(preserveSelection: true)
        }
    }

    // MARK: - Навигация и действия

    func selectNext() { moveSelection(1) }
    func selectPrevious() { moveSelection(-1) }

    private func moveSelection(_ delta: Int) {
        guard !searchResults.isEmpty else { return }
        let current = searchResults.firstIndex { $0.id == selectedResult?.id }
            ?? (delta > 0 ? -1 : 0)
        let next = min(max(current + delta, 0), searchResults.count - 1)
        selectedResult = searchResults[next]
    }

    func openSelected() {
        guard let result = selectedResult else { return }
        NSWorkspace.shared.open(result.fileURL)
        PanelController.shared.hide()
    }

    func revealSelected() {
        guard let result = selectedResult else { return }
        NSWorkspace.shared.activateFileViewerSelecting([result.fileURL])
        PanelController.shared.hide()
    }

    func clearSearch() {
        searchQuery = ""
    }

    func focusSearch() {
        focusTick += 1
    }

    func handleEscape() {
        if searchQuery.isEmpty {
            PanelController.shared.hide()
        } else {
            clearSearch()
        }
    }
}
