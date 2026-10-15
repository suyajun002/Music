# douyin2mp3

把抖音分享链接变成手机上能听的本地视频。**主路径是纯手机版**：iPhone App 自己完成解析、下载、保存、播放，不依赖 Mac、不依赖服务器、不重编码音频。仓库里的 Mac agent 是可选组件，手机版不需要它。

## iPhone App（主路径）

位置：`ios/Douyin2MP3`，SwiftUI，零第三方依赖。

流程（全程确定性代码，不调用任何模型）：

1. 从分享文本里抠出链接，短链 `v.douyin.com` 读 302 拿到作品 ID
2. 注册 `ttwid` 反爬凭证（GET 抖音首页 + POST ttwid 注册接口）
3. 请求 `iesdouyin.com/share/video/<id>/`（iPhone UA + Cookie），解析 `play_addr.uri` 与标题
4. 用 `aweme/v1/play/?video_id=...` 换 CDN 直链，按 1080p → 720p → 540p 回退
5. 带 Referer 下载无水印 MP4，校验 `ftyp` 签名后存进沙盒

播放：`AVPlayer` + `playback` 音频会话 + Now Playing，锁屏和后台继续播放；进入后台时主动摘掉视频图层，避免系统挂起视频渲染导致声音中断。

### 安装到 iPhone

用 Xcode 打开 `ios/Douyin2MP3/Douyin2MP3.xcodeproj`，选自己的 Apple ID 作为签名团队，连上手机后 Run。免费 Apple ID 的签名 7 天有效，付费开发者账号 1 年。

### 已知边界

- 抖音改接口后需要重新编译安装一次；接口形态变了要同步改 `Services/DouyinExtractor.swift`
- 图文作品（无视频）会明确报错，不下载图片
- iOS 不允许后台长时间下载，下载要在前台完成
- 仅个人自用；视频版权归原作者，不要二次发布

## Mac agent（可选）

位置：`agent/`，Node 零依赖（需 Node ≥ 18.17），复用 `~/.agents/skills/douyin-skill` 的下载脚本取流，再用 ffmpeg 出 MP3。

```bash
agent/bin/d2m start     # 启动（launchd 常驻，登录自启）
agent/bin/d2m status    # 状态 + 配对地址 + 当前任务
agent/bin/d2m logs      # 跟随日志
```

局域网 HTTP 接口（Bearer 令牌鉴权，令牌存 `~/.douyin2mp3/token`，0600）：

- `GET  /health` 探活（免令牌）
- `POST /v1/jobs` 提交 `{ "url": "..." }`
- `GET  /v1/jobs` / `GET /v1/jobs/{id}` 查任务
- `GET  /v1/jobs/{id}/audio` 取 MP3（支持 Range）
- `DELETE /v1/jobs/{id}`

手机 Safari 打开 `http://<Mac 局域网 IP>:8787/` 可自检连通性并试听。
