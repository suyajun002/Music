---
name: douyin-iphone-app
description: >
  用户要把抖音链接变成 iPhone 上能播放的本地视频（无水印下载、离线保存、锁屏与后台播放），
  或要在这个 App 上继续开发（改界面、改取流、换图标、重新装到真机、签名过期重装）时使用。
  同时涵盖「不打开 Xcode GUI，从命令行构建并安装 iOS App 到真机」的通用流程。
  YouTube 那条走 Apify 的现成 actor（REST 调用，不是自己实现下载器）。
  纯工程实现（Swift + 系统框架），app 内不调用任何模型。
triggers:
  - 抖音转视频/抖音下载到手机/抖音链接变成本地视频/手机上播放抖音
  - douyin2mp3/抖音转MP3 App/抖音 App 改一下
  - YouTube 链接转 mp3/YouTube 下载音频/粘 YouTube 链接到 App/配 Apify token
  - 装到 iPhone/安装到真机/签名过期/重新安装 App
  - 命令行构建 iOS App/devicectl 安装/信任开发者证书
---

# 抖音 / YouTube → iPhone 本地媒体 App

把抖音分享链接变成手机上能播的本地视频（App 自己解析、下载无水印 MP4、存沙盒、离线播放，锁屏与后台继续出声），把 YouTube 链接变成 mp3（交给 Apify 上的 actor 代跑，见「YouTube → 音频（Apify）」）。粘链接时按域名**自动认来源**，两条链路后面共用队列、进度、资料库、续播。不依赖 Mac、不依赖自己的服务器；YouTube 那条要花钱（约 ¥0.5/首）。

