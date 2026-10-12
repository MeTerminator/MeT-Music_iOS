import SwiftUI

struct ListenTogetherView: View {
  var usesNavigationStack = true
  @EnvironmentObject private var app: AppStore
  var body: some View {
    ListenTogetherContent(together: app.together, usesNavigationStack: usesNavigationStack)
      .environmentObject(app)
  }
}

private struct ListenTogetherContent: View {
  @EnvironmentObject private var app: AppStore
  @ObservedObject var together: ListenTogetherStore
  var usesNavigationStack = true
  @StateObject private var form = ListenTogetherFormModel()

  var body: some View {
    Group {
      if usesNavigationStack { NavigationStack { togetherContent } } else { togetherContent }
    }
  }

  private var togetherContent: some View {
    Group {
      Group {
        if together.isInRoom {
          roomView
        } else {
          #if os(macOS)
            desktopEntryView
          #else
            entryView
          #endif
        }
      }
      .navigationTitle("一起听")
      .musicNavigationBarHidden(false)
      .alert(
        "提示",
        isPresented: Binding(
          get: { together.errorMessage != nil }, set: { if !$0 { together.errorMessage = nil } })
      ) {
        Button("好", role: .cancel) { together.errorMessage = nil }
      } message: {
        Text(together.errorMessage ?? "")
      }
    }
  }

