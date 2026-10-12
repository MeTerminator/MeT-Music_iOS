# MeT-Music iOS / Mac

MeT-Music 的原生 SwiftUI 客户端，覆盖 iPhone、iPad 和原生 macOS App，为 iPad 横屏与 Mac 提供双栏播放器布局。业务能力与 MeT-Music Android / Mobile 端保持一致，音频、后台播放、锁屏媒体信息及系统控制均基于 Apple 原生框架实现。

> 本项目使用远端 MeT-Music 服务获取歌单、音频地址和歌词。Apple Music 是 Apple Inc. 的商标，本项目与 Apple Inc. 没有官方关联。

## 功能

### 音乐库与播放

- 通过 QQ 号读取用户歌单，无需在 App 内提交账号密码。
- 支持歌单详情、播放队列，以及顺序、列表循环、随机和单曲循环。
- 独立播放立即使用远端音频串流，同时在后台缓存完整文件。
- 支持标准、高品质、无损、Hi-Res、DTS、360 Reality Audio 和臻品母带等服务端音质档位。
- 完整本地文件由 `AVAudioPlayer` 播放，跳转是同步赋值 `currentTime`，没有可被后续请求打断的异步回调；仅在文件尚未缓存完成时使用 `AVPlayer` 串流。
- 已缓存的歌曲一律从磁盘播放，不再走网络。
- 跳转是一次串行事务：暂停播放 → 确认媒体可 seek（串流先缓存为完整本地文件）→ 零容差 seek → 校验落点 → 恢复播放。
- 同一时刻只有一次跳转事务；连续点击歌词只会改写事务目标，最终停在最后点击的那一行，不会让播放器同时追多个位置。
- 支持后台音频、锁屏与控制中心歌曲信息、封面、播放/暂停、上一曲、下一曲和进度跳转。
- 底部迷你播放器采用固定 72 点高度的不透明栏，页面内容在其上方结束，并在没有当前歌曲时自动隐藏。

### Apple Music 风格歌词

