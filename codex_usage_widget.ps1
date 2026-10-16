param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
$script:RefreshSeconds = 60
$script:RequestTimeoutSeconds = 20
$script:CurrentJob = $null
$script:JobStartedAt = $null
$script:Cards = New-Object System.Collections.ArrayList
$script:Closed = $false

function Get-WindowLabel {
    param([Nullable[int]]$Minutes, [string]$Slot)
    if ($Minutes -eq 300) { return '5 小时额度' }
    if ($Minutes -eq 10080) { return '每周额度' }
    if ($Minutes -and ($Minutes % 10080 -eq 0)) { return "$(($Minutes / 10080)) 周额度" }
    if ($Minutes -and ($Minutes % 1440 -eq 0)) { return "$(($Minutes / 1440)) 天额度" }
    if ($Minutes -and ($Minutes % 60 -eq 0)) { return "$(($Minutes / 60)) 小时额度" }
    if ($Minutes) { return "$Minutes 分钟额度" }
    if ($Slot -eq 'primary') { return '主要额度' }
    return '次要额度'
}

function Convert-RateLimitResult {
    param($Payload)

    $bucketItems = @()
    if ($Payload.rateLimitsByLimitId) {
        foreach ($property in $Payload.rateLimitsByLimitId.PSObject.Properties) {
            $bucketItems += [pscustomobject]@{ Id = $property.Name; Data = $property.Value }
        }
    }
    elseif ($Payload.rateLimits) {
        $bucketItems += [pscustomobject]@{ Id = 'codex'; Data = $Payload.rateLimits }
    }

    $bucketItems = $bucketItems | Sort-Object @{ Expression = { if ($_.Id -eq 'codex') { 0 } else { 1 } } }, Id
    $windows = @()
    $plan = $null
    foreach ($bucket in $bucketItems) {
        $data = $bucket.Data
        if (-not $plan -and $data.planType) { $plan = [string]$data.planType }
        $bucketName = if ($data.limitName) { [string]$data.limitName } else { [string]$bucket.Id }
        foreach ($slot in @('primary', 'secondary')) {
            $window = $data.$slot
            if ($null -eq $window -or $null -eq $window.usedPercent) { continue }
            $used = [Math]::Min(100.0, [Math]::Max(0.0, [double]$window.usedPercent))
            $duration = if ($null -ne $window.windowDurationMins) { [int]$window.windowDurationMins } else { $null }
            $reset = if ($null -ne $window.resetsAt) { [long]$window.resetsAt } else { $null }
            $label = Get-WindowLabel -Minutes $duration -Slot $slot
            if ($bucket.Id -ne 'codex') { $label = "$bucketName · $label" }
            $windows += [pscustomobject]@{
                Label = $label
                Remaining = 100.0 - $used
                Used = $used
                ResetsAt = $reset
            }
        }
    }

    $resetCredits = $null
    if ($Payload.rateLimitResetCredits -and $null -ne $Payload.rateLimitResetCredits.availableCount) {
        $resetCredits = [int]$Payload.rateLimitResetCredits.availableCount
    }
    [pscustomobject]@{ Windows = @($windows); Plan = $plan; ResetCredits = $resetCredits }
}

function Get-ResetText {
    param([Nullable[long]]$Timestamp)
    if (-not $Timestamp) { return [pscustomobject]@{ Absolute = '重置时间未知'; Countdown = '' } }
    $resetTime = [DateTimeOffset]::FromUnixTimeSeconds($Timestamp).LocalDateTime
    $remaining = $resetTime - [DateTime]::Now
    if ($remaining.TotalSeconds -le 0) { $countdown = '即将刷新' }
    elseif ($remaining.Days -gt 0) { $countdown = "$($remaining.Days)天 $($remaining.Hours)小时后" }
    elseif ($remaining.Hours -gt 0) { $countdown = "$($remaining.Hours)小时 $($remaining.Minutes)分后" }
    else { $countdown = "$([Math]::Max(1, $remaining.Minutes))分钟后" }
    [pscustomobject]@{ Absolute = $resetTime.ToString('MM-dd HH:mm') + ' 重置'; Countdown = $countdown }
}

