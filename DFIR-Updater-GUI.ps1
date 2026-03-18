#Requires -Version 5.1
<#
.SYNOPSIS
    DFIR Drive Updater - WPF GUI
.DESCRIPTION
    Provides a professional WPF-based graphical interface for checking and
    updating DFIR tools on the drive. Displays tool status in a color-coded
    data grid and supports background update checking to keep the UI responsive.
.NOTES
    Requires: PresentationFramework, PresentationCore, WindowsBase
    Module dependency: modules/Update-Checker.ps1
#>

# ─── Load WPF Assemblies ────────────────────────────────────────────────────
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -AssemblyName System.Drawing

# ─── Resolve Paths (portable: never hardcode a drive letter) ─────────────────
$script:ScriptDir = $PSScriptRoot
if (-not $script:ScriptDir) { $script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }

# Determine drive root: prefer parent of ScriptDir, fall back to volume label, then D:\
$script:DriveRoot = Split-Path -Parent $script:ScriptDir
if (-not $script:DriveRoot -or -not (Test-Path $script:DriveRoot)) {
    # Fallback: search for a volume labeled "DFIR"
    $dfirVolume = Get-Volume | Where-Object { $_.FileSystemLabel -eq 'DFIR' -and $_.DriveLetter } | Select-Object -First 1
    if ($dfirVolume) {
        $script:DriveRoot = "$($dfirVolume.DriveLetter):\"
    } else {
        # Last resort fallback
        $script:DriveRoot = "D:\"
    }
}

# ─── Forensic Mode State ─────────────────────────────────────────────────────
$script:ForensicModeFile = Join-Path $script:DriveRoot 'FORENSIC_MODE'
$script:ForensicModeActive = Test-Path -LiteralPath $script:ForensicModeFile

# ─── Debug Log Setup ────────────────────────────────────────────────────────
$script:DebugLogPath = Join-Path $script:ScriptDir "debug.log"
$script:DebugLogMaxBytes = 2 * 1024 * 1024   # 2 MB max before rotation

# Rotate if the log file is too large
if (Test-Path -LiteralPath $script:DebugLogPath) {
    try {
        $logSize = (Get-Item -LiteralPath $script:DebugLogPath -ErrorAction Stop).Length
        if ($logSize -gt $script:DebugLogMaxBytes) {
            $backupPath = $script:DebugLogPath + '.old'
            if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force }
            Rename-Item -LiteralPath $script:DebugLogPath -NewName (Split-Path $backupPath -Leaf) -Force
        }
    } catch { }
}

function Write-DebugLog {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','DEBUG')]
        [string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $caller = ''
    $callStack = Get-PSCallStack
    if ($callStack.Count -ge 2) {
        $frame = $callStack[1]
        $caller = " [$($frame.FunctionName):$($frame.ScriptLineNumber)]"
    }
    $line = "$ts [$Level]$caller $Message"
    try {
        [System.IO.File]::AppendAllText($script:DebugLogPath, "$line`r`n")
    } catch { }
}

# Session header
Write-DebugLog "═══════════════════════════════════════════════════════════════" 'INFO'
Write-DebugLog "DFIR-Updater session started" 'INFO'
Write-DebugLog "PowerShell $($PSVersionTable.PSVersion) | OS $([System.Environment]::OSVersion.VersionString)" 'INFO'
Write-DebugLog "ScriptDir: $script:ScriptDir | DriveRoot: $script:DriveRoot" 'INFO'
Write-DebugLog "═══════════════════════════════════════════════════════════════" 'INFO'

$script:ModulePath          = Join-Path $script:ScriptDir "modules\Update-Checker.ps1"
$script:AutoDiscoveryPath   = Join-Path $script:ScriptDir "modules\Auto-Discovery.ps1"
$script:ToolLauncherPath    = Join-Path $script:ScriptDir "modules\Tool-Launcher.ps1"
$script:PkgManagerPath      = Join-Path $script:ScriptDir "modules\Package-Manager.ps1"
$script:ConfigPath          = Join-Path $script:ScriptDir "tools-config.json"
$script:HasModule           = Test-Path $script:ModulePath
$script:HasAutoDiscovery    = Test-Path $script:AutoDiscoveryPath
$script:HasToolLauncher     = Test-Path $script:ToolLauncherPath
$script:HasPkgManager       = Test-Path $script:PkgManagerPath

# ─── Dot-source the update-checker backend ───────────────────────────────────
Write-DebugLog "Modules: Update-Checker=$($script:HasModule) AutoDiscovery=$($script:HasAutoDiscovery) ToolLauncher=$($script:HasToolLauncher) PkgManager=$($script:HasPkgManager)" 'DEBUG'
if ($script:HasModule) {
    . $script:ModulePath
    Write-DebugLog "Loaded Update-Checker module" 'DEBUG'
} else {
    Write-Warning "Update-Checker module not found at: $script:ModulePath"
    Write-Warning "Running in UI-preview mode with sample data."
    Write-DebugLog "Update-Checker module NOT FOUND - preview mode" 'WARN'
}

# The module sets Set-StrictMode -Version Latest which propagates to this scope
# via dot-sourcing and breaks WPF property access / event handlers. Reset it.
Set-StrictMode -Off

# ─── Dot-source the auto-discovery module (optional) ─────────────────────────
if ($script:HasAutoDiscovery) {
    . $script:AutoDiscoveryPath
}

# ─── Dot-source the tool launcher module (optional) ──────────────────────────
if ($script:HasToolLauncher) {
    . $script:ToolLauncherPath
    Set-StrictMode -Off
}

# ─── Dot-source the package manager module (optional) ────────────────────────
if ($script:HasPkgManager) {
    . $script:PkgManagerPath
    Set-StrictMode -Off
}

# ─── Observable Tool Item Class ──────────────────────────────────────────────
Add-Type -Language CSharp @"
using System;
using System.ComponentModel;

public class ToolItem : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler PropertyChanged;
    private void OnPropertyChanged(string name)
    {
        if (PropertyChanged != null)
            PropertyChanged(this, new PropertyChangedEventArgs(name));
    }

    private bool _isSelected;
    public bool IsSelected
    {
        get { return _isSelected; }
        set { _isSelected = value; OnPropertyChanged("IsSelected"); }
    }

    private string _name;
    public string Name
    {
        get { return _name; }
        set { _name = value; OnPropertyChanged("Name"); }
    }

    private string _category;
    public string Category
    {
        get { return _category; }
        set { _category = value; OnPropertyChanged("Category"); }
    }

    private string _currentVersion;
    public string CurrentVersion
    {
        get { return _currentVersion; }
        set { _currentVersion = value; OnPropertyChanged("CurrentVersion"); }
    }

    private string _latestVersion;
    public string LatestVersion
    {
        get { return _latestVersion; }
        set { _latestVersion = value; OnPropertyChanged("LatestVersion"); }
    }

    private string _status;
    public string Status
    {
        get { return _status; }
        set { _status = value; OnPropertyChanged("Status"); }
    }

    private string _statusKey;
    public string StatusKey
    {
        get { return _statusKey; }
        set { _statusKey = value; OnPropertyChanged("StatusKey"); }
    }

    private string _toolPath;
    public string ToolPath
    {
        get { return _toolPath; }
        set { _toolPath = value; OnPropertyChanged("ToolPath"); }
    }

    private string _sourceType;
    public string SourceType
    {
        get { return _sourceType; }
        set { _sourceType = value; OnPropertyChanged("SourceType"); }
    }

    private string _installType;
    public string InstallType
    {
        get { return _installType; }
        set { _installType = value; OnPropertyChanged("InstallType"); }
    }

    private string _downloadUrl;
    public string DownloadUrl
    {
        get { return _downloadUrl; }
        set { _downloadUrl = value; OnPropertyChanged("DownloadUrl"); }
    }

    private string _notes;
    public string Notes
    {
        get { return _notes; }
        set { _notes = value; OnPropertyChanged("Notes"); }
    }
}
"@

