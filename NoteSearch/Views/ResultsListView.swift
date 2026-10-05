import SwiftUI

struct ResultsListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Результаты")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(appState.searchResults.count)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            if appState.searchResults.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text(appState.statusText)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(appState.searchResults) { result in
                                ResultRowView(
                                    result: result,
                                    isSelected: appState.selectedResult?.id == result.id
                                )
                                .id(result.id)
                                .onTapGesture { appState.selectedResult = result }
                            }
                        }
                    }
                    .onChange(of: appState.selectedResult?.id) { _, id in
                        if let id {
                            withAnimation(.easeOut(duration: 0.1)) {
                                proxy.scrollTo(id)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct ResultRowView: View {
    let result: SearchResult
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: iconName(for: result.fileURL.pathExtension))
                    .foregroundColor(.secondary)
                    .frame(width: 16)
                Text(result.fileName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text("\(result.matchCount)")
                    .font(.system(size: 11))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2))
                    .cornerRadius(4)
            }

            Text(result.relativePath)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text("\(result.fileURL.pathExtension.uppercased()) · \(result.modifiedAt.formatted(date: .abbreviated, time: .omitted))")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
    }

    private func iconName(for ext: String) -> String {
        switch ext.lowercased() {
        case "md", "markdown", "txt": return "doc.text"
        case "json": return "curlybraces"
        case "yaml", "yml": return "list.bullet"
        case "py", "js", "ts", "html", "htm": return "chevron.left.forwardslash.chevron.right"
        case "css": return "paintbrush"
        default: return "doc"
        }
    }
}