function Find-CodexExecutable {
    $command = Get-Command codex.exe -ErrorAction SilentlyContinue
    if (-not $command) { $command = Get-Command codex -ErrorAction SilentlyContinue }
    if ($command) { return $command.Source }

    $binRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    $candidate = Get-ChildItem -LiteralPath $binRoot -Filter codex.exe -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($candidate) { return $candidate.FullName }
    throw '未找到 codex.exe。请先安装并登录 Codex 桌面应用。'
}

if ($SelfTest) {
    $sample = [pscustomobject]@{
        rateLimitsByLimitId = [pscustomobject]@{
            codex = [pscustomobject]@{
                planType = 'plus'
                primary = [pscustomobject]@{ usedPercent = 58; windowDurationMins = 300; resetsAt = 2000000000 }
                secondary = [pscustomobject]@{ usedPercent = 47.5; windowDurationMins = 10080; resetsAt = 2000100000 }
            }
        }
        rateLimitResetCredits = [pscustomobject]@{ availableCount = 3 }
    }
    $parsed = Convert-RateLimitResult $sample
    if ($parsed.Windows.Count -ne 2) { throw '自检失败：额度窗口数量错误。' }
    if ($parsed.Windows[0].Label -ne '5 小时额度' -or $parsed.Windows[0].Remaining -ne 42) { throw '自检失败：短周期解析错误。' }
    if ($parsed.Windows[1].Label -ne '每周额度' -or $parsed.Windows[1].Remaining -ne 52.5) { throw '自检失败：长周期解析错误。' }
    if ($parsed.Plan -ne 'plus' -or $parsed.ResetCredits -ne 3) { throw '自检失败：账号信息解析错误。' }
    Write-Output 'Self-test passed.'
    exit 0
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="390" Height="220" WindowStyle="None" ResizeMode="NoResize"
        AllowsTransparency="True" Background="Transparent" Topmost="True"
        ShowInTaskbar="True" Title="Codex 额度">
  <Border Background="#0F1115" BorderBrush="#2B313B" BorderThickness="1" CornerRadius="12">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="56"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="38"/>
      </Grid.RowDefinitions>
      <Grid x:Name="Header" Grid.Row="0" Margin="14,8,8,0" Background="Transparent">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock Text="Codex 额度" Foreground="#F3F4F6" FontFamily="Segoe UI" FontWeight="SemiBold" FontSize="17"/>
          <TextBlock x:Name="PlanText" Margin="9,4,0,0" Foreground="#9CA3AF" FontFamily="Segoe UI" FontSize="11"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <Button x:Name="RefreshButton" Content="↻" Width="32" Height="32" FontSize="17" Background="Transparent" Foreground="#9CA3AF" BorderThickness="0" Cursor="Hand"/>
          <Button x:Name="MinimizeButton" Content="—" Width="32" Height="32" FontSize="12" Background="Transparent" Foreground="#9CA3AF" BorderThickness="0" Cursor="Hand"/>
          <Button x:Name="CloseButton" Content="×" Width="32" Height="32" FontSize="18" Background="Transparent" Foreground="#9CA3AF" BorderThickness="0" Cursor="Hand"/>
        </StackPanel>
      </Grid>
      <StackPanel x:Name="CardsPanel" Grid.Row="1" Margin="12,0,12,0">
        <Border x:Name="EmptyCard" Background="#181B21" BorderBrush="#2B313B" BorderThickness="1" CornerRadius="9" Padding="20,26">
          <TextBlock x:Name="EmptyText" Text="正在读取额度…" Foreground="#9CA3AF" FontFamily="Segoe UI" FontSize="13" TextAlignment="Center" TextWrapping="Wrap"/>
        </Border>
      </StackPanel>
      <Grid Grid.Row="2" Margin="14,5,14,10">
        <TextBlock x:Name="StatusText" Foreground="#9CA3AF" FontFamily="Segoe UI" FontSize="10" VerticalAlignment="Center"/>
        <TextBlock x:Name="CreditText" Foreground="#9CA3AF" FontFamily="Segoe UI" FontSize="10" VerticalAlignment="Center" HorizontalAlignment="Right"/>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$script:Window = [Windows.Markup.XamlReader]::Load($reader)
$header = $script:Window.FindName('Header')
$script:CardsPanel = $script:Window.FindName('CardsPanel')
$script:EmptyCard = $script:Window.FindName('EmptyCard')
$script:EmptyText = $script:Window.FindName('EmptyText')
$script:StatusText = $script:Window.FindName('StatusText')
$script:CreditText = $script:Window.FindName('CreditText')
$script:PlanText = $script:Window.FindName('PlanText')
$script:RefreshButton = $script:Window.FindName('RefreshButton')
$minimizeButton = $script:Window.FindName('MinimizeButton')
$closeButton = $script:Window.FindName('CloseButton')

function New-QuotaCard {
    $border = New-Object Windows.Controls.Border
    $border.Background = '#181B21'
    $border.BorderBrush = '#2B313B'
    $border.BorderThickness = 1
    $border.CornerRadius = 9
    $border.Margin = '0,0,0,8'
    $border.Padding = '14,10,14,10'

    $grid = New-Object Windows.Controls.Grid
    $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = 'Auto' }))
    $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = 'Auto' }))
    $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = 'Auto' }))

    $top = New-Object Windows.Controls.Grid
    [Windows.Controls.Grid]::SetRow($top, 0)
    $name = New-Object Windows.Controls.TextBlock -Property @{ Foreground = '#F3F4F6'; FontFamily = 'Segoe UI'; FontSize = 13; FontWeight = 'SemiBold' }
    $value = New-Object Windows.Controls.TextBlock -Property @{ Foreground = '#31C48D'; FontFamily = 'Segoe UI'; FontSize = 18; FontWeight = 'Bold'; HorizontalAlignment = 'Right' }
    $top.Children.Add($name) | Out-Null
    $top.Children.Add($value) | Out-Null
    $grid.Children.Add($top) | Out-Null

    $progress = New-Object Windows.Controls.ProgressBar -Property @{ Height = 8; Minimum = 0; Maximum = 100; Margin = '0,8,0,0'; Background = '#20242C'; BorderThickness = 0 }
    [Windows.Controls.Grid]::SetRow($progress, 1)
    $grid.Children.Add($progress) | Out-Null

    $bottom = New-Object Windows.Controls.Grid -Property @{ Margin = '0,7,0,0' }
    [Windows.Controls.Grid]::SetRow($bottom, 2)
    $reset = New-Object Windows.Controls.TextBlock -Property @{ Foreground = '#9CA3AF'; FontFamily = 'Segoe UI'; FontSize = 11 }
    $countdown = New-Object Windows.Controls.TextBlock -Property @{ Foreground = '#9CA3AF'; FontFamily = 'Segoe UI'; FontSize = 11; HorizontalAlignment = 'Right' }
    $bottom.Children.Add($reset) | Out-Null
    $bottom.Children.Add($countdown) | Out-Null
    $grid.Children.Add($bottom) | Out-Null
    $border.Child = $grid
    $script:CardsPanel.Children.Add($border) | Out-Null

    [pscustomobject]@{ Border = $border; Name = $name; Value = $value; Progress = $progress; Reset = $reset; Countdown = $countdown; ResetsAt = $null }
}

