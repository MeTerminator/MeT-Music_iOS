#if os(macOS)
  import SwiftUI

  struct DesktopCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: () -> Content

    var body: some View {
      VStack(alignment: .leading, spacing: 18) {
        Label(title, systemImage: symbol)
          .font(.headline)
          .foregroundStyle(.primary)
        content()
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 18))
      .overlay {
        RoundedRectangle(cornerRadius: 18)
          .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
      }
    }
  }
#endif