  #if os(macOS)
    private var desktopEntryView: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          HStack(spacing: 18) {
            Image(systemName: "person.2.wave.2.fill")
              .font(.system(size: 28))
              .foregroundStyle(.pink)
              .frame(width: 64, height: 64)
              .background(.pink.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
            VStack(alignment: .leading, spacing: 6) {
              Text("和朋友一起听").font(.system(size: 28, weight: .bold))
              Text("共享播放队列，让音乐同步响起。")
                .font(.subheadline).foregroundStyle(.secondary)
            }
          }
          .padding(.bottom, 4)

          DesktopCard(title: "你的身份", symbol: "person.crop.circle") {
            HStack(alignment: .center, spacing: 24) {
              VStack(alignment: .leading, spacing: 8) {
                Text("昵称").font(.subheadline).foregroundStyle(.secondary)
                TextField("输入房间内显示的昵称", text: $form.nickname)
                  .textFieldStyle(.roundedBorder)
                  .disabled(form.anonymous)
              }
              Toggle("匿名加入", isOn: $form.anonymous)
                .toggleStyle(.switch)
                .fixedSize()
            }
          }

          ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) {
              desktopJoinCard.frame(minWidth: 260)
              desktopCreateCard.frame(minWidth: 260)
            }
            VStack(spacing: 20) {
              desktopJoinCard
              desktopCreateCard
            }
          }
          if together.connecting {
            HStack(spacing: 10) {
              ProgressView().controlSize(.small)
              Text("正在连接房间…").foregroundStyle(.secondary)
            }
          }
        }
        .frame(maxWidth: 760)
        .padding(32)
        .frame(maxWidth: .infinity, alignment: .top)
      }
      .background(.quaternary.opacity(0.2))
      .onAppear { populateNickname() }
    }

    private var desktopJoinCard: some View {
      DesktopCard(title: "加入房间", symbol: "rectangle.portrait.and.arrow.right") {
        Text("输入朋友分享的 6 位房间号。")
          .font(.subheadline).foregroundStyle(.secondary)
        TextField("6 位房间号", text: $form.roomCode)
          .font(.system(size: 20, weight: .medium, design: .monospaced))
          .textFieldStyle(.roundedBorder)
          .onSubmit { joinRoom() }
          .onChange(of: form.roomCode) { _, value in
            form.roomCode = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
          }
        Button(action: joinRoom) {
          Text("加入房间").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(together.connecting || form.roomCode.count != 6)
      }
    }

    private var desktopCreateCard: some View {
      DesktopCard(title: "创建房间", symbol: "plus.circle") {
        Text("开启一个新房间，再邀请朋友加入。")
          .font(.subheadline).foregroundStyle(.secondary)
        Label("一起选歌，同步播放", systemImage: "music.note.list")
          .font(.subheadline).foregroundStyle(.secondary)
          .frame(height: 30)
        Button {
          Task { await together.createRoom(nickname: form.nickname, anonymous: form.anonymous) }
        } label: {
          Text("创建新房间").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(together.connecting)
      }
    }

    private func joinRoom() {
      guard !together.connecting, form.roomCode.count == 6 else { return }
      Task {
        await together.joinRoom(
          code: form.roomCode, nickname: form.nickname, anonymous: form.anonymous)
      }
    }
  #endif

  private func populateNickname() {
    if form.nickname.isEmpty { form.nickname = app.nickname == "未登录" ? "" : app.nickname }
  }

  private var entryView: some View {
    Form {
      Section {
        TextField("昵称", text: $form.nickname)
        Toggle("匿名加入", isOn: $form.anonymous)
      } header: {
        Text("身份")
      }
      Section("加入房间") {
        TextField("6 位房间号", text: $form.roomCode)
        Button {
          Task {
            await together.joinRoom(
              code: form.roomCode, nickname: form.nickname, anonymous: form.anonymous)
          }
        } label: {
          Label("加入房间", systemImage: "rectangle.portrait.and.arrow.right")
        }
        .disabled(together.connecting)
      }
      Section {
        Button {
          Task { await together.createRoom(nickname: form.nickname, anonymous: form.anonymous) }
        } label: {
          Label("创建新房间", systemImage: "plus.circle.fill")
        }
        .disabled(together.connecting)
      }
      if together.connecting {
        Section {
          HStack {
            Spacer()
            ProgressView("正在连接")
            Spacer()
          }
        }
      }
    }
    .onAppear { populateNickname() }
  }

  private var roomView: some View {
    #if os(macOS)
      ScrollView {
        VStack(spacing: 20) { roomSections }
          .frame(maxWidth: 800)
          .padding(32)
          .frame(maxWidth: .infinity)
      }
      .background(.quaternary.opacity(0.2))
    #else
      List { roomSections }
    #endif
  }

  @ViewBuilder
  private var roomSections: some View {
    TogetherSection(title: "房间", symbol: "person.2.wave.2") {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(together.roomCode).font(.largeTitle.bold().monospaced())
          Text("剩余 \(format(together.remainingSeconds))").font(.subheadline).foregroundStyle(
            .secondary)
        }
        Spacer()
        ShareLink(item: "一起听房间号：\(together.roomCode)") { Image(systemName: "square.and.arrow.up") }
      }
    }
    if let room = together.room {
      TogetherSection(title: "成员 · \(room.members.count)", symbol: "person.2") {
        ScrollView(.horizontal) {
          HStack(spacing: 16) {
            ForEach(room.members) { member in
              VStack(spacing: 5) {
                ArtworkView(
                  url: RemoteAssetURL.make(
                    member.avatar.isEmpty ? member.user?.avatar : member.avatar), cornerRadius: 26
                ).frame(width: 52, height: 52)
                Text(member.nickname.isEmpty ? member.user?.nickname ?? "成员" : member.nickname)
                  .font(.caption).lineLimit(1)
              }.frame(width: 70)
            }
          }.padding(.vertical, 4)
        }.scrollIndicators(.hidden)
      }
      TogetherSection(title: "播放控制", symbol: "play.circle") {
        HStack {
          Button {
            together.send(action: "prev")
          } label: {
            Image(systemName: "backward.fill")
          }
          Spacer()
          Button(action: together.sendPlayOrPause) {
            Image(systemName: room.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(
              .system(size: 48))
          }
          Spacer()
          Button {
            together.send(action: "next")
          } label: {
            Image(systemName: "forward.fill")
          }
        }.buttonStyle(.plain).padding(.horizontal, 36)
        Picker("播放模式", selection: Binding(get: { room.playMode }, set: together.setPlayMode)) {
          Text("顺序").tag("normal")
          Text("随机").tag("random")
          Text("单曲循环").tag("single")
        }
      }
      TogetherSection(title: "房间队列", symbol: "music.note.list") {
        if room.playlist.isEmpty {
          ContentUnavailableView(
            "队列为空", systemImage: "music.note.list", description: Text("在歌单中点选歌曲即可添加"))
        }
        ForEach(Array(room.playlist.enumerated()), id: \.element.id) { index, roomSong in
          HStack {
            Button {
              together.playSong(at: index)
            } label: {
              SongRow(
                song: roomSong.song, number: index + 1, active: room.currentSongIndex == index)
            }.buttonStyle(.plain)
            Button(role: .destructive) {
              together.removeSong(at: index)
            } label: {
              Image(systemName: "minus.circle")
            }
          }
        }
      }
      TogetherSection(title: "房间设置", symbol: "slider.horizontal.3") {
        Toggle("自动续期", isOn: $together.autoRenew)
        Toggle(
          "播完删除",
          isOn: Binding(
            get: { room.deleteAfterPlayed },
            set: { together.updateSettings(deleteAfterPlayed: $0, loopPlaylist: room.loopPlaylist) }
          ))
        Toggle(
          "循环播放列表",
          isOn: Binding(
            get: { room.loopPlaylist },
            set: {
              together.updateSettings(deleteAfterPlayed: room.deleteAfterPlayed, loopPlaylist: $0)
            }
          ))
        Button("立即续期", action: together.renewRoom)
      }
    }
    TogetherSection(title: "房间操作", symbol: "rectangle.portrait.and.arrow.right") {
      Button("离开房间", role: .destructive, action: together.leaveRoom)
      Button("解散房间", role: .destructive, action: together.deleteRoom)
    }
  }

  private func format(_ seconds: Int64) -> String {
    String(format: "%02lld:%02lld", seconds / 60, seconds % 60)
  }
}

private struct TogetherSection<Content: View>: View {
  let title: String
  let symbol: String
  @ViewBuilder var content: () -> Content

  var body: some View {
    #if os(macOS)
      DesktopCard(title: title, symbol: symbol) {
        VStack(alignment: .leading, spacing: 16) { content() }
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    #else
      Section(title) { content() }
    #endif
  }
}

private final class ListenTogetherFormModel: ObservableObject {
  @Published var roomCode = ""
  @Published var nickname = ""
  @Published var anonymous = false
}