function Update-Countdowns {
    foreach ($card in $script:Cards) {
        $text = Get-ResetText $card.ResetsAt
        $card.Reset.Text = $text.Absolute
        $card.Countdown.Text = $text.Countdown
    }
}

function Apply-Snapshot {
    param($RawPayload)
    $snapshot = Convert-RateLimitResult $RawPayload
    if ($snapshot.Windows.Count -eq 0) { throw '当前账号没有返回可显示的 Codex 额度窗口。' }

    $script:EmptyCard.Visibility = 'Collapsed'
    while ($script:Cards.Count -lt $snapshot.Windows.Count) {
        [void]$script:Cards.Add((New-QuotaCard))
    }
    for ($i = 0; $i -lt $script:Cards.Count; $i++) {
        $card = $script:Cards[$i]
        if ($i -ge $snapshot.Windows.Count) { $card.Border.Visibility = 'Collapsed'; continue }
        $card.Border.Visibility = 'Visible'
        $item = $snapshot.Windows[$i]
        $card.Name.Text = $item.Label
        $card.Value.Text = '剩余 ' + $item.Remaining.ToString('0.#') + '%'
        $card.Progress.Value = $item.Remaining
        $color = if ($item.Remaining -le 15) { '#EF5B5B' } elseif ($item.Remaining -le 35) { '#F5A524' } else { '#31C48D' }
        $card.Progress.Foreground = $color
        $card.Value.Foreground = $color
        $card.ResetsAt = $item.ResetsAt
    }
    Update-Countdowns
    $script:PlanText.Text = if ($snapshot.Plan) { $snapshot.Plan.ToUpperInvariant() } else { '' }
    $script:CreditText.Text = if ($null -ne $snapshot.ResetCredits) { "可用重置券 $($snapshot.ResetCredits)" } else { '' }
    $script:StatusText.Foreground = '#9CA3AF'
    $script:StatusText.Text = '更新于 ' + [DateTime]::Now.ToString('HH:mm:ss') + ' · 每分钟自动刷新'
    $script:Window.Height = 102 + (105 * $snapshot.Windows.Count)
}