- 歌词引擎已直接内置于 `MeTMusic/Lyrics`，不再作为单独 Swift 组件维护。
- 优先加载 TTML 逐字歌词，失败时自动回退到普通 LRC/QRC 歌词。
- 支持逐字渐变、强调字符、背景歌词、对唱、翻译、音译、间奏提示和点击跳转。
- TTML 能力直接读取歌曲接口返回的 `ttml` 字段，并在歌单和播放队列中显示标识。
- 使用 Apple 系统字体和接近 Apple Music 的字号、行距、模糊及缩放表现。
- 长句参考 [AMLL 的分段换行思路](https://github.com/amll-dev/applemusic-like-lyrics/blob/main/packages/core/src/utils/lyric-line-break.ts)，先确定所需行数，再结合标点、空格和系统分词边界平衡行宽；避免标点悬在行首，换行处的空格不影响左右对齐，英文音节和带注音的词保持完整。
- 汉字、韩文、日文等单字歌词的原始换行点左右两个字内若有空格，优先移到最近的可用空格；两侧同距时选择行宽更均衡的位置，并保持相邻行不溢出、不拆英文单词或注音词。
- 换行断点随容器宽度、字号和词组信息缓存，逐字播放进度不会重新分词；主唱、背景歌词和对唱共用这套布局。
- 点击歌词时使用第一个真实非空单词的原始时间，避免视觉优化后的提前时间造成错行。
- 歌词何时变为当前行只取决于真实演唱时间加上设置里的「提前步进」，优化器为视觉效果提前的行起始时间不再叠加进来。
- 跳转后锚定到最近开始的那一行；重叠歌词（对唱、上一句拖到下一句）不会把视图拉回更早的那一行。
- 歌词以低频媒体采样加显示帧插值运行；每进入新的一行，会读取一次 `AVPlayer.currentTime()` 重新校准歌词时钟。
- seek 完成后以 AVPlayer 的实际位置为准，并通过媒体源版本号重置歌词插值，避免 iPad 上拖动进度后的不同步。
- iPad 与 Mac 使用较低的歌词渲染帧率、懒加载列表和轻量化特效，降低长歌词及快速滚动时的开销。

### 全屏播放器与自适应布局

- 背景覆盖安全区，并由当前封面生成模糊色彩背景。
- 竖屏布局与 iPhone 一致，可在封面控制页和歌词页之间左右滑动。
- iPad / Mac 横屏时左侧显示封面和播放控制，右侧显示纯歌词区域及翻译开关。
- 全屏播放器左上角提供 X 关闭按钮，打开时隐藏原页面及其顶部操作，关闭后恢复原导航状态；Mac 播放器采用淡入淡出过渡。
- 拖动播放进度条或音量条时会锁定控件手势，不会误触发页面左右切换。
- 播放队列支持跳转到当前歌曲、TTML 标识及轻量封面加载。

### 一起听与缓存

- 支持创建、加入、续期及解散一起听房间。
- 房间内同步队列、播放状态、进度和服务器时间，并按设置阈值自动校正。
- 一起听会等待完整音频缓存后再播放，并根据下载耗时重新计算房间位置。
- 可查看单曲缓存、按分类统计空间占用并清理歌单、封面、歌曲、歌曲信息或歌词缓存。
- 网络不可用时可回退到已经缓存的歌单数据。

## 平台与技术栈

| 项目 | 要求或实现 |
| --- | --- |
| 系统 | iOS / iPadOS 17.0 及以上；macOS 14.0 及以上 |
| 语言与界面 | Swift 6、SwiftUI |
| 音频 | AVFoundation、AVPlayer |
| 系统媒体控制 | MediaPlayer、MPNowPlayingInfoCenter |
| 网络 | URLSession、WebSocket |
| 数据与缓存 | Codable、UserDefaults、文件缓存 |
| 歌词 | 内置 TTML 解析器、LRC/QRC 回退解析器 |
| 测试 | Swift Testing、Swift Package Manager |

Xcode 的 `MeT-Music` target 同时支持 iOS 与原生 macOS（非 Mac Catalyst）。Mac 版提供资料库 / 一起听 / 已缓存歌曲侧栏、独立设置窗口和可调整大小的双栏播放器，支持 Apple silicon 与 Intel Mac。

Mac 快捷键：⌘P 播放/暂停、⌘← / ⌘→ 上一首/下一首、⇧⌘L 打开/关闭播放器、Esc 关闭播放器、⌘0 显示主窗口、⌘, 打开设置。关闭主窗口后，使用菜单「文件 → 显示主窗口」重新打开。

## 播放与歌词时间模型

播放器将 AVPlayer 的媒体时间作为唯一权威时钟，不对 AirPods、蓝牙或 AirPlay 的输出延迟进行人工补偿，避免系统延迟与应用补偿被重复计算。

歌词的提前量只有一个来源：设置里的「提前步进」（默认 0 ms）。`optimizeLyricLines` 仍会把行起始时间提前 400–600 ms 用于视觉过渡，但歌词时间轴使用的是真实演唱时间（首个有声单词），两者不再叠加。想要更早或更晚换行，调这一个设置即可。

正常播放时，AVPlayer 以较低频率发布媒体位置，歌词视图在显示刷新期间进行平滑插值。以下事件会强制重新锚定歌词时钟：

- 用户拖动进度条或点击歌词；
- 控制中心或耳机发起进度跳转；
- 播放媒体源发生变化；
- 新的主歌词行开始；
- AVPlayer 的实际 seek 结果与目标位置存在差异。

播放有两个引擎，由 URL 决定：本地完整文件走 `AVAudioPlayer`，远端串流走 `AVPlayer`。前者的位置是可读写属性，赋值即生效，因此不存在"seek 被下一次 seek 取消后停在中间位置"这一类竞态；后者保留给尚未缓存完成的首次播放。`AVAudioPlayer` 无法解码的格式会自动回落到 `AVPlayer`。文件引擎自行处理中断（来电）与拔出耳机，避免音频已静音而歌词继续滚动。

跳转按固定顺序执行，不依赖回调竞争：先暂停播放，再确保媒体能够服务目标位置（`seekableTimeRanges` 覆盖该点；远端串流则先等待同一个缓存任务下载出完整本地文件并重新装载），然后以零容差 seek 跳转，读取播放器实际位置校验落点，不一致时最多重试 3 次，最后才恢复播放。因为移动期间播放是暂停的，读到的时间就是最终落点，不会被"边播边跳"的时钟推进干扰。

同一时刻只有一次跳转事务。事务进行中的点击只改写目标位置并立即显示，不会再发一次 seek；重复点击同一行不会重复跳转。是否恢复播放由这一串点击之前的播放状态决定，事务期间手动暂停或播放会改写该状态。所有 seek 仍带有媒体源 generation 和 discontinuity revision，过期回调无法修改新歌曲的播放位置。

## 项目结构

```text
MeTMusic/
├── App/          # SwiftUI App 入口
├── Lyrics/       # TTML 解析、歌词优化、布局、动画和时间轴
├── Models/       # 歌曲、歌单、房间及普通歌词模型
├── Networking/   # MeT-Music REST API
├── Playback/     # AVPlayer 与 Now Playing / 远程控制
├── State/        # AppStore 与一起听状态
├── Storage/      # 音频、封面、歌单和歌词缓存
└── Views/        # 音乐库、播放器、队列、设置等界面
```

Android/KMP 功能到原生 iOS 实现的对照见 [MIGRATION.md](MIGRATION.md)。

## 构建运行

1. 安装包含 iOS 17 SDK 的完整 Xcode。
2. 使用 Xcode 打开 `MeT-Music-iOS.xcodeproj`。
3. 选择 `MeT-Music` scheme。
4. 在 Signing & Capabilities 中选择自己的开发团队。
5. 选择 iPhone / iPad 真机、模拟器，或 **My Mac** 运行原生 Mac App。

Mac 使用 `Configuration/MacInfo.plist` 和独立 Bundle Identifier `top.met6.music.macos`，复用音频、缓存、歌词与一起听逻辑。

应用启用了 Background Modes 中的 Audio。若更换 Bundle Identifier，需要同步检查签名、后台播放和系统媒体控制能力。

## 验证

运行 Swift Package 测试：

```bash
swift test
```

构建原生 Mac App：

```bash
xcodebuild \
  -project MeT-Music-iOS.xcodeproj \
  -scheme MeT-Music \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

构建 iOS Simulator target：

```bash
xcodebuild \
  -project MeT-Music-iOS.xcodeproj \
  -scheme MeT-Music \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

如果 `xcode-select` 当前指向 Command Line Tools，请显式指定完整 Xcode：

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

## 开发说明

- 服务端地址定义在 `MeTMusic/Networking/APIClient.swift`；部署到其他环境时需要修改 API 与房间服务地址。
- `MeTMusic/Lyrics` 是 App 源码的一部分，歌词功能的修改和测试应与主工程一起提交。
- UI 状态更新运行在 MainActor；AVPlayer 回调通过 generation 校验后才能写回界面状态。
- 不要在歌词显示帧中直接发起网络、磁盘或 AVPlayer 查询。逐行时钟校准通过去重的异步边界事件执行。

## 许可证

本项目使用 [MIT License](LICENSE)。
