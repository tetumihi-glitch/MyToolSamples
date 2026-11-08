Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Windows APIのインポート
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class WinAPI {
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

    [DllImport("user32.dll")]
    public static extern bool SetLayeredWindowAttributes(IntPtr hWnd, uint crKey, byte bAlpha, uint dwFlags);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_LAYERED = 0x80000;
    public const uint LWA_ALPHA = 0x2;

    public static void SetTransparency(IntPtr hWnd, byte alpha) {
        int exStyle = GetWindowLong(hWnd, GWL_EXSTYLE);
        if ((exStyle & WS_EX_LAYERED) == 0) {
            SetWindowLong(hWnd, GWL_EXSTYLE, exStyle | WS_EX_LAYERED);
        }
        SetLayeredWindowAttributes(hWnd, 0, alpha, LWA_ALPHA);
    }
}
'@

# タスクトレイアイコンの作成
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = [System.Drawing.SystemIcons]::Application
$notifyIcon.Text = "アクティブウィンドウ追随バー"
$notifyIcon.Visible = $true

$contextMenu = New-Object System.Windows.Forms.ContextMenu
$menuItemExit = New-Object System.Windows.Forms.MenuItem("終了")
$contextMenu.MenuItems.Add($menuItemExit) | Out-Null
$notifyIcon.ContextMenu = $contextMenu

# 追随バー本体（WPF製）
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

[xml]$xaml = @"
<Window 
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="FloatingBar" Height="30" Width="240"
    AllowsTransparency="True" WindowStyle="None" Background="#B31E1E1E" Topmost="True" ShowInTaskbar="False">
    
    <Border x:Name="MainBorder" BorderBrush="#55FFFFFF" BorderThickness="1" CornerRadius="4">
        <DockPanel Margin="8,0" LastChildFill="True">
            <TextBlock x:Name="TargetTitle" Text="追随中..." Foreground="White" VerticalAlignment="Center" FontSize="11" Width="110" TextTrimming="CharacterEllipsis" Margin="0,0,6,0"/>
            <Slider x:Name="OpacitySlider" Minimum="10" Maximum="100" Value="100" VerticalAlignment="Center" TickFrequency="10"/>
        </DockPanel>
    </Border>
</Window>
"@

$reader = (New-Object System.Xml.XmlNodeReader $xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$slider = $window.FindName("OpacitySlider")
$targetTitleBlock = $window.FindName("TargetTitle")
$mainBorder = $window.FindName("MainBorder")

# バーをドラッグして位置を微調整できるようにする
$mainBorder.Add_MouseLeftButtonDown({ if ($_.Button -eq 'Left') { $window.DragMove() } })

$global:targetHWnd = [IntPtr]::Zero

# 追随タイマー（0.05秒おき）
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(50)
$timer.Add_Tick({
    $hwnd = [WinAPI]::GetForegroundWindow()
    
    if ($hwnd -ne [IntPtr]::Zero) {
        $sb = New-Object System.Text.StringBuilder 256
        [WinAPI]::GetWindowText($hwnd, $sb, $sb.Capacity) > $null
        $title = $sb.ToString()

        if (![string]::IsNullOrWhiteSpace($title) -and $title -ne "FloatingBar") {
            if ($hwnd -ne $global:targetHWnd) {
                $global:targetHWnd = $hwnd
                $targetTitleBlock.Text = $title
                $slider.Value = 100
            }

            $rect = New-Object WinAPI+RECT
            if ([WinAPI]::GetWindowRect($global:targetHWnd, [ref]$rect)) {
                # 【変更点】最小・最大・閉じるボタン（大体右端から140px程度）を避けるため、
                # 右端からさらに「160px」左側にずらして配置します。
                $targetLeft = $rect.Right - 160 - 240 # 240はバー自体の幅
                $targetTop = $rect.Top + 3
                
                # 画面外にはみ出さないように調整
                if ($targetLeft -lt $rect.Left) { 
                    $targetLeft = $rect.Left + 10 
                }

                $window.Left = $targetLeft
                $window.Top = $targetTop
            }
        }
    }
})
$timer.Start()

# スライダー操作時
$slider.Add_ValueChanged({
    if ($global:targetHWnd -ne [IntPtr]::Zero) {
        $alpha = [byte]($slider.Value * 255 / 100)
        [WinAPI]::SetTransparency($global:targetHWnd, $alpha)
    }
})

# 終了処理
$menuItemExit.Add_Click({
    $timer.Stop()
    $notifyIcon.Visible = $false
    $window.Close()
    [System.Windows.Forms.Application]::ExitThread()
})

$window.Add_Closed({
    $timer.Stop()
    $notifyIcon.Visible = $false
})

[void]$window.Show()
[System.Windows.Forms.Application]::Run()