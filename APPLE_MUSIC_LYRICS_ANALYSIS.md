# 本机 Apple Music 歌词实现分析

分析日期：2026-10-27。样本为用户提供的 `/Users/meterminator/Temp/Contents/`，只读检查，未修改原应用。

## 样本与方法

- `Info.plist` 和 `version.plist` 的版本为 **1.7.2**，项目名 `MusicDesktop`，SourceVersion `1007002036000`。
- `MacOS/Music` 是包含 `arm64e` 和 `arm64e.x1` 的 Mach-O 通用可执行文件。
- SHA-256：`9480ef601f529c5b61821c171d3b608e5051b9651ed7838d097cb17b8ea4425d`。
- 检查资源、字符串、Swift 反射字段、Objective-C 符号，并对 `arm64e` 切片中滚动回调及其目标函数做静态反汇编。
- 这不是源码恢复，也没有对原应用播放画面做逐帧测量。下文分别标出可确认的结构、可确认的常量，以及项目自行选择的近似参数。

## 可确认的组件结构

歌词组件嵌在 Music 可执行文件内，模块名为 `LyricsX`；`Resources/LyricsX_LyricsX.bundle` 主要提供本地化资源，不包含可直接移植的歌词 JavaScript/CSS。

| 证据 | 对应职责 |
| --- | --- |
| `SyncedLyricsViewController`、`SyncedLyricsVisualExperienceManager` | 视图布局、显示帧更新、播放时间与选中行协调 |
| `SyncedLyricsLineView`、`SyncedLyricsLineLayer` | 可交互的歌词行及其图层 |
| `Line` → `Word` → `Syllable` → `Glyph` | 行、词、音节和字形分层，音节保存原始时间和绘制位置 |
| `LineProgressGradientLayer`，字段 `color`、`featherWidth`、`direction` | 支持方向和羽化宽度的逐字渐变 |
| `InstrumentalContentLayer`，字段 `dots`、`breathDuration`、`dotFadeInDuration` | 独立的间奏点阵，包含呼吸和逐点淡入状态 |
| `backgroundVocalsLayer`、`backgroundVocalsPosition` | 独立背景声部及上下位置 |
| `translationLineLayer`、`transliterationLineLayer` | 翻译和音译独立布局 |
| `blurFilter`、`brightnessFilter`、`isLineFocused`、`isHighlighted` | 焦点、模糊、亮度、交互高亮分别处理 |

`isSelected`、`isScrolling`、`progress` 是不同状态。管理器存在 `regular`、`scroll`、`tracking` 模式，并有 `selectedLineViews`、`blurredLineViews`、`hiddenLineViews` 集合，表明浏览与播放跟随不是同一种展示状态。

反射字段还包括 `firstLineStartingPosition`、`selectedLinePosition`、`paragraphSpacing`、`lineDelay`、`maxSelectedLines`、`deselectedScrollTextColor`、`touchDownTransform`、`highlightViewCornerRadius`、`syllableLift`、`lineFinishProgressAnimationDuration` 和弹簧质量/刚度/阻尼。这能确认能力和配置入口，不能仅凭字段名确定数值或具体状态转移。

## 确认到的交互时序

### 手动滚动结束：3 秒计时器

`-[LyricsX.SyncedLyricsViewController scrollViewDidEndScrolling]` 位于未重定位地址 `0x1010665c0`，调用 `0x1010ea5bc`。

目标函数在 `0x1010ea67c` 执行 `fmov d0, #3.0`，随后以 `repeats = false` 调用 `scheduledTimerWithTimeInterval:repeats:block:`（调用点 `0x1010ea68c`，选择子桩 `0x1018f3740`）。管理器字段名为 `allowAnimateToNextLineAfterScrollTimer`。

这确认滚动结束路径存在 3 秒的恢复动画许可计时器；具体回调是否立即回到当前行还受管理器配置影响。本项目采用停止输入 3 秒后恢复自动跟随的行为。Mac 的触控板惯性事件也会续期，避免滚动尚未结束就拉回。

### 点击：约 1 秒保护窗口

二进制中的调试消息明确包含以下语义：

- 点击后不足 1 秒，忽略 timing provider 更新；
- 点击 1 秒后，如果当前播放时间指向明显不同的行，强制更新；
- 1 秒内没有新 timing provider，回到旧 provider；
- timing provider 更新时间差小于半秒时忽略。

