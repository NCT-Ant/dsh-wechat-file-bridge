# dsh-wechat-file-bridge

把 DeepSeek Harness 接到微信电脑版的「文件传输助手」，让电脑和手机之间能互传文件、互发消息。

装完就一个工具：`wechat_bridge`。

> 手机 → 电脑：**锁屏也能用**，完全不动界面。
> 电脑 → 手机：需要微信窗口能到前台（即会话已解锁），否则会被明确拒绝，**不会静默失败、不会发到别的会话**。

## 运行前提

| 项目 | 要求 |
|---|---|
| 系统 | Windows 10 / 11（只支持 Windows，插件用 `win32` 限定了平台） |
| 微信 | 微信电脑版 4.x（开发与验证基于 4.2.0.53），并已登录 |
| 会话 | 需要「文件传输助手」出现在会话列表里（手机上给它发过任意一条消息即可） |
| 权限 | 发送时会把微信窗口临时切到前台，需要当前桌面是**未锁定**的交互式会话 |
| 运行时 | DeepSeek Harness；系统自带 Windows PowerShell 5.1（无需安装 PowerShell 7、Node、Python） |
| 可选 | 装了 [`dsh-pc-guard`](https://github.com/NCT-Ant/dsh-pc-guard) 时，发送期间会写「发送租约」，管家不会在你发送时熄屏或锁屏 |

## 为什么是这么个设计

微信 4.x 是 Qt 自绘界面，实测结论：

| 试图做的事 | 结果 |
|---|---|
| UI Automation 读控件树 | ❌ 只有 2 个 Pane，没有任何可定位控件 |
| `PostMessage` 投递按键 | ❌ 完全无效，窗口无反应 |
| `PrintWindow` 后台截图 | ✅ 能完整抓到界面，锁屏/被遮挡都行 |
| 真前台 + 注入输入 | ✅ 唯一能发消息的方式，但**必须已解锁** |
| 读收到的文件 | ✅ 微信自己会把文件落到磁盘，根本不需要碰界面 |

所以插件走两条完全不同的通道：

- **收（手机 → 电脑）**：只看磁盘。微信 4.x 会把收到的文件自动下载到
  `%USERPROFILE%\Documents\xwechat_files\<wxid>\msg\file\<YYYY-MM>\`，
  文件名保留原样。这条通道**锁屏时照样工作**。
- **发（电脑 → 手机）**：只能把微信窗口拉到前台、点搜索框、粘贴会话名、粘贴正文、回车。
  锁屏时直接拒绝并给出明确错误。

## 安装

从 Releases 下载 `dsh-wechat-file-bridge-1.0.0.zip`，解压后让 DSH 以 bundle 方式安装：

```powershell
# 方式一：让 DSH 自己装（推荐）
#   在 DeepSeek Harness 里用 plugin_manager：
#   install_bundle  target = <解压后的目录绝对路径>
#   set_plugin      target = "include:dsh-wechat-file-bridge"  enabled = true

# 方式二：手工链接进 profile
$nm = "$env:USERPROFILE\.dsh\profiles\desktop\node_modules"
New-Item -ItemType Junction -Path "$nm\dsh-wechat-file-bridge" -Target "<解压目录>" -Force
# 然后在 profile 的 package.json 里：
#   dependencies 里加 "dsh-wechat-file-bridge": "link:<解压目录>"
#   dsh.profile.bundles 里追加 "dsh-wechat-file-bridge"
```

装完**重启 DeepSeek Harness**，工具列表里会出现 `wechat_bridge`。

## 用法

| action | 参数 | 作用 | 锁屏可用 |
|---|---|---|---|
| `status` | — | 微信是否在跑、账号目录、收件目录、是否锁屏、能否发送 | ✅ |
| `list` | `limit` `sinceDays` | 列出最新收到的文件（路径 / 大小 / 收到时间） | ✅ |
| `snapshot` | — | 截取微信窗口存成 PNG | ✅ |
| `send_text` | `text` `chat` | 发一条文本消息 | ❌ |
| `send_file` | `path` `chat` | 发一个文件 | ❌ |
| `outbox` | — | 查看锁屏时排队的待发项 | ✅ |

`chat` 默认 `文件传输助手`。

## 安全设计

发送流程里有几道硬闸，任何一道不过就**中止**，绝不"尽力而为"：

1. **编码闸**：Windows PowerShell 5.1 在管道 stdin 下按 ANSI 解码，直接把中文喂进去会变成乱码 → 搜不到会话 → 文件落进当前打开的群。所以 Node 侧把非 ASCII 全部转成 `\uXXXX` 转义再写 stdin。
2. **前台闸**（`Assert-Foreground`）：`GetForegroundWindow()` 必须正好是微信主窗，否则抛错。防止"切前台失败但继续敲键盘"，把输入打进别的窗口。
3. **切换闸**：`Assert-Focus` 切换失败即抛错；`Open-Chat` 打开会话后必须确认界面真的变了，否则拒绝发送。
4. **剪贴板回读闸**：粘贴会话名前，剪贴板内容必须逐字等于目标会话名。
5. **锁屏闸**：锁屏时不点亮屏幕、直接返回 `locked`，由上层放进待发队列。
6. **发送租约**：发送期间写 `%TEMP%\dsh-wechat-send.lease`（默认 240 秒），`dsh-pc-guard` 见到租约就不熄屏、不锁屏。

## 已知限制

- **锁屏不能发**：锁屏后输入全被 Winlogon 安全桌面吸走，注入无效。只能排队等解锁后补发。
- **发送依赖窗口坐标**：发送前会把微信窗口临时设成 1000x800 再操作，结束后恢复。微信改布局需要重新校准 `Open-Chat` 与 `Send-TextBody` 里的相对坐标。
- **发送期间不要抢鼠标键盘**：脚本会检查前台窗口，被抢焦点就中止（安全，但这次发送会失败并留队列）。
- **收件目录是一锅端**：`msg\file` 里是所有聊天收到的文件，不区分来源，只能靠文件名和时间判断。
- **微信设成「回车换行」时会失败**：发送靠回车提交，若客户端设成 Ctrl+Enter 发送，需要改 `Send-TextBody` 的按键。
- **同一时间只允许一个微信实例**：脚本按进程名找主窗，多开会取到错误窗口。

## 文件

- `index.js` — 插件本体，注册 `wechat_bridge` 工具、管待发队列
- `assets/WechatBridge.ps1` — Windows 侧驱动，stdin 收 JSON、stdout 回 JSON
- `cordis.patch.yml` — bundle 补丁

## License

MIT © 2026 Benzalkonium chloride
