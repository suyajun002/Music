---
name: douyin-iphone-app
description: >
  用户要把抖音链接变成 iPhone 上能播放的本地视频（无水印下载、离线保存、锁屏与后台播放），
  或要在这个 App 上继续开发（改界面、改取流、换图标、重新装到真机、签名过期重装）时使用。
  同时涵盖「不打开 Xcode GUI，从命令行构建并安装 iOS App 到真机」的通用流程。
  纯工程实现（Swift + 系统框架），app 内不调用任何模型。
triggers:
  - 抖音转视频/抖音下载到手机/抖音链接变成本地视频/手机上播放抖音
  - douyin2mp3/抖音转MP3 App/抖音 App 改一下
  - 装到 iPhone/安装到真机/签名过期/重新安装 App
  - 命令行构建 iOS App/devicectl 安装/信任开发者证书
---

# 抖音 → iPhone 本地视频 App

把抖音分享链接变成手机上能播的本地视频：App 自己解析、下载无水印 MP4、存沙盒、离线播放，锁屏与后台继续出声。不依赖 Mac、不依赖服务器、不重编码音频。

> 本文件从 [douyin2mp3](https://github.com/suyajun002/douyin2mp3) 导出，路径均相对仓库根目录。

## 何时用

- 用户要「抖音链接 → 手机能听/能看」
- 要改这个 App（界面、取流、图标、签名、重装）
- 要把任意 iOS App 从命令行构建并装到真机（见「通用：命令行构建并安装到真机」）

## 项目位置

- App 工程：`ios/Douyin2MP3`（SwiftUI，零第三方依赖；**显示名「Music」**，图标淡粉底 + 深莓色音符，见「命名与图标」）
- 签名：工程里的 `DEVELOPMENT_TEAM` / bundle id 是原作者的值，**复用时必须换成自己的**，否则签名失败或与手机上已装 App 冲突
- 取流核心：`ios/Douyin2MP3/Douyin2MP3/Services/DouyinExtractor.swift`
- 并发闸门：`Services/ConcurrencyGate.swift`（纯 Foundation，可命令行单测）
- 播放：`Services/MediaPlayer.swift` + `Views/VideoSurface.swift`
- 图标源：`design/appicon.svg`（`rsvg-convert` 出 1024 PNG → `Assets.xcassets/AppIcon.appiconset`）
- 早期 Mac agent（已废弃，仅作参考）：`legacy/mac-agent`
- 构建产物：`build/Build/Products/Debug-iphoneos/Douyin2MP3.app`

## 取流链路（2026-10-15 实测可用）

| 步骤 | 请求 | 关键点 |
|---|---|---|
| 1 抠链接 | 分享文本里第一个 `https://`，去掉结尾中文标点 | 短链 `v.douyin.com` 读 302 Location；ID 取 `modal_id` 或路径最后一段 |
| 2 基础 Cookie | `GET https://www.douyin.com/`（桌面 UA + Referer） | 失败不致命，继续 |
| 3 ttwid | `POST https://ttwid.bytedance.com/ttwid/union/register/`，固定 JSON body（region cn / aid 1768 / service www.ixigua.com） | 无 ttwid 时 share 页退化为壳页；Cookie 池跨域全带 |
| 4 share 页 | `GET https://www.iesdouyin.com/share/video/<id>/`（iPhone UA + Cookie + Referer） | 壳页判定：HTML 必须含 `"aweme_type"`，否则换 `/share/note/<id>/`；解析 `"play_addr":{"uri":"..."`、`images`、`desc` |
| 5 换直链 | `GET https://aweme.snssdk.com/aweme/v1/play/?video_id=<uri>&ratio=<X>&line=0` | 免签名；**必须阻止自动跟随跳转**才能读到 302 的 Location |
| 6 下载 | CDN 直链，带 `Referer: https://www.douyin.com/` | 缺 Referer 直接 403；校验前 64 字节含 `ftyp`；清晰度 1080p → 720p → 540p 回退 |

**坑（都踩过）**

- 图文作品的背景音乐也有 `play_addr`（mp3 域），判定顺序必须先 `images` 再回退视频，否则会当视频去下载并三个清晰度全失败。
- 不要用 `aweme/v1/web/aweme/detail`：需要 UIFID Cookie + a_bogus 签名链，2026-09 起被风控。
- URLSession 默认跟随跳转，会吃掉 Location：要用 `willPerformHTTPRedirection` 返回 `nil` 的 delegate。
- 全程 HTTPS，**不需要** ATS 豁免，也不需要本地网络权限（别多加，省得弹无谓授权）。
- 同一作品重复提交时，先查本地库再决定是否重复下载。
- **CDN 走 chunked、没有 `Content-Length`**：`URLSessionDownloadTask` 的 `totalBytesExpectedToWrite` 会是 `-1`。若进度回调写 `guard expected > 0 else { return }`，进度条会**永远钉在进入下载时的百分比**（表现为「一直 25%，但其实早就下完了」）。必须回退成「已下载 X MB + 不确定进度条」，不要假装一个百分比。
- 进度回调 `urlSession(_:downloadTask:didWriteData:...)` 属于 **`URLSessionDownloadDelegate`**；delegate 类要声明这个协议（只声明 `URLSessionTaskDelegate` 属于碰运气）。
- **`session.download(for:delegate:)` 的任务级 delegate 收不到 `didWriteData`**：2026-10-15 实测数据一路下到 730MB，界面永远停在 25%。进度必须走**会话级 delegate**（`URLSession(configuration:delegate:delegateQueue:)`），这也是后台会话的硬要求。落点：`Services/MediaDownloader.swift`。
- **锁屏/切后台会把下载掐断**：iOS 几秒内挂起 App，正在进行的连接报 `network connection was lost`，并留下半截临时文件。要「不亮屏也能下完」必须用 `URLSessionConfiguration.background(withIdentifier:)`（交给系统 `nsurlsessiond`），并在 AppDelegate 实现 `application(_:handleEventsForBackgroundURLSession:completionHandler:)` 把 completionHandler 交回 URLSession。
- **半截下载会堆满沙盒**：每次被掐断的 `URLSessionDownloadTask` 都在 `tmp/CFNetworkDownload_*.tmp` 留一个文件，实测 25 个、单个最大 730MB、合计 1GB+（App 本体才 2.4MB，用户会在「iPhone 储存空间 → 文稿与数据」看到）。启动时清 `CFNetworkDownload_*`，失败时删目标半成品。
- **盘点沙盒占用**：`xcrun devicectl device info files --device <UDID> --username mobile --domain-type appDataContainer --domain-identifier <bundleID> -r`，比在手机上猜快得多。
- **`devicectl` 安装/启动都要求设备「解锁且唤醒」**：屏幕息屏或锁屏时报 `Unable to launch ... device was not, or could not be, unlocked` 或 `CoreDeviceError 4016 ... CurrentlyAssertableStates = ( )`。没有远程唤醒/按电源键的接口，必须让用户解锁后再执行；别反复重试。
- **手机侧偶发 `The network connection was lost`（-1005）**：2026-10-15 实测同一条 `uri` 在 Mac 上 `curl` 正常返回 206/`video/mp4`，手机却三个清晰度全部 -1005。这是手机到 CDN 边缘节点的问题，**重复试同一个地址没用**：用 `DouyinConfig.lineCandidates = [0,1,2]` 换 `line` 参数命中不同边缘节点，按「清晰度 × 线路」逐个尝试。
- 下载超时别再设 600s：`URLRequest.timeoutInterval` 是**空闲**超时（多久没新数据算超时），设 600 会让卡死的连接原地停十分钟。30s 足够，卡住就换下一条线路。
- `URLSessionConfiguration.waitsForConnectivity = true` 在真机上把每次失败拖到 ~2 分钟才报错，下载器场景不要开。

## 接口变了改哪里

只改 `DouyinExtractor.swift`（`DouyinConfig` 里的 UA / 清晰度候选 / 超时，以及各解析方法）。改完必须重新构建并重装 App。

## 通用：命令行构建并安装到真机

不打开 Xcode GUI 也能建工程、签名、装真机：

1. **手写工程文件**：`objectVersion = 77` + `PBXFileSystemSynchronizedRootGroup`，目录内 `.swift` 自动进编译，不必逐个列文件；配 `GENERATE_INFOPLIST_FILE = YES`。
2. **Info.plist 必须放在同步目录之外**，否则和自动生成清单冲突，报 `Multiple commands produce .../Info.plist`。
3. **纯逻辑先用命令行验证**：`swiftc` 把那个 `.swift` 加一个 `main.swift` 编成 macOS 命令行，直接喂真实链接，不用模拟器/真机（本机没有 iOS 模拟器运行时也能验）。
4. **拿团队 ID**：`security find-certificate -c "Apple Development: <email>" -p | openssl x509 -noout -subject`，取 `OU=`。
5. **构建**：`xcodebuild -project X.xcodeproj -scheme X -destination 'generic/platform=iOS' -configuration Debug -allowProvisioningUpdates -derivedDataPath <稳定目录> build`
6. **安装**：`xcrun devicectl device install app --device <UDID> <X.app>`（UDID 用 `xcrun devicectl list devices` 查）
7. **启动**：`xcrun devicectl device process launch --device <UDID> <bundleID>`
8. **首次必须由用户在手机上信任证书**：设置 → 通用 → VPN与设备管理 → 开发者App → 信任。否则报 “invalid code signature / profile has not been explicitly trusted”。这一步只能用户点，别尝试代劳。
9. **免费个人团队 7 天过期**：到期 App 打不开，重跑第 5、6 步即可。
10. **图标**：单尺寸 1024×1024 PNG + 资产目录 `AppIcon.appiconset`（`"platform":"ios"`、`size 1024x1024`）+ 构建设置 `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`；无设计稿时用 `rsvg-convert -w 1024 -h 1024 icon.svg -o icon-1024.png` 确定性出图。

## App 结构（对齐 Apple 音乐 App）

- 两个页签：**资料库**（歌曲列表：封面缩略图 + 标题 + 时长，可搜索、可排序、可滑动删除）、**转视频**（转换记录，含进度与失败原因）。
- 播放：页签栏上方常驻**迷你播放条**（封面 + 标题 + 播放/暂停 + 下一首），点开是**全屏「正在播放」**：大封面（点右上角图标可切回视频画面）、标题/艺人、进度条 + 剩余时间、上一首/播放/下一首、音量条（`MPVolumeView`，附带 AirPlay 路由按钮）。
- 封面：下载完用 `AVAssetImageGenerator` 抽视频第 1 秒的帧存 `<id>.jpg`，同时作为锁屏 `MPMediaItemArtwork`。抽帧失败用渐变音符占位图，不阻塞入库。
- 队列：以资料库顺序为队列，一首播完自动下一首；「上一首」遵循音乐 App 习惯——播放超过 3 秒先回到开头，3 秒内才切上一首。
- 分层：播放器不碰文件系统，由 `ConversionService` 注入 `configure(files:artwork:)`；视图只读状态、只发指令。
- 后台播放：`scenePhase` 变 background 时把 `showsVideo` 置 false，`VideoSurface` 被移除即自动摘掉 `AVPlayerLayer`，音频不中断；回前台恢复画面。
- ⚠️ **播放状态必须让视图单独观察**：`PlayerBar` / `PlayerView` / `LibraryView` 只持有 `ConversionService` 这个 `EnvironmentObject` 时，读 `service.player.isPlaying` 不会随播放器刷新 —— 图标会停在旧状态（点了暂停、按钮还显示暂停图标），全屏进度条也不动。App 入口要额外 `.environmentObject(service.player)`，这些视图各自声明 `@EnvironmentObject private var player: MediaPlayer`。
- ⚠️ **`isPlaying` 不能只手翻**：由 `player.observe(\.timeControlStatus)` 驱动（`.playing` → true、`.paused` → false、`.waitingToPlayAtSpecifiedRate` 保持现状），`toggle()` 也以 `player.timeControlStatus` 判断该 pause 还是 play。否则播完、被系统中断、缓冲时图标都和实际不符。

## 底部条与键盘（iOS 26）

- ⚠️ **不要用 `tabViewBottomAccessory`** 挂迷你播放条：即使内容为空它也会占一条槽位，用户看到的就是「没播放也多一条白条」。
- 正确做法：`safeAreaInset(edge: .bottom) { PlayerBar() }` 挂在 **TabView 内部每个页签页面**上（`PlayerBar.swift` 的 `miniPlayerInset()`）。挂在 TabView **外面**会盖住页签栏；没播放时 `if let` 不产出视图，高度自动塌成 0。
- ⚠️ **不要给键盘加 `.keyboard` 位置的「完成」按钮**：它会和底部迷你播放条挤在同一片区，看起来像播放控件旁边多出来一个按钮。`TextEditor` 在 `List` 里靠 `.scrollDismissesKeyboard(.immediately)` 收键盘就够。

## 粘贴即自动下载

- 界面不做识别：`ConversionService.autoSubmit(from:)` 返回结构化 `SubmitOutcome`（`queued` / `downloaded` / `running` 计数），视图只用它拼一行结论，并按 `hasLink` 决定清不清输入框、要不要提示「没识别到链接」。
- 触发用 `.task(id: input)`：输入一变就重跑，天然防抖（450ms 后提交），不用手写 Timer。识别到链接就清空输入框并收起键盘，让用户直接看到下面跑起来的任务。
- 去重要分两种，缺一不可：**正在下载**按 `sourceURL` 比 `jobs`；**已经下过**按 `sourceURL` 比资料库。后者需要 `MediaItem.sourceURL` —— 可选字段，旧 `library.json` 缺这个键会解成 nil（实测确认向后兼容），只是老条目无法参与去重。

## 文本解码（标题里的 \u002F）

- ⚠️ `JSONSerialization.jsonObject(with:)` **默认不接受顶层是字符串片段**，必须带 `options: [.fragmentsAllowed]`；少了它，解 JSON 字符串永远返回 `nil`，标题就一直显示成 `开车\u002F健身`（旧代码就是这个毛病，`?? raw` 兜底把未解码文本直接展示出来了）。
- 分享页的 desc 有时被转义**两层**：解一层后仍残留 `\u002F`，所以 `JSONEscapes.decode` 最多解三层、解不动就停（`Services/JSONEscapes.swift`）。
- 老索引里的标题要**就地迁移**（`MediaLibrary.migrateTitles()`），否则为了改一个标题得重下整条视频。

## 并发下载（一次粘多条）

- 一次可粘贴多条分享文本：`DouyinExtractor.allURLs(in:)` 抠出全部 `https://` 链接、去重、去掉结尾中文标点；`DouyinExtractor` 是 **actor**，凭证与 Cookie 池在多任务间天然串行，网络等待可交错，所以并行下载是真并行。
- 并发规则集中在 `Services/ConcurrencyGate.swift`（纯 Foundation，不碰下载实现与 UI）：`limit`（最低 1）、`takeStartable()` 取当前可启动的任务（先到先跑、不超过上限）、`finish()` 释放名额。`ConversionService.pump()` 只负责「取任务 → 起 Task → 跑完回来 `finish()` 再 `pump()`」。
- 并发数用户可调并持久化：`ConversionService.concurrencyOptions = [1,2,3,4,6]`，默认 3，键 `conversion.maxConcurrent`，改完立刻重排。
- ⚠️ `@Published var maxConcurrent` 的 `didSet` **在 `init` 里赋值时不会触发**，所以 `init` 里必须再显式 `gate.limit = initial` 一次，否则持久化的并发数不会生效。
- 提交时按 `sourceURL` 与「在处理中的任务」去重，避免同一链接重复下载。
- 视图只展示 `runningCount` / `waitingCount`（不要用 `activeCount - waitingCount` 这种推导口径）。

## 命名与图标

- 显示名在工程里：`ios/Douyin2MP3/Douyin2MP3.xcodeproj/project.pbxproj` 的 `INFOPLIST_KEY_CFBundleDisplayName`（Debug/Release **两处**都要改），不是 Info.plist。
- 图标规范：**淡粉背景 + 深莓色连梁双八分音符**。源文件 `~/douyin2mp3/design/appicon.svg`，出图 `rsvg-convert -w 1024 -h 1024 design/appicon.svg -o design/appicon-1024.png`，再拷到 `Assets.xcassets/AppIcon.appiconset/icon-1024.png`。
- 画法要点：音符各部件共用 `gradientUnits="userSpaceOnUse"` 的渐变，否则每个矩形/椭圆各自映射渐变、拼接处会出现接缝；符干顶端要藏进连梁里，否则露出圆头；整体用 `transform="translate(...) scale(1.28)"` 居中放大。
- 改名后必须重新构建并重装；`devicectl` 安装**不会自动重启**已在运行的 App，装完要 `--terminate-existing` 启动一次才看得到新界面。

## 验证归档

- 取流：真机取不到时，先在本机用 Swift 命令行版喂同一条链接复现，再判断是接口问题还是 App 问题。
- 并发：`swiftc -O Services/ConcurrencyGate.swift main.swift -o gatetest` 直接单测闸门（上限、FIFO、去重、取消、名额释放）+ 计时（3 并发跑 6 条约 2 轮，实测加速 2.95x）。
- 进度换算：`swiftc -O Services/DouyinExtractor.swift main.swift -o progresstest` 单测 `FetchProgress.fromBytes`（`expected=-1` → `fraction=nil` 且上报字节；`expected=0` 不产生 NaN；超额夹到 1.0）。
- 只有 `main.swift` 那个文件名能放顶层语句；其它文件名必须 `@main struct X { static func main() }`，否则报 `expressions are not allowed at the top level`。
- 真机诊断：`DEVICECTL_CHILD_D2M_DEBUG=1 xcrun devicectl device process launch --console --terminate-existing --device <UDID> <bundleID>`，App 里 `D2M_DEBUG=1` 时才打印 `[d2m]` 取流/下载细节（默认关闭）。
- 截真机屏幕（不用 WebDriverAgent）：`xcrun devicectl device capture screenshot --device <UDID> --destination /tmp/x.png`。
- 安装：`devicectl install` 成功后必须再 `process launch` 一次，才算「装完能跑」。
- ⚠️ 真机**远程点击不可靠**：WebDriverAgent 这类远程控制方案依赖设备已信任开发者证书，证书没信任时直接起不来，反复重试很费时（每次探测约 20 秒）。命令行能稳定做到的是**安装、启动、截图**；凡是要点一下才能看到的（点歌、看迷你条、收键盘）就请用户手点，然后自己截图核对。

## 注意

- 仅个人学习自用；视频版权归原作者，不要二次发布。
- 硬编码约束：UA、清晰度候选、超时、端口、ID 等可变项都在 `DouyinConfig` / 配置里，不要把某条链接或某次抓包的固定值写进实现。