# ─── XAML Window Definition ──────────────────────────────────────────────────
[xml]$xaml = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="DFIR Drive Updater"
    Width="1050" Height="700"
    MinWidth="850" MinHeight="550"
    WindowStartupLocation="CenterScreen"
    Background="#1E1E1E"
    Foreground="White"
    FontFamily="Segoe UI">

    <Window.Resources>
        <!-- Shared style for buttons -->
        <Style x:Key="ActionButton" TargetType="Button">
            <Setter Property="Background"  Value="#3C3C3C"/>
            <Setter Property="Foreground"  Value="White"/>
            <Setter Property="FontSize"    Value="13"/>
            <Setter Property="Padding"     Value="14,7"/>
            <Setter Property="Margin"      Value="4,0"/>
            <Setter Property="BorderBrush" Value="#555555"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Cursor"      Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="3"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#505050"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#606060"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="border" Property="Background" Value="#2A2A2A"/>
                                <Setter Property="Foreground" Value="#666666"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Primary (accent) button -->
        <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource ActionButton}">
            <Setter Property="Background"  Value="#0078D4"/>
            <Setter Property="BorderBrush" Value="#005A9E"/>
            <Setter Property="FontWeight"  Value="SemiBold"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="3"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#1A8AD4"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#005A9E"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="border" Property="Background" Value="#2A2A2A"/>
                                <Setter Property="Foreground" Value="#666666"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Sidebar NavButton style -->
        <Style x:Key="NavButton" TargetType="Button">
            <Setter Property="Width" Value="56"/>
            <Setter Property="Height" Value="48"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#888888"/>
            <Setter Property="FontSize" Value="20"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="HorizontalContentAlignment" Value="Center"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Grid>
                            <!-- Active indicator bar (left edge) -->
                            <Border x:Name="activeBar" Width="3" HorizontalAlignment="Left"
                                    Background="Transparent" CornerRadius="0,2,2,0"/>
                            <Border x:Name="bgBorder" Background="{TemplateBinding Background}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bgBorder" Property="Background" Value="#2A2A30"/>
                            </Trigger>
                            <Trigger Property="Tag" Value="Active">
                                <Setter TargetName="activeBar" Property="Background" Value="#0078D4"/>
                                <Setter TargetName="bgBorder" Property="Background" Value="#252530"/>
                                <Setter Property="Foreground" Value="White"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- DataGrid column header style -->
        <Style TargetType="DataGridColumnHeader">
            <Setter Property="Background"  Value="#2D2D2D"/>
            <Setter Property="Foreground"  Value="#CCCCCC"/>
            <Setter Property="FontWeight"  Value="SemiBold"/>
            <Setter Property="FontSize"    Value="13"/>
            <Setter Property="Padding"     Value="8,6"/>
            <Setter Property="BorderBrush" Value="#3E3E3E"/>
            <Setter Property="BorderThickness" Value="0,0,1,1"/>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>   <!-- Row 0: Header -->
            <RowDefinition Height="*"/>      <!-- Row 1: Main area (sidebar + content) -->
            <RowDefinition Height="Auto"/>   <!-- Row 2: Status bar (shared) -->
            <RowDefinition Height="Auto"/>   <!-- Row 3: Log panel (shared, collapsed) -->
        </Grid.RowDefinitions>

        <!-- ═══ Row 0: Header ═══ -->
        <Border Grid.Row="0" Background="#252526" Padding="12,8" BorderBrush="#3E3E3E" BorderThickness="0,0,0,1">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <!-- Shield icon -->
                <Border Grid.Column="0" Width="42" Height="42" CornerRadius="6"
                        Background="#0078D4" Margin="0,0,14,0" VerticalAlignment="Center">
                    <TextBlock Text="&#x1F6E1;" FontSize="22"
                               HorizontalAlignment="Center" VerticalAlignment="Center"
                               Foreground="White"/>
                </Border>

                <StackPanel Grid.Column="1" VerticalAlignment="Center">
                    <StackPanel Orientation="Horizontal">
                        <TextBlock Text="DFIR Drive Updater" FontSize="20" FontWeight="Bold" Foreground="White"/>
                        <Button x:Name="btnForensicToggle" Margin="12,0,0,0" VerticalAlignment="Center"
                                Cursor="Hand" BorderThickness="1" Padding="10,3"
                                Content="FORENSIC MODE: OFF" FontSize="10" FontWeight="SemiBold"
                                Background="#1B5E20" Foreground="#4CAF50" BorderBrush="#2E7D32">
                            <Button.Template>
                                <ControlTemplate TargetType="Button">
                                    <Border x:Name="forensicBorder" CornerRadius="3"
                                            Padding="{TemplateBinding Padding}"
                                            BorderThickness="{TemplateBinding BorderThickness}"
                                            Background="{TemplateBinding Background}"
                                            BorderBrush="{TemplateBinding BorderBrush}">
                                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                    </Border>
                                    <ControlTemplate.Triggers>
                                        <Trigger Property="IsMouseOver" Value="True">
                                            <Setter TargetName="forensicBorder" Property="Opacity" Value="0.8"/>
                                        </Trigger>
                                        <Trigger Property="IsPressed" Value="True">
                                            <Setter TargetName="forensicBorder" Property="Opacity" Value="0.65"/>
                                        </Trigger>
                                    </ControlTemplate.Triggers>
                                </ControlTemplate>
                            </Button.Template>
                        </Button>
                    </StackPanel>
                </StackPanel>

                <StackPanel Grid.Column="2" VerticalAlignment="Center" Orientation="Horizontal">
                    <TextBlock x:Name="txtSummary" FontSize="12" Foreground="#AAAAAA"
                               VerticalAlignment="Center" Margin="0,0,8,0"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- ═══ Row 1: Main area - Sidebar + Content ═══ -->
        <Grid Grid.Row="1">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="56"/>   <!-- Sidebar -->
                <ColumnDefinition Width="*"/>    <!-- Content -->
            </Grid.ColumnDefinitions>

            <!-- Sidebar -->
            <Border Grid.Column="0" Background="#1B1B1F" BorderBrush="#3E3E3E" BorderThickness="0,0,1,0">
                <StackPanel VerticalAlignment="Top">
                    <Button x:Name="btnNavDashboard"  Content="&#x1F3E0;" Style="{StaticResource NavButton}" ToolTip="Dashboard" Tag="Active"/>
                    <Button x:Name="btnNavUpdates"    Content="&#x1F504;" Style="{StaticResource NavButton}" ToolTip="Update Center"/>
                    <Button x:Name="btnNavReferences" Content="&#x1F517;" Style="{StaticResource NavButton}" ToolTip="Linux/macOS References"/>
                    <Button x:Name="btnNavSettings"   Content="&#x2699;"  Style="{StaticResource NavButton}" ToolTip="Settings"/>
                </StackPanel>
            </Border>

            <!-- Content area -->
            <Grid Grid.Column="1">

                <!-- ── Panel 1: Dashboard (Tool Launcher) ── -->
                <Grid x:Name="panelDashboard" Visibility="Visible">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <!-- Top bar: Tools label | category chips | search box | refresh -->
                    <Border Grid.Row="0" Background="#252526" Padding="12,8" BorderBrush="#3E3E3E" BorderThickness="0,0,0,1">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center" Margin="4,0,16,0">
                                <TextBlock Text="Tools" FontSize="16" FontWeight="SemiBold" Foreground="White"/>
                                <TextBlock x:Name="txtDashToolCount" Text="" FontSize="12" Foreground="#888888" VerticalAlignment="Center" Margin="8,0,0,0"/>
                            </StackPanel>
                            <ScrollViewer Grid.Column="1" HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Disabled">
                                <StackPanel x:Name="pnlDashCategories" Orientation="Horizontal" VerticalAlignment="Center"/>
                            </ScrollViewer>
                            <TextBox x:Name="txtDashSearch" Grid.Column="2" Width="200" Height="28" Background="#333333" Foreground="White" BorderBrush="#555555" Padding="6,4" FontSize="12" VerticalContentAlignment="Center" Margin="8,0,0,0"/>
                            <Button x:Name="btnDashRefresh" Grid.Column="3" Content="&#x1F504;" FontSize="14" ToolTip="Rescan tools" Background="Transparent" Foreground="#AAAAAA" BorderThickness="0" Cursor="Hand" Padding="8,4" Margin="4,0,0,0"/>
                        </Grid>
                    </Border>

                    <!-- Scrollable tile area -->
                    <ScrollViewer x:Name="svDashTools" Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Background="#1E1E1E" Padding="12">
                        <WrapPanel x:Name="wpDashTools" Orientation="Horizontal"/>
                    </ScrollViewer>
                </Grid>

                <!-- ── Panel 2: Updates ── -->
                <Grid x:Name="panelUpdates" Visibility="Collapsed">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <!-- Update button bar -->
                    <Border Grid.Row="0" Background="#252526" Padding="12,8" BorderBrush="#3E3E3E" BorderThickness="0,0,0,1">
                        <DockPanel>
                            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                                <Button x:Name="btnCancelUpdate" Content="&#x274C; Cancel" Style="{StaticResource ActionButton}" Visibility="Collapsed"
                                        Foreground="#FF6B6B" BorderBrush="#CC4444"/>
                                <Button x:Name="btnRetryFailed" Content="&#x1F504; Retry Failed" Style="{StaticResource ActionButton}" Visibility="Collapsed"
                                        Foreground="#FFE066" BorderBrush="#B8A000"/>
                                <Button x:Name="btnRefresh" Content="&#x1F504; Check for Updates" Style="{StaticResource ActionButton}"/>
                            </StackPanel>
                            <StackPanel Orientation="Horizontal">
                                <Button x:Name="btnUpdateAll" Content="&#x26A1; Update All" Style="{StaticResource PrimaryButton}" Margin="0,0,8,0"/>
                                <Button x:Name="btnSelectUpdates" Content="Select All Updates" Style="{StaticResource ActionButton}"/>
                                <Button x:Name="btnDeselectAll"    Content="Deselect All"       Style="{StaticResource ActionButton}"/>
                                <Button x:Name="btnUpdateSelected" Content="Update Selected"    Style="{StaticResource ActionButton}"/>
                            </StackPanel>
                        </DockPanel>
                    </Border>

                    <!-- DataGrid -->
                    <DataGrid x:Name="dgTools" Grid.Row="1"
                              AutoGenerateColumns="False"
                              IsReadOnly="False"
                              SelectionMode="Single"
                              SelectionUnit="FullRow"
                              CanUserAddRows="False"
                              CanUserDeleteRows="False"
                              CanUserReorderColumns="False"
                              CanUserSortColumns="True"
                              GridLinesVisibility="Horizontal"
                              HorizontalGridLinesBrush="#2E2E2E"
                              Background="#1E1E1E"
                              Foreground="White"
                              RowBackground="#1E1E1E"
                              AlternatingRowBackground="#232323"
                              BorderBrush="#3E3E3E"
                              BorderThickness="0"
                              HeadersVisibility="Column"
                              RowHeaderWidth="0"
                              FontSize="13"
                              Margin="0">

                        <DataGrid.Resources>
                            <SolidColorBrush x:Key="{x:Static SystemColors.HighlightBrushKey}" Color="#333333"/>
                            <SolidColorBrush x:Key="{x:Static SystemColors.InactiveSelectionHighlightBrushKey}" Color="#2A2A2A"/>
                            <SolidColorBrush x:Key="{x:Static SystemColors.HighlightTextBrushKey}" Color="White"/>
                        </DataGrid.Resources>

                        <DataGrid.CellStyle>
                            <Style TargetType="DataGridCell">
                                <Setter Property="Foreground" Value="White"/>
                                <Setter Property="BorderThickness" Value="0"/>
                                <Setter Property="Padding" Value="6,4"/>
                                <Setter Property="Template">
                                    <Setter.Value>
                                        <ControlTemplate TargetType="DataGridCell">
                                            <Border Background="{TemplateBinding Background}"
                                                    Padding="{TemplateBinding Padding}">
                                                <ContentPresenter VerticalAlignment="Center"/>
                                            </Border>
                                        </ControlTemplate>
                                    </Setter.Value>
                                </Setter>
                            </Style>
                        </DataGrid.CellStyle>

                        <DataGrid.RowStyle>
                            <Style TargetType="DataGridRow">
                                <Setter Property="Background" Value="#1E1E1E"/>
                                <Setter Property="BorderBrush" Value="#2E2E2E"/>
                                <Setter Property="BorderThickness" Value="0,0,0,1"/>
                                <Setter Property="ToolTip">
                                    <Setter.Value>
                                        <MultiBinding StringFormat="{}{0}&#x0a;Path: {1}&#x0a;Install: {2}&#x0a;{3}">
                                            <Binding Path="Name"/>
                                            <Binding Path="ToolPath"/>
                                            <Binding Path="InstallType"/>
                                            <Binding Path="Notes"/>
                                        </MultiBinding>
                                    </Setter.Value>
                                </Setter>
                                <Style.Triggers>
                                    <DataTrigger Binding="{Binding StatusKey}" Value="UpToDate">
                                        <Setter Property="Background" Value="#1C2E1C"/>
                                    </DataTrigger>
                                    <DataTrigger Binding="{Binding StatusKey}" Value="UpdateAvailable">
                                        <Setter Property="Background" Value="#2E2E1C"/>
                                    </DataTrigger>
                                    <DataTrigger Binding="{Binding StatusKey}" Value="ManualCheck">
                                        <Setter Property="Background" Value="#2A2A2A"/>
                                    </DataTrigger>
                                    <DataTrigger Binding="{Binding StatusKey}" Value="Checking">
                                        <Setter Property="Background" Value="#1E1E1E"/>
                                    </DataTrigger>
                                    <DataTrigger Binding="{Binding StatusKey}" Value="Error">
                                        <Setter Property="Background" Value="#331C1C"/>
                                    </DataTrigger>
                                    <Trigger Property="IsMouseOver" Value="True">
                                        <Setter Property="Background" Value="#333340"/>
                                    </Trigger>
                                </Style.Triggers>
                            </Style>
                        </DataGrid.RowStyle>

                        <DataGrid.Columns>
                            <DataGridTemplateColumn Header="" Width="40" CanUserResize="False" CanUserSort="False">
                                <DataGridTemplateColumn.CellTemplate>
                                    <DataTemplate>
                                        <CheckBox IsChecked="{Binding IsSelected, UpdateSourceTrigger=PropertyChanged, Mode=TwoWay}"
                                                  HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellTemplate>
                            </DataGridTemplateColumn>

                            <DataGridTextColumn Header="Tool Name"       Binding="{Binding Name}"           Width="*"    IsReadOnly="True"/>
                            <DataGridTextColumn Header="Category"        Binding="{Binding Category}"       Width="110"  IsReadOnly="True"/>
                            <DataGridTextColumn Header="Source"          Binding="{Binding SourceType}"     Width="65"   IsReadOnly="True"/>
                            <DataGridTextColumn Header="Current"         Binding="{Binding CurrentVersion}" Width="90"   IsReadOnly="True"/>
                            <DataGridTextColumn Header="Latest"          Binding="{Binding LatestVersion}"  Width="90"   IsReadOnly="True"/>

                            <DataGridTemplateColumn Header="Status" Width="150" IsReadOnly="True" CanUserSort="True" SortMemberPath="StatusKey">
                                <DataGridTemplateColumn.CellTemplate>
                                    <DataTemplate>
                                        <Grid>
                                            <!-- Regular status text (hidden for ManualCheck) -->
                                            <TextBlock Text="{Binding Status}" Padding="4,0">
                                                <TextBlock.Style>
                                                    <Style TargetType="TextBlock">
                                                        <Setter Property="Foreground" Value="#AAAAAA"/>
                                                        <Style.Triggers>
                                                            <DataTrigger Binding="{Binding StatusKey}" Value="UpToDate">
                                                                <Setter Property="Foreground" Value="#7CDF8A"/>
                                                            </DataTrigger>
                                                            <DataTrigger Binding="{Binding StatusKey}" Value="UpdateAvailable">
                                                                <Setter Property="Foreground" Value="#FFE066"/>
                                                            </DataTrigger>
                                                            <DataTrigger Binding="{Binding StatusKey}" Value="ManualCheck">
                                                                <Setter Property="Visibility" Value="Collapsed"/>
                                                            </DataTrigger>
                                                            <DataTrigger Binding="{Binding StatusKey}" Value="Checking">
                                                                <Setter Property="Foreground" Value="#6CB4EE"/>
                                                            </DataTrigger>
                                                            <DataTrigger Binding="{Binding StatusKey}" Value="Error">
                                                                <Setter Property="Visibility" Value="Collapsed"/>
                                                            </DataTrigger>
                                                        </Style.Triggers>
                                                    </Style>
                                                </TextBlock.Style>
                                            </TextBlock>
                                            <!-- Clickable link for ManualCheck and Error (failed update) items -->
                                            <Button Tag="OpenDownloadPage" Cursor="Hand"
                                                    ToolTip="{Binding DownloadUrl}">
                                                <Button.Template>
                                                    <ControlTemplate TargetType="Button">
                                                        <StackPanel Orientation="Horizontal" Cursor="Hand">
                                                            <TextBlock x:Name="linkText"
                                                                       Text="{Binding Status}"
                                                                       TextDecorations="Underline"
                                                                       Foreground="{Binding Foreground, RelativeSource={RelativeSource TemplatedParent}}"
                                                                       Padding="4,0,0,0"/>
                                                            <TextBlock x:Name="linkArrow" Text=" &#x2197;"
                                                                       Foreground="{Binding Foreground, RelativeSource={RelativeSource TemplatedParent}}"
                                                                       VerticalAlignment="Center"
                                                                       Padding="2,0,0,0"/>
                                                        </StackPanel>
                                                        <ControlTemplate.Triggers>
                                                            <Trigger Property="IsMouseOver" Value="True">
                                                                <Setter TargetName="linkText" Property="Foreground" Value="#9DD4FF"/>
                                                            </Trigger>
                                                        </ControlTemplate.Triggers>
                                                    </ControlTemplate>
                                                </Button.Template>
                                                <Button.Style>
                                                    <Style TargetType="Button">
                                                        <Setter Property="Visibility" Value="Collapsed"/>
                                                        <Setter Property="Foreground" Value="#6CB4EE"/>
                                                        <Style.Triggers>
                                                            <DataTrigger Binding="{Binding StatusKey}" Value="ManualCheck">
                                                                <Setter Property="Visibility" Value="Visible"/>
                                                            </DataTrigger>
                                                            <DataTrigger Binding="{Binding StatusKey}" Value="Error">
                                                                <Setter Property="Visibility" Value="Visible"/>
                                                                <Setter Property="Foreground" Value="#FF6B6B"/>
                                                            </DataTrigger>
                                                        </Style.Triggers>
                                                    </Style>
                                                </Button.Style>
                                            </Button>
                                        </Grid>
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellTemplate>
                            </DataGridTemplateColumn>

                            <!-- Per-row action button (UniGetUI-style) -->
                            <DataGridTemplateColumn Header="" Width="80" CanUserResize="False" CanUserSort="False">
                                <DataGridTemplateColumn.CellTemplate>
                                    <DataTemplate>
                                        <Button Tag="RowAction" Cursor="Hand" Padding="8,2" FontSize="11"
                                                Background="#0078D4" Foreground="White" BorderThickness="0">
                                            <Button.Template>
                                                <ControlTemplate TargetType="Button">
                                                    <Border x:Name="actionBorder" CornerRadius="3"
                                                            Background="{TemplateBinding Background}"
                                                            Padding="{TemplateBinding Padding}">
                                                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                                    </Border>
                                                    <ControlTemplate.Triggers>
                                                        <Trigger Property="IsMouseOver" Value="True">
                                                            <Setter TargetName="actionBorder" Property="Background" Value="#1A8AD4"/>
                                                        </Trigger>
                                                        <Trigger Property="IsPressed" Value="True">
                                                            <Setter TargetName="actionBorder" Property="Background" Value="#005A9E"/>
                                                        </Trigger>
                                                    </ControlTemplate.Triggers>
                                                </ControlTemplate>
                                            </Button.Template>
                                            <Button.Style>
                                                <Style TargetType="Button">
                                                    <Setter Property="Visibility" Value="Collapsed"/>
                                                    <Setter Property="Content" Value="Update"/>
                                                    <Style.Triggers>
                                                        <DataTrigger Binding="{Binding StatusKey}" Value="UpdateAvailable">
                                                            <Setter Property="Visibility" Value="Visible"/>
                                                            <Setter Property="Content" Value="Update"/>
                                                        </DataTrigger>
                                                        <DataTrigger Binding="{Binding StatusKey}" Value="ManualCheck">
                                                            <Setter Property="Visibility" Value="Visible"/>
                                                            <Setter Property="Content" Value="Open"/>
                                                            <Setter Property="Background" Value="#555555"/>
                                                        </DataTrigger>
                                                        <DataTrigger Binding="{Binding StatusKey}" Value="Error">
                                                            <Setter Property="Visibility" Value="Visible"/>
                                                            <Setter Property="Content" Value="Retry"/>
                                                            <Setter Property="Background" Value="#8B4513"/>
                                                        </DataTrigger>
                                                    </Style.Triggers>
                                                </Style>
                                            </Button.Style>
                                        </Button>
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellTemplate>
                            </DataGridTemplateColumn>
                        </DataGrid.Columns>
                    </DataGrid>
                </Grid>

                <!-- ── Panel 3: Settings ── -->
                <Grid x:Name="panelSettings" Visibility="Collapsed">
                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Background="#1E1E1E" Padding="24,16">
                        <StackPanel MaxWidth="600" HorizontalAlignment="Left">

                            <!-- Forensic Mode Card -->
                            <Border Background="#252526" CornerRadius="6" Padding="16" BorderBrush="#3E3E3E" BorderThickness="1" Margin="0,0,0,16">
                                <StackPanel>
                                    <TextBlock Text="Forensic Mode" FontSize="16" FontWeight="SemiBold" Foreground="White" Margin="0,0,0,8"/>
                                    <TextBlock Text="When enabled, the drive is set to read-only and all updates are blocked. Use this before connecting to a target or evidence system to preserve chain of custody." Foreground="#AAAAAA" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,12"/>
                                    <Button x:Name="btnForensicToggleSettings" Content="FORENSIC MODE: OFF" Padding="14,8"
                                            FontSize="12" FontWeight="SemiBold" Cursor="Hand" BorderThickness="1"
                                            Background="#1B5E20" Foreground="#4CAF50" BorderBrush="#2E7D32" HorizontalAlignment="Left">
                                        <Button.Template>
                                            <ControlTemplate TargetType="Button">
                                                <Border x:Name="fsBorder" CornerRadius="4"
                                                        Padding="{TemplateBinding Padding}"
                                                        BorderThickness="{TemplateBinding BorderThickness}"
                                                        Background="{TemplateBinding Background}"
                                                        BorderBrush="{TemplateBinding BorderBrush}">
                                                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                                </Border>
                                                <ControlTemplate.Triggers>
                                                    <Trigger Property="IsMouseOver" Value="True">
                                                        <Setter TargetName="fsBorder" Property="Opacity" Value="0.8"/>
                                                    </Trigger>
                                                    <Trigger Property="IsPressed" Value="True">
                                                        <Setter TargetName="fsBorder" Property="Opacity" Value="0.65"/>
                                                    </Trigger>
                                                </ControlTemplate.Triggers>
                                            </ControlTemplate>
                                        </Button.Template>
                                    </Button>
                                </StackPanel>
                            </Border>

                            <!-- Reports Card -->
                            <Border Background="#252526" CornerRadius="6" Padding="16" BorderBrush="#3E3E3E" BorderThickness="1" Margin="0,0,0,16">
                                <StackPanel>
                                    <TextBlock Text="Reports" FontSize="16" FontWeight="SemiBold" Foreground="White" Margin="0,0,0,8"/>
                                    <TextBlock Text="Generate a forensic integrity report documenting the current state of all tools on the drive, including SHA-256 hashes, for chain-of-custody purposes." Foreground="#AAAAAA" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,12"/>
                                    <Button x:Name="btnForensicReportSettings" Content="Generate Forensic Report" Style="{StaticResource ActionButton}" HorizontalAlignment="Left"/>
                                </StackPanel>
                            </Border>

                            <!-- Tool Discovery Card -->
                            <Border Background="#252526" CornerRadius="6" Padding="16" BorderBrush="#3E3E3E" BorderThickness="1" Margin="0,0,0,16">
                                <StackPanel>
                                    <TextBlock Text="Tool Discovery" FontSize="16" FontWeight="SemiBold" Foreground="White" Margin="0,0,0,8"/>
                                    <TextBlock Text="Scan the drive for executables that are not yet tracked in the tools configuration. Discovered tools can be added to the config for automatic update checking." Foreground="#AAAAAA" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,12"/>
                                    <Button x:Name="btnScanNewToolsSettings" Content="Scan for New Tools" Style="{StaticResource ActionButton}" HorizontalAlignment="Left"/>
                                </StackPanel>
                            </Border>

                            <!-- Export Card -->
                            <Border Background="#252526" CornerRadius="6" Padding="16" BorderBrush="#3E3E3E" BorderThickness="1" Margin="0,0,0,16">
                                <StackPanel>
                                    <TextBlock Text="Export" FontSize="16" FontWeight="SemiBold" Foreground="White" Margin="0,0,0,8"/>
                                    <TextBlock Text="Export the tool inventory as a CSV file for documentation, auditing, or import into spreadsheets. Includes tool name, version, category, status, and paths." Foreground="#AAAAAA" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,12"/>
                                    <Button x:Name="btnExportCsv" Content="Export Tool List (CSV)" Style="{StaticResource ActionButton}" HorizontalAlignment="Left"/>
                                </StackPanel>
                            </Border>

                            <!-- Drive Information Card -->
                            <Border Background="#252526" CornerRadius="6" Padding="16" BorderBrush="#3E3E3E" BorderThickness="1" Margin="0,0,0,16">
                                <StackPanel>
                                    <TextBlock Text="Drive Information" FontSize="16" FontWeight="SemiBold" Foreground="White" Margin="0,0,0,8"/>
                                    <TextBlock x:Name="txtDrivePathSettings" Text="Drive: " Foreground="#AAAAAA" FontSize="12" Margin="0,0,0,4"/>
                                    <TextBlock x:Name="txtToolCountSettings" Text="Tools: " Foreground="#AAAAAA" FontSize="12" Margin="0,0,0,4"/>
                                    <TextBlock x:Name="txtDriveSpaceSettings" Text="Space: " Foreground="#AAAAAA" FontSize="12" Margin="0,0,0,8"/>
                                    <Button x:Name="btnOpenConfig" Content="Open tools-config.json" Style="{StaticResource ActionButton}" HorizontalAlignment="Left" Margin="0,8,0,0"/>
                                    <!-- Drive space bar -->
                                    <Grid Height="8" Margin="0,0,0,4">
                                        <Border Background="#3E3E3E" CornerRadius="4"/>
                                        <Border x:Name="barDriveSpace" Background="#0078D4" CornerRadius="4" HorizontalAlignment="Left" Width="0"/>
                                    </Grid>
                                    <TextBlock x:Name="txtLastCheckedSettings" Text="" Foreground="#666666" FontSize="11" Margin="0,4,0,0"/>
                                </StackPanel>
                            </Border>

                            <!-- Unblock Tools Card -->
                            <Border Background="#252526" CornerRadius="6" Padding="16" BorderBrush="#3E3E3E" BorderThickness="1" Margin="0,0,0,16">
                                <StackPanel>
                                    <TextBlock Text="Unblock Tools" FontSize="16" FontWeight="SemiBold" Foreground="White" Margin="0,0,0,8"/>
                                    <TextBlock Text="Remove Windows SmartScreen blocks (Mark of the Web) from all tool executables on the drive. Downloaded files are often blocked by Windows, preventing them from launching." Foreground="#AAAAAA" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,12"/>
                                    <Button x:Name="btnUnblockAll" Content="Unblock All Tools" Style="{StaticResource ActionButton}" HorizontalAlignment="Left"/>
                                    <TextBlock x:Name="txtUnblockResult" Text="" Foreground="#AAAAAA" FontSize="11" Margin="0,8,0,0"/>
                                </StackPanel>
                            </Border>

                            <!-- Keyboard Shortcuts Card -->
                            <Border Background="#252526" CornerRadius="6" Padding="16" BorderBrush="#3E3E3E" BorderThickness="1" Margin="0,0,0,16">
                                <StackPanel>
                                    <TextBlock Text="Keyboard Shortcuts" FontSize="16" FontWeight="SemiBold" Foreground="White" Margin="0,0,0,10"/>
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="120"/>
                                            <ColumnDefinition Width="*"/>
                                        </Grid.ColumnDefinitions>
                                        <Grid.RowDefinitions>
                                            <RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/>
                                        </Grid.RowDefinitions>
                                        <TextBlock Grid.Row="0" Grid.Column="0" Text="Ctrl+1" Foreground="#0078D4" FontFamily="Consolas" FontSize="12" Margin="0,2"/>
                                        <TextBlock Grid.Row="0" Grid.Column="1" Text="Dashboard" Foreground="#AAAAAA" FontSize="12" Margin="0,2"/>
                                        <TextBlock Grid.Row="1" Grid.Column="0" Text="Ctrl+2" Foreground="#0078D4" FontFamily="Consolas" FontSize="12" Margin="0,2"/>
                                        <TextBlock Grid.Row="1" Grid.Column="1" Text="Update Center" Foreground="#AAAAAA" FontSize="12" Margin="0,2"/>
                                        <TextBlock Grid.Row="2" Grid.Column="0" Text="Ctrl+3" Foreground="#0078D4" FontFamily="Consolas" FontSize="12" Margin="0,2"/>
                                        <TextBlock Grid.Row="2" Grid.Column="1" Text="References" Foreground="#AAAAAA" FontSize="12" Margin="0,2"/>
                                        <TextBlock Grid.Row="3" Grid.Column="0" Text="Ctrl+4" Foreground="#0078D4" FontFamily="Consolas" FontSize="12" Margin="0,2"/>
                                        <TextBlock Grid.Row="3" Grid.Column="1" Text="Settings" Foreground="#AAAAAA" FontSize="12" Margin="0,2"/>
                                        <TextBlock Grid.Row="4" Grid.Column="0" Text="F5 / Ctrl+R" Foreground="#0078D4" FontFamily="Consolas" FontSize="12" Margin="0,2"/>
                                        <TextBlock Grid.Row="4" Grid.Column="1" Text="Check for updates" Foreground="#AAAAAA" FontSize="12" Margin="0,2"/>
                                        <TextBlock Grid.Row="5" Grid.Column="0" Text="Ctrl+F" Foreground="#0078D4" FontFamily="Consolas" FontSize="12" Margin="0,2"/>
                                        <TextBlock Grid.Row="5" Grid.Column="1" Text="Search tools" Foreground="#AAAAAA" FontSize="12" Margin="0,2"/>
                                        <TextBlock Grid.Row="6" Grid.Column="0" Text="Ctrl+L" Foreground="#0078D4" FontFamily="Consolas" FontSize="12" Margin="0,2"/>
                                        <TextBlock Grid.Row="6" Grid.Column="1" Text="Toggle log panel" Foreground="#AAAAAA" FontSize="12" Margin="0,2"/>
                                    </Grid>
                                </StackPanel>
                            </Border>

                        </StackPanel>
                    </ScrollViewer>
                </Grid>

                <!-- ── Panel 4: Linux/macOS References ── -->
                <Grid x:Name="panelReferences" Visibility="Collapsed">
                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Background="#1E1E1E" Padding="24,16">
                        <StackPanel MaxWidth="700" HorizontalAlignment="Left">
                            <TextBlock Text="Linux / macOS Tool Reference" FontSize="20" FontWeight="Bold" Foreground="White" Margin="0,0,0,4"/>
                            <TextBlock Text="These DFIR tools run primarily on Linux or macOS. Click any tool name to open its project page in your browser." Foreground="#AAAAAA" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,20"/>
                            <StackPanel x:Name="pnlLinuxTools"/>
                        </StackPanel>
                    </ScrollViewer>
                </Grid>

            </Grid>
        </Grid>

        <!-- ═══ Row 2: Status Bar (shared) ═══ -->
        <Border Grid.Row="2" Background="#2D2D30" Padding="12,6" BorderBrush="#3E3E3E" BorderThickness="0,1,0,0">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="txtStatus" Grid.Column="0" Text="Ready" FontSize="12"
                           Foreground="#CCCCCC" VerticalAlignment="Center" Margin="0,0,12,0"/>
                <ProgressBar x:Name="progressBar" Grid.Column="1" Height="6"
                             Minimum="0" Maximum="100" Value="0"
                             Background="#3E3E3E" Foreground="#0078D4"
                             BorderThickness="0" VerticalAlignment="Center"/>
                <ToggleButton x:Name="btnToggleLog" Grid.Column="2" Content="&#x25B6; Log" FontSize="11"
                              Background="Transparent" Foreground="#AAAAAA" BorderThickness="0"
                              Cursor="Hand" Padding="8,2" Margin="8,0,0,0"/>
            </Grid>
        </Border>

        <!-- ═══ Row 3: Log Area (collapsed by default) ═══ -->
        <Border x:Name="logPanel" Grid.Row="3" Background="#1A1A1A" Padding="8"
                BorderBrush="#3E3E3E" BorderThickness="0,1,0,0"
                Visibility="Collapsed" MaxHeight="180">
            <TextBox x:Name="txtLog"
                     IsReadOnly="True"
                     TextWrapping="Wrap"
                     VerticalScrollBarVisibility="Auto"
                     Background="#1A1A1A"
                     Foreground="#CCCCCC"
                     BorderThickness="0"
                     FontFamily="Consolas"
                     FontSize="11"
                     AcceptsReturn="True"/>
        </Border>
    </Grid>