> 本文件从 [douyin2mp3](https://github.com/suyajun002/douyin2mp3) 导出，路径均相对仓库根目录。

## 何时用

- 用户要「抖音链接 → 手机能听/能看」，或「YouTube 链接 → 手机上一首 mp3」
- 要改这个 App（界面、取流、图标、签名、重装）；YouTube 那条要改 actor 参数或换 token
- 要把任意 iOS App 从命令行构建并装到真机（见「通用：命令行构建并安装到真机」）

## 项目位置

- App 工程：`ios/Douyin2MP3`（SwiftUI，零第三方依赖；**显示名「Music」**，图标淡粉底 + 深莓色音符，见「命名与图标」）
- 签名：工程里**不含** `DEVELOPMENT_TEAM`（已清空），bundle id 是占位值 `com.example.douyin2mp3`。装真机必须自己配团队，或构建时用 `DEVELOPMENT_TEAM=<团队ID> PRODUCT_BUNDLE_IDENTIFIER=<自己的ID>` 从命令行传入 —— 个人值留在命令行、不写回仓库；只做编译校验加 `CODE_SIGNING_ALLOWED=NO`
- 取流核心：`ios/Douyin2MP3/Douyin2MP3/Services/DouyinExtractor.swift`（抖音）
- 抽流接口与来源路由：`Services/MediaExtracting.swift`（两家共用的协议）、`Models/MediaSource.swift`（按域名认来源）
- YouTube：`Services/YouTubeExtractor.swift`（Apify REST）+ `Services/KeychainStore.swift`（token 存 Keychain）
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

## YouTube → 音频（Apify）

第二条取流链路，和抖音**完全不是一个套路**：抖音是自己解分享页 + CDN 直连，YouTube 是花钱让 Apify 上的 actor 代跑（YouTube 对自建 IP 封锁很狠，自建不划算）。两边实现同一个 `MediaExtracting` 协议，`ConversionService` 按 `Job.source` 选，UI 不知道有几个来源。

**链路**（actor `lurkapi/youtube-to-mp3-audio-downloader`，REST 直连，不走 SDK）：

1. `POST https://api.apify.com/v2/acts/<actor>/runs?token=<TOKEN>`，body 里传 `url` → 拿 `data.id` 和 `data.defaultDatasetId`
2. `GET /v2/actor-runs/<id>?token=` → `data.status`，`READY`/`RUNNING` 继续等，`SUCCEEDED` 收工，其余算失败（把 `statusMessage` 带进错误里）
3. `GET /v2/datasets/<datasetId>/items?clean=true&format=json&limit=1000&offset=0&token=` → 一条一条 `{videoId,title,duration,audioFileUrl,status,error}`
4. 直接 HTTP GET `audioFileUrl` 拿 mp3（若 401/403，给它补上 `?token=` 再试一次）

**⚠️ 必须显式指定住宅代理**：`proxyConfiguration: {useApifyProxy: true, apifyProxyGroups: ["RESIDENTIAL"]}`。不写的话 actor 自己会挑机房代理，YouTube 直接封，症状是一律「下载失败」——看起来像 token 或参数错，其实只是代理。这不是可选项。

**钱**：按音频时长计费，`$0.0001785 × 秒 + $0.0193`，均值 **≈$0.068/首（约 ¥0.5）**，一首 1~3 分钟；其中住宅代理流量占账单 68%（$8/GB）。免费计划 $5/月 ≈ 73 首。**失败不计下载费**（只收约 $0.006 的计算费）。已知必失败：直播回放、年龄限制、私享/已删除。所以 App 里含 YouTube 的批量确认框把价格写在脸上，别让用户稀里糊涂花了钱。

- 每条链接**单独开一次 run**（而不是批量一次）：进度和失败各自独立，也套得上现成的 `Job` + `ConcurrencyGate`。代价是每 run 约 $0.009 的固定计算费（约占 13%），量小可以先这么着。
- token 存 **Keychain**（`Services/KeychainStore.swift`，`kSecClassGenericPassword` + `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`，不进备份）。**不要用 `UserDefaults`**：那是明文 plist，会跟着 iTunes/iCloud 备份走。设置面板里可随时更换，读取是**每次调用现读**，所以改完立即生效、不用重启 App。
- token 走**查询串**而不是 `Authorization` 头（skill 里脚本是这么通的，换写法得重新验一遍）。代价是 URL 本身带凭证：**别把完整 URL 打进日志**。
- 结果里没 `audioFileUrl` 时要报 `status`/`error` 里的原因（「直播回放不支持」之类），不要笼统说「下载失败」。地址字段另做一道校验：只认 http(s) 绝对地址，空白串/相对地址一律当没给——`URL(string:)` 很宽容，会把空白串变成一个相对 URL，拿到下载器里只会报看不懂的错。
- `URL(string:)` 之外，抠视频 ID 的正则要覆盖 `youtu.be/`、`/shorts/`、`/embed/`、`?v=` 四种；长度必须正好 11 位，多了少了都算认不出。纯播放列表（只有 `list=`）没有 ID，不认。
- 域名路由在 `Models/MediaSource.swift`，匹配规则是「**等于该域名 或 以 `.该域名` 结尾**」——**不能用 `contains`**，否则 `douyin.com.evil.example` 会被当成抖音。

**不花命令行验证**：`swiftc -O Services/MediaExtracting.swift Models/MediaSource.swift Services/YouTubeExtractor.swift Services/DouyinExtractor.swift Services/JSONEscapes.swift main.swift -o yttest`（`DouyinExtractor.swift` 是纯 Foundation，可以拉进来提供 `DouyinConfig`，省得写桩；`YouTubeExtractor` 里解析用的 `ResultItem(json:)` 是 `internal`，命令行直接喂真实 JSON）。49 项：来源路由、扩展名/计费、视频 ID 正则、抠链接、Apify 响应解析（成功 / 失败 / 空 / 垃圾地址）、run 状态终态、补 token 重试、进度换算、mp3 魔数校验。
**花钱的端到端验证**：`D2M_YT_URL=<链接>` 环境变量起 App（`ConversionService.submitDemoLinkIfRequested()`）走真实 Apify 链路，**跑之前先问用户**（一次约 ¥0.5）。

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
- ⚠️ **进度条不能直接 `Binding(get: player.progress, set: player.seek)`**：`AVPlayer.seek` 是异步的、`elapsed` 又由 0.5s 周期观察者回写，`get` 与 `set` 不同步 → 拖的时候进度条被观察者拉回旧位置，手感就是「拖不动/没法快进」。正确做法：按住（`onEditingChanged(true)`）期间**停止观察者回写 `elapsed`**、`set` 只改 UI，松手（`false`）再落一次 seek；`seek` 里顺手乐观更新 `elapsed` 并 `updateNowPlaying()`。落点 `MediaPlayer.beginScrubbing/scrub(to:)/endScrubbing`。
- ⚠️ **锁屏/控制中心要能快进，必须自己注册遥控命令**：只注册 play/pause/next/previous 的话，锁屏上既没有可拖的进度条、也没有 ±15 秒按钮 —— 表现为「锁屏上完全没法快进」（听 1~2 小时的长音频时这是唯一的快进手段）。要 `changePlaybackPositionCommand`（拖动进度条）+ `skipForward/BackwardCommand`（±15 秒，AirPods 双击/三击也走这两个）。`preferredIntervals` 类型是 `[NSNumber]`，`Double` 字面量**不能**隐式桥接，写 `[NSNumber(value: 15.0)]`。
- ⚠️ **`isPlaying` 不能只手翻**：由 `player.observe(\.timeControlStatus)` 驱动（`.playing` → true、`.paused` → false、`.waitingToPlayAtSpecifiedRate` 保持现状），`toggle()` 也以 `player.timeControlStatus` 判断该 pause 还是 play。否则播完、被系统中断、缓冲时图标都和实际不符。

## 底部条与键盘（iOS 26）

- ⚠️ **不要用 `tabViewBottomAccessory`** 挂迷你播放条：即使内容为空它也会占一条槽位，用户看到的就是「没播放也多一条白条」。
- 正确做法：`safeAreaInset(edge: .bottom) { PlayerBar() }` 挂在 **TabView 内部每个页签页面**上（`PlayerBar.swift` 的 `miniPlayerInset()`）。挂在 TabView **外面**会盖住页签栏；没播放时 `if let` 不产出视图，高度自动塌成 0。
- ⚠️ **不要给键盘加 `.keyboard` 位置的「完成」按钮**：它会和底部迷你播放条挤在同一片区，看起来像播放控件旁边多出来一个按钮。`TextEditor` 在 `List` 里靠 `.scrollDismissesKeyboard(.immediately)` 收键盘就够。

## 粘贴即自动下载

- 界面不做识别：`ConversionService.autoSubmit(from:)` 返回结构化 `SubmitOutcome`（`queued` / `downloaded` / `running` 计数），视图只用它拼一行结论，并按 `hasLink` 决定清不清输入框、要不要提示「没识别到链接」。
- 触发用 `.task(id: input)`：输入一变就重跑，天然防抖（450ms 后提交），不用手写 Timer。识别到链接就清空输入框并收起键盘，让用户直接看到下面跑起来的任务。
- 去重要分两种，缺一不可：**正在下载**按 `sourceURL` 比 `jobs`；**已经下过**按 `sourceURL` 比资料库。后者需要 `MediaItem.sourceURL` —— 可选字段，旧 `library.json` 缺这个键会解成 nil（实测确认向后兼容），只是老条目无法参与去重。

## 剪贴板识别 → 确认框（圆圈倒计时）

- 打开 App / 切回前台识别剪贴板，落点 `Services/ClipboardReader.swift` + `ConversionService.checkClipboard()`。
- 先用**不需要授权**的元数据筛：`changeCount` 变了 且 `hasStrings`/`hasURLs`，才真去读内容。iOS 16 起读 `UIPasteboard.general.string` **必然弹系统授权框**，没有静默 API；所以「值不值得读」必须靠元数据先判。不管读没读到都先记下 `changeCount`，否则被拒后每次启动都再弹一次，变成骚扰。
- 只认认得的域名：`LinkScanner.recognizableURLs(in:)` 抠链再按 `MediaSource.of(url)` 过滤（抖音 + YouTube 两家）。复制个 B站/淘宝链接打开 App 不该弹框（确认了也只会下失败）。域名要按 `host == 域名` 或 `host.hasSuffix("." + 域名)` 比，**别用 `contains`**，否则 `douyin.com.evil.example` 会被当成抖音。
- 确认框**不能用 `.alert`**：系统弹窗只有一排按钮，塞不下「外圈倒计时环 + 圈里一个按钮」，按钮标题也不能跟着秒数实时变（倒计时会卡在初始值）。落点 `Views/ClipboardConfirmView.swift`：外圈 `Circle().trim` 倒计时环，圈里是唯一的按钮「忽略」，不点就 5 秒后自动入队。
- ⚠️ **别给框里的按钮加 `role: .cancel`**：那个角色接的是系统「取消」动作，配在这个自定义框上没有好处。
- ⚠️ **`checkClipboard()` 要挡住重复推送**：启动时 `.task` 和 `scenePhase` 转 `.active` 会各调一次，同一批链接被推第二个 prompt 的话倒计时会从头再来、界面也会抖。判断用 `prompt.id != clipboardPrompt?.id`。
- ⚠️ **倒计时不能只靠 `.task {}` 的初始值**：用 `.task(id: prompt.id)`，且进任务先 `remaining = countdownSeconds` 复位一次，否则同一个 prompt 被重新推上来时会拿着上一轮的 `0` 秒立刻重复下载。
- 想真机看一眼这个框：`D2M_CLIPBOARD_DEMO=1`（`ClipboardReader.demoText`）喂一段**真实分享文本**，后面的抠链接/去重/弹框全走真实代码路径（比直接塞一个假 prompt 可信）。里面的链接是故意不存在的短链，倒计时真跑了也只会失败、不会往资料库里塞东西。用法：
  `xcrun devicectl device process launch --device <UDID> --terminate-existing --console --environment-variables '{"D2M_CLIPBOARD_DEMO":"1","D2M_DEBUG":"1"}' <bundleID>`

## 打开 App 自动续播

- 行为：**只在冷启动**、且**只在当前没在放**的时候，接着**上次那首 + 上次那个位置**放（`MediaPlayer.resumeLastPlayback(from:)`，`RootView` 的 `.task` 里调）。切回前台不续播——否则「暂停着切走、回来被强行放起来」，正在放的那首也会被打断。
- 存档点三个，缺一个就会丢：① `startCurrent()` 末尾（切歌即存档）；② 播放器的 `.paused` 分支；③ 时间观察者里每 5 秒兜底一次（进程被直接杀掉，走不到 ①②）。键 `playback.lastItemID` / `playback.lastElapsed`。进后台（`scenePhase == .background`）也要存一次，那是被系统回收前最后的回调。
- ⚠️ **续播必须先读存档、再调 `play()`**。`play()` 会走 `startCurrent()`，那里有一发「切歌即存档」，会把「当前条目 = 这一首、位置 = 0」写回去。先 play 再读，读到的永远是刚被覆盖的 0 —— 表现为**续播永远从头开始**，日志里是 `存档续播点：0s / 254s` 紧跟着 `上次没听到 1 秒，从头放`。实测抓过这个。
- ⚠️ 定位那一刻**不能用 `seek(toSeconds:)`**：它按 `progress` 算，而 `duration` 在条目加载完之前是 0（`MediaItem.durationSec` 也是可选），会直接 return。要直接落绝对秒数（`seekDirectly(toSeconds:)`）。
- 停在片尾（`elapsed >= duration - 1`）存档要记 0，否则下次一进去就是「已经放完」，直接跳下一首。
- 上次那首被删了就退回第一首——用户要的是「打开就有声」，不是「精确回到某首」。
- 顺序不能反：`.task` 里先 `adoptExternalMedia()` 再 `resumeLastPlayback(from: library.items)`，不然刚收进来的外部文件还不在 `items` 里，续播找不到。

## 打开 App 自动续播 / 切歌接位置

收听位置**按条目分开存**（`playback.positions` = `[条目id: 秒数]`），不是只存「最后那一首的位置」——只存一个的话，切走再切回来就从头了。另存 `playback.lastItemID` 用来回答「冷启动该放哪首」。

- 冷启动：`resumeLastPlayback(from:)`（只在 `RootView` 的 `.task` 里调）读出「上次那首」→ `play(items:startIndex:)`。**不自己 seek**，接位置统一由 `startCurrent` 里的 `restorePosition` 负责，两处都 seek 会互相打架，而且那一刻 `duration` 还没加载出来。切回前台不续播——否则「暂停着切走、回来被强行放起来」，正在放的那首也会被打断。
- 切歌也接位置：换到哪一首，就把它上次听到的地方接上（`restorePosition`），所以「听一半跳到别的歌、再切回来」不用重听。
- ⚠️ **放完自动跳下一首要传 `restoringPosition: false`**。手动切歌（按钮/遥控）传 `true`，自动续播传 `false` —— 一首刚放完，下一首该从开头起，把下一首拉到二十分钟处是惊吓不是贴心。时间观察者里的自动下一首是直接 `index += 1; startCurrent(restoringPosition: false)`，**不能**直接调 `next()`。
- ⚠️ **存档「正要离开的那首」必须在 `currentID` 被改写之前**（`startCurrent` 开头就 `savePosition()`）。位置是挂在 `currentID` 上的，换掉之后就再也取不到了。
- 存档点三个，缺一个就会丢：① `startCurrent()` 开头（切歌即存档）；② 播放器的 `.paused` 分支；③ 时间观察者里每 5 秒兜底一次（进程被直接杀掉，走不到 ①②）。进后台（`scenePhase == .background`）也要存一次，那是被系统回收前最后的回调。
- ⚠️ 定位那一刻**不能用 `seek(toSeconds:)`**：它按 `progress` 算，而 `duration` 在条目加载完之前是 0（`MediaItem.durationSec` 也是可选），会直接 return。要直接落绝对秒数（`seekDirectly(toSeconds:)`）。
- 停在片尾（`elapsed >= duration - 1`）存档要记 0：这样一首放完、用户按上一首回去，它是从头放的，而不是又跳到结尾；下次续播也不会一进去就「已经放完」。`restorePosition` 里还有第二道闸防旧数据。
- 接位置的门槛是 **1 秒**：比这更短说明上次基本没听，从头放更符合直觉。
- 上次那首被删了就退回第一首——用户要的是「打开就有声」，不是「精确回到某首」。
- 顺序不能反：`.task` 里先 `adoptExternalMedia()` 再 `resumeLastPlayback(from: library.items)`，不然刚收进来的外部文件还不在 `items` 里，续播找不到。
- 旧版本的单条存档键 `playback.lastElapsed` 在 `init()` 的 `migrateLegacySavePoint()` 里并进表、随即删掉，所以升级那一刻不会白丢一次位置。

## 文本解码（标题里的 \u002F）

- ⚠️ `JSONSerialization.jsonObject(with:)` **默认不接受顶层是字符串片段**，必须带 `options: [.fragmentsAllowed]`；少了它，解 JSON 字符串永远返回 `nil`，标题就一直显示成 `开车\u002F健身`（旧代码就是这个毛病，`?? raw` 兜底把未解码文本直接展示出来了）。
- 分享页的 desc 有时被转义**两层**：解一层后仍残留 `\u002F`，所以 `JSONEscapes.decode` 最多解三层、解不动就停（`Services/JSONEscapes.swift`）。
- 老索引里的标题要**就地迁移**（`MediaLibrary.migrateTitles()`），否则为了改一个标题得重下整条视频。

## 并发下载（一次粘多条）

- 一次可粘贴多条分享文本：`LinkScanner.allURLs(in:)` 抠出全部 `https://` 链接、去重、去掉结尾中文标点；两个抽取器都是 **actor**，凭证与 Cookie 池在多任务间天然串行，网络等待可交错，所以并行下载是真并行。
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

## 分段音频的段号（P1/4）

- `phonemusic` 用 `ffmpeg -f segment` 切分，段号**默认 0 起**：产物是 `<标题>.part00.mp3`、`part03.mp3`……（实测确认），而它写进 ID3 的 `track`/`title` 是 `P1/4`…（1 起）。**两者差一**：解析文件名拿到的是原始段号，展示成 `P` 号要 +1。落点 `ios/Douyin2MP3/Douyin2MP3/Models/Segments.swift`。
- 列表副标题的统一口径在 `MediaLibrary.subtitle(for:)`（列表 / 迷你播放条 / 全屏播放页三处共用，别再往 `MediaItem` 上挂第二份）。总段数按**库内同前缀条目**统计，所以 `P2/4` 的含义是「这个合集在库里一共 4 段」，不是「源文件一共切了几段」；库里只有一段时不标，免得全是噪音。
- 分段文件要出现在资料库里，得放进 App 沙盒的 `Documents/Video`（`adoptExternalFiles()` 启动时收录）：
  `xcrun devicectl device copy to --device <UDID> --domain-type appDataContainer --domain-identifier <bundleID> --user mobile --source <目录或文件> --destination Documents/Video`
  （`phonemusic` 的 `pull` 是只读的，没有反向推送子命令；`--source` 传目录是递归的。）
- `Segments.parse` 是纯 Foundation，可命令行单测：`swiftc -O Models/Segments.swift main.swift -o segtest`（注意它只依赖 Foundation，编译时把 `extension MediaItem/MediaLibrary` 那两段剪掉即可，`main.swift` 才能放顶层语句）。

## 验证归档

- 取流：真机取不到时，先在本机用 Swift 命令行版喂同一条链接复现，再判断是接口问题还是 App 问题。
- 并发：`swiftc -O Services/ConcurrencyGate.swift main.swift -o gatetest` 直接单测闸门（上限、FIFO、去重、取消、名额释放）+ 计时（3 并发跑 6 条约 2 轮，实测加速 2.95x）。
- 进度换算：`swiftc -O Services/DouyinExtractor.swift main.swift -o progresstest` 单测 `FetchProgress.fromBytes`（`expected=-1` → `fraction=nil` 且上报字节；`expected=0` 不产生 NaN；超额夹到 1.0）。
- 只有 `main.swift` 那个文件名能放顶层语句；其它文件名必须 `@main struct X { static func main() }`，否则报 `expressions are not allowed at the top level`。
- 真机诊断：`DEVICECTL_CHILD_D2M_DEBUG=1 xcrun devicectl device process launch --console --terminate-existing --device <UDID> <bundleID>`，App 里 `D2M_DEBUG=1` 时才打印 `[d2m]` 取流/下载细节（默认关闭）。
- ⚠️ **`DouyinDebug.log` 必须 `fflush(stdout)`**：`devicectl --console` 下 stdout 是块缓冲的管道，进程被 kill（`timeout`、`--terminate-existing`）时最后几行还在缓冲区里，日志会缺掉最关键的那几行 —— 看起来就像「这段代码根本没执行」，很容易顺着这个假象去查错地方。
- ⚠️ **截图里读小字别硬猜**：确认框这类半透明 `Material` 卡片，像素取样分不出「环的颜色」和「卡片本身透出的背景色」（实测卡片的青色调来自背景透色，不是控件颜色）。要判断行为就让代码自己把结论打进日志，别靠肉眼看 3 像素高的字。
- ⚠️ **续播/切歌这类「要点一下才能看到」的行为，用 `D2M_JUMP_DEMO=1` 验**（`MediaPlayer.runJumpDemoIfRequested()`，`RootView` 的 `.task` 里调）：自动「听 6 秒 → 切下一首 → 再 6 秒 → 切回上一首」，全走真实链路。**别直接把 `previous()` 写进演示** —— 它带「播放 3 秒内才真切歌」的规矩，6 秒后调它只会回到本首开头、什么都验不到，要直接 `index -= 1; startCurrent(restoringPosition: true)`。实测输出：`存档《1小时…》：933s` → `切歌续播：《1小时…》从 933s 接上`，正好接回离开的那一刻。
- 截真机屏幕（不用 WebDriverAgent）：`xcrun devicectl device capture screenshot --device <UDID> --destination /tmp/x.png`。
- 安装：`devicectl install` 成功后必须再 `process launch` 一次，才算「装完能跑」。
- ⚠️ 真机**远程点击不可靠**：WebDriverAgent 这类远程控制方案依赖设备已信任开发者证书，证书没信任时直接起不来，反复重试很费时（每次探测约 20 秒）。命令行能稳定做到的是**安装、启动、截图**；凡是要点一下才能看到的（点歌、看迷你条、收键盘）就请用户手点，然后自己截图核对。

## 注意

- 仅个人学习自用；视频版权归原作者，不要二次发布。
- 硬编码约束：UA、清晰度候选、超时、端口、ID 等可变项都在 `DouyinConfig` / 配置里，不要把某条链接或某次抓包的固定值写进实现。
