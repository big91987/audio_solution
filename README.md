# audio_solution

本仓库记录「远程桌面场景下用本机麦克风做语音输入」的方案探索，当前可用产物是 **VoiceBridge**。

---

## VoiceBridge 是什么

一台 Mac（说话端）按住触发键说话，语音在本机被豆包输入法识别成文字，文字经剪贴板 + UU 远程自带的剪贴板同步送到另一台 Mac（被控端），并在被控端光标处自动粘贴。

```
[本机 MacBook Air]                          [远端 MacBook Pro]
按住空格
   ↓
合成 Control → 唤起豆包语音输入
   ↓
豆包识别 → 文字落入浮窗
   ↓
写入本机剪贴板
   ↓  ← UU 远程「同步剪贴板」自动传输 →
                                        Cmd+V 粘贴到光标处
```

画面仍然走 UU 远程，VoiceBridge 只补上「说话」这一环。

## 环境要求

| 项 | 要求 |
|---|---|
| 操作系统 | macOS 14+（实测 14.7.6 arm64，Apple Silicon） |
| 输入法 | 豆包输入法 `/Library/Input Methods/DoubaoIme.app`，**语音触发键设为 Control** |
| 远程工具 | UU 远程 `com.netease.uuremote`（实测 4.43.0） |
| UU 设置 | 远控界面 `操作 → 安全 → 同步剪贴板` 必须打开 |
| 权限 | 系统设置 → 隐私与安全性 → 已授权 **辅助功能** 与 **输入监控** |

两台机器登录同一 UU 账号，本机连远端即可。剪贴板同步不需要额外开发。

## 编译

```bash
cd voicebridge
./build.sh
```

一条命令产出两样东西：

| 产物 | 路径 |
|---|---|
| 可运行的 App | `voicebridge/VoiceBridge.app` |
| **安装包** | `output/VoiceBridge-1.0.dmg` |

DMG 里是 `VoiceBridge.app` + 指向 `/Applications` 的快捷方式，拖进去即可安装。`output/` 已加入 `.gitignore`，是本地构建产物，不进仓库。

编译失败时 `build.sh` 有 `set -e`，但**务必确认输出里有「构建完成」和「DMG 已输出」**——历史上出现过编译失败却继续用旧二进制测试的情况。

## 安装

1. 双击 `output/VoiceBridge-1.0.dmg`，把 VoiceBridge 拖进 `Applications`
2. 首次启动会被 Gatekeeper 拦（本地 ad-hoc 签名、未公证），**右键 → 打开**，或执行：
   ```bash
   xattr -d com.apple.quarantine /Applications/VoiceBridge.app
   ```
3. 启动后授权「辅助功能」和「输入监控」，菜单栏出现 🎙 图标

**配置文件不在项目目录里**，存放在用户主目录：

```
~/.voicebridge/config.yaml
```

## 运行

```bash
cd voicebridge
: > /tmp/vb.log
(nohup ./VoiceBridge.app/Contents/MacOS/VoiceBridge >> /tmp/vb.log 2>&1 &)
```

启动后 `cat /tmp/vb.log` 应看到：

```
辅助功能权限: 已授权
输入监控权限: 已授权
事件监听已安装
VoiceBridge 已启动 · 按住空格键说话，松开自动粘贴到远端
```

**确保同时只有一个实例**，否则互相干扰：

```bash
ps -eo pid,comm | grep -i voicebridge
# 有多个就逐个 kill -9（pkill -f 曾杀不干净）
```

## 使用

1. 按住**空格键**（超过 0.35 秒才开录，短按仍是正常空格）
2. 说一句话
3. 松开

松开后约 0.9 秒，文字自动粘到当前光标处。屏幕底部会有一个小浮窗显示识别内容。

全屏 UU 状态下也能触发，浮窗设置了 `canJoinAllSpaces + fullScreenAuxiliary`。

菜单栏会有一个 **🎙** 图标，点开的菜单里可以直接改快捷键。

## 配置

两种方式，共用同一份配置：

**方式一：菜单栏点选**（立即生效并写回文件）

- **触发键**：空格 / Tab / 回车 / Esc / 分号 / 逗号 / 句号 / 反引号 / F13 / 右侧 Command / 左侧 Shift
- **唤起豆包的键**：左 Control / 右 Control / 左 Option / 右 Option / F13 / F5~F9
- **按住时长**：200 / 300 / 350 / 500 / 800 ms

**方式二：手改 `~/.voicebridge/config.yaml`**（保存后 1 秒内自动重载，不用重启）

```yaml
triggerKeyCode: 49      # 触发键，49 = 空格
doubaoKeyCode: 59       # 唤起豆包的键，59 = 左侧 Control
armDelay: 0.35          # 按住多久才开录（秒）
clipboardWait: 0.85     # 写剪贴板到按 Cmd+V 的等待（秒，给 UU 同步留时间）
```

常用键码：

