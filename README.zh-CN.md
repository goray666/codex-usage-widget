# Codex 额度桌面悬浮窗

这是一个轻量的 Windows 桌面小窗，用于显示：

- 每个 Codex 额度周期的剩余百分比；
- 下一次额度重置的本地时间和倒计时；
- 当前套餐，以及账号返回的可用重置券数量；
- 每 60 秒自动刷新，也可点右上角 `↻` 手动刷新。

## 运行

双击 `start_widget.cmd`。本机需要：

1. Windows 10/11（使用系统自带的 PowerShell 和 WPF，不需要 Python）；
2. 已安装 Codex 桌面应用，并已登录 ChatGPT 账号。

小窗默认总在最前。拖动窗口空白处可移动；右键可刷新、切换“总在最前”或退出。

## 创建桌面快捷方式

在此文件夹打开 PowerShell，运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\install_shortcuts.ps1
```

如需随 Windows 登录自动启动：

```powershell
powershell -ExecutionPolicy Bypass -File .\install_shortcuts.ps1 -StartWithWindows
```

## 数据与隐私

程序通过官方 Codex app-server 的 `account/rateLimits/read` 方法读取当前已登录账号的额度。它不会要求、保存或输出 API Key、ChatGPT Cookie 或登录令牌。窗口位置会保存到 `%LOCALAPPDATA%\CodexUsageWidget\settings.json`。

如果显示“无法读取 Codex 额度”，请先确认 Codex 桌面应用已经登录，再点 `↻` 重试。