</Window>
"@

# ─── Build the Window ────────────────────────────────────────────────────────
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

# ─── Grab Named Controls ────────────────────────────────────────────────────
$txtStatus         = $window.FindName("txtStatus")
$txtSummary        = $window.FindName("txtSummary")
$progressBar       = $window.FindName("progressBar")
$dgTools           = $window.FindName("dgTools")
$btnSelectUpdates  = $window.FindName("btnSelectUpdates")
$btnDeselectAll    = $window.FindName("btnDeselectAll")
$btnUpdateSelected = $window.FindName("btnUpdateSelected")
$btnUpdateAll      = $window.FindName("btnUpdateAll")
$btnRefresh        = $window.FindName("btnRefresh")
$btnToggleLog      = $window.FindName("btnToggleLog")
$btnForensicToggle = $window.FindName("btnForensicToggle")
$btnCancelUpdate   = $window.FindName("btnCancelUpdate")
$btnRetryFailed    = $window.FindName("btnRetryFailed")
$logPanel          = $window.FindName("logPanel")
$txtLog            = $window.FindName("txtLog")

# Cancellation flag for update operations (thread-safe)
$script:UpdateCancelRequested = $false

# Navigation & panels
$panelDashboard    = $window.FindName("panelDashboard")
$panelUpdates      = $window.FindName("panelUpdates")
$panelSettings     = $window.FindName("panelSettings")
$panelReferences   = $window.FindName("panelReferences")
$btnNavDashboard   = $window.FindName("btnNavDashboard")
$btnNavUpdates     = $window.FindName("btnNavUpdates")
$btnNavReferences  = $window.FindName("btnNavReferences")
$btnNavSettings    = $window.FindName("btnNavSettings")
$pnlLinuxTools     = $window.FindName("pnlLinuxTools")

# Dashboard controls
$pnlDashCategories = $window.FindName("pnlDashCategories")
$wpDashTools       = $window.FindName("wpDashTools")
$svDashTools       = $window.FindName("svDashTools")
$txtDashSearch     = $window.FindName("txtDashSearch")
$txtDashToolCount  = $window.FindName("txtDashToolCount")
$btnDashRefresh    = $window.FindName("btnDashRefresh")

# Settings controls
$btnForensicToggleSettings  = $window.FindName("btnForensicToggleSettings")
$btnForensicReportSettings  = $window.FindName("btnForensicReportSettings")
$btnScanNewToolsSettings    = $window.FindName("btnScanNewToolsSettings")
$btnExportCsv               = $window.FindName("btnExportCsv")
$btnOpenConfig              = $window.FindName("btnOpenConfig")
$txtDrivePathSettings       = $window.FindName("txtDrivePathSettings")
$txtToolCountSettings       = $window.FindName("txtToolCountSettings")
$txtDriveSpaceSettings      = $window.FindName("txtDriveSpaceSettings")
$barDriveSpace              = $window.FindName("barDriveSpace")
$txtLastCheckedSettings     = $window.FindName("txtLastCheckedSettings")
$btnUnblockAll              = $window.FindName("btnUnblockAll")
$txtUnblockResult           = $window.FindName("txtUnblockResult")

# ─── State ───────────────────────────────────────────────────────────────────
$script:ToolItems = [System.Collections.ObjectModel.ObservableCollection[ToolItem]]::new()
$dgTools.ItemsSource = $script:ToolItems

# ─── Category Map: derive display category from path prefix ─────────────────
$script:CategoryMap = @{
    '01_Acquisition'      = 'Acquisition'
    '02_Analysis'         = 'Analysis'
    '03_Network'          = 'Network'
    '04_Mobile-Forensics' = 'Mobile'
    '04_Memory'           = 'Memory'
    '05_Registry'         = 'Registry'
    '06_Mobile'           = 'Mobile'
    '07_Malware'          = 'Malware'
    '08_Utilities'        = 'Utilities'
}

function Get-CategoryFromPath {
    param([string]$ToolPath)
    if ([string]::IsNullOrWhiteSpace($ToolPath)) { return "Other" }
    # The path field in config is relative, e.g. "01_Acquisition/FTK Imager"
    $firstSegment = ($ToolPath -split '[/\\]')[0]
    if ($script:CategoryMap.ContainsKey($firstSegment)) {
        return $script:CategoryMap[$firstSegment]
    }
    # Fallback: try to parse prefix pattern NN_Name
    if ($firstSegment -match '^\d+_(.+)$') {
        return $Matches[1]
    }
    return "Other"
}

# ─── Initialize Linux/macOS References Panel ────────────────────────────────
function Initialize-LinuxReferences {
    $pnlLinuxTools.Children.Clear()
    $bc = New-Object System.Windows.Media.BrushConverter

    # Load linux_reference_tools from config
    try {
        $raw    = Get-Content -LiteralPath $script:ConfigPath -Raw -ErrorAction Stop
        $config = $raw | ConvertFrom-Json -ErrorAction Stop
        $linuxTools = $config.linux_reference_tools
    } catch {
        $linuxTools = $null
    }
    if (-not $linuxTools -or $linuxTools.Count -eq 0) { return }

    # Group by category
    $groups = $linuxTools | Group-Object -Property category

    foreach ($group in ($groups | Sort-Object Name)) {
        # Card container
        $card = New-Object System.Windows.Controls.Border
        $card.Background      = $bc.ConvertFrom('#252526')
        $card.CornerRadius    = [System.Windows.CornerRadius]::new(6)
        $card.Padding         = [System.Windows.Thickness]::new(16)
        $card.BorderBrush     = $bc.ConvertFrom('#3E3E3E')
        $card.BorderThickness = [System.Windows.Thickness]::new(1)
        $card.Margin          = [System.Windows.Thickness]::new(0, 0, 0, 16)

        $sp = New-Object System.Windows.Controls.StackPanel

        # Category header
        $header = New-Object System.Windows.Controls.TextBlock
        $header.Text       = $group.Name
        $header.FontSize   = 16
        $header.FontWeight = [System.Windows.FontWeights]::SemiBold
        $header.Foreground = $bc.ConvertFrom('#FFFFFF')
        $header.Margin     = [System.Windows.Thickness]::new(0, 0, 0, 10)
        [void]$sp.Children.Add($header)

        foreach ($tool in $group.Group) {
            # Row: tool name (link) + description
            $row = New-Object System.Windows.Controls.StackPanel
            $row.Orientation = [System.Windows.Controls.Orientation]::Horizontal
            $row.Margin      = [System.Windows.Thickness]::new(0, 3, 0, 3)

            # Clickable tool name
            $link = New-Object System.Windows.Controls.TextBlock
            $link.Text       = $tool.name
            $link.Foreground = $bc.ConvertFrom('#0078D4')
            $link.FontSize   = 13
            $link.FontWeight = [System.Windows.FontWeights]::SemiBold
            $link.Cursor     = [System.Windows.Input.Cursors]::Hand
            $link.Tag        = $tool.url
            $link.Add_MouseLeftButtonUp({
                param($s, $e)
                $url = $s.Tag
                if ($url) { Start-Process $url }
            })
            $link.Add_MouseEnter({
                param($s, $e)
                $s.TextDecorations = [System.Windows.TextDecorations]::Underline
            })
            $link.Add_MouseLeave({
                param($s, $e)
                $s.TextDecorations = $null
            })

            # Separator
            $sep = New-Object System.Windows.Controls.TextBlock
            $sep.Text       = "  -  "
            $sep.Foreground = $bc.ConvertFrom('#666666')
            $sep.FontSize   = 13

            # Description
            $desc = New-Object System.Windows.Controls.TextBlock
            $desc.Text       = $tool.description
            $desc.Foreground = $bc.ConvertFrom('#AAAAAA')
            $desc.FontSize   = 12
            $desc.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

            [void]$row.Children.Add($link)
            [void]$row.Children.Add($sep)
            [void]$row.Children.Add($desc)
            [void]$sp.Children.Add($row)
        }

        $card.Child = $sp
        [void]$pnlLinuxTools.Children.Add($card)
    }
}

# ─── Helper: Unblock files with Mark of the Web ─────────────────────────────
function Unblock-ToolIfNeeded {
    <# Removes the Zone.Identifier ADS (MOTW) that causes Windows SmartScreen
       to block downloaded executables from launching. Returns $true if the file
       was unblocked or had no MOTW, $false if unblock failed. #>
    param([string]$FilePath)
    if (-not (Test-Path -LiteralPath $FilePath)) { return $true }
    try {
        $zone = Get-Content -LiteralPath $FilePath -Stream Zone.Identifier -ErrorAction SilentlyContinue
        if ($zone) {
            if ($script:ForensicModeActive) {
                # Cannot modify files in Forensic Mode
                return $false
            }
            Remove-Item -LiteralPath $FilePath -Stream Zone.Identifier -ErrorAction Stop
            return $true
        }
    } catch {
        return $false
    }
    return $true  # No MOTW present
}

# ─── Helper: Append to Log (thread-safe) ────────────────────────────────────
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "HH:mm:ss"
    $line = "[$timestamp] $Message`r`n"
    $txtLog.AppendText($line)
    $txtLog.ScrollToEnd()
    # Mirror to debug log file
    $level = if ($Message -match '^ERROR|^UPDATE ERROR') { 'ERROR' }
             elseif ($Message -match '^WARNING') { 'WARN' }
             else { 'INFO' }
    Write-DebugLog $Message $level
}

# ─── Helper: Update Status Text (thread-safe) ───────────────────────────────
function Set-StatusText {
    param([string]$Text)
    $txtStatus.Text = $Text
}

# ─── Helper: Update Progress Bar (thread-safe) ──────────────────────────────
function Set-Progress {
    param(
        [double]$Value,
        [bool]$Indeterminate = $false,
        [string]$Color = ''
    )
    $progressBar.IsIndeterminate = $Indeterminate
    $progressBar.Value = $Value
    if ($Color) {
        $progressBar.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)
    }
}

# ─── Helper: Update Drive Space Info ────────────────────────────────────────
function Update-DriveSpaceInfo {
    try {
        $driveLetter = $script:DriveRoot.TrimEnd(':\/')
        $vol = Get-Volume -DriveLetter $driveLetter -ErrorAction Stop
        $usedGB   = [math]::Round(($vol.Size - $vol.SizeRemaining) / 1GB, 1)
        $totalGB  = [math]::Round($vol.Size / 1GB, 1)
        $freeGB   = [math]::Round($vol.SizeRemaining / 1GB, 1)
        $pctUsed  = if ($vol.Size -gt 0) { [math]::Round(($vol.Size - $vol.SizeRemaining) / $vol.Size * 100, 0) } else { 0 }
        $txtDriveSpaceSettings.Text = "Space: $usedGB GB used of $totalGB GB ($freeGB GB free)"
        # Update the space bar width proportionally (max width = parent width)
        $barDriveSpace.Width = [math]::Max(2, $pctUsed / 100.0 * 568)
        # Color: green when < 80%, yellow < 90%, red >= 90%
        if ($pctUsed -ge 90) {
            $barDriveSpace.Background = $script:BrushConverter.ConvertFrom('#FF4444')
        } elseif ($pctUsed -ge 80) {
            $barDriveSpace.Background = $script:BrushConverter.ConvertFrom('#FFD93D')
        } else {
            $barDriveSpace.Background = $script:BrushConverter.ConvertFrom('#0078D4')
        }
    } catch {
        $txtDriveSpaceSettings.Text = "Space: N/A"
    }
}

# ─── Helper: Update Summary Counts ──────────────────────────────────────────
function Update-Summary {
    $upToDate  = @($script:ToolItems | Where-Object { $_.StatusKey -eq "UpToDate"        }).Count
    $available = @($script:ToolItems | Where-Object { $_.StatusKey -eq "UpdateAvailable" }).Count
    $manual    = @($script:ToolItems | Where-Object { $_.StatusKey -eq "ManualCheck"     }).Count
    $errors    = @($script:ToolItems | Where-Object { $_.StatusKey -eq "Error"           }).Count
    $total     = $script:ToolItems.Count

    # Build summary text with status indicator
    $indicator = if ($errors -gt 0) { [char]::ConvertFromUtf32(0x1F534) }         # red circle
                 elseif ($available -gt 0) { [char]::ConvertFromUtf32(0x1F7E1) }  # yellow circle
                 else { [char]::ConvertFromUtf32(0x1F7E2) }                        # green circle

    $parts = @("$indicator $total tools")
    if ($upToDate  -gt 0) { $parts += "$upToDate current"  }
    if ($available -gt 0) { $parts += "$available updates" }
    if ($manual    -gt 0) { $parts += "$manual manual"     }
    if ($errors    -gt 0) { $parts += "$errors errors"     }
    $txtSummary.Text = $parts -join "  |  "

    # Update tool count in Settings if available
    $txtToolCountSettings.Text = "Tools: $total tracked in config ($upToDate current, $available updates)"
}

# ─── Helper: Update Forensic Mode UI ─────────────────────────────────────────
$script:BrushConverter = New-Object System.Windows.Media.BrushConverter

function Update-ForensicModeUI {
    if ($script:ForensicModeActive) {
        # ON state: red/locked - header badge
        $btnForensicToggle.Content    = "FORENSIC MODE: ON"
        $btnForensicToggle.Background = $script:BrushConverter.ConvertFrom("#7B1F1F")
        $btnForensicToggle.Foreground = $script:BrushConverter.ConvertFrom("#FF8A80")
        $btnForensicToggle.BorderBrush = $script:BrushConverter.ConvertFrom("#B71C1C")

        # Settings panel toggle button
        $btnForensicToggleSettings.Content    = "FORENSIC MODE: ON"
        $btnForensicToggleSettings.Background = $script:BrushConverter.ConvertFrom("#7B1F1F")
        $btnForensicToggleSettings.Foreground = $script:BrushConverter.ConvertFrom("#FF8A80")
        $btnForensicToggleSettings.BorderBrush = $script:BrushConverter.ConvertFrom("#B71C1C")

        # Disable all modification buttons
        $btnSelectUpdates.IsEnabled  = $false
        $btnDeselectAll.IsEnabled    = $false
        $btnUpdateSelected.IsEnabled = $false
        $btnUpdateAll.IsEnabled      = $false
        $btnRefresh.IsEnabled        = $false
        $btnScanNewToolsSettings.IsEnabled = $false
        $txtStatus.Text = "Forensic Mode active - drive is read-only. Updates are disabled."
    } else {
        # OFF state: green/unlocked - header badge
        $btnForensicToggle.Content    = "FORENSIC MODE: OFF"
        $btnForensicToggle.Background = $script:BrushConverter.ConvertFrom("#1B5E20")
        $btnForensicToggle.Foreground = $script:BrushConverter.ConvertFrom("#4CAF50")
        $btnForensicToggle.BorderBrush = $script:BrushConverter.ConvertFrom("#2E7D32")

        # Settings panel toggle button
        $btnForensicToggleSettings.Content    = "FORENSIC MODE: OFF"
        $btnForensicToggleSettings.Background = $script:BrushConverter.ConvertFrom("#1B5E20")
        $btnForensicToggleSettings.Foreground = $script:BrushConverter.ConvertFrom("#4CAF50")
        $btnForensicToggleSettings.BorderBrush = $script:BrushConverter.ConvertFrom("#2E7D32")

        # Enable buttons
        $btnSelectUpdates.IsEnabled  = $true
        $btnDeselectAll.IsEnabled    = $true
        $btnUpdateSelected.IsEnabled = $true
        $btnUpdateAll.IsEnabled      = $true
        $btnRefresh.IsEnabled        = $true
        $btnScanNewToolsSettings.IsEnabled = $true
        $txtStatus.Text = "Ready"
    }
}

# ─── Helper: Get disk number for write protection ────────────────────────────
function Get-DfirDiskNumber {
    $driveLetter = $script:DriveRoot.TrimEnd(':\/')
    try {
        $partition = Get-Partition -DriveLetter $driveLetter -ErrorAction Stop
        return $partition.DiskNumber
    } catch { }
    # Fallback: WMI
    try {
        $wmiParts = Get-WmiObject -Query "ASSOCIATORS OF {Win32_LogicalDisk.DeviceID='${driveLetter}:'} WHERE AssocClass=Win32_LogicalDiskToPartition" -ErrorAction Stop
        foreach ($p in $wmiParts) {
            $wmiDisks = Get-WmiObject -Query "ASSOCIATORS OF {Win32_DiskPartition.DeviceID='$($p.DeviceID)'} WHERE AssocClass=Win32_DiskDriveToDiskPartition" -ErrorAction Stop
            foreach ($d in $wmiDisks) { return $d.Index }
        }
    } catch { }
    return $null
}

# ─── Helper: Check if running as administrator ──────────────────────────────
function Test-IsAdmin {
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

# ─── Helper: Set disk write protection via diskpart ──────────────────────────
function Set-WriteProtection {
    param([bool]$Enable)
    $diskNum = Get-DfirDiskNumber
    if ($null -eq $diskNum) {
        Write-Log "WARNING: Could not find disk number for write protection."
        return $false
    }

    # If already admin, try directly first
    if (Test-IsAdmin) {
        try {
            Set-Disk -Number $diskNum -IsReadOnly $Enable -ErrorAction Stop
            Write-Log "Write protection $(if ($Enable) {'enabled'} else {'disabled'}) via Set-Disk (Disk #$diskNum)."
            return $true
        } catch {
            Write-Log "Set-Disk failed: $($_.Exception.Message). Trying diskpart..."
        }

        try {
            $action = if ($Enable) { 'attributes disk set readonly' } else { 'attributes disk clear readonly' }
            $dpScript = Join-Path $env:TEMP 'dfir-wp-toggle.txt'
            @("select disk $diskNum", $action) | Set-Content -Path $dpScript -Encoding ASCII
            $output = & diskpart /s $dpScript 2>&1
            Remove-Item -LiteralPath $dpScript -Force -ErrorAction SilentlyContinue
            foreach ($line in $output) {
                if ($line -match 'successfully') {
                    Write-Log "Write protection $(if ($Enable) {'enabled'} else {'disabled'}) via diskpart (Disk #$diskNum)."
                    return $true
                }
            }
        } catch {
            Write-Log "diskpart (direct) failed: $($_.Exception.Message)"
        }
        return $false
    }

    # Not admin: launch an elevated process to set write protection
    Write-Log "Not running as admin. Requesting elevation for write protection..."
    try {
        $resultFile = Join-Path $env:TEMP 'dfir-wp-result.txt'
        if (Test-Path $resultFile) { Remove-Item -LiteralPath $resultFile -Force }

        $elevatedScript = @"
try {
    Set-Disk -Number $diskNum -IsReadOnly `$$Enable -ErrorAction Stop
    'SUCCESS' | Set-Content -Path '$($resultFile -replace "'","''")' -Encoding ASCII
} catch {
    try {
        `$action = if (`$$Enable) { 'attributes disk set readonly' } else { 'attributes disk clear readonly' }
        `$dpScript = Join-Path `$env:TEMP 'dfir-wp-toggle.txt'
        @("select disk $diskNum", `$action) | Set-Content -Path `$dpScript -Encoding ASCII
        `$output = & diskpart /s `$dpScript 2>&1
        Remove-Item -LiteralPath `$dpScript -Force -ErrorAction SilentlyContinue
        `$found = `$false
        foreach (`$line in `$output) { if (`$line -match 'successfully') { `$found = `$true; break } }
        if (`$found) { 'SUCCESS' | Set-Content -Path '$($resultFile -replace "'","''")' -Encoding ASCII }
        else { 'FAIL' | Set-Content -Path '$($resultFile -replace "'","''")' -Encoding ASCII }
    } catch {
        'FAIL' | Set-Content -Path '$($resultFile -replace "'","''")' -Encoding ASCII
    }
}
"@

        $encodedCmd = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($elevatedScript))

        $proc = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedCmd `
            -Verb RunAs -WindowStyle Hidden -Wait -PassThru -ErrorAction Stop

        # Read result
        if ((Test-Path $resultFile) -and ((Get-Content -LiteralPath $resultFile -Raw).Trim() -eq 'SUCCESS')) {
            Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue
            Write-Log "Write protection $(if ($Enable) {'enabled'} else {'disabled'}) via elevated process (Disk #$diskNum)."
            return $true
        }
        Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue
        Write-Log "Elevated write protection command did not succeed."
    } catch {
        if ($_.Exception.Message -match 'canceled by the user|was cancelled') {
            Write-Log "User declined UAC elevation for write protection."
        } else {
            Write-Log "Elevation failed: $($_.Exception.Message)"
        }
    }
    return $false
}

# ─── Helper: Toggle Forensic Mode ────────────────────────────────────────────
function Toggle-ForensicMode {
    if ($script:ForensicModeActive) {
        # ── Turning OFF ──
        $confirm = [System.Windows.MessageBox]::Show(
            "Disable Forensic Mode?`n`nThis will:`n  - Remove drive write protection`n  - Allow the updater to modify tools on this drive`n`nOnly disable on YOUR workstation, never on a target/evidence system.",
            "Disable Forensic Mode",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning
        )
        if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }

        Write-Log "Disabling Forensic Mode..."

        # Remove write protection first (while flag still exists)
        $wpResult = Set-WriteProtection -Enable $false
        if (-not $wpResult) {
            Write-Log "WARNING: Could not remove write protection. You may need admin privileges."
            $proceed = [System.Windows.MessageBox]::Show(
                "Could not remove disk write protection.`nThis may require administrator privileges.`n`nWould you like to disable Forensic Mode anyway?`n(The flag file may fail to delete if the drive is still read-only.)",
                "Write Protection Warning",
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Warning
            )
            if ($proceed -ne [System.Windows.MessageBoxResult]::Yes) { return }
        }

        # Remove flag file
        try {
            if (Test-Path -LiteralPath $script:ForensicModeFile) {
                Remove-Item -LiteralPath $script:ForensicModeFile -Force -ErrorAction Stop
            }
            $script:ForensicModeActive = $false
            Write-Log "Forensic Mode: OFF"
        } catch {
            Write-Log "ERROR: Failed to remove forensic mode flag: $($_.Exception.Message)"
            [System.Windows.MessageBox]::Show(
                "Failed to remove the Forensic Mode flag file.`nThe drive may still be write-protected.`n`n$($_.Exception.Message)",
                "Error",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            )
            return
        }
    } else {
        # ── Turning ON ──
        $confirm = [System.Windows.MessageBox]::Show(
            "Enable Forensic Mode?`n`nThis will:`n  - Write-protect the drive (read-only)`n  - Block all updates and modifications`n`nUse this before connecting to a target/evidence system.",
            "Enable Forensic Mode",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question
        )
        if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }

        Write-Log "Enabling Forensic Mode..."

        # Create flag file first (before write protection)
        try {
            [System.IO.File]::WriteAllText($script:ForensicModeFile, "Forensic Mode enabled at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') by $env:USERNAME on $env:COMPUTERNAME`n")
            Write-Log "Forensic mode flag created."
        } catch {
            Write-Log "ERROR: Failed to create forensic mode flag: $($_.Exception.Message)"
            [System.Windows.MessageBox]::Show(
                "Failed to create the Forensic Mode flag file.`n`n$($_.Exception.Message)",
                "Error",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            )
            return
        }

        # Enable write protection
        $wpResult = Set-WriteProtection -Enable $true
        if (-not $wpResult) {
            Write-Log "WARNING: Could not enable write protection. You may need admin privileges."
            [System.Windows.MessageBox]::Show(
                "Forensic Mode flag was set, but disk write protection could not be enabled.`nThis may require administrator privileges.`n`nThe updater will still be blocked, but the drive is not hardware-protected.",
                "Write Protection Warning",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Warning
            )
        }

        $script:ForensicModeActive = $true
        Write-Log "Forensic Mode: ON"

        # Auto-generate forensic report on activation
        Write-Log "Auto-generating forensic integrity report..."
        $reportPath = New-ForensicReport
        if ($reportPath) {
            [System.Windows.MessageBox]::Show(
                "Forensic Mode is now active.`n`nAn integrity report has been saved to:`n$reportPath`n`nThis report documents the drive state for chain-of-custody purposes.",
                "Forensic Mode Enabled",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Information
            )
        }
    }

    Update-ForensicModeUI
}

