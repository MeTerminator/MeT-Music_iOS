#if os(macOS)
import SwiftUI

struct MacLibraryView: View {
    @EnvironmentObject private var store: AppStore
    private enum Destination: String, CaseIterable, Identifiable {
        case library, together, cached
        var id: Self { self }
        var title: String {
            switch self {
            case .library: "资料库"
            case .together: "一起听"
            case .cached: "已缓存歌曲"
            }
        }
        var symbol: String {
            switch self {
            case .library: "music.note.list"
            case .together: "person.2.wave.2"
            case .cached: "externaldrive"
            }
        }
    }

    @State private var selection: Destination? = .library
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(Destination.allCases, selection: $selection) { destination in
                Label(destination.title, systemImage: destination.symbol)
                    .tag(destination)
            }
            .navigationTitle(store.isPlayerPresented ? "" : "MeT-Music")
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            switch selection ?? .library {
            case .library: LibraryView()
            case .together: ListenTogetherView()
            case .cached: NavigationStack { CachedAudioView() }
            }
        }
        .toolbar {
            if !store.isPlayerPresented {
                ToolbarItem(placement: .navigation) {
                    Button("切换侧栏", systemImage: "sidebar.left") {
                        withAnimation {
                            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                        }
                    }
                    .help("切换侧栏")
                }
            }
        }
    }
}
#endif
