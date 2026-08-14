import SwiftUI

struct ListenTogetherView: View {
    @EnvironmentObject private var app: AppStore
    var body: some View { ListenTogetherContent(together: app.together).environmentObject(app) }
}

private struct ListenTogetherContent: View {
    @EnvironmentObject private var app: AppStore
    @ObservedObject var together: ListenTogetherStore
    @StateObject private var form = ListenTogetherFormModel()

    var body: some View {
        NavigationStack {
            Group {
                if together.isInRoom { roomView }
                else { entryView }
            }
            .navigationTitle("一起听")
            .alert("提示", isPresented: Binding(get: { together.errorMessage != nil }, set: { if !$0 { together.errorMessage = nil } })) {
                Button("好", role: .cancel) { together.errorMessage = nil }
            } message: { Text(together.errorMessage ?? "") }
        }
    }

    private var entryView: some View {
        Form {
            Section {
                TextField("昵称", text: $form.nickname)
                Toggle("匿名加入", isOn: $form.anonymous)
            } header: { Text("身份") }
            Section("加入房间") {
                TextField("6 位房间号", text: $form.roomCode)
                Button {
                    Task { await together.joinRoom(code: form.roomCode, nickname: form.nickname, anonymous: form.anonymous) }
                } label: { Label("加入房间", systemImage: "rectangle.portrait.and.arrow.right") }
                .disabled(together.connecting)
            }
            Section {
                Button {
                    Task { await together.createRoom(nickname: form.nickname, anonymous: form.anonymous) }
                } label: { Label("创建新房间", systemImage: "plus.circle.fill") }
                .disabled(together.connecting)
            }
            if together.connecting { Section { HStack { Spacer(); ProgressView("正在连接"); Spacer() } } }
        }
        .onAppear { if form.nickname.isEmpty { form.nickname = app.nickname == "未登录" ? "" : app.nickname } }
    }

    private var roomView: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(together.roomCode).font(.largeTitle.bold().monospaced())
                        Text("剩余 \(format(together.remainingSeconds))").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ShareLink(item: "一起听房间号：\(together.roomCode)") { Image(systemName: "square.and.arrow.up") }
                }
            } header: { Text("房间") }
            if let room = together.room {
                Section("成员 · \(room.members.count)") {
                    ScrollView(.horizontal) {
                        HStack(spacing: 16) {
                            ForEach(room.members) { member in
                                VStack(spacing: 5) {
                                    ArtworkView(url: RemoteAssetURL.make(member.avatar.isEmpty ? member.user?.avatar : member.avatar), cornerRadius: 26).frame(width: 52, height: 52)
                                    Text(member.nickname.isEmpty ? member.user?.nickname ?? "成员" : member.nickname).font(.caption).lineLimit(1)
                                }.frame(width: 70)
                            }
                        }.padding(.vertical, 4)
                    }.scrollIndicators(.hidden)
                }
                Section("播放控制") {
                    HStack {
                        Button { together.send(action: "prev") } label: { Image(systemName: "backward.fill") }
                        Spacer()
                        Button(action: together.sendPlayOrPause) {
                            Image(systemName: room.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 48))
                        }
                        Spacer()
                        Button { together.send(action: "next") } label: { Image(systemName: "forward.fill") }
                    }.buttonStyle(.plain).padding(.horizontal, 36)
                    Picker("播放模式", selection: Binding(get: { room.playMode }, set: together.setPlayMode)) {
                        Text("顺序").tag("normal")
                        Text("随机").tag("random")
                        Text("单曲循环").tag("single")
                    }
                }
                Section("房间队列") {
                    if room.playlist.isEmpty {
                        ContentUnavailableView("队列为空", systemImage: "music.note.list", description: Text("在歌单中点选歌曲即可添加"))
                    }
                    ForEach(Array(room.playlist.enumerated()), id: \.element.id) { index, roomSong in
                        HStack {
                            Button { together.playSong(at: index) } label: {
                                SongRow(song: roomSong.song, number: index + 1, active: room.currentSongIndex == index)
                            }.buttonStyle(.plain)
                            Button(role: .destructive) { together.removeSong(at: index) } label: { Image(systemName: "minus.circle") }
                        }
                    }
                }
                Section("房间设置") {
                    Toggle("自动续期", isOn: $together.autoRenew)
                    Toggle("播完删除", isOn: Binding(
                        get: { room.deleteAfterPlayed },
                        set: { together.updateSettings(deleteAfterPlayed: $0, loopPlaylist: room.loopPlaylist) }
                    ))
                    Toggle("循环播放列表", isOn: Binding(
                        get: { room.loopPlaylist },
                        set: { together.updateSettings(deleteAfterPlayed: room.deleteAfterPlayed, loopPlaylist: $0) }
                    ))
                    Button("立即续期", action: together.renewRoom)
                }
            }
            Section {
                Button("离开房间", role: .destructive, action: together.leaveRoom)
                Button("解散房间", role: .destructive, action: together.deleteRoom)
            }
        }
    }

    private func format(_ seconds: Int64) -> String { String(format: "%02lld:%02lld", seconds / 60, seconds % 60) }
}

private final class ListenTogetherFormModel: ObservableObject {
    @Published var roomCode = ""
    @Published var nickname = ""
    @Published var anonymous = false
}