# ─── Helper: Generate Forensic Report ─────────────────────────────────────────
function New-ForensicReport {
    $timestamp    = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $reportDir    = Join-Path $script:DriveRoot 'DFIR-Updater\forensic-reports'
    $reportFile   = Join-Path $reportDir "Forensic-Report_$timestamp.txt"
    $separator    = '=' * 72
    $subSeparator = '-' * 72

    # ── Collect disk information ──
    $driveLetter = $script:DriveRoot.TrimEnd(':\/')
    $diskInfo     = @{ Number = 'N/A'; Model = 'N/A'; Serial = 'N/A'; Size = 'N/A'; BusType = 'N/A'; MediaType = 'N/A'; IsReadOnly = 'N/A'; PartitionStyle = 'N/A' }
    $volumeInfo   = @{ Label = 'N/A'; FileSystem = 'N/A'; Size = 'N/A'; FreeSpace = 'N/A'; DriveType = 'N/A' }

    try {
        $partition = Get-Partition -DriveLetter $driveLetter -ErrorAction Stop
        $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
        $diskInfo.Number         = $disk.Number
        $diskInfo.Model          = $disk.FriendlyName
        $diskInfo.Serial         = $disk.SerialNumber
        $diskInfo.Size           = "$([math]::Round($disk.Size / 1GB, 2)) GB ($($disk.Size) bytes)"
        $diskInfo.BusType        = $disk.BusType
        $diskInfo.MediaType      = $disk.MediaType
        $diskInfo.IsReadOnly     = $disk.IsReadOnly
        $diskInfo.PartitionStyle = $disk.PartitionStyle
    } catch {
        # Fallback: WMI
        try {
            $wmiParts = Get-WmiObject -Query "ASSOCIATORS OF {Win32_LogicalDisk.DeviceID='${driveLetter}:'} WHERE AssocClass=Win32_LogicalDiskToPartition" -ErrorAction Stop
            foreach ($p in $wmiParts) {
                $wmiDisks = Get-WmiObject -Query "ASSOCIATORS OF {Win32_DiskPartition.DeviceID='$($p.DeviceID)'} WHERE AssocClass=Win32_DiskDriveToDiskPartition" -ErrorAction Stop
                foreach ($d in $wmiDisks) {
                    $diskInfo.Number = $d.Index
                    $diskInfo.Model  = $d.Caption
                    $diskInfo.Serial = $d.SerialNumber
                    $diskInfo.Size   = "$([math]::Round($d.Size / 1GB, 2)) GB ($($d.Size) bytes)"
                    $diskInfo.BusType    = $d.InterfaceType
                    $diskInfo.MediaType  = $d.MediaType
                    break
                }
                break
            }
        } catch { }
    }

    try {
        $vol = Get-Volume -DriveLetter $driveLetter -ErrorAction Stop
        $volumeInfo.Label      = $vol.FileSystemLabel
        $volumeInfo.FileSystem = $vol.FileSystem
        $volumeInfo.Size       = "$([math]::Round($vol.Size / 1GB, 2)) GB ($($vol.Size) bytes)"
        $volumeInfo.FreeSpace  = "$([math]::Round($vol.SizeRemaining / 1GB, 2)) GB ($($vol.SizeRemaining) bytes)"
        $volumeInfo.DriveType  = $vol.DriveType
    } catch {
        try {
            $wmiVol = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='${driveLetter}:'" -ErrorAction Stop
            $volumeInfo.Label      = $wmiVol.VolumeName
            $volumeInfo.FileSystem = $wmiVol.FileSystem
            $volumeInfo.Size       = "$([math]::Round($wmiVol.Size / 1GB, 2)) GB ($($wmiVol.Size) bytes)"
            $volumeInfo.FreeSpace  = "$([math]::Round($wmiVol.FreeSpace / 1GB, 2)) GB ($($wmiVol.FreeSpace) bytes)"
            $volumeInfo.DriveType  = $wmiVol.DriveType
        } catch { }
    }

    # ── Forensic mode flag details ──
    $flagDetails = 'Flag file does not exist (Forensic Mode OFF)'
    if (Test-Path -LiteralPath $script:ForensicModeFile) {
        try {
            $flagItem = Get-Item -LiteralPath $script:ForensicModeFile -ErrorAction Stop
            $flagContent = Get-Content -LiteralPath $script:ForensicModeFile -Raw -ErrorAction SilentlyContinue
            $flagDetails = @(
                "Flag file    : $($script:ForensicModeFile)"
                "  Created    : $($flagItem.CreationTime.ToString('yyyy-MM-dd HH:mm:ss'))"
                "  Modified   : $($flagItem.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
                "  Contents   : $($flagContent.Trim())"
            ) -join "`r`n"
        } catch {
            $flagDetails = "Flag file exists but could not be read: $($_.Exception.Message)"
        }
    }

    # ── Write protection log history ──
    $wpLogContent = '(No write-protect log found)'
    $wpLogPath = Join-Path $script:ScriptDir 'write-protect-logs\write-protect.log'
    if (Test-Path -LiteralPath $wpLogPath) {
        try {
            $wpLogContent = Get-Content -LiteralPath $wpLogPath -Raw -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($wpLogContent)) { $wpLogContent = '(Log file is empty)' }
        } catch { $wpLogContent = "(Could not read log: $($_.Exception.Message))" }
    }

    # ── Tool inventory with hashes ──
    $toolInventory = [System.Text.StringBuilder]::new()
    $configPath = $script:ConfigPath
    $toolEntries = @()
    if (Test-Path -LiteralPath $configPath) {
        try {
            $config = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $toolEntries = $config.tools
        } catch { }
    }

    if ($toolEntries.Count -gt 0) {
        $toolNum = 0
        foreach ($t in $toolEntries) {
            $toolNum++
            $fullPath = Join-Path $script:DriveRoot $t.path
            $exists = Test-Path -LiteralPath $fullPath
            [void]$toolInventory.AppendLine("  $toolNum. $($t.name)")
            [void]$toolInventory.AppendLine("     Path       : $($t.path)")
            [void]$toolInventory.AppendLine("     Version    : $(if ($t.current_version) { $t.current_version } else { 'Unknown' })")
            [void]$toolInventory.AppendLine("     Source     : $($t.source_type)")
            [void]$toolInventory.AppendLine("     Present    : $exists")
            if ($exists) {
                $item = Get-Item -LiteralPath $fullPath -ErrorAction SilentlyContinue
                if ($item -and -not $item.PSIsContainer) {
                    # Single file: hash it
                    try {
                        $hash = Get-FileHash -LiteralPath $fullPath -Algorithm SHA256 -ErrorAction Stop
                        [void]$toolInventory.AppendLine("     SHA-256    : $($hash.Hash)")
                    } catch {
                        [void]$toolInventory.AppendLine("     SHA-256    : (could not compute)")
                    }
                    [void]$toolInventory.AppendLine("     Size       : $($item.Length) bytes")
                    [void]$toolInventory.AppendLine("     Modified   : $($item.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))")
                } elseif ($item -and $item.PSIsContainer) {
                    # Directory: count contents and hash key executables
                    $files = Get-ChildItem -LiteralPath $fullPath -Recurse -File -ErrorAction SilentlyContinue
                    $fileCount = @($files).Count
                    $dirSize = ($files | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                    [void]$toolInventory.AppendLine("     Files      : $fileCount")
                    [void]$toolInventory.AppendLine("     Total Size : $([math]::Round($dirSize / 1MB, 2)) MB ($dirSize bytes)")
                    [void]$toolInventory.AppendLine("     Modified   : $($item.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))")
                    # Hash primary executable if found
                    $mainExe = $files | Where-Object { $_.Extension -eq '.exe' } | Sort-Object Length -Descending | Select-Object -First 1
                    if ($mainExe) {
                        try {
                            $hash = Get-FileHash -LiteralPath $mainExe.FullName -Algorithm SHA256 -ErrorAction Stop
                            [void]$toolInventory.AppendLine("     Primary EXE: $($mainExe.Name)")
                            [void]$toolInventory.AppendLine("     EXE SHA-256: $($hash.Hash)")
                        } catch { }
                    }
                }
            }
            [void]$toolInventory.AppendLine('')
        }
    } else {
        [void]$toolInventory.AppendLine('  (No tool configuration found)')
    }

    # ── Compute hash of the config file itself ──
    $configHash = 'N/A'
    if (Test-Path -LiteralPath $configPath) {
        try {
            $configHash = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256 -ErrorAction Stop).Hash
        } catch { }
    }

    # ── Build the report ──
    $report = @"
$separator
  DFIR DRIVE FORENSIC INTEGRITY REPORT
$separator

  Report Generated  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss (zzz)')
  Report File       : $reportFile

$separator
  SECTION 1: EXAMINER / SYSTEM INFORMATION
$subSeparator

  Computer Name     : $env:COMPUTERNAME
  Username          : $env:USERNAME
  User Domain       : $env:USERDOMAIN
  OS                : $((Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption)
  OS Version        : $([System.Environment]::OSVersion.VersionString)
  PowerShell Version: $($PSVersionTable.PSVersion)
  System Time       : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  UTC Time          : $(([DateTime]::UtcNow).ToString('yyyy-MM-dd HH:mm:ss'))
  Time Zone         : $([TimeZoneInfo]::Local.DisplayName)

$separator
  SECTION 2: DFIR DRIVE IDENTIFICATION
$subSeparator

  Drive Letter      : ${driveLetter}:\
  Drive Root        : $($script:DriveRoot)
  Volume Label      : $($volumeInfo.Label)
  File System       : $($volumeInfo.FileSystem)
  Volume Size       : $($volumeInfo.Size)
  Free Space        : $($volumeInfo.FreeSpace)
  Drive Type        : $($volumeInfo.DriveType)

  Disk Number       : $($diskInfo.Number)
  Disk Model        : $($diskInfo.Model)
  Disk Serial No.   : $($diskInfo.Serial)
  Disk Total Size   : $($diskInfo.Size)
  Bus Type          : $($diskInfo.BusType)
  Media Type        : $($diskInfo.MediaType)
  Partition Style   : $($diskInfo.PartitionStyle)

$separator
  SECTION 3: FORENSIC MODE STATUS
$subSeparator

  Forensic Mode     : $(if ($script:ForensicModeActive) { 'ON (Active)' } else { 'OFF (Inactive)' })
  Write Protected   : $($diskInfo.IsReadOnly)

  $flagDetails

$separator
  SECTION 4: WRITE PROTECTION AUDIT LOG
$subSeparator

$wpLogContent

$separator
  SECTION 5: TOOL INVENTORY AND INTEGRITY HASHES
$subSeparator

  Config File       : $configPath
  Config SHA-256    : $configHash
  Tools on Drive    :

$($toolInventory.ToString())
$separator
  SECTION 6: CHAIN OF CUSTODY NOTES
$subSeparator

  Case Number       : ________________________________________

  Evidence Item No. : ________________________________________

  Examiner Name     : ________________________________________

  Date Received     : ________________________________________

  Received From     : ________________________________________

  Purpose           : ________________________________________

  Notes:




  ________________________________________________________________

  ________________________________________________________________

  ________________________________________________________________

  ________________________________________________________________


$separator
  SECTION 7: VERIFICATION
$subSeparator

  I verify that the information in this report accurately reflects
  the state of the DFIR drive at the time of report generation.

  Examiner Signature: ________________________________________

  Date              : ________________________________________

  Witness Signature : ________________________________________

  Date              : ________________________________________

$separator
  END OF REPORT
  Generated by DFIR Drive Updater $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
$separator
"@

    # ── Write the report ──
    try {
        if (-not (Test-Path -LiteralPath $reportDir)) {
            New-Item -Path $reportDir -ItemType Directory -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($reportFile, $report)
        Write-Log "Forensic report saved: $reportFile"
        return $reportFile
    } catch {
        Write-Log "ERROR: Failed to save forensic report: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show(
            "Failed to save the forensic report.`nThe drive may be write-protected.`n`n$($_.Exception.Message)",
            "Report Error",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        )
        return $null
    }
}

# ─── Helper: Test internet connectivity ──────────────────────────────────────
function Test-InternetConnection {
    try {
        $request = [System.Net.WebRequest]::Create("https://api.github.com")
        $request.Timeout = 5000
        $request.Method  = "HEAD"
        if ($request -is [System.Net.HttpWebRequest]) {
            $request.UserAgent = "DFIR-Updater/1.0"
        }
        $response = $request.GetResponse()
        $response.Close()
        return $true
    } catch {
        return $false
    }
}