这支持“先响应点击、短暂保护选中状态、再按真实播放时间校正”的设计。半秒消息属于 provider 更新路径，不能证明它就是 seek 成功容差；本项目将 500 ms 作为视觉保护提前结束的近似阈值，音频 seek 仍使用已有的严格验证。

## 本次项目修改

1. 默认手动浏览恢复等待由 5 秒改为 3 秒，播放器中的显式配置同步修改。
2. 点击使用首个真实单词的原始时间发起跳转。存在真实播放器时钟时，歌词等待播放器发布跳转事件后立即重建，不先渲染一个与播放器无关的目标时间；没有时钟提供者的通用组件调用方保留最多 1 秒的视觉保护与超时校正。连续点击以最后一次为准，手动浏览或切换歌词会取消保护。
3. 歌词行改为原生 `Button`：支持按压反馈、Mac 悬停背景和 VoiceOver 操作。浏览时提高未选中文字亮度、取消缩小并展示背景声部，悬停行清除模糊。
4. 缓存每行前的真实无歌词区间：补上前奏提示；间奏起点使用所有前序主唱及背景声部的最晚结束时间，终点使用原始演唱开始时间。避免紧邻的一行虽已结束，较早的重叠声部仍在唱时，错误显示过长间奏。
5. 保留歌词原始换行：优化器只合并横向空白；TTML 的 `<br/>` 在逐字 span、无时间格式容器、按行文本及翻译中保留为硬断点。XML 缩进仍按格式空白处理，不误变成歌词换行。换行不会新增演唱时间。
6. 长句继续使用系统分词、标点和行宽平衡，英文音节合并及注音词保持整体；窄屏超长词仍使用保留原始时间的片段。硬断点优先于行宽平衡，即使宽屏能放下也不会合并。
7. 宽度、字号和翻译显示变化时，布局位置和相邻歌词以弹簧过渡；断行结果仍按宽度和字体缓存，逐字进度不会重排。音频驱动的逐字蒙版不参与布局补间。
8. 正常步进使用整列共享的滚动位移和动画时间戳。以内容坐标系与视口坐标系的差值计算真实滚动量，不再逐行追踪各自的绝对屏幕目标。当前句先上移，后续句延迟跟上；折行、翻译和背景声部产生的实际高度包含在整列滚动量中。连续切句保留已有步进的时间与位移，再叠加新步进，维持位置和速度连续。
9. 快速歌词保留逐行运动但缩短延迟并加快收敛；同一行的位置校正不重放动效。手动拖动时冻结剩余视觉补偿，并在 160 ms 内释放，输入直接作用于原生滚动。尺寸变化和页面切换清除旧动效。跳转、间奏以及缺少目标行几何信息时回退原生滚动；减少动态效果时直接定位。

### 换行与动画的证据范围

原二进制包含 `textLayoutDiffMetadata`、`previousLines`、`previousWords`、`previousLineFrames`、`reusedLines`、`lineBreakAdjustmentCountMap`、`lineDelay`，以及含 `deltaY`、`curve`、`views`、`delay` 的动画描述字段。它们支持“保存布局差异并复用行、分开描述位移与延迟”的结构判断，不能证明项目当前的平衡断行算法与原版相同。

重排弹簧仍为 `response = 0.38`、`dampingFraction = 0.92`。步进采用临界阻尼闭式解，普通行角频率 12/s、后续行每行延迟 55 ms（最多 220 ms）；快速行角频率 18/s、每行延迟 18 ms（最多 72 ms）。连续切句通过叠加新位移保留旧步进的速度，新位移以零初速度进入。显示时长上限 1.4 秒，仅用于回收已经接近零的补偿。上述参数是本项目的近似选择，未声称恢复了 Apple 的确切常量。歌词占位高度和点击时间不随视觉补偿改变。

## 近似与保留

- 浏览文字 0.55 透明度、悬停背景 0.08、按压背景 0.12、按压缩放 0.98 和反馈 0.16 秒是本项目选择的近似值，未声称从 Apple 常量恢复。
- 保留现有逐字羽化、长音字形伸展、背景声部展开、快速歌词优先高亮及弹簧跟随；本次未恢复 Apple 的精确弹簧、逐行延迟、发光包络和字形曲线。
- 间奏最小长度沿用项目已有的 4 秒；没有证据证明该值与此版本 Apple Music 完全一致。
- 没有歌曲总时长输入，暂未合成尾奏段。原版还包含段落、作词者、语言方向和不同渲染模式等配置，当前数据模型不能完整表达全部行为。
- 原样本是 macOS 应用；不能据此宣称与所有 iPhone/iPad Apple Music 版本逐像素、逐帧一致。

