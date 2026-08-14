# KMP → 原生 iOS 迁移对照

| MeT-Music_Mobile 功能 | 原生 iOS 实现 |
| --- | --- |
| QQ 登录、用户歌单 | `AppStore`、`LoginView`、`LibraryView` |
| 歌单详情、离线回退 | `PlaylistDetailView`、`CacheStore` |
| 队列、顺序/循环/随机/单曲循环 | `AppStore`、`QueueView` |
| 普通 LRC/QRC、翻译、音译 | `OrdinaryLyricParser` |
| 普通歌词后检查 TTML | `AppStore.loadLyrics(for:)` |
| Apple Music 风格逐字歌词 | App 内置 `MeTMusic/Lyrics` |
| 独立播放立即串流、后台缓存 | `AppStore.startStandalone(_:)`、`CacheStore.audioURL` |
| 一起听缓存后播放 | `ListenTogetherStore.playRoomSong` |
| 房间创建/加入/续期/解散 | `ListenTogetherStore`、`ListenTogetherView` |
| 房间队列、播放控制、时间校正 | `ListenTogetherStore` |
| 锁屏/耳机控制 | `NowPlayingController` |
| 音质、歌词偏移、字号、QRC 信息行过滤 | `SettingsView` |
| 缓存分类统计、单曲缓存管理 | `SettingsView`、`CachedAudioView`、`CacheStore` |
| Android/桌面悬浮歌词 | iOS 不适用；由锁屏媒体中心与全屏歌词替代 |

音频时间轴不做 AirPods、蓝牙或 AirPlay latency 人工补偿。歌词与 seek 均以 `AVPlayer` 的媒体时间为准，避免路由延迟被重复计入。
独立播放先使用远端串流并后台缓存；用户 seek 时若仍在远端资源上，会暂停并等待同一缓存任务完成，再以本地完整文件执行零容差 seek。