# ─── Background Check for Updates ────────────────────────────────────────────
function Start-UpdateCheck {
    # Guard: RunspacePool must be ready
    if (-not $script:RunspacePool -or $script:RunspacePool.RunspacePoolStateInfo.State -ne 'Opened') {
        Write-Log "ERROR: RunspacePool is not available. Cannot check for updates."
        Set-StatusText "Background engine failed to start. Try restarting the application."
        return
    }

    # Disable buttons during check
    $btnRefresh.IsEnabled        = $false
    $btnUpdateSelected.IsEnabled = $false
    $btnUpdateAll.IsEnabled      = $false
    $btnSelectUpdates.IsEnabled  = $false

    Set-StatusText "Checking for updates..."
    Set-Progress -Value 0 -Indeterminate $true
    Write-Log "Starting update check for drive: $script:DriveRoot"

    # Clear existing items
    $script:ToolItems.Clear()

    # ── First, load the config on the UI thread to populate the grid immediately ──
    $configTools = $null
    try {
        if ($script:HasModule) {
            $config = Get-ToolConfig -Path $script:ConfigPath
            $configTools = $config.tools
        } elseif (Test-Path $script:ConfigPath) {
            $raw = Get-Content -LiteralPath $script:ConfigPath -Raw -ErrorAction Stop
            $config = $raw | ConvertFrom-Json -ErrorAction Stop
            $configTools = $config.tools
        }
    } catch {
        Write-Log "ERROR: Failed to load config: $_"
    }

    # Fallback sample data if no config found
    if (-not $configTools) {
        Write-Log "WARNING: No tools-config.json found. Using sample data."
        $configTools = @(
            [PSCustomObject]@{ name="FTK Imager";   path="01_Acquisition/FTK Imager";  source_type="web";    current_version=$null;   install_type="manual"; download_url="https://www.exterro.com/ftk-imager"; github_repo=$null; github_asset_pattern=$null; notes="Manual download" }
            [PSCustomObject]@{ name="Autopsy";      path="02_Analysis/Autopsy";        source_type="github"; current_version="4.21.0"; install_type="extract_zip"; download_url=$null; github_repo="sleuthkit/autopsy"; github_asset_pattern="autopsy.*\\.zip"; notes="" }
            [PSCustomObject]@{ name="Wireshark";    path="03_Network/Wireshark";       source_type="github"; current_version="4.2.3";  install_type="manual"; download_url=$null; github_repo="wireshark/wireshark"; github_asset_pattern=$null; notes="" }
            [PSCustomObject]@{ name="Volatility3";  path="04_Memory/Volatility3";      source_type="github"; current_version="2.5.0";  install_type="extract_zip"; download_url=$null; github_repo="volatilityfoundation/volatility3"; github_asset_pattern=$null; notes="" }
            [PSCustomObject]@{ name="RegRipper";    path="05_Registry/RegRipper";      source_type="github"; current_version="3.0";    install_type="extract_zip"; download_url=$null; github_repo="keydet89/RegRipper3.0"; github_asset_pattern=$null; notes="" }
        )
    }

    # Populate the grid with "Checking..." state
    foreach ($t in $configTools) {
        $item = New-Object ToolItem
        $item.Name           = $t.name
        $item.Category       = Get-CategoryFromPath $t.path
        $item.CurrentVersion = if ($t.current_version) { $t.current_version } else { "Unknown" }
        $item.LatestVersion  = "Checking..."
        $item.Status         = "Checking..."
        $item.StatusKey      = "Checking"
        $item.ToolPath       = $t.path
        $item.SourceType     = $t.source_type
        $item.InstallType    = $t.install_type
        $item.DownloadUrl    = $t.download_url
        $item.Notes          = $t.notes
        $item.IsSelected     = $false
        $script:ToolItems.Add($item)
    }

    Write-Log "Loaded $($configTools.Count) tools from configuration."

    # ── Run the actual version checks using the pre-opened RunspacePool ──
    $psCmd = [PowerShell]::Create()
    $psCmd.RunspacePool = $script:RunspacePool

    [void]$psCmd.AddScript({
        param($DriveRoot, $ModulePath, $PkgManagerPath, $ConfigPath, $HasModule, $HasPkgManager, $ToolItems, $Dispatcher, $DebugLogPath)
        # Helper: write to debug log from the check runspace
        function Write-RsDebugLog ($msg, $lvl) {
            if (-not $DebugLogPath) { return }
            $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
            try { [System.IO.File]::AppendAllText($DebugLogPath, "$ts [$lvl] [CheckRunspace] $msg`r`n") } catch { }
        }
        # Load Package-Manager module for PM-based version lookups
        if ($HasPkgManager) {
            try { . $PkgManagerPath; Set-StrictMode -Off } catch { }
        }
        # Check internet first
        $hasInternet = $true
        try {
            $req = [System.Net.WebRequest]::Create("https://api.github.com")
            $req.Timeout = 5000
            $req.Method  = "HEAD"
            # User-Agent is a restricted header; use the dedicated property
            if ($req -is [System.Net.HttpWebRequest]) {
                $req.UserAgent = "DFIR-Updater/1.0"
            }
            $resp = $req.GetResponse()
            $resp.Close()
        } catch {
            $hasInternet = $false
        }

        if (-not $hasInternet) {
            try {
                [void]$Dispatcher.BeginInvoke([Action]{
                    foreach ($item in $ToolItems) {
                        $item.LatestVersion = "No Internet"
                        $item.Status        = "No connection"
                        $item.StatusKey     = "Error"
                    }
                }.GetNewClosure())
            } catch {
                # Dispatcher call failed; items will remain in Checking state
            }
            return @{ Success = $false; Error = "NoInternet" }
        }

        # Use the module if available
        if ($HasModule) {
            try {
                . $ModulePath
                Set-StrictMode -Off

                $results = Get-AllUpdateStatus -ConfigPath $ConfigPath
                Write-RsDebugLog "Update check returned $(@($results).Count) results" 'INFO'
                foreach ($r in $results) {
                    Write-RsDebugLog "  $($r.ToolName): Latest=$($r.LatestVersion) Update=$($r.UpdateAvailable) Source=$($r.SourceType) Notes=$($r.Notes)" 'DEBUG'
                }

                # ── PM version supplementation ──
                # For tools that the standard checker couldn't resolve, try
                # package managers as a fallback version source.
                $pmSupplemented = @{}
                if ($HasPkgManager) {
                    $configJson = Get-Content $ConfigPath -Raw | ConvertFrom-Json
                    foreach ($r in $results) {
                        $needsPM = (-not $r.UpdateAvailable) -and (-not $r.LatestVersion -or $r.LatestVersion -eq 'N/A')
                        $isError = $r.Notes -and $r.Notes -match 'error|fail'
                        if (-not $needsPM -and -not $isError) { continue }

                        $cfg = $configJson.tools | Where-Object { $_.name -eq $r.ToolName } | Select-Object -First 1
                        if (-not $cfg) { continue }

                        $pmVer = $null
                        if ($cfg.scoop_id -and (Test-PackageManager 'scoop')) {
                            $pmVer = Get-ScoopPackageVersion -PackageId $cfg.scoop_id
                            Write-RsDebugLog "  PM scoop '$($cfg.scoop_id)' for '$($r.ToolName)': $pmVer" 'DEBUG'
                        }
                        if (-not $pmVer -and $cfg.winget_id -and (Test-PackageManager 'winget')) {
                            $pmVer = Get-WingetPackageVersion -PackageId $cfg.winget_id
                            Write-RsDebugLog "  PM winget '$($cfg.winget_id)' for '$($r.ToolName)': $pmVer" 'DEBUG'
                        }

                        if ($pmVer) {
                            $pmSupplemented[$r.ToolName] = $pmVer
                            Write-RsDebugLog "  PM resolved '$($r.ToolName)' -> $pmVer" 'INFO'
                        }
                    }
                }

                # Map results back to the UI items
                [void]$Dispatcher.BeginInvoke([Action]{
                    foreach ($r in $results) {
                        $matchItem = $ToolItems | Where-Object { $_.Name -eq $r.ToolName } | Select-Object -First 1
                        if (-not $matchItem) { continue }

                        if ($r.LatestVersion) {
                            $matchItem.LatestVersion = $r.LatestVersion
                        }

                        if ($r.DownloadUrl) {
                            $matchItem.DownloadUrl = $r.DownloadUrl
                        }

                        if ($r.Notes) {
                            $matchItem.Notes = $r.Notes
                        }

                        # Check if PM provided a version where normal check couldn't
                        $pmVer = $pmSupplemented[$r.ToolName]

                        # Determine status
                        if ($r.UpdateAvailable -eq $true) {
                            $matchItem.Status    = "Update available"
                            $matchItem.StatusKey = "UpdateAvailable"
                        } elseif ($r.UpdateAvailable -eq $false) {
                            $matchItem.Status    = "Up to date"
                            $matchItem.StatusKey = "UpToDate"
                        } elseif ($pmVer) {
                            # PM resolved a version — compare with current
                            $matchItem.LatestVersion = $pmVer
                            $curVer = $matchItem.CurrentVersion
                            if ($curVer -and $curVer -ne 'Unknown' -and $curVer -ne 'N/A') {
                                if ($pmVer -eq $curVer) {
                                    $matchItem.Status    = "Up to date"
                                    $matchItem.StatusKey = "UpToDate"
                                } else {
                                    # Normalize: strip leading 'v' for comparison
                                    $normCur = ($curVer -replace '^v','').Trim()
                                    $normPm  = ($pmVer  -replace '^v','').Trim()
                                    if ($normCur -eq $normPm) {
                                        $matchItem.Status    = "Up to date"
                                        $matchItem.StatusKey = "UpToDate"
                                    } else {
                                        $matchItem.Status    = "Update available"
                                        $matchItem.StatusKey = "UpdateAvailable"
                                    }
                                }
                            } else {
                                # No current version known — show PM version as latest, suggest verify
                                $matchItem.Status    = "Latest: $pmVer"
                                $matchItem.StatusKey = "ManualCheck"
                            }
                        } elseif ($r.SourceType -eq 'web' -and $r.LatestVersion) {
                            $matchItem.LatestVersion = $r.LatestVersion
                            $matchItem.Status        = "Verify version"
                            $matchItem.StatusKey     = "ManualCheck"
                        } elseif ($r.SourceType -eq 'web') {
                            $matchItem.LatestVersion = "N/A"
                            $matchItem.Status        = "Check manually"
                            $matchItem.StatusKey     = "ManualCheck"
                        } elseif ($r.Notes -and $r.Notes -match 'error|fail') {
                            $matchItem.LatestVersion = "N/A"
                            $matchItem.Status        = "Check manually"
                            $matchItem.StatusKey     = "ManualCheck"
                        } else {
                            $matchItem.LatestVersion = "N/A"
                            $matchItem.Status        = "Check manually"
                            $matchItem.StatusKey     = "ManualCheck"
                        }
                    }
                }.GetNewClosure())

                return @{ Success = $true; Count = @($results).Count }
            } catch {
                $errMsg = $_.Exception.Message
                try {
                    [void]$Dispatcher.BeginInvoke([Action]{
                        foreach ($item in $ToolItems) {
                            if ($item.StatusKey -eq "Checking") {
                                $item.LatestVersion = "Error"
                                $item.Status        = "Module error"
                                $item.StatusKey     = "Error"
                            }
                        }
                    }.GetNewClosure())
                } catch {
                    # Dispatcher call failed in error handler
                }
                return @{ Success = $false; Error = $errMsg }
            }
        }
        else {
            # No module: simulate with sample results for preview mode
            [void]$Dispatcher.BeginInvoke([Action]{
                foreach ($item in $ToolItems) {
                    if ($item.SourceType -eq 'web') {
                        $item.LatestVersion = "N/A"
                        $item.Status        = "Check manually  ?"
                        $item.StatusKey     = "ManualCheck"
                    } elseif ($item.CurrentVersion -eq "Unknown") {
                        $item.LatestVersion = "N/A"
                        $item.Status        = "Check manually  ?"
                        $item.StatusKey     = "ManualCheck"
                    } else {
                        # Simulate: mark all as up-to-date in preview
                        $item.LatestVersion = $item.CurrentVersion
                        $item.Status        = "Up to date"
                        $item.StatusKey     = "UpToDate"
                    }
                }
            }.GetNewClosure())
            return @{ Success = $true; Count = $ToolItems.Count; Preview = $true }
        }
    })
    # Pass variables as arguments (matched to param() order above)
    [void]$psCmd.AddArgument($script:DriveRoot)
    [void]$psCmd.AddArgument($script:ModulePath)
    [void]$psCmd.AddArgument($script:PkgManagerPath)
    [void]$psCmd.AddArgument($script:ConfigPath)
    [void]$psCmd.AddArgument($script:HasModule)
    [void]$psCmd.AddArgument($script:HasPkgManager)
    [void]$psCmd.AddArgument($script:ToolItems)
    [void]$psCmd.AddArgument($window.Dispatcher)
    [void]$psCmd.AddArgument($script:DebugLogPath)

    $handle = $psCmd.BeginInvoke()

    # ── Store info in script-scope variables ──
    $script:ChkHandle    = $handle
    $script:ChkCommand   = $psCmd
    $script:ChkStartTime = [DateTime]::Now
    $script:ChkTimeoutSec = 120
    $script:ChkFinalTick = $false

    # ── Helper to finalize the check (re-enable buttons, cleanup) ──
    function script:Complete-UpdateCheck {
        try {
            $btnRefresh.IsEnabled        = $true
            $btnUpdateSelected.IsEnabled = $true
            $btnUpdateAll.IsEnabled      = $true
            $btnSelectUpdates.IsEnabled  = $true
            Set-Progress -Value 100 -Indeterminate $false
            Update-Summary
            $script:LastCheckTime = Get-Date
            $txtLastCheckedSettings.Text = "Last checked: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        } catch {
            # Ensure buttons are re-enabled even if summary/progress fail
            try { $btnRefresh.IsEnabled = $true } catch {}
            try { $btnUpdateSelected.IsEnabled = $true } catch {}
            try { $btnSelectUpdates.IsEnabled = $true } catch {}
        }
    }

    # ── DispatcherTimer to poll for runspace completion without blocking the UI ──
    $script:ChkTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:ChkTimer.Interval = [TimeSpan]::FromMilliseconds(500)

    $script:ChkTimer.Add_Tick({
        try {
            # Timeout check: if runspace runs too long, force-stop it
            $elapsed = ([DateTime]::Now - $script:ChkStartTime).TotalSeconds
            if ($elapsed -gt $script:ChkTimeoutSec -and -not $script:ChkHandle.IsCompleted) {
                $script:ChkTimer.Stop()
                Write-Log "WARNING: Update check timed out after $([int]$elapsed) seconds."
                try { $script:ChkCommand.Stop() } catch {}
                try { $script:ChkCommand.Dispose() } catch {}
                # Runspace is managed by the pool — no manual close needed
                # Mark remaining Checking items as timed out
                foreach ($item in $script:ToolItems) {
                    if ($item.StatusKey -eq "Checking") {
                        $item.LatestVersion = "Timeout"
                        $item.Status    = "Check timed out"
                        $item.StatusKey = "Error"
                    }
                }
                Set-StatusText "Update check timed out. Some tools could not be checked."
                Complete-UpdateCheck
                return
            }

            if ($script:ChkHandle.IsCompleted) {
                # Wait one extra tick so BeginInvoke delegates finish on the UI thread
                if (-not $script:ChkFinalTick) {
                    $script:ChkFinalTick = $true
                    return
                }
                $script:ChkTimer.Stop()

                try {
                    $result = $script:ChkCommand.EndInvoke($script:ChkHandle)
                } catch { }

                # Log any runspace errors
                try {
                    if ($script:ChkCommand.Streams.Error.Count -gt 0) {
                        foreach ($err in $script:ChkCommand.Streams.Error) {
                            $pos = ''
                            try {
                                if ($err.InvocationInfo -and $err.InvocationInfo.PositionMessage) {
                                    $pos = " | $($err.InvocationInfo.PositionMessage -replace '[\r\n]+', ' ')"
                                }
                            } catch {}
                            Write-Log "RUNSPACE ERROR: $($err.ToString())$pos"
                        }
                    }
                } catch {}

                try { $script:ChkCommand.Dispose() } catch {}
                # Runspace is managed by the pool — no manual close needed

                Complete-UpdateCheck

                # Check results
                $noInternet = @($script:ToolItems | Where-Object { $_.StatusKey -eq "Error" -and $_.LatestVersion -eq "No Internet" }).Count
                if ($noInternet -gt 0) {
                    Set-StatusText "No internet connection. Cannot check for updates."
                    Write-Log "ERROR: No internet connection detected."
                } else {
                    $updatesAvailable = @($script:ToolItems | Where-Object { $_.StatusKey -eq "UpdateAvailable" }).Count
                    $errCount         = @($script:ToolItems | Where-Object { $_.StatusKey -eq "Error" }).Count
                    if ($errCount -gt 0) {
                        Set-StatusText "Check complete. $updatesAvailable update(s) available, $errCount error(s)."
                    } elseif ($updatesAvailable -gt 0) {
                        Set-StatusText "Check complete. $updatesAvailable update(s) available."
                    } else {
                        Set-StatusText "Check complete. All tools are up to date."
                    }
                    Write-Log "Update check finished. $updatesAvailable update(s) available."

                    # Update nav badge on Updates button
                    $updatesAvail = @($script:ToolItems | Where-Object { $_.StatusKey -eq "UpdateAvailable" }).Count
                    if ($updatesAvail -gt 0) {
                        $btnNavUpdates.Content = [char]::ConvertFromUtf32(0x1F504) + " $updatesAvail"
                    } else {
                        $btnNavUpdates.Content = [char]::ConvertFromUtf32(0x1F504)
                    }
                }
            } else {
                # While running, update progress based on how many items have been resolved
                $checked = @($script:ToolItems | Where-Object { $_.StatusKey -ne "Checking" }).Count
                $total   = $script:ToolItems.Count
                if ($total -gt 0) {
                    $pct = [math]::Round(($checked / $total) * 100)
                    Set-Progress -Value $pct -Indeterminate ($pct -eq 0)
                    Set-StatusText "Checking for updates... ($checked / $total)"
                }
            }
        } catch {
            # Catch-all: if ANYTHING fails in the tick handler, stop the timer and re-enable buttons
            try { $script:ChkTimer.Stop() } catch {}
            try { $script:ChkCommand.Dispose() } catch {}
            try { $script:ChkRunspace.Close() } catch {}
            Write-Host "[DIAG] Timer tick ERROR: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "[DIAG] $($_.ScriptStackTrace)" -ForegroundColor Red
            Write-DebugLog "Check timer error: $($_.Exception.Message)" 'ERROR'
            Write-DebugLog "  Stack: $($_.ScriptStackTrace)" 'ERROR'
            Write-Log "ERROR in update check timer: $($_.Exception.Message)"
            Set-StatusText "Update check encountered an error."
            Complete-UpdateCheck
        }
    })

    $script:ChkTimer.Start()
}