| 键 | 键码 | 键 | 键码 |
|---|---|---|---|
| 空格 | 49 | 左 Control | 59 |
| Tab | 48 | 右 Control | 62 |
| 回车 | 36 | 左 Option | 58 |
| Esc | 53 | 右 Option | 61 |
| 分号 | 41 | 右 Command | 54 |
| 逗号 | 43 | 左 Command | 55 |
| 句号 | 47 | 左 Shift | 56 |
| 反引号 | 50 | F13 | 105 |

两个必须注意的点：

- **「唤起豆包的键」必须和豆包输入法里设置的语音键一致**，否则唤不起来。
- **触发键别选修饰键**（如右 Command）。按住 ⌘ 时系统物理修饰状态常驻，合成的事件会被污染，这是实测踩过的坑。

## 工作原理与关键实现

| 步骤 | 实现 | 备注 |
|---|---|---|
| 捕获热键 | `CGEvent.tapCreate(.cgSessionEventTap, .headInsertEventTap, .defaultTap)`，mask 含 flagsChanged / keyDown / keyUp | |
| 开录前 | **彻底销毁事件监听**：`tapEnable(false)` + `CFRunLoopRemoveSource` + `CFMachPortInvalidate` | 这是全项目最关键的一处，见下 |
| 唤起豆包 | 合成左 Control（keyCode 59）`flagsChanged` 事件，`flags` 只保留 `.maskControl` | 合成 Option 无效 |
| 判定松手 | 每 0.05s 轮询 `CGEventSource.keyState(.combinedSessionState, key: 49)` | |
| 结束录音 | 合成 Control up | |
| 取文字 | 每 0.25s 轮询浮窗 `textView.string`，连续 4 次不变且非空即收尾，最多等 7 秒 | |
| 送远端 | 写 `NSPasteboard.general` → 激活 UU → 等 0.85s → 合成 Cmd+V | 等待时间用于 UU 剪贴板跨网同步 |

### 最关键的坑：事件监听必须销毁，不能只是禁用

只要自己的 `CGEventTap` 还挂在系统里（`defaultTap` 或 `listenOnly` 都算，`tapEnable(false)` 也不够），合成的 Control 事件就到不了豆包输入法，录音条不会出现。

必须 `CFMachPortInvalidate` 彻底销毁，合成 Ctrl 才能生效。

## 已知限制

- **热键必须是非修饰键**。右侧 Command 不可用：手指按着 ⌘ 时系统物理修饰状态一直带 Command，合成 Ctrl 变成 ⌘+⌃，豆包不认；伪造「⌘ 松开」又会让按键轮询误判松手。
- **分号键在 UU 场景下捕获不稳定**（实测全屏时日志完全收不到按键），空格稳定。
- **全屏 UU 连续使用时第二、三次起可能粘不过去**。唤醒与识别都正常（剪贴板已写入），失败点在「激活 UU → Cmd+V」的时序或 UU 剪贴板同步延迟。属于当前版本的已知缺陷。
- 松手到粘贴约有 0.85 秒以上延迟，取决于跨网 RTT（实测 400ms~1.1s，走 Tailscale DERP）。
- 按住触发键期间键盘的自动重复可能漏一个空格到远端。
- 每次重新编译 ad-hoc 签名哈希会变，TCC 权限（辅助功能 / 输入监控）可能需要重新授权。
- 未做开机自启、未做签名公证。

## 排错顺序

1. 看日志：`tail -30 /tmp/vb.log`
2. 判定成功必须**同时**出现 `[诊断] 豆包录音条: 已出现` 和 `[文本] <非空>`；只有 `[合成] Ctrl down` 不代表成功
3. 唤醒失败（日志连 `[tap] 已销毁` 都没有）→ 检查是否有多个实例、权限是否丢失
4. 文字有但远端没粘上 → 检查 UU `同步剪贴板` 开关、网络延迟
5. 改代码后忘记重启 → 旧进程仍在跑，测的是旧二进制

## 为什么没采用其他方案

| 方案 | 否决原因 |
|---|---|
| UU 被控端直接上行麦克风 | UU Mac 被控端不支持，官方仅「远控 Windows 时」支持控制端麦克风 |
| Blurt（`crates/blurt-remote`） | 只覆盖手机→电脑，无 Mac 客户端；需远端装 Blurt + 2.5GB 本地模型，太重 |
| Jump Desktop Fluid + Send Audio | 要配两套软件，太重 |
| Mac 上装 UU 移动版 | App Store 兼容性不含 Mac |
| Tailscale Exit Node 转发 | 合规与出口 IP 问题，明确否决 |

Blurt 源码未纳入本仓库（体积过大），来源：`https://github.com/AGIHunt/blurt`

## 仓库结构

```
audio_solution/
├── README.md
├── .gitignore
└── voicebridge/
    ├── main.swift      # 主程序
    ├── Info.plist      # CFBundleIdentifier com.cuijin.voicebridge
    └── build.sh        # 编译脚本
```

运行时配置单独存在 `~/.voicebridge/config.yaml`，不进仓库。
