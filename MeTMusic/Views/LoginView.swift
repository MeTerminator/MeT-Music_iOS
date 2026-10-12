import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var model = LoginFormModel()
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: [.pink.opacity(0.32), .purple.opacity(0.18), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            VStack(spacing: 28) {
                Spacer()
                Image(systemName: "music.note.house.fill")
                    .font(.system(size: 68, weight: .medium))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .pink)
                    .padding(28)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
                VStack(spacing: 8) {
                    Text("MeT-Music").font(.largeTitle.bold())
                    Text("输入 QQ 号载入你的音乐库").foregroundStyle(.secondary)
                }
                TextField("QQ 号", text: $model.qq)
                    .focused($focused)
                    .onSubmit { login() }
                    .font(.title3)
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: 360)
                Button {
                    login()
                } label: {
                    HStack {
                        if store.loadingPlaylists { ProgressView().tint(.white) }
                        Text(store.loadingPlaylists ? "正在载入" : "登录").fontWeight(.bold)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 16))
                .frame(maxWidth: 360)
                .disabled(store.loadingPlaylists)
                Spacer()
                Text("账号仅用于读取公开歌单，不会保存密码。")
                    .font(.footnote).foregroundStyle(.tertiary)
            }
            .padding(24)
        }
    }
    private func login() {
        guard !store.loadingPlaylists else { return }
        focused = false
        Task { _ = await store.login(qq: model.qq) }
    }
}

private final class LoginFormModel: ObservableObject {
    @Published var qq = ""
}