# ─── Background Update Execution ─────────────────────────────────────────────
function Start-SelectedUpdates {
    # Guard: RunspacePool must be ready
    if (-not $script:RunspacePool -or $script:RunspacePool.RunspacePoolStateInfo.State -ne 'Opened') {
        [System.Windows.MessageBox]::Show(
            "Background engine is not available.`nPlease restart the application.",
            "Engine Error",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        )
        return
    }

    if ($script:ForensicModeActive) {
        [System.Windows.MessageBox]::Show(
            "Forensic Mode is active.`nDisable Forensic Mode before updating tools.",
            "Forensic Mode",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        )
        return
    }
    $selected = @($script:ToolItems | Where-Object { $_.IsSelected -and $_.StatusKey -eq "UpdateAvailable" })
    if ($selected.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            "No updatable tools are selected.`nSelect tools with available updates first.",
            "Nothing to Update",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        )
        return
    }

    $confirm = [System.Windows.MessageBox]::Show(
        "Update $($selected.Count) selected tool(s)?",
        "Confirm Update",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )
    if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }

    # Disable normal buttons, show Cancel
    $btnRefresh.IsEnabled        = $false
    $btnUpdateSelected.IsEnabled = $false
    $btnUpdateAll.IsEnabled      = $false
    $btnSelectUpdates.IsEnabled  = $false
    $btnDeselectAll.IsEnabled    = $false
    $btnCancelUpdate.Visibility  = [System.Windows.Visibility]::Visible
    $btnRetryFailed.Visibility   = [System.Windows.Visibility]::Collapsed
    $script:UpdateCancelRequested = $false

    Set-StatusText "Updating tools..."
    Set-Progress -Value 0 -Indeterminate $false -Color '#0078D4'
    Write-Log "Starting update for $($selected.Count) tool(s)..."

    # Expand log panel automatically
    $btnToggleLog.IsChecked = $true
    $logPanel.Visibility = [System.Windows.Visibility]::Visible
    $btnToggleLog.Content = [char]0x25BC + " Hide Log"

    # Track which tools are being updated (for accurate fail detection in results)
    $script:UpdatedToolNames = @($selected | ForEach-Object { $_.Name })

    # Build data to pass into the runspace (include PM IDs from config)
    $updateJobs = @()
    $configTools = $null
    try {
        $raw = Get-Content -LiteralPath $script:ConfigPath -Raw -ErrorAction Stop
        $configTools = ($raw | ConvertFrom-Json -ErrorAction Stop).tools
    } catch { }

    foreach ($item in $selected) {
        $jobData = @{
            Name        = $item.Name
            DownloadUrl = $item.DownloadUrl
            ToolPath    = $item.ToolPath
            InstallType = $item.InstallType
            WingetId    = $null
            ScoopId     = $null
        }
        # Look up PM IDs from config
        if ($configTools) {
            $cfgEntry = $configTools | Where-Object { $_.name -eq $item.Name } | Select-Object -First 1
            if ($cfgEntry) {
                $jobData.WingetId = $cfgEntry.winget_id
                $jobData.ScoopId  = $cfgEntry.scoop_id
            }
        }
        $updateJobs += $jobData
    }

    $psCmd = [PowerShell]::Create()
    $psCmd.RunspacePool = $script:RunspacePool

    # Thread-safe cancel flag shared with runspace
    $script:CancelFlag = [hashtable]::Synchronized(@{ Cancelled = $false })

    [void]$psCmd.AddScript({
        param($DriveRoot, $ModulePath, $PkgManagerPath, $HasModule, $HasPkgManager, $ToolItems, $UpdateJobs, $Dispatcher, $CancelFlag, $DebugLogPath, $ConfigPath)
        if ($HasModule) {
            . $ModulePath
            Set-StrictMode -Off
        }
        if ($HasPkgManager) {
            . $PkgManagerPath
            Set-StrictMode -Off
        }

        # Helper: write to debug log from the runspace thread
        function Write-RsDebugLog ($msg, $lvl) {
            $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
            try { [System.IO.File]::AppendAllText($DebugLogPath, "$ts [$lvl] [UpdateRunspace] $msg`r`n") } catch { }
        }

        # Helper: update per-tool status on UI thread
        function Set-ToolStatus ($toolName, $statusText) {
            [void]$Dispatcher.BeginInvoke([Action]{
                $item = $ToolItems | Where-Object { $_.Name -eq $toolName } | Select-Object -First 1
                if ($item) { $item.Status = $statusText }
            }.GetNewClosure())
        }

        $successCount  = 0
        $failCount     = 0
        $cancelCount   = 0
        $idx           = 0
        $resultDetails = @()

        Write-RsDebugLog "Starting update batch: $($UpdateJobs.Count) tool(s)" 'INFO'

        foreach ($job in $UpdateJobs) {
            $idx++
            $name = $job.Name
            Write-RsDebugLog "[$idx/$($UpdateJobs.Count)] Processing '$name' | URL=$($job.DownloadUrl) | Type=$($job.InstallType) | Scoop=$($job.ScoopId) | Winget=$($job.WingetId)" 'DEBUG'

            # ── Check cancellation ──
            if ($CancelFlag.Cancelled) {
                Write-RsDebugLog "[$idx] '$name' cancelled by user" 'INFO'
                $cancelCount++
                Set-ToolStatus $name "Cancelled"
                [void]$Dispatcher.BeginInvoke([Action]{
                    $item = $ToolItems | Where-Object { $_.Name -eq $name } | Select-Object -First 1
                    if ($item) { $item.StatusKey = "ManualCheck" }
                }.GetNewClosure())
                $resultDetails += @{ Name = $name; Result = 'Cancelled'; Message = 'Cancelled by user' }
                continue
            }

            # Mark as "Downloading..." on UI
            Set-ToolStatus $name "Downloading..."

            $success = $false
            $message = ""

            # ── Strategy 1: Try package manager (scoop > winget) ──
            $pmTried = $false
            if ($HasPkgManager) {
                if ($job.ScoopId -and (Test-PackageManager 'scoop')) {
                    $pmTried = $true
                    Write-RsDebugLog "[$idx] '$name' -> trying scoop ($($job.ScoopId))" 'DEBUG'
                    Set-ToolStatus $name "Installing via scoop..."
                    try {
                        $pmResult = Install-ScoopPackage -PackageId $job.ScoopId
                        $success = $pmResult.Success
                        $message = $pmResult.Message
                        Write-RsDebugLog "[$idx] '$name' scoop result: Success=$success Msg=$message" 'DEBUG'
                    } catch {
                        $message = "scoop update failed for '$name': $_"
                        Write-RsDebugLog "[$idx] '$name' scoop exception: $_" 'ERROR'
                    }
                }
                elseif ($job.WingetId -and (Test-PackageManager 'winget')) {
                    $pmTried = $true
                    Write-RsDebugLog "[$idx] '$name' -> trying winget ($($job.WingetId))" 'DEBUG'
                    Set-ToolStatus $name "Installing via winget..."
                    $installPath = Join-Path $DriveRoot $job.ToolPath
                    try {
                        $pmResult = Install-WingetPackage -PackageId $job.WingetId -TargetDir $installPath
                        $success = $pmResult.Success
                        $message = $pmResult.Message
                        Write-RsDebugLog "[$idx] '$name' winget result: Success=$success Msg=$message" 'DEBUG'
                    } catch {
                        $message = "winget update failed for '$name': $_"
                        Write-RsDebugLog "[$idx] '$name' winget exception: $_" 'ERROR'
                    }
                }
            }

            # Check cancellation between strategies
            if ($CancelFlag.Cancelled -and -not $success) {
                $cancelCount++
                Set-ToolStatus $name "Cancelled"
                [void]$Dispatcher.BeginInvoke([Action]{
                    $item = $ToolItems | Where-Object { $_.Name -eq $name } | Select-Object -First 1
                    if ($item) { $item.StatusKey = "ManualCheck" }
                }.GetNewClosure())
                $resultDetails += @{ Name = $name; Result = 'Cancelled'; Message = 'Cancelled by user' }
                continue
            }

            # ── Strategy 2: Fall back to direct download ──
            if (-not $success -and $HasModule) {
                $installPath = Join-Path $DriveRoot $job.ToolPath

                if ($job.InstallType -eq 'manual') {
                    try {
                        Start-Process $job.DownloadUrl -ErrorAction Stop
                        $success = $true
                        $message = "Opened download page for '$name'."
                    } catch {
                        $message = "Failed to open URL for '$name': $_"
                    }
                } elseif (-not [string]::IsNullOrWhiteSpace($job.DownloadUrl)) {
                    # Map unsupported install types to closest supported type
                    $effectiveType = $job.InstallType
                    if ($effectiveType -notin @('extract_zip', 'extract_7z', 'copy_exe', 'manual')) {
                        $effectiveType = 'extract_zip'
                    }

                    if ($pmTried) {
                        Set-ToolStatus $name "PM failed, downloading..."
                        $message = "PM failed, trying direct download... "
                    } else {
                        Set-ToolStatus $name "Downloading..."
                    }
                    Write-RsDebugLog "[$idx] '$name' -> direct download: $($job.DownloadUrl) (type=$effectiveType)" 'DEBUG'
                    try {
                        $result = Install-ToolUpdate -ToolName $name `
                                                     -DownloadUrl $job.DownloadUrl `
                                                     -InstallPath $installPath `
                                                     -InstallType $effectiveType `
                                                     -Confirm:$false
                        $success = $result.Success
                        $message += $result.Message
                        Write-RsDebugLog "[$idx] '$name' download result: Success=$success Msg=$($result.Message)" 'DEBUG'
                    } catch {
                        $message += "Update failed for '$name': $_"
                        Write-RsDebugLog "[$idx] '$name' download exception: $_" 'ERROR'
                    }
                } elseif (-not $pmTried) {
                    $message = "No download URL or package manager available for '$name'."
                    Write-RsDebugLog "[$idx] '$name' -> no download URL or PM available" 'WARN'
                }
            } elseif (-not $success -and -not $HasModule) {
                # Preview mode: simulate
                Set-ToolStatus $name "Installing..."
                Start-Sleep -Milliseconds (Get-Random -Minimum 500 -Maximum 1500)
                $success = ((Get-Random -Minimum 0 -Maximum 10) -lt 8)
                $message = if ($success) { "Simulated success." } else { "Simulated failure." }
            }

            if ($success) {
                $successCount++
                Set-ToolStatus $name "Extracting..."
                Start-Sleep -Milliseconds 200   # brief visual pause so user sees the stage
                # Persist updated version to config file (file I/O from runspace thread)
                $savedVersion = $null
                $toolItem = $ToolItems | Where-Object { $_.Name -eq $name } | Select-Object -First 1
                if ($toolItem -and $toolItem.LatestVersion -and $toolItem.LatestVersion -notin @("N/A","Error","No Internet","Checking...")) {
                    $savedVersion = $toolItem.LatestVersion
                    try {
                        $raw = [System.IO.File]::ReadAllText($ConfigPath)
                        $cfg = $raw | ConvertFrom-Json
                        foreach ($t in $cfg.tools) {
                            if ($t.name -eq $name) {
                                $t.current_version = $savedVersion
                                break
                            }
                        }
                        $cfg.last_updated = (Get-Date -Format 'yyyy-MM-dd')
                        $json = $cfg | ConvertTo-Json -Depth 10
                        [System.IO.File]::WriteAllText($ConfigPath, $json)
                        Write-RsDebugLog "[$idx] '$name' version saved to config: $savedVersion" 'INFO'
                    } catch {
                        Write-RsDebugLog "[$idx] '$name' failed to save version to config: $_" 'ERROR'
                    }
                }
                [void]$Dispatcher.BeginInvoke([Action]{
                    $item = $ToolItems | Where-Object { $_.Name -eq $name } | Select-Object -First 1
                    if ($item) {
                        if ($savedVersion) {
                            $item.CurrentVersion = $savedVersion
                        }
                        $item.Status    = "Updated"
                        $item.StatusKey = "UpToDate"
                        $item.IsSelected = $false
                    }
                }.GetNewClosure())
                $resultDetails += @{ Name = $name; Result = 'Success'; Message = $message }
            } else {
                $failCount++
                [void]$Dispatcher.BeginInvoke([Action]{
                    $item = $ToolItems | Where-Object { $_.Name -eq $name } | Select-Object -First 1
                    if ($item) {
                        $item.Status    = "Update failed"
                        $item.StatusKey = "Error"
                        $item.Notes     = $message
                    }
                }.GetNewClosure())
                $resultDetails += @{ Name = $name; Result = 'Failed'; Message = $message }
            }
        }

        return @{
            Success  = $successCount
            Failed   = $failCount
            Cancelled = $cancelCount
            Total    = $UpdateJobs.Count
            Details  = $resultDetails
        }
    })
    # Pass variables as arguments (matched to param() order above)
    [void]$psCmd.AddArgument($script:DriveRoot)
    [void]$psCmd.AddArgument($script:ModulePath)
    [void]$psCmd.AddArgument($script:PkgManagerPath)
    [void]$psCmd.AddArgument($script:HasModule)
    [void]$psCmd.AddArgument($script:HasPkgManager)
    [void]$psCmd.AddArgument($script:ToolItems)
    [void]$psCmd.AddArgument($updateJobs)
    [void]$psCmd.AddArgument($window.Dispatcher)
    [void]$psCmd.AddArgument($script:CancelFlag)
    [void]$psCmd.AddArgument($script:DebugLogPath)
    [void]$psCmd.AddArgument($script:ConfigPath)

    $handle = $psCmd.BeginInvoke()

    # Store in script-scope variables for reliable access from timer tick
    $script:UpdHandle    = $handle
    $script:UpdCommand   = $psCmd
    $script:UpdFinalTick = $false

    $script:UpdTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:UpdTimer.Interval = [TimeSpan]::FromMilliseconds(500)

    $script:UpdTimer.Add_Tick({
        try {
            if ($script:UpdHandle.IsCompleted) {
                # Wait one extra tick so BeginInvoke delegates finish on the UI thread
                if (-not $script:UpdFinalTick) {
                    $script:UpdFinalTick = $true
                    return
                }
                $script:UpdTimer.Stop()

                $result = $null
                try {
                    $result = $script:UpdCommand.EndInvoke($script:UpdHandle)
                } catch { }

                # Log runspace errors
                try {
                    if ($script:UpdCommand.Streams.Error.Count -gt 0) {
                        foreach ($err in $script:UpdCommand.Streams.Error) {
                            Write-Log "UPDATE ERROR: $($err.ToString())"
                        }
                    }
                } catch {}

                try { $script:UpdCommand.Dispose() } catch {}

                # Re-enable buttons, hide Cancel, reset its state
                $btnRefresh.IsEnabled        = $true
                $btnUpdateSelected.IsEnabled = $true
                $btnUpdateAll.IsEnabled      = $true
                $btnSelectUpdates.IsEnabled  = $true
                $btnDeselectAll.IsEnabled    = $true
                $btnCancelUpdate.Visibility  = [System.Windows.Visibility]::Collapsed
                $btnCancelUpdate.IsEnabled   = $true
                $btnCancelUpdate.Content     = [char]::ConvertFromUtf32(0x274C) + " Cancel"

                $s = 0; $f = 0; $c = 0
                $details = @()
                if ($result -and $result.Count -gt 0) {
                    $r = $result[0]
                    if ($r -is [hashtable]) {
                        $s = $r.Success; $f = $r.Failed; $c = $r.Cancelled
                        $details = $r.Details
                    }
                }

                # ── Color-coded progress bar ──
                if ($f -gt 0) {
                    Set-Progress -Value 100 -Indeterminate $false -Color '#E74C3C'   # Red for failures
                } elseif ($c -gt 0) {
                    Set-Progress -Value 100 -Indeterminate $false -Color '#F39C12'   # Yellow for cancelled
                } else {
                    Set-Progress -Value 100 -Indeterminate $false -Color '#2ECC71'   # Green for all success
                }

                Update-Summary

                # ── Inline results in the log panel (no MessageBox) ──
                Write-Log "────────────────────────────────────────"
                Write-Log "UPDATE COMPLETE: $s succeeded, $f failed, $c cancelled"
                Write-Log "────────────────────────────────────────"

                if ($details -and $details.Count -gt 0) {
                    foreach ($d in $details) {
                        $icon = switch ($d.Result) {
                            'Success'   { '+' }
                            'Failed'    { 'x' }
                            'Cancelled' { '-' }
                            default     { '?' }
                        }
                        $msg = if ($d.Message) { " - $($d.Message)" } else { '' }
                        # Truncate long messages for readability
                        if ($msg.Length -gt 120) { $msg = $msg.Substring(0, 117) + '...' }
                        Write-Log "  $icon  $($d.Name)$msg"
                    }
                }
                Write-Log "────────────────────────────────────────"

                # Build status text summary
                $statusParts = @()
                if ($s -gt 0) { $statusParts += "$s updated" }
                if ($f -gt 0) { $statusParts += "$f failed" }
                if ($c -gt 0) { $statusParts += "$c cancelled" }
                Set-StatusText "Update complete: $($statusParts -join ', ')."

                # Show Retry Failed button if there were failures
                if ($f -gt 0) {
                    $btnRetryFailed.Visibility = [System.Windows.Visibility]::Visible
                } else {
                    $btnRetryFailed.Visibility = [System.Windows.Visibility]::Collapsed
                }

                # Reset progress bar color after a delay
                $script:ProgressResetTimer = New-Object System.Windows.Threading.DispatcherTimer
                $script:ProgressResetTimer.Interval = [TimeSpan]::FromSeconds(5)
                $script:ProgressResetTimer.Add_Tick({
                    $script:ProgressResetTimer.Stop()
                    Set-Progress -Value 0 -Color '#0078D4'
                })
                $script:ProgressResetTimer.Start()

            } else {
                # ── Live per-tool progress while running ──
                $activeItem = $script:ToolItems | Where-Object {
                    $_.Status -match 'Downloading|Installing|Extracting|PM failed'
                } | Select-Object -First 1

                # Count completed items from the tracked update set only
                $trackedNames = $script:UpdatedToolNames
                $doneCount = @($script:ToolItems | Where-Object {
                    $_.Name -in $trackedNames -and
                    ($_.Status -in @("Updated","Up to date","Update failed","Cancelled"))
                }).Count
                $totalUpd = $trackedNames.Count

                if ($totalUpd -gt 0) {
                    $pct = [math]::Round(($doneCount / $totalUpd) * 100)
                    Set-Progress -Value $pct -Indeterminate $false -Color '#0078D4'
                }
                if ($activeItem) {
                    $progressText = if ($totalUpd -gt 0) { " ($([math]::Min($doneCount + 1, $totalUpd))/$totalUpd)" } else { "" }
                    Set-StatusText "$($activeItem.Status): $($activeItem.Name)$progressText"
                }
            }
        } catch {
            # Catch-all: stop timer and re-enable buttons on any error
            try { $script:UpdTimer.Stop() } catch {}
            try { $script:UpdCommand.Dispose() } catch {}
            try { $script:UpdRunspace.Close() } catch {}
            Write-Log "ERROR in update timer: $($_.Exception.Message)"
            $btnRefresh.IsEnabled        = $true
            $btnUpdateSelected.IsEnabled = $true
            $btnUpdateAll.IsEnabled      = $true
            $btnSelectUpdates.IsEnabled  = $true
            $btnDeselectAll.IsEnabled    = $true
            $btnCancelUpdate.Visibility  = [System.Windows.Visibility]::Collapsed
            $btnCancelUpdate.IsEnabled   = $true
            $btnCancelUpdate.Content     = [char]::ConvertFromUtf32(0x274C) + " Cancel"
            Set-StatusText "Update encountered an error."
            Set-Progress -Value 0 -Color '#0078D4'
        }
    })

    $script:UpdTimer.Start()
}

# ─── Navigation ──────────────────────────────────────────────────────────────
function Set-ActivePanel {
    param([string]$PanelName)
    $panelDashboard.Visibility  = [System.Windows.Visibility]::Collapsed
    $panelUpdates.Visibility    = [System.Windows.Visibility]::Collapsed
    $panelSettings.Visibility   = [System.Windows.Visibility]::Collapsed
    $panelReferences.Visibility = [System.Windows.Visibility]::Collapsed
    $btnNavDashboard.Tag  = $null
    $btnNavUpdates.Tag    = $null
    $btnNavReferences.Tag = $null
    $btnNavSettings.Tag   = $null
    switch ($PanelName) {
        "Dashboard"  { $panelDashboard.Visibility = [System.Windows.Visibility]::Visible;  $btnNavDashboard.Tag  = "Active" }
        "Updates"    { $panelUpdates.Visibility = [System.Windows.Visibility]::Visible;    $btnNavUpdates.Tag    = "Active" }
        "References" { $panelReferences.Visibility = [System.Windows.Visibility]::Visible; $btnNavReferences.Tag = "Active" }
        "Settings"   { $panelSettings.Visibility = [System.Windows.Visibility]::Visible;   $btnNavSettings.Tag   = "Active" }
    }
}

# ─── Dashboard: Icon Cache ───────────────────────────────────────────────────
$script:IconCache = @{}

# ─── Dashboard: Icon extraction helper ───────────────────────────────────────
function Get-ToolIcon {
    param([string]$ExePath, [string]$PngIconPath)

    # Try PNG from PortableApps first
    if ($PngIconPath -and (Test-Path -LiteralPath $PngIconPath)) {
        if ($script:IconCache.ContainsKey($PngIconPath)) { return $script:IconCache[$PngIconPath] }
        try {
            $uri = New-Object System.Uri($PngIconPath)
            $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
            $bmp.BeginInit()
            $bmp.UriSource = $uri
            $bmp.DecodePixelWidth = 36
            $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bmp.EndInit()
            $bmp.Freeze()
            $script:IconCache[$PngIconPath] = $bmp
            return $bmp
        } catch { }
    }

    # Extract icon from exe/bat/py (ExtractAssociatedIcon works for any file type)
    if ($ExePath -and (Test-Path -LiteralPath $ExePath) -and $ExePath -match '\.(exe|bat|py|cmd)$') {
        if ($script:IconCache.ContainsKey($ExePath)) { return $script:IconCache[$ExePath] }
        try {
            $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($ExePath)
            if ($icon) {
                $bitmap = $icon.ToBitmap()
                $ms = New-Object System.IO.MemoryStream
                $bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
                $ms.Position = 0

                $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
                $bmp.BeginInit()
                $bmp.StreamSource = $ms
                $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                $bmp.EndInit()
                $bmp.Freeze()
                $ms.Dispose()
                $icon.Dispose()
                $bitmap.Dispose()

                $script:IconCache[$ExePath] = $bmp
                return $bmp
            }
        } catch { }
    }

    return $null
}