$fetchScript = {
    param($CodexPath)
    $ErrorActionPreference = 'Stop'
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $CodexPath
    $info.Arguments = 'app-server --stdio'
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    if (-not $info.EnvironmentVariables['HOME'] -and $env:USERPROFILE) { $info.EnvironmentVariables['HOME'] = $env:USERPROFILE }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    [void]$process.Start()
    try {
        $initialize = @{ method = 'initialize'; id = 1; params = @{ clientInfo = @{ name = 'codex-usage-widget'; version = '1.0.0' }; capabilities = @{} } } | ConvertTo-Json -Compress -Depth 8
        $process.StandardInput.WriteLine($initialize)
        $process.StandardInput.Flush()
        do { $line = $process.StandardOutput.ReadLine(); if ($null -eq $line) { throw 'Codex app-server 已意外退出。' }; $message = $line | ConvertFrom-Json } until ($message.id -eq 1)
        if ($message.error) { throw [string]$message.error.message }
        $process.StandardInput.WriteLine('{' + '"method":"initialized","params":{}' + '}')
        $process.StandardInput.WriteLine('{' + '"method":"account/rateLimits/read","id":2' + '}')
        $process.StandardInput.Flush()
        do { $line = $process.StandardOutput.ReadLine(); if ($null -eq $line) { throw 'Codex app-server 已意外退出。' }; $message = $line | ConvertFrom-Json } until ($message.id -eq 2)
        if ($message.error) { throw [string]$message.error.message }
        $message.result
    }
    finally {
        if (-not $process.HasExited) { $process.Kill() }
        $process.Dispose()
    }
}

function Start-Refresh {
    if ($script:CurrentJob -and $script:CurrentJob.State -in @('Running', 'NotStarted')) { return }
    try { $codexPath = Find-CodexExecutable }
    catch { Show-RefreshError $_.Exception.Message; return }
    $script:RefreshButton.IsEnabled = $false
    $script:RefreshButton.Content = '…'
    $script:StatusText.Foreground = '#9CA3AF'
    $script:StatusText.Text = '正在刷新…'
    $script:CurrentJob = Start-Job -ScriptBlock $fetchScript -ArgumentList $codexPath
    $script:JobStartedAt = [DateTime]::Now
}

function Show-RefreshError {
    param([string]$Message)
    $concise = ($Message -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 1)
    $script:EmptyCard.Visibility = 'Visible'
    $script:EmptyText.Foreground = '#F3F4F6'
    $script:EmptyText.Text = "无法读取 Codex 额度`n`n$concise`n`n请确认 Codex 桌面应用已登录，然后点 ↻ 重试。"
    $script:StatusText.Foreground = '#EF5B5B'
    $script:StatusText.Text = '读取失败'
    $script:Window.Height = 245
}

