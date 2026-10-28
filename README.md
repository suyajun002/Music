<p align="center">
  <img src="design/appicon-1024.png" width="128" alt="App icon">
</p>

<h1 align="center">Music</h1>

<p align="center">
  把抖音分享链接变成 iPhone 上能离线听的本地视频。<br>
  <b>解析、下载、入库、播放全部在手机上完成</b> —— 不需要服务器，不需要 Mac 常驻，App 内不调用任何模型。
</p>

<p align="center">
  <img alt="license" src="https://img.shields.io/badge/license-MIT-blue">
  <img alt="platform" src="https://img.shields.io/badge/platform-iOS%2018%2B-lightgrey">
  <img alt="dependencies" src="https://img.shields.io/badge/dependencies-0-brightgreen">
</p>

---

## 为什么是它

抖音下载工具已经有很多，但它们几乎都是 Python / Go / Node 写的命令行或自托管服务，需要一个常年开着的机器（VPS、NAS、Mac）来跑。这个项目走另一条路：**一个 iPhone 原生 App，自己把活干完**。

- **原生 App**：SwiftUI + 系统框架，零第三方依赖，装完就没有别的依赖
- **无服务器**：不用一台常开的机器，也不受内网 / 公网可达性限制
- **锁屏不停**：下载走后台 `URLSession`，熄屏、锁屏、切后台都继续；播放走 `AVAudioSession.playback` + Now Playing
- **不重编码**：直接保存原始 MP4，用 `AVPlayer` 播它的音轨 —— 没有转码损失，也不用等转码
- **确定性代码**：没有任何模型调用，接口变了只改一个 `DouyinExtractor.swift`

> App 名叫 `Music`，但它**不做 MP3 转码**。iOS 能直接播 MP4 的音轨，转码只会多花时间、损失音质。所以 App 存原始文件、按音频来听。

## 功能

- **粘贴即识别**：贴进分享文本就自动开始，不用点按钮；一次可粘多条，自动去重
- **并行下载**：并发数 1 / 2 / 3 / 4 / 6 可调，默认 3，改完立刻重排
- **不重复下载**：下过的作品不再下第二次
- **后台下载**：锁屏、熄屏、切后台都继续，进度可见；被掐断的半截文件自动清理
- **资料库**：封面（视频首帧）、标题、时长，可搜索、可排序、可滑动删除
- **播放**：页签上方的迷你播放条 + 全屏「正在播放」；播完自动下一首；锁屏与后台继续出声；音量条带 AirPlay 路由
- **转视频页**：每条任务的状态、进度、失败原因

## 安装

需要 macOS + Xcode + 一台 iPhone（iOS 18+）。

```bash
git clone https://github.com/suyajun002/Music.git
cd Music
open ios/Music/Music.xcodeproj
```

1. **Signing & Capabilities** 里选上你自己的 Apple ID 团队 —— 工程里**没有**签名团队，不选会签名失败
2. 把 bundle id 从占位值 `com.example.music` 改成你自己的，例如 `com.yourname.music`
3. 选中你的 iPhone，Run
4. 首次运行要在手机上信任证书：**设置 → 通用 → VPN 与设备管理 → 开发者 App → 信任**

免费 Apple ID 的签名 **7 天**过期，到期 App 打不开，重新 Run 一次即可；付费开发者账号是 1 年。

不打开 Xcode GUI 也能装：

```bash
xcodebuild -project ios/Music/Music.xcodeproj -scheme Music \
  -destination 'generic/platform=iOS' -configuration Debug \
  -allowProvisioningUpdates -derivedDataPath build build

xcrun devicectl list devices                       # 查 UDID
xcrun devicectl device install app --device <UDID> build/Build/Products/Debug-iphoneos/Music.app
xcrun devicectl device process launch --device <UDID> com.yourname.music
```

`devicectl` 安装和启动都要求手机**已解锁且亮屏**，否则报 `device was not, or could not be, unlocked`。

不想把自己的团队 ID 和 bundle id 写进工程（避免提交个人配置），可以构建时从命令行传入，工程文件保持干净：

```bash
xcodebuild -project ios/Music/Music.xcodeproj -scheme Music \
  -destination 'generic/platform=iOS' -configuration Debug \
  -allowProvisioningUpdates -derivedDataPath build \
  DEVELOPMENT_TEAM=<你的团队ID> \
  PRODUCT_BUNDLE_IDENTIFIER=com.yourname.music \
  build
```

只做编译校验（不签名、不装真机）时加 `CODE_SIGNING_ALLOWED=NO` 就能在没有团队的情况下编过。

## 取流原理

全部是确定性 HTTP 请求，没有签名链、没有模型。踩过的坑见下面的表格和清单。