## 复核命令

```sh
strings /Users/meterminator/Temp/Contents/MacOS/Music | rg 'LyricsX|SyncedLyricsDebug'
xcrun nm -arch arm64e /Users/meterminator/Temp/Contents/MacOS/Music | rg 'LyricsX'
lipo /Users/meterminator/Temp/Contents/MacOS/Music -thin arm64e -output /tmp/met-apple-music-arm64e
xcrun llvm-objdump -d --start-address=0x1010665c0 --stop-address=0x10106661c /tmp/met-apple-music-arm64e
xcrun llvm-objdump -d --start-address=0x1010ea5bc --stop-address=0x1010ea6cc /tmp/met-apple-music-arm64e
```

地址仅适用于上述哈希的 `arm64e` 样本，其他版本和切片不可直接套用。

## 验证

- `swift test`：112 项测试，覆盖前奏、跨多行重叠声部的间奏边界、点击后的旧时间保护、到达与超时校正、连续点击、手动浏览取消、无播放 tick 时的保护退出，以及显式断行、TTML 换行与缩进区别、换行前后时间连续性、完整步进距离、延迟、连续步进的位置/速度连续性、手动滚动接管，以及真实本地音频跳转后的歌词时间轴同步。
- Xcode `MeT-Music` scheme：macOS 与通用 iOS Simulator 构建通过，关闭代码签名。
- 独立 macOS 验证窗口直接编译本项目 `Lyrics` 源码，使用合成中文、英文、翻译和对唱歌词；观察前奏、逐字进度、点击后媒体延迟 600 ms 才返回目标、手动浏览增亮，以及空闲后回归跟随。此验证不需要真实账号或播放网络音频，不能代替真机音乐播放与原版逐帧对比。

## 进度跳转后的严格同步修复

- 实际播放器时钟存在时，行激活与逐字进度直接使用共享媒体采样，不再先平滑到插值时间；声部之间最多复用一个 120 Hz 帧间隔的样本。实际时钟停住，歌词也停住。
- 读取媒体位置时以实际读取时刻记录采样时间，不将新的媒体位置与 `TimelineView` 可能过期的计划时间戳配对。
- 跳转开始、跳转完成、媒体载入与切歌均发送不连续事件；事件取消旧步进、点击保护、浏览恢复及校准任务，强制重建时间轴并直接定位。正常逐行校准不发送跳转事件。
- 歌词源比较覆盖中间行的文字与时间，替换源后重建行视图，避免相同首尾 ID 掩盖源变化。
- 切歌取消旧跳转事务，并在取出待跳转目标前核对播放版本；旧事务结束不能清除新事务。异步歌词响应也校验播放版本。
- 跳转后重叠声部持续选择最近开始的行，修复下一次普通 tick 又退回旧声部的问题。
- 使用真实本地音频覆盖 900 → 1100 → 1050 → 2600 → 200 → 3100 ms 的往返跳转及重新载入，断言实际媒体时间与歌词时间相等、每次跳转都重建正确行；另用实际播放器验证窗口检查 2300 → 1100 → 950 ms、重新载入至 500 ms 后继续播放。

## 切行顺序修复

旧实现为每行保留独立的绝对屏幕位置与速度，并在每行自己的显示时钟中追踪当前几何位置。当原生滚动、行高度变化和新一轮步进同时发生时，参考位置可能不一致；各行也缺少不能相互穿越的约束。

当前实现让整列共用一个帧时间，并将每次步进表示为一个共有滚动量乘以延迟的临界阻尼余量。上移时，后续行的余量不小于前行，因此相邻行的视觉间距不会小于布局间距；多次步进叠加仍保持这一性质。下移校正使用统一余量，不施加会挤压行距的延迟。手动接管时冻结整列余量并统一衰减，同样不改变顺序。

新增回归场景在连续 70 ms 切句、交替快慢参数、38–280 pt 行高、背景声部收起、反向校正和手动释放期间逐帧断言偏移单调、相邻歌词不重叠。另用带 ①–⑥ 编号、背景声部、翻译和多行文本的 macOS 窗口检查宽窄布局与连续播放。
