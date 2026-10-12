#if os(macOS)
import SwiftUI

struct MacLibraryView: View {
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

    var body: some View {
        NavigationSplitView {
            List(Destination.allCases, selection: $selection) { destination in
                Label(destination.title, systemImage: destination.symbol)
                    .tag(destination)
            }
            .navigationTitle("MeT-Music")
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
        } detail: {
            switch selection ?? .library {
            case .library: LibraryView()
            case .together: ListenTogetherView()
            case .cached: NavigationStack { CachedAudioView() }
            }
        }
    }
}
#endif
