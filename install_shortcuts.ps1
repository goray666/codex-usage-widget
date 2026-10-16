param(
    [switch]$StartWithWindows
)

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$launcherPath = Join-Path $scriptDirectory 'start_widget.cmd'
$shell = New-Object -ComObject WScript.Shell

$desktopDirectory = [Environment]::GetFolderPath('Desktop')
$desktopShortcut = $shell.CreateShortcut((Join-Path $desktopDirectory 'Codex 额度.lnk'))
$desktopShortcut.TargetPath = $launcherPath
$desktopShortcut.WorkingDirectory = $scriptDirectory
$desktopShortcut.Description = '显示 Codex 剩余额度和下次重置时间'
$desktopShortcut.Save()

if ($StartWithWindows) {
    $startupDirectory = [Environment]::GetFolderPath('Startup')
    $startupShortcut = $shell.CreateShortcut((Join-Path $startupDirectory 'Codex 额度.lnk'))
    $startupShortcut.TargetPath = $launcherPath
    $startupShortcut.WorkingDirectory = $scriptDirectory
    $startupShortcut.Description = '登录 Windows 后显示 Codex 额度'
    $startupShortcut.Save()
}

Write-Host '桌面快捷方式已创建。'
if ($StartWithWindows) {
    Write-Host '已同时启用开机登录后自动启动。'
}
