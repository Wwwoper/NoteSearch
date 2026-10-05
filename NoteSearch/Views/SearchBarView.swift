import SwiftUI
import AppKit

struct SearchBarView: View {
    @EnvironmentObject var appState: AppState
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)

                TextField("Поиск по заметкам...", text: $appState.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($isSearchFocused)
                    .onSubmit { appState.openSelected() }
                    .onKeyPress(.downArrow) {
                        appState.selectNext()
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        appState.selectPrevious()
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        appState.handleEscape()
                        return .handled
                    }

                if !appState.searchQuery.isEmpty {
                    Button(action: { appState.clearSearch() }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                HStack(spacing: 8) {
                    if appState.isIndexing {
                        ProgressView().scaleEffect(0.6)
                    }
                    Text(appState.isIndexing ? "Индексирование" : appState.indexingProgress)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                Button(action: { appState.reindex() }) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Переиндексировать")

                Button(action: { SettingsWindowController.shared.show() }) {
                    Image(systemName: "gear")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Настройки")
            }

            Text(appState.statusText)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(NSColor.controlBackgroundColor))
        .background(
            Group {
                Button("") { appState.revealSelected() }
                    .keyboardShortcut(.return, modifiers: .command)
                Button("") { isSearchFocused = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("") { appState.clearSearch() }
                    .keyboardShortcut(.delete, modifiers: .command)
            }
            .opacity(0)
            .allowsHitTesting(false)
        )
        .onAppear { isSearchFocused = true }
        .onChange(of: appState.focusTick) { _, _ in
            isSearchFocused = true
        }
    }
}
