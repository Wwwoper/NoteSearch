import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 0) {
            SearchBarView()
            Divider()
            HStack(spacing: 0) {
                ResultsListView()
                    .frame(minWidth: 300, maxWidth: 400)
                Divider()
                PreviewView()
            }
        }
        .frame(minWidth: 900, minHeight: 560)
    }
}