| 步骤 | 请求 | 关键点 |
|---|---|---|
| 1 抠链接 | 分享文本里第一个 `https://`，去掉结尾中文标点 | 短链 `v.douyin.com` 读 302 Location；ID 取 `modal_id` 或路径最后一段 |
| 2 基础 Cookie | `GET https://www.douyin.com/`（桌面 UA + Referer） | 失败不致命，继续 |
| 3 ttwid | `POST https://ttwid.bytedance.com/ttwid/union/register/` | 没有 ttwid 时 share 页会退化成壳页 |
| 4 share 页 | `GET https://www.iesdouyin.com/share/video/<id>/`（iPhone UA + Cookie） | HTML 必须含 `"aweme_type"` 否则换 `/share/note/<id>/`；解析 `play_addr.uri`、`images`、`desc` |
| 5 换直链 | `GET https://aweme.snssdk.com/aweme/v1/play/?video_id=<uri>&ratio=<X>&line=<N>` | 免签名；**必须阻止自动跟随跳转**才能读到 302 的 Location |
| 6 下载 | CDN 直链，带 `Referer: https://www.douyin.com/` | 缺 Referer 直接 403；校验前 64 字节含 `ftyp`；清晰度 1080p → 720p → 540p 回退 |

几个值得单独说的坑：

- **CDN 走 chunked、不给 `Content-Length`**：进度回调里 `expected` 会是 `-1`。如果写 `guard expected > 0 else { return }`，进度条会永远钉在进入下载时的百分比（看起来就是「一直卡在 25%，其实早下完了」）。要回退成「已下载 X MB + 不确定进度条」。
- **进度回调必须用会话级 delegate**：`session.download(for:delegate:)` 的任务级 delegate 收不到 `didWriteData`，界面会一直不动。
- **图文作品的背景音乐也有 `play_addr`**：判定顺序必须先看 `images` 再回退视频，否则会当成视频去下、三个清晰度全失败。
- **手机侧偶发 `-1005 network connection was lost`**：同一条地址在 Mac 上正常、手机上三个清晰度全挂，是手机到 CDN 边缘节点的问题。换 `line` 参数换节点比反复重试同一个地址有用。
- **半截下载会堆满沙盒**：每次被掐断的任务都会在 `tmp/CFNetworkDownload_*.tmp` 留一个文件，实测能堆到 1GB+，而 App 本体只有 2.4MB。启动时清、失败时删。

## 已知限制

- 抖音改接口后要改代码重新编译安装，接口形态集中在 `Services/DouyinExtractor.swift`
- 图文作品（没有视频）会明确报错，不下载图片
- 极端超长的下载仍可能被系统回收，不是 100% 保证后台跑完
- 只有 iOS，没有 Android / 桌面端

## 项目结构

```
ios/Music/                   iPhone App（SwiftUI，零依赖）
  Music/Services/
    DouyinExtractor.swift      取流：抠链接、ttwid、share 页解析、换直链
    MediaDownloader.swift      后台下载 + 进度 + 半截文件清理
    ConcurrencyGate.swift      并发闸门（纯 Foundation，可命令行单测）
    MediaLibrary.swift         资料库索引 + 标题迁移
    MediaPlayer.swift          播放、后台音频、Now Playing
    JSONEscapes.swift          标题转义解码
  Music/Views/                 资料库 / 转视频 / 全屏播放 / 迷你播放条
design/                      图标源文件（SVG）与 1024 PNG
legacy/mac-agent/            早期方案：Mac 上常驻 agent + ffmpeg 出 MP3（已废弃，留作参考）
```

## 配套 skill

早期版本在仓库里带过一份给 AI 编码助手（Claude Code / Codex）用的 skill 文件，记了取流链路、全部踩坑、命令行构建安装真机的完整流程和 UI 结构约定。**现在它只在作者本机维护，仓库里不再保留**（同一份内容维护两个副本必然对不上）。想照着改这个 App，看本文件的「取流原理」和「项目结构」两节，加上代码里的注释就够起步。

## 免责声明

本项目仅供个人学习与离线收听使用，视频版权归原作者所有。请勿用于商业用途、二次分发或任何侵犯版权的场景。使用者需自行承担使用本项目产生的一切后果。

## License

[MIT](LICENSE)

---

## English

**Music** turns a Douyin (Chinese TikTok) share link into locally playable media on iPhone — entirely on-device.

Most Douyin downloaders are CLI tools or self-hosted servers that need an always-on machine. This one is a native SwiftUI app with zero third-party dependencies: it extracts the link, handles the `ttwid` anti-bot cookie, parses the share page, resolves the watermark-free CDN URL, downloads the MP4 through a background `URLSession` (survives lock screen), and plays it with `AVPlayer` — including background audio and Now Playing controls. No server, no cloud, no LLM calls.

It does not transcode: the original MP4 is stored and its audio track is played directly.

Personal / educational use only. All videos belong to their original creators.