# ─── Dashboard: Build tile for a single tool ─────────────────────────────────
function New-ToolTile {
    param([PSCustomObject]$Tool)

    $border = New-Object System.Windows.Controls.Border
    $border.Width = 150
    $border.Height = 120
    $border.Margin = New-Object System.Windows.Thickness(4)
    $border.Padding = New-Object System.Windows.Thickness(6)
    $border.CornerRadius = New-Object System.Windows.CornerRadius(6)
    $border.Background = $script:BrushConverter.ConvertFrom('#2D2D2D')
    $border.BorderBrush = $script:BrushConverter.ConvertFrom('#3E3E3E')
    $border.BorderThickness = New-Object System.Windows.Thickness(1)
    $border.Cursor = [System.Windows.Input.Cursors]::Hand
    $border.ToolTip = "$($Tool.Name)`n$($Tool.ExePath)"
    $border.Tag = $Tool.ExePath

    # Hover effects - use pre-created brushes to avoid closure scope issues
    $hoverBg = $script:BrushConverter.ConvertFrom('#3A3A4A')
    $hoverBorder = $script:BrushConverter.ConvertFrom('#0078D4')
    $normalBg = $border.Background
    $normalBorder = $border.BorderBrush
    $border.Add_MouseEnter({
        $this.Background = $hoverBg
        $this.BorderBrush = $hoverBorder
    }.GetNewClosure())
    $border.Add_MouseLeave({
        $this.Background = $normalBg
        $this.BorderBrush = $normalBorder
    }.GetNewClosure())

    # Click to launch - store paths in Tag for access without closure issues
    $border.Add_MouseLeftButtonUp({
        $clickedExe = $this.Tag
        $clickedName = $this.ToolTip -split "`n" | Select-Object -First 1
        try {
            $workingDir = Split-Path $clickedExe -Parent
            # Handle different file types
            if ($clickedExe -match '\.py$') {
                # Python scripts - launch with python.exe
                Start-Process python.exe -ArgumentList "`"$clickedExe`"" -WorkingDirectory $workingDir
            } elseif ($clickedExe -match '\.bat$') {
                # Batch files - launch via cmd
                Start-Process cmd.exe -ArgumentList "/c `"$clickedExe`"" -WorkingDirectory $workingDir
            } else {
                # Executables - unblock MOTW first
                $unblocked = Unblock-ToolIfNeeded $clickedExe
                if (-not $unblocked) {
                    Write-Log "WARNING: Could not unblock MOTW on $clickedExe (Forensic Mode or permissions)"
                }
                Start-Process -FilePath $clickedExe -WorkingDirectory $workingDir
            }
            Write-Log "Launched: $clickedName ($clickedExe)"
        } catch {
            # If still blocked, give a helpful message
            $msg = $_.Exception.Message
            if ($msg -match 'canceled by the user') {
                $msg = "Windows SmartScreen blocked this file (downloaded from internet).`n`nRight-click the file in Explorer > Properties > check 'Unblock' and try again.`n`nPath: $clickedExe"
            }
            [System.Windows.MessageBox]::Show(
                "Failed to launch '$clickedName':`n$msg",
                "Launch Error",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            )
        }
    })

    # Right-click context menu for tile
    $tileMenu = New-Object System.Windows.Controls.ContextMenu
    $tileMenu.Background = $script:BrushConverter.ConvertFrom('#2D2D2D')
    $tileMenu.Foreground = $script:BrushConverter.ConvertFrom('#CCCCCC')
    $tileMenu.BorderBrush = $script:BrushConverter.ConvertFrom('#555555')

    $tileLaunch = New-Object System.Windows.Controls.MenuItem
    $tileLaunch.Header = "Launch"
    $tileLaunch.FontWeight = [System.Windows.FontWeights]::SemiBold
    $tileLaunch.Tag = $Tool.ExePath
    $tileLaunch.Add_Click({
        $exePath = $this.Tag
        try {
            $wd = Split-Path $exePath -Parent
            if ($exePath -match '\.py$') {
                Start-Process python.exe -ArgumentList "`"$exePath`"" -WorkingDirectory $wd
            } elseif ($exePath -match '\.bat$') {
                Start-Process cmd.exe -ArgumentList "/c `"$exePath`"" -WorkingDirectory $wd
            } else {
                Unblock-ToolIfNeeded $exePath | Out-Null
                Start-Process -FilePath $exePath -WorkingDirectory $wd
            }
        } catch { }
    })
    [void]$tileMenu.Items.Add($tileLaunch)

    [void]$tileMenu.Items.Add((New-Object System.Windows.Controls.Separator))

    $tileOpenFolder = New-Object System.Windows.Controls.MenuItem
    $tileOpenFolder.Header = "Open Folder in Explorer"
    $tileOpenFolder.Tag = $Tool.ExePath
    $tileOpenFolder.Add_Click({
        $exePath = $this.Tag
        $folder = Split-Path $exePath -Parent
        if (Test-Path -LiteralPath $folder) {
            Start-Process explorer.exe -ArgumentList "`"$folder`""
        }
    })
    [void]$tileMenu.Items.Add($tileOpenFolder)

    $tileCopyPath = New-Object System.Windows.Controls.MenuItem
    $tileCopyPath.Header = "Copy Path to Clipboard"
    $tileCopyPath.Tag = $Tool.ExePath
    $tileCopyPath.Add_Click({
        [System.Windows.Clipboard]::SetText($this.Tag)
    })
    [void]$tileMenu.Items.Add($tileCopyPath)

    $border.ContextMenu = $tileMenu

    $stack = New-Object System.Windows.Controls.StackPanel
    $stack.HorizontalAlignment = 'Center'
    $stack.VerticalAlignment = 'Center'

    # Icon
    $iconImage = New-Object System.Windows.Controls.Image
    $iconImage.Width = 36
    $iconImage.Height = 36
    $iconImage.Stretch = [System.Windows.Media.Stretch]::Uniform
    $iconImage.HorizontalAlignment = 'Center'
    $iconImage.Margin = New-Object System.Windows.Thickness(0, 4, 0, 6)

    $bmpSrc = Get-ToolIcon -ExePath $Tool.ExePath -PngIconPath $Tool.IconPath
    if ($bmpSrc) {
        $iconImage.Source = $bmpSrc
    } else {
        # Fallback: text glyph
        $iconImage.Visibility = [System.Windows.Visibility]::Collapsed
        $fallback = New-Object System.Windows.Controls.TextBlock
        $fallback.Text = [char]::ConvertFromUtf32(0x1F4E6)
        $fallback.FontSize = 32
        $fallback.HorizontalAlignment = 'Center'
        $fallback.Margin = New-Object System.Windows.Thickness(0, 4, 0, 6)
        [void]$stack.Children.Add($fallback)
    }

    if ($iconImage.Visibility -ne [System.Windows.Visibility]::Collapsed) {
        [void]$stack.Children.Add($iconImage)
    }

    # Name label
    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $Tool.Name
    $label.Foreground = $script:BrushConverter.ConvertFrom('#DDDDDD')
    $label.FontSize = 11
    $label.TextAlignment = 'Center'
    $label.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $label.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
    $label.MaxHeight = 34
    $label.HorizontalAlignment = 'Center'
    [void]$stack.Children.Add($label)

    # Category badge
    $catLabel = New-Object System.Windows.Controls.TextBlock
    $catLabel.Text = $Tool.Category
    $catLabel.Foreground = $script:BrushConverter.ConvertFrom('#999999')
    $catLabel.FontSize = 9
    $catLabel.HorizontalAlignment = 'Center'
    $catLabel.Margin = New-Object System.Windows.Thickness(0, 2, 0, 0)
    [void]$stack.Children.Add($catLabel)

    $border.Child = $stack
    return $border
}

# ─── Dashboard: Populate tiles ───────────────────────────────────────────────
function Populate-DashboardTiles {
    param([string]$CategoryFilter = 'All', [string]$SearchFilter = '')

    $wpDashTools.Children.Clear()

    $filtered = $script:AllLaunchTools
    if ($CategoryFilter -ne 'All') {
        $filtered = @($filtered | Where-Object { $_.Category -eq $CategoryFilter })
    }
    if ($SearchFilter -and $SearchFilter -ne 'Search tools...') {
        $filtered = @($filtered | Where-Object { $_.Name -match [regex]::Escape($SearchFilter) })
    }

    foreach ($tool in $filtered) {
        $tile = New-ToolTile -Tool $tool
        [void]$wpDashTools.Children.Add($tile)
    }

    # Update tool count label
    $totalCount = @($script:AllLaunchTools).Count
    $shownCount = @($filtered).Count
    if ($shownCount -eq $totalCount) {
        $txtDashToolCount.Text = "($totalCount)"
    } else {
        $txtDashToolCount.Text = "($shownCount of $totalCount)"
    }
}

# ─── Dashboard: Initialize ───────────────────────────────────────────────────
function Initialize-Dashboard {
    Write-Log "Scanning drive for launchable tools..."
    $launchTools = $null
    try {
        $launchTools = Get-LaunchableTools -DriveRoot $script:DriveRoot
    } catch {
        Write-Log "ERROR: Tool scan failed: $($_.Exception.Message)"
        return
    }

    if (-not $launchTools -or @($launchTools).Count -eq 0) {
        Write-Log "No launchable tools found on the drive."
        return
    }

    Write-Log "Found $(@($launchTools).Count) launchable tools."
    $script:AllLaunchTools = $launchTools
    $script:DashCurrentCategory = 'All'

    # Update Settings panel tool count
    $txtToolCountSettings.Text = "Tools: $(@($launchTools).Count) launchable tools found"

    # Build category chips
    $pnlDashCategories.Children.Clear()
    $categories = @('All') + @($launchTools | ForEach-Object { $_.Category } | Sort-Object -Unique)

    $script:DashCatButtons = @{}
    foreach ($cat in $categories) {
        $btn = New-Object System.Windows.Controls.Button
        $btn.Content = $cat
        $btn.Padding = New-Object System.Windows.Thickness(12, 4, 12, 4)
        $btn.Margin = New-Object System.Windows.Thickness(2, 0, 2, 0)
        $btn.FontSize = 12
        $btn.Cursor = [System.Windows.Input.Cursors]::Hand
        $btn.BorderThickness = New-Object System.Windows.Thickness(0, 0, 0, 2)

        if ($cat -eq 'All') {
            $btn.Background = $script:BrushConverter.ConvertFrom('#3A3A4A')
            $btn.Foreground = $script:BrushConverter.ConvertFrom('#FFFFFF')
            $btn.BorderBrush = $script:BrushConverter.ConvertFrom('#0078D4')
        } else {
            $btn.Background = [System.Windows.Media.Brushes]::Transparent
            $btn.Foreground = $script:BrushConverter.ConvertFrom('#AAAAAA')
            $btn.BorderBrush = [System.Windows.Media.Brushes]::Transparent
        }

        $btn.Tag = $cat
        $btn.Add_Click({
            $clickedCat = $this.Tag
            $script:DashCurrentCategory = $clickedCat
            # Update chip styling
            foreach ($k in $script:DashCatButtons.Keys) {
                $b = $script:DashCatButtons[$k]
                if ($k -eq $clickedCat) {
                    $b.Background = $script:BrushConverter.ConvertFrom('#3A3A4A')
                    $b.Foreground = $script:BrushConverter.ConvertFrom('#FFFFFF')
                    $b.BorderBrush = $script:BrushConverter.ConvertFrom('#0078D4')
                } else {
                    $b.Background = [System.Windows.Media.Brushes]::Transparent
                    $b.Foreground = $script:BrushConverter.ConvertFrom('#AAAAAA')
                    $b.BorderBrush = [System.Windows.Media.Brushes]::Transparent
                }
            }
            $searchText = $txtDashSearch.Text
            Populate-DashboardTiles -CategoryFilter $clickedCat -SearchFilter $searchText
        })

        $script:DashCatButtons[$cat] = $btn
        [void]$pnlDashCategories.Children.Add($btn)
    }

    # Initial populate
    Populate-DashboardTiles -CategoryFilter 'All'
}

# ─── Wire Up Event Handlers ─────────────────────────────────────────────────

# ── Download-page link handling ─────────────────────────────────────────────

# Handle link-button and row-action clicks inside the DataGrid (routed event)
$dgTools.AddHandler(
    [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,
    [System.Windows.RoutedEventHandler]{
        param($sender, $e)
        $element = $e.OriginalSource
        while ($element -ne $null) {
            if ($element -is [System.Windows.Controls.Button]) {
                $tag = $element.Tag
                $item = $element.DataContext

                if ($tag -eq 'OpenDownloadPage') {
                    # Status column link click
                    if ($item -and $item.DownloadUrl) {
                        try {
                            Start-Process $item.DownloadUrl
                            Write-Log "Opened download page for $($item.Name): $($item.DownloadUrl)"
                        } catch {
                            Write-Log "ERROR: Failed to open URL: $($_.Exception.Message)"
                        }
                    } elseif ($item) {
                        [System.Windows.MessageBox]::Show(
                            "No download page URL is configured for '$($item.Name)'.",
                            "No URL Available",
                            [System.Windows.MessageBoxButton]::OK,
                            [System.Windows.MessageBoxImage]::Information
                        )
                    }
                    $e.Handled = $true
                    break
                }
                elseif ($tag -eq 'RowAction') {
                    # Per-row action button (Update / Open / Retry)
                    if (-not $item) { break }

                    if ($item.StatusKey -eq 'UpdateAvailable') {
                        # One-click update for this single tool
                        if ($script:ForensicModeActive) {
                            [System.Windows.MessageBox]::Show(
                                "Forensic Mode is active. Disable it first.",
                                "Forensic Mode",
                                [System.Windows.MessageBoxButton]::OK,
                                [System.Windows.MessageBoxImage]::Warning
                            )
                        } else {
                            # Select only this tool and start update
                            foreach ($t in $script:ToolItems) { $t.IsSelected = $false }
                            $item.IsSelected = $true
                            $dgTools.Items.Refresh()
                            Start-SelectedUpdates
                        }
                    }
                    elseif ($item.StatusKey -eq 'ManualCheck') {
                        # Open download page
                        if ($item.DownloadUrl) {
                            try { Start-Process $item.DownloadUrl } catch {}
                            Write-Log "Opened download page for $($item.Name)"
                        }
                    }
                    elseif ($item.StatusKey -eq 'Error') {
                        # Retry: open download page or re-check
                        if ($item.DownloadUrl) {
                            try { Start-Process $item.DownloadUrl } catch {}
                            Write-Log "Opened download page for retry: $($item.Name)"
                        }
                    }
                    $e.Handled = $true
                    break
                }
            }
            try {
                $element = [System.Windows.Media.VisualTreeHelper]::GetParent($element)
            } catch { break }
        }
    }
)

# Double-click any row to open its download page
$dgTools.Add_MouseDoubleClick({
    param($sender, $e)
    $item = $dgTools.SelectedItem
    if ($item -and $item.DownloadUrl) {
        try { Start-Process $item.DownloadUrl } catch {}
        Write-Log "Opened download page for $($item.Name)"
    }
})

# Right-click context menu
$script:GridContextMenu = New-Object System.Windows.Controls.ContextMenu
$script:GridContextMenu.Background = $script:BrushConverter.ConvertFrom("#2D2D2D")
$script:GridContextMenu.Foreground = $script:BrushConverter.ConvertFrom("#CCCCCC")
$script:GridContextMenu.BorderBrush = $script:BrushConverter.ConvertFrom("#555555")

$menuOpenPage = New-Object System.Windows.Controls.MenuItem
$menuOpenPage.Header = "Open Download Page"
$menuOpenPage.Add_Click({
    $item = $dgTools.SelectedItem
    if ($item -and $item.DownloadUrl) {
        try { Start-Process $item.DownloadUrl } catch {}
        Write-Log "Opened download page for $($item.Name)"
    } else {
        [System.Windows.MessageBox]::Show(
            "No download page URL is configured for this tool.",
            "No URL Available",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        )
    }
})
[void]$script:GridContextMenu.Items.Add($menuOpenPage)

# ── Open Folder in Explorer ──
$menuOpenFolder = New-Object System.Windows.Controls.MenuItem
$menuOpenFolder.Header = "Open Folder in Explorer"
$menuOpenFolder.Add_Click({
    $item = $dgTools.SelectedItem
    if ($item -and $item.ToolPath) {
        $fullPath = Join-Path $script:DriveRoot $item.ToolPath
        # If it points to a file, open its parent folder; if a folder, open directly
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            $folder = Split-Path $fullPath -Parent
        } else {
            $folder = $fullPath
        }
        if (Test-Path -LiteralPath $folder) {
            Start-Process explorer.exe -ArgumentList "`"$folder`""
            Write-Log "Opened folder: $folder"
        } else {
            [System.Windows.MessageBox]::Show(
                "Folder not found:`n$folder",
                "Folder Not Found",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Warning
            )
        }
    }
})
[void]$script:GridContextMenu.Items.Add($menuOpenFolder)

# ── Copy Tool Path ──
$menuCopyPath = New-Object System.Windows.Controls.MenuItem
$menuCopyPath.Header = "Copy Path to Clipboard"
$menuCopyPath.Add_Click({
    $item = $dgTools.SelectedItem
    if ($item -and $item.ToolPath) {
        $fullPath = Join-Path $script:DriveRoot $item.ToolPath
        [System.Windows.Clipboard]::SetText($fullPath)
        Write-Log "Copied path to clipboard: $fullPath"
    }
})
[void]$script:GridContextMenu.Items.Add($menuCopyPath)

# ── Separator ──
[void]$script:GridContextMenu.Items.Add((New-Object System.Windows.Controls.Separator))

# ── Helper: update current_version in tools-config.json ──
function Save-ToolVersion {
    param([string]$ToolName, [string]$NewVersion)
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) { return $false }
    try {
        $raw = Get-Content -LiteralPath $script:ConfigPath -Raw -ErrorAction Stop
        $config = $raw | ConvertFrom-Json -ErrorAction Stop
        $found = $false
        foreach ($t in $config.tools) {
            if ($t.name -eq $ToolName) {
                $t.current_version = $NewVersion
                $found = $true
                break
            }
        }
        if (-not $found) { return $false }
        $config.last_updated = (Get-Date -Format 'yyyy-MM-dd')
        $json = $config | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($script:ConfigPath, $json)
        return $true
    } catch {
        Write-Log "ERROR: Failed to save version to config: $($_.Exception.Message)"
        return $false
    }
}

# ── Mark as Updated (use the latest version shown in the grid) ──
$menuMarkUpdated = New-Object System.Windows.Controls.MenuItem
$menuMarkUpdated.Header = "Mark as Updated"
$menuMarkUpdated.Add_Click({
    $item = $dgTools.SelectedItem
    if (-not $item) { return }

    # Determine the version to set
    $newVersion = $null
    if ($item.LatestVersion -and $item.LatestVersion -notin @("N/A","Error","No Internet","Checking...","Timeout","Unknown")) {
        $newVersion = $item.LatestVersion
    }

    if (-not $newVersion) {
        # No known latest version — prompt the user to enter one
        $newVersion = [Microsoft.VisualBasic.Interaction]::InputBox(
            "No latest version is known for '$($item.Name)'.`n`nEnter the version you installed:",
            "Set Version - $($item.Name)",
            $item.CurrentVersion
        )
        if ([string]::IsNullOrWhiteSpace($newVersion)) { return }
    } else {
        $confirm = [System.Windows.MessageBox]::Show(
            "Mark '$($item.Name)' as updated to version ${newVersion}?",
            "Confirm Mark as Updated",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question
        )
        if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }
    }

    # Save to config
    $saved = Save-ToolVersion -ToolName $item.Name -NewVersion $newVersion
    if ($saved) {
        $item.CurrentVersion = $newVersion
        $item.Status    = "Up to date"
        $item.StatusKey = "UpToDate"
        $item.IsSelected = $false
        Update-Summary
        Write-Log "Marked '$($item.Name)' as updated to version $newVersion."
    } else {
        [System.Windows.MessageBox]::Show(
            "Failed to save the version update to the configuration file.",
            "Save Error",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        )
    }
})
[void]$script:GridContextMenu.Items.Add($menuMarkUpdated)

# ── Set Version (let the user type any version) ──
$menuSetVersion = New-Object System.Windows.Controls.MenuItem
$menuSetVersion.Header = "Set Current Version..."
$menuSetVersion.Add_Click({
    $item = $dgTools.SelectedItem
    if (-not $item) { return }

    # Need VisualBasic InputBox for a simple text prompt
    $newVersion = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Enter the currently installed version for '$($item.Name)':",
        "Set Version - $($item.Name)",
        $item.CurrentVersion
    )
    if ([string]::IsNullOrWhiteSpace($newVersion)) { return }

    $saved = Save-ToolVersion -ToolName $item.Name -NewVersion $newVersion
    if ($saved) {
        $item.CurrentVersion = $newVersion
        # Re-evaluate status against latest if known
        if ($item.LatestVersion -and $item.LatestVersion -notin @("N/A","Error","No Internet","Checking...","Timeout","Unknown")) {
            if ($script:HasModule) {
                $updateAvail = Compare-Versions -CurrentVersion $newVersion -LatestVersion $item.LatestVersion
                if ($updateAvail) {
                    $item.Status    = "Update available"
                    $item.StatusKey = "UpdateAvailable"
                } else {
                    $item.Status    = "Up to date"
                    $item.StatusKey = "UpToDate"
                }
            } else {
                $item.Status    = "Up to date"
                $item.StatusKey = "UpToDate"
            }
        } else {
            $item.Status    = "Version set"
            $item.StatusKey = "UpToDate"
        }
        $item.IsSelected = $false
        Update-Summary
        Write-Log "Set '$($item.Name)' current version to $newVersion."
    } else {
        [System.Windows.MessageBox]::Show(
            "Failed to save the version to the configuration file.",
            "Save Error",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        )
    }
})
[void]$script:GridContextMenu.Items.Add($menuSetVersion)

# ── Separator ──
[void]$script:GridContextMenu.Items.Add((New-Object System.Windows.Controls.Separator))

# ── Copy Tool Details (for troubleshooting) ──
$menuCopyDetails = New-Object System.Windows.Controls.MenuItem
$menuCopyDetails.Header = "Copy Details to Clipboard"
$menuCopyDetails.Add_Click({
    $item = $dgTools.SelectedItem
    if ($item) {
        $details = [System.Text.StringBuilder]::new()
        [void]$details.AppendLine("Tool:      $($item.Name)")
        [void]$details.AppendLine("Category:  $($item.Category)")
        [void]$details.AppendLine("Path:      $($item.ToolPath)")
        [void]$details.AppendLine("Source:    $($item.SourceType)")
        [void]$details.AppendLine("Install:   $($item.InstallType)")
        [void]$details.AppendLine("Current:   $($item.CurrentVersion)")
        [void]$details.AppendLine("Latest:    $($item.LatestVersion)")
        [void]$details.AppendLine("Status:    $($item.Status)")
        [void]$details.AppendLine("URL:       $($item.DownloadUrl)")
        if ($item.Notes) {
            [void]$details.AppendLine("Notes:     $($item.Notes)")
        }
        [System.Windows.Clipboard]::SetText($details.ToString())
        Write-Log "Copied details for '$($item.Name)' to clipboard."
    }
})
[void]$script:GridContextMenu.Items.Add($menuCopyDetails)

$dgTools.ContextMenu = $script:GridContextMenu

# Forensic Mode Toggle
$btnForensicToggle.Add_Click({
    Toggle-ForensicMode
})

# Select All Updates
$btnSelectUpdates.Add_Click({
    foreach ($item in $script:ToolItems) {
        if ($item.StatusKey -eq "UpdateAvailable") {
            $item.IsSelected = $true
        }
    }
    $dgTools.Items.Refresh()
})

# Deselect All
$btnDeselectAll.Add_Click({
    foreach ($item in $script:ToolItems) {
        $item.IsSelected = $false
    }
    $dgTools.Items.Refresh()
})

# Update Selected
$btnUpdateSelected.Add_Click({
    Start-SelectedUpdates
})