$pollTimer = New-Object Windows.Threading.DispatcherTimer
$pollTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$pollTimer.Add_Tick({
    if (-not $script:CurrentJob) { return }
    if ($script:CurrentJob.State -eq 'Completed') {
        try {
            $payload = Receive-Job $script:CurrentJob -ErrorAction Stop
            Apply-Snapshot $payload
        }
        catch { Show-RefreshError $_.Exception.Message }
        finally {
            Remove-Job $script:CurrentJob -Force -ErrorAction SilentlyContinue
            $script:CurrentJob = $null
            $script:RefreshButton.IsEnabled = $true
            $script:RefreshButton.Content = '↻'
        }
    }
    elseif ($script:CurrentJob.State -eq 'Failed') {
        $reason = $script:CurrentJob.ChildJobs[0].JobStateInfo.Reason.Message
        Show-RefreshError $reason
        Remove-Job $script:CurrentJob -Force -ErrorAction SilentlyContinue
        $script:CurrentJob = $null
        $script:RefreshButton.IsEnabled = $true
        $script:RefreshButton.Content = '↻'
    }
    elseif (([DateTime]::Now - $script:JobStartedAt).TotalSeconds -gt $script:RequestTimeoutSeconds) {
        Stop-Job $script:CurrentJob -ErrorAction SilentlyContinue
        Remove-Job $script:CurrentJob -Force -ErrorAction SilentlyContinue
        $script:CurrentJob = $null
        $script:RefreshButton.IsEnabled = $true
        $script:RefreshButton.Content = '↻'
        Show-RefreshError '读取额度超时，请确认 Codex 已登录。'
    }
})

$tickTimer = New-Object Windows.Threading.DispatcherTimer
$tickTimer.Interval = [TimeSpan]::FromSeconds(1)
$tickTimer.Add_Tick({ Update-Countdowns })

$refreshTimer = New-Object Windows.Threading.DispatcherTimer
$refreshTimer.Interval = [TimeSpan]::FromSeconds($script:RefreshSeconds)
$refreshTimer.Add_Tick({ Start-Refresh })

$settingsPath = Join-Path $env:LOCALAPPDATA 'CodexUsageWidget\settings.json'
try {
    $saved = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    $script:Window.Left = [double]$saved.x
    $script:Window.Top = [double]$saved.y
}
catch {
    $script:Window.WindowStartupLocation = 'Manual'
    $script:Window.Left = [Math]::Max(0, [System.Windows.SystemParameters]::WorkArea.Right - 410)
    $script:Window.Top = 60
}

$header.Add_MouseLeftButtonDown({ if ($_.ChangedButton -eq 'Left') { $script:Window.DragMove() } })
$script:RefreshButton.Add_Click({ Start-Refresh })
$minimizeButton.Add_Click({ $script:Window.WindowState = 'Minimized' })
$closeButton.Add_Click({ $script:Window.Close() })
$script:Window.Add_Closed({
    $script:Closed = $true
    $pollTimer.Stop(); $tickTimer.Stop(); $refreshTimer.Stop()
    if ($script:CurrentJob) { Stop-Job $script:CurrentJob -ErrorAction SilentlyContinue; Remove-Job $script:CurrentJob -Force -ErrorAction SilentlyContinue }
    try {
        $settingsDirectory = Split-Path -Parent $settingsPath
        New-Item -ItemType Directory -Path $settingsDirectory -Force | Out-Null
        @{ x = $script:Window.Left; y = $script:Window.Top } | ConvertTo-Json | Set-Content -LiteralPath $settingsPath -Encoding UTF8
    }
    catch { }
})

$pollTimer.Start(); $tickTimer.Start(); $refreshTimer.Start()
$script:Window.Add_ContentRendered({ Start-Refresh })
[void]$script:Window.ShowDialog()