# Update All (one-click: auto-select all updatable tools, then run)
$btnUpdateAll.Add_Click({
    if ($script:ForensicModeActive) {
        [System.Windows.MessageBox]::Show(
            "Forensic Mode is active.`nDisable Forensic Mode before updating tools.",
            "Forensic Mode",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        )
        return
    }

    $updatable = @($script:ToolItems | Where-Object { $_.StatusKey -eq "UpdateAvailable" })
    if ($updatable.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            "No updates available.`nAll tools are up to date.",
            "All Current",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        )
        return
    }

    $confirm = [System.Windows.MessageBox]::Show(
        "Update all $($updatable.Count) tool(s) with available updates?`n`n$(($updatable | ForEach-Object { "  - $($_.Name): $($_.CurrentVersion) -> $($_.LatestVersion)" }) -join "`n")",
        "Update All",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )
    if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }

    # Select all updatable tools and start update
    foreach ($item in $script:ToolItems) {
        $item.IsSelected = ($item.StatusKey -eq "UpdateAvailable")
    }
    $dgTools.Items.Refresh()
    Start-SelectedUpdates
})

# Cancel Update
$btnCancelUpdate.Add_Click({
    if ($script:CancelFlag) {
        $script:CancelFlag.Cancelled = $true
        $script:UpdateCancelRequested = $true
        $btnCancelUpdate.IsEnabled = $false
        $btnCancelUpdate.Content = "Cancelling..."
        Write-Log "Cancel requested - finishing current tool, then stopping..."
        Set-StatusText "Cancelling update..."
    }
})

# Retry Failed
$btnRetryFailed.Add_Click({
    $btnRetryFailed.Visibility = [System.Windows.Visibility]::Collapsed
    # Select all tools that failed in the last update run
    $failedItems = @($script:ToolItems | Where-Object { $_.Status -eq "Update failed" -and $_.StatusKey -eq "Error" })
    if ($failedItems.Count -eq 0) {
        Write-Log "No failed tools to retry."
        return
    }
    foreach ($item in $script:ToolItems) { $item.IsSelected = $false }
    foreach ($item in $failedItems) {
        $item.IsSelected = $true
        $item.StatusKey  = "UpdateAvailable"
        $item.Status     = "Update available"
    }
    $dgTools.Items.Refresh()
    Write-Log "Retrying $($failedItems.Count) failed tool(s)..."
    Start-SelectedUpdates
})

# Refresh
$btnRefresh.Add_Click({
    Start-UpdateCheck
})

# ── Navigation button handlers ──
$btnNavDashboard.Add_Click({ Set-ActivePanel "Dashboard" })
$btnNavUpdates.Add_Click({ Set-ActivePanel "Updates" })
$btnNavReferences.Add_Click({ Set-ActivePanel "References" })
$btnNavSettings.Add_Click({ Set-ActivePanel "Settings" })

# ── Dashboard: Search placeholder behavior ──
$txtDashSearch.Text = 'Search tools...'
$txtDashSearch.Foreground = $script:BrushConverter.ConvertFrom('#888888')

$txtDashSearch.Add_GotFocus({
    if ($txtDashSearch.Text -eq 'Search tools...') {
        $txtDashSearch.Text = ''
        $txtDashSearch.Foreground = $script:BrushConverter.ConvertFrom('#FFFFFF')
    }
})
$txtDashSearch.Add_LostFocus({
    if ([string]::IsNullOrWhiteSpace($txtDashSearch.Text)) {
        $txtDashSearch.Text = 'Search tools...'
        $txtDashSearch.Foreground = $script:BrushConverter.ConvertFrom('#888888')
    }
})

# ── Dashboard: Search filtering ──
$txtDashSearch.Add_TextChanged({
    $searchText = $txtDashSearch.Text
    if ($searchText -eq 'Search tools...') { $searchText = '' }
    if ($script:AllLaunchTools) {
        Populate-DashboardTiles -CategoryFilter $script:DashCurrentCategory -SearchFilter $searchText
    }
})

# ── Dashboard: Refresh button rescans the drive ──
$btnDashRefresh.Add_Click({
    if (-not $script:HasToolLauncher) { return }
    try {
        $script:AllLaunchTools = Get-LaunchableTools -DriveRoot $script:DriveRoot
        $script:IconCache = @{}
        Write-Log "Dashboard refreshed: found $($script:AllLaunchTools.Count) tools."
        Initialize-Dashboard
    } catch {
        Write-Log "ERROR: Dashboard refresh failed: $($_.Exception.Message)"
    }
})

# ── Settings: Scan for New Tools ──
$btnScanNewToolsSettings.Add_Click({
    if (-not $script:HasAutoDiscovery) {
        [System.Windows.MessageBox]::Show(
            "The Auto-Discovery module was not found at:`n$script:AutoDiscoveryPath`n`nThis feature requires the Auto-Discovery module to be installed in the modules folder.",
            "Module Not Available",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        )
        return
    }

    # Check that the Find-NewTools function is available
    if (-not (Get-Command -Name 'Find-NewTools' -ErrorAction SilentlyContinue)) {
        [System.Windows.MessageBox]::Show(
            "The Find-NewTools function is not available.`nThe Auto-Discovery module may be incomplete or failed to load.",
            "Function Not Available",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        )
        return
    }

    Set-StatusText "Scanning for new tools on the drive..."
    Write-Log "Scanning for new tools in: $script:DriveRoot"

    try {
        $newTools = Find-NewTools -DriveRoot $script:DriveRoot -ConfigPath $script:ConfigPath

        if (-not $newTools -or @($newTools).Count -eq 0) {
            Set-StatusText "Scan complete. No new tools found."
            Write-Log "No new tools discovered on the drive."
            [System.Windows.MessageBox]::Show(
                "No new tools were discovered on the drive.`nAll executables appear to be already tracked in the configuration.",
                "Scan Complete",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Information
            )
            return
        }

        # Build a selection dialog for discovered tools
        $toolList = @($newTools)
        $count = $toolList.Count
        Write-Log "Discovered $count potential new tool(s)."

        # Build display text
        $displayLines = [System.Text.StringBuilder]::new()
        [void]$displayLines.AppendLine("Found $count potential new tool(s) on the drive:")
        [void]$displayLines.AppendLine("")
        $idx = 0
        foreach ($tool in $toolList) {
            $idx++
            $name = if ($tool.Name) { $tool.Name } else { $tool.Path }
            $path = if ($tool.Path) { $tool.Path } else { "Unknown" }
            [void]$displayLines.AppendLine("  $idx. $name")
            [void]$displayLines.AppendLine("     Path: $path")
            [void]$displayLines.AppendLine("")
        }
        [void]$displayLines.AppendLine("Would you like to add these to the configuration?")
        [void]$displayLines.AppendLine("(You can edit details in tools-config.json afterward)")

        $result = [System.Windows.MessageBox]::Show(
            $displayLines.ToString(),
            "New Tools Discovered ($count found)",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question
        )

        if ($result -eq [System.Windows.MessageBoxResult]::Yes) {
            if (Get-Command -Name 'Add-ToolsToConfig' -ErrorAction SilentlyContinue) {
                try {
                    Add-ToolsToConfig -Tools $toolList -ConfigPath $script:ConfigPath
                    Write-Log "Added $count new tool(s) to configuration."
                    Set-StatusText "Added $count new tool(s). Refreshing..."
                    Start-UpdateCheck
                } catch {
                    Write-Log "ERROR: Failed to add tools to config: $_"
                    [System.Windows.MessageBox]::Show(
                        "Failed to update configuration:`n$_",
                        "Error",
                        [System.Windows.MessageBoxButton]::OK,
                        [System.Windows.MessageBoxImage]::Error
                    )
                }
            } else {
                Write-Log "Add-ToolsToConfig function not available. Tools were discovered but not added."
                [System.Windows.MessageBox]::Show(
                    "The tools were discovered but the Add-ToolsToConfig function is not available in the Auto-Discovery module.`nPlease add them manually to tools-config.json.",
                    "Manual Action Required",
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Information
                )
            }
        } else {
            Write-Log "User declined to add discovered tools."
        }

        Set-StatusText "Scan complete. $count new tool(s) found."
    } catch {
        Set-StatusText "Scan failed."
        Write-Log "ERROR: Tool scan failed: $_"
        [System.Windows.MessageBox]::Show(
            "Tool scan failed:`n$_",
            "Scan Error",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        )
    }
})

# ── Settings: Forensic Report ──
$btnForensicReportSettings.Add_Click({
    Set-StatusText "Generating forensic report..."
    Write-Log "Generating forensic integrity report..."

    $reportPath = New-ForensicReport

    if ($reportPath) {
        $result = [System.Windows.MessageBox]::Show(
            "Forensic report saved to:`n$reportPath`n`nWould you like to open it now?",
            "Report Generated",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Information
        )
        if ($result -eq [System.Windows.MessageBoxResult]::Yes) {
            Start-Process notepad.exe -ArgumentList "`"$reportPath`""
        }
        Set-StatusText "Report saved."
    } else {
        Set-StatusText "Report generation failed."
    }
})

# ── Settings: Export Tool List as CSV ──
$btnExportCsv.Add_Click({
    if ($script:ToolItems.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            "No tools loaded. Run an update check first to populate the tool list.",
            "No Data",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        )
        return
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $exportDir = Join-Path $script:ScriptDir 'exports'
    if (-not (Test-Path -LiteralPath $exportDir)) {
        [void](New-Item -Path $exportDir -ItemType Directory -Force)
    }
    $csvPath = Join-Path $exportDir "DFIR-Tools_$timestamp.csv"

    try {
        $rows = @()
        foreach ($item in $script:ToolItems) {
            $rows += [PSCustomObject]@{
                Name           = $item.Name
                Category       = $item.Category
                CurrentVersion = $item.CurrentVersion
                LatestVersion  = $item.LatestVersion
                Status         = $item.Status
                SourceType     = $item.SourceType
                InstallType    = $item.InstallType
                Path           = $item.ToolPath
                DownloadUrl    = $item.DownloadUrl
                Notes          = $item.Notes
            }
        }
        $rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

        Write-Log "Exported $($rows.Count) tools to: $csvPath"
        $result = [System.Windows.MessageBox]::Show(
            "Tool list exported to:`n$csvPath`n`nWould you like to open it?",
            "Export Complete",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Information
        )
        if ($result -eq [System.Windows.MessageBoxResult]::Yes) {
            Start-Process $csvPath
        }
    } catch {
        Write-Log "ERROR: CSV export failed: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show(
            "Export failed:`n$($_.Exception.Message)",
            "Export Error",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        )
    }
})

# ── Settings: Open Config File ──
$btnOpenConfig.Add_Click({
    if (Test-Path -LiteralPath $script:ConfigPath) {
        Start-Process notepad.exe -ArgumentList "`"$script:ConfigPath`""
        Write-Log "Opened config file: $script:ConfigPath"
    } else {
        [System.Windows.MessageBox]::Show(
            "Config file not found:`n$script:ConfigPath",
            "File Not Found",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        )
    }
})

# ── Settings: Unblock All Tools ──
$btnUnblockAll.Add_Click({
    if ($script:ForensicModeActive) {
        $txtUnblockResult.Text = "Cannot unblock files while Forensic Mode is active."
        $txtUnblockResult.Foreground = $script:BrushConverter.ConvertFrom('#FF4444')
        return
    }

    $btnUnblockAll.IsEnabled = $false
    $btnUnblockAll.Content = "Unblocking..."
    $count = 0
    $errors = 0

    try {
        # Scan all category folders for executables with MOTW
        $categoryDirs = @('01_Acquisition','02_Analysis','03_Network','04_Mobile-Forensics','08_Utilities')
        foreach ($catDir in $categoryDirs) {
            $fullDir = Join-Path $script:DriveRoot $catDir
            if (-not (Test-Path -LiteralPath $fullDir)) { continue }

            $exes = @(Get-ChildItem -Path $fullDir -Filter '*.exe' -Recurse -File -ErrorAction SilentlyContinue)
            foreach ($exe in $exes) {
                try {
                    $zone = Get-Content -LiteralPath $exe.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue
                    if ($zone) {
                        Remove-Item -LiteralPath $exe.FullName -Stream Zone.Identifier -ErrorAction Stop
                        $count++
                    }
                } catch {
                    $errors++
                }
            }
        }

        $msg = "Unblocked $count file(s)."
        if ($errors -gt 0) { $msg += " $errors file(s) could not be unblocked." }
        $txtUnblockResult.Text = $msg
        $txtUnblockResult.Foreground = $script:BrushConverter.ConvertFrom($(if ($errors -gt 0) { '#FFD93D' } else { '#4CAF50' }))
        Write-Log "Unblock All: $msg"
    } catch {
        $txtUnblockResult.Text = "Error: $($_.Exception.Message)"
        $txtUnblockResult.Foreground = $script:BrushConverter.ConvertFrom('#FF4444')
        Write-Log "ERROR: Unblock All failed: $($_.Exception.Message)"
    } finally {
        $btnUnblockAll.IsEnabled = $true
        $btnUnblockAll.Content = "Unblock All Tools"
    }
})

# ── Settings: Forensic Mode Toggle ──
$btnForensicToggleSettings.Add_Click({
    Toggle-ForensicMode
})

# Toggle Log panel
$btnToggleLog.Add_Checked({
    $logPanel.Visibility = [System.Windows.Visibility]::Visible
    $btnToggleLog.Content = [char]0x25BC + " Log"
})

$btnToggleLog.Add_Unchecked({
    $logPanel.Visibility = [System.Windows.Visibility]::Collapsed
    $btnToggleLog.Content = [char]0x25B6 + " Log"
})

# ─── Keyboard Shortcuts ──────────────────────────────────────────────────────
$window.Add_PreviewKeyDown({
    param($sender, $e)
    $ctrl = [System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control

    # Don't intercept when a TextBox has focus (let typing work normally)
    $focused = [System.Windows.Input.FocusManager]::GetFocusedElement($window)
    $inTextBox = $focused -is [System.Windows.Controls.TextBox]

    if ($ctrl) {
        switch ($e.Key) {
            'D1' { Set-ActivePanel "Dashboard";  $e.Handled = $true }   # Ctrl+1
            'D2' { Set-ActivePanel "Updates";    $e.Handled = $true }   # Ctrl+2
            'D3' { Set-ActivePanel "References"; $e.Handled = $true }   # Ctrl+3
            'D4' { Set-ActivePanel "Settings";   $e.Handled = $true }   # Ctrl+4
            'R'  {                                                      # Ctrl+R  Refresh
                if (-not $inTextBox -and -not $script:ForensicModeActive) {
                    Start-UpdateCheck; $e.Handled = $true
                }
            }
            'F'  {                                                      # Ctrl+F  Focus search
                if (-not $inTextBox) {
                    Set-ActivePanel "Dashboard"
                    $txtDashSearch.Focus()
                    if ($txtDashSearch.Text -eq 'Search tools...') {
                        $txtDashSearch.Text = ''
                        $txtDashSearch.Foreground = $script:BrushConverter.ConvertFrom('#FFFFFF')
                    }
                    $e.Handled = $true
                }
            }
            'L'  {                                                      # Ctrl+L  Toggle log
                if (-not $inTextBox) {
                    $btnToggleLog.IsChecked = -not $btnToggleLog.IsChecked
                    $e.Handled = $true
                }
            }
        }
    } else {
        switch ($e.Key) {
            'F5' {                                                      # F5  Check for updates
                if (-not $script:ForensicModeActive) {
                    Start-UpdateCheck; $e.Handled = $true
                }
            }
            'Escape' {                                                  # Esc  Clear search / unfocus
                if ($inTextBox) {
                    $txtDashSearch.Text = ''
                    $window.Focus()
                    $e.Handled = $true
                }
            }
        }
    }
})

# ─── Window Loaded: Kick Off Initial Check ──────────────────────────────────
$window.Add_Loaded({
    try {
        Write-Log "DFIR Drive Updater initialized."
        Write-Log "Drive root: $script:DriveRoot"
        if (-not $script:HasModule) {
            Write-Log "WARNING: Update-Checker module not found. Running in preview mode."
        }

        # Set default panel
        Set-ActivePanel "Dashboard"

        # Initialize dashboard
        if ($script:HasToolLauncher) {
            try {
                Initialize-Dashboard
            } catch {
                Write-Host "[DIAG] Dashboard init FAILED: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "[DIAG] $($_.ScriptStackTrace)" -ForegroundColor Red
                Write-Log "Dashboard init failed: $($_.Exception.Message)"
            }
        }

        # Initialize Linux/macOS references panel
        try {
            Initialize-LinuxReferences
        } catch {
            Write-Log "References panel init failed: $($_.Exception.Message)"
        }

        # Set initial forensic mode UI
        Update-ForensicModeUI

        if ($script:ForensicModeActive) {
            Write-Log "Forensic Mode is active. Updates are disabled."
            # Re-apply write protection in case it was lost (e.g. drive re-plugged)
            Write-Log "Verifying write protection..."
            $wpOk = Set-WriteProtection -Enable $true
            if ($wpOk) {
                Write-Log "Write protection verified/re-applied."
            } else {
                Write-Log "WARNING: Could not verify write protection. May need admin privileges."
            }
        } else {
            Start-UpdateCheck
        }

        # Show drive info in Settings
        $txtDrivePathSettings.Text = "Drive: $script:DriveRoot"
        $txtToolCountSettings.Text = "Tools: $($script:ToolItems.Count) tracked in config"
        Update-DriveSpaceInfo

        # Detect available package managers
        if ($script:HasPkgManager) {
            $pms = Get-AvailablePackageManagers
            if ($pms.Count -gt 0) {
                $pmNames = ($pms | ForEach-Object { "$($_.Name) $($_.Version)" }) -join ', '
                Write-Log "Package managers available: $pmNames"
            } else {
                Write-Log "No package managers detected (winget, scoop, choco). Using direct download for updates."
            }
        }
    } catch {
        # Ensure the GUI is usable even if initialization fails
        Write-Host "[DIAG] ERROR in Window.Loaded: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "[DIAG] $($_.ScriptStackTrace)" -ForegroundColor Red
        try { Write-Log "ERROR during initialization: $($_.Exception.Message)" } catch {}
        try { Set-StatusText "Initialization error. Use Refresh to retry." } catch {}
        try {
            $btnRefresh.IsEnabled        = $true
            $btnUpdateSelected.IsEnabled = $true
            $btnSelectUpdates.IsEnabled  = $true
            $btnDeselectAll.IsEnabled    = $true
        } catch {}
    }
})

# ─── Pre-create background runspace pool ─────────────────────────────────
# Use MTA apartment state — background threads do not need STA since they
# never access UI/COM elements directly.  STA requires a running message
# pump; calling Open() in STA *before* the WPF message loop starts will
# hang the process indefinitely, which is the primary freeze root-cause.
$script:RunspacePool = $null
try {
    $script:RunspacePool = [RunspaceFactory]::CreateRunspacePool(1, 2)
    $script:RunspacePool.ApartmentState = [System.Threading.ApartmentState]::MTA
    $script:RunspacePool.Open()
} catch {
    Write-Log "ERROR: RunspacePool creation failed: $($_.Exception.Message)"
}

# Clean up pool when window closes
$window.Add_Closed({
    try {
        if ($script:RunspacePool) {
            $script:RunspacePool.Close()
            $script:RunspacePool.Dispose()
        }
    } catch {}
})

# ─── Show the Window ────────────────────────────────────────────────────────
# ShowDialog() uses a nested DispatcherFrame that can freeze in PowerShell 5.1.
# Application.Run() provides a proper top-level WPF message pump instead.
try {
    $app = [System.Windows.Application]::new()
    $app.ShutdownMode = [System.Windows.ShutdownMode]::OnMainWindowClose
    # Catch unhandled exceptions inside WPF message pump to prevent silent crashes
    $app.Add_DispatcherUnhandledException({
        param($sender, $e)
        $msg = $e.Exception.Message
        $src = $e.Exception.Source
        $stk = $e.Exception.StackTrace
        $inner = if ($e.Exception.InnerException) { $e.Exception.InnerException.Message } else { '' }

        Write-Host "[DIAG] WPF unhandled exception: $msg" -ForegroundColor Red
        Write-Host "[DIAG] Source: $src" -ForegroundColor Red
        Write-Host "[DIAG] Stack: $stk" -ForegroundColor Red
        if ($inner) { Write-Host "[DIAG] Inner: $inner" -ForegroundColor Red }

        # Write to debug log file
        Write-DebugLog "UNHANDLED EXCEPTION: $msg" 'ERROR'
        Write-DebugLog "  Source: $src" 'ERROR'
        Write-DebugLog "  Stack: $stk" 'ERROR'
        if ($inner) { Write-DebugLog "  Inner: $inner" 'ERROR' }

        $e.Handled = $true  # Prevent crash, keep GUI running
    })
    [void]$app.Run($window)
} catch {
    # Fallback if Application already exists or other issue
    Write-Host "[DIAG] Application.Run failed: $($_.Exception.Message), using Dispatcher.Run fallback" -ForegroundColor Yellow
    Write-DebugLog "Application.Run failed: $($_.Exception.Message) - using Dispatcher.Run fallback" 'WARN'
    if ($_.Exception.InnerException) {
        Write-Host "[DIAG] Inner: $($_.Exception.InnerException.Message)" -ForegroundColor Red
        Write-DebugLog "  Inner: $($_.Exception.InnerException.Message)" 'WARN'
    }
    $window.Add_Closed({
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
    })
    $window.Show()
    [System.Windows.Threading.Dispatcher]::Run()
}
