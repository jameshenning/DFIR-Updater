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

# ─── Forensic Mode Check ─────────────────────────────────────────────────────
$script:ForensicModeFile = Join-Path $script:DriveRoot 'FORENSIC_MODE'
if (Test-Path -LiteralPath $script:ForensicModeFile) {
    [System.Windows.MessageBox]::Show(
        "Forensic Mode is active.`n`nThe updater is blocked to protect target system integrity.`nDisable Forensic Mode from Forensic-Mode.bat before using the updater.",
        'DFIR Drive Updater - Forensic Mode',
        'OK',
        'Warning'
    ) | Out-Null
    exit
}

$script:ModulePath          = Join-Path $script:ScriptDir "modules\Update-Checker.ps1"
$script:AutoDiscoveryPath   = Join-Path $script:ScriptDir "modules\Auto-Discovery.ps1"
$script:ConfigPath          = Join-Path $script:ScriptDir "tools-config.json"
$script:HasModule           = Test-Path $script:ModulePath
$script:HasAutoDiscovery    = Test-Path $script:AutoDiscoveryPath

# ─── Dot-source the update-checker backend ───────────────────────────────────
if ($script:HasModule) {
    . $script:ModulePath
} else {
    Write-Warning "Update-Checker module not found at: $script:ModulePath"
    Write-Warning "Running in UI-preview mode with sample data."
}

# ─── Dot-source the auto-discovery module (optional) ─────────────────────────
if ($script:HasAutoDiscovery) {
    . $script:AutoDiscoveryPath
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
    Width="880" Height="650"
    MinWidth="700" MinHeight="500"
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

        <!-- Close (red-ish) button -->
        <Style x:Key="CloseButton" TargetType="Button" BasedOn="{StaticResource ActionButton}">
            <Setter Property="Background"  Value="#4A2020"/>
            <Setter Property="BorderBrush" Value="#6A3030"/>
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
                                <Setter TargetName="border" Property="Background" Value="#7A3030"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#9A4040"/>
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
            <RowDefinition Height="Auto"/>   <!-- Header -->
            <RowDefinition Height="Auto"/>   <!-- Status bar -->
            <RowDefinition Height="*"/>      <!-- DataGrid -->
            <RowDefinition Height="Auto"/>   <!-- Buttons -->
            <RowDefinition Height="Auto"/>   <!-- Log toggle -->
            <RowDefinition Height="Auto"/>   <!-- Log area -->
        </Grid.RowDefinitions>

        <!-- Header -->
        <Border Grid.Row="0" Background="#252526" Padding="16,12" BorderBrush="#3E3E3E" BorderThickness="0,0,0,1">
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
                        <Border Background="#1B5E20" CornerRadius="3" Padding="8,2" Margin="12,0,0,0" VerticalAlignment="Center">
                            <TextBlock Text="FORENSIC MODE: OFF" FontSize="10" FontWeight="SemiBold" Foreground="#4CAF50"/>
                        </Border>
                    </StackPanel>
                    <TextBlock x:Name="txtDrivePath" FontSize="11" Foreground="#999999" Margin="0,2,0,0"/>
                </StackPanel>

                <StackPanel Grid.Column="2" VerticalAlignment="Center" Orientation="Horizontal">
                    <TextBlock x:Name="txtSummary" FontSize="12" Foreground="#AAAAAA"
                               VerticalAlignment="Center" Margin="0,0,8,0"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- Status Bar -->
        <Border Grid.Row="1" Background="#2D2D30" Padding="12,6" BorderBrush="#3E3E3E" BorderThickness="0,0,0,1">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="txtStatus" Grid.Column="0" Text="Ready" FontSize="12"
                           Foreground="#CCCCCC" VerticalAlignment="Center" Margin="0,0,12,0"/>
                <ProgressBar x:Name="progressBar" Grid.Column="1" Height="6"
                             Minimum="0" Maximum="100" Value="0"
                             Background="#3E3E3E" Foreground="#0078D4"
                             BorderThickness="0" VerticalAlignment="Center"/>
            </Grid>
        </Border>

        <!-- DataGrid -->
        <DataGrid x:Name="dgTools" Grid.Row="2"
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
                <DataGridTextColumn Header="Current"         Binding="{Binding CurrentVersion}" Width="90"   IsReadOnly="True"/>
                <DataGridTextColumn Header="Latest"          Binding="{Binding LatestVersion}"  Width="90"   IsReadOnly="True"/>

                <DataGridTemplateColumn Header="Status" Width="150" IsReadOnly="True" CanUserSort="True" SortMemberPath="StatusKey">
                    <DataGridTemplateColumn.CellTemplate>
                        <DataTemplate>
                            <TextBlock Text="{Binding Status}" Padding="4,0">
                                <TextBlock.Style>
                                    <Style TargetType="TextBlock">
                                        <Setter Property="Foreground" Value="#AAAAAA"/>
                                        <Style.Triggers>
                                            <DataTrigger Binding="{Binding StatusKey}" Value="UpToDate">
                                                <Setter Property="Foreground" Value="#6BCB77"/>
                                            </DataTrigger>
                                            <DataTrigger Binding="{Binding StatusKey}" Value="UpdateAvailable">
                                                <Setter Property="Foreground" Value="#FFD93D"/>
                                            </DataTrigger>
                                            <DataTrigger Binding="{Binding StatusKey}" Value="ManualCheck">
                                                <Setter Property="Foreground" Value="#AAAAAA"/>
                                            </DataTrigger>
                                            <DataTrigger Binding="{Binding StatusKey}" Value="Checking">
                                                <Setter Property="Foreground" Value="#6CB4EE"/>
                                            </DataTrigger>
                                            <DataTrigger Binding="{Binding StatusKey}" Value="Error">
                                                <Setter Property="Foreground" Value="#FF6B6B"/>
                                            </DataTrigger>
                                        </Style.Triggers>
                                    </Style>
                                </TextBlock.Style>
                            </TextBlock>
                        </DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                </DataGridTemplateColumn>
            </DataGrid.Columns>
        </DataGrid>

        <!-- Button Bar -->
        <Border Grid.Row="3" Background="#252526" Padding="12,10" BorderBrush="#3E3E3E" BorderThickness="0,1,0,0">
            <DockPanel>
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                    <Button x:Name="btnClose" Content="Close" Style="{StaticResource CloseButton}"/>
                </StackPanel>

                <StackPanel Orientation="Horizontal">
                    <Button x:Name="btnSelectUpdates" Content="Select All Updates" Style="{StaticResource ActionButton}"/>
                    <Button x:Name="btnDeselectAll"    Content="Deselect All"       Style="{StaticResource ActionButton}"/>
                    <Button x:Name="btnUpdateSelected" Content="Update Selected"    Style="{StaticResource PrimaryButton}"/>
                    <Button x:Name="btnRefresh"        Content="Refresh"            Style="{StaticResource ActionButton}"/>
                    <Button x:Name="btnScanNewTools"   Content="Scan for New Tools" Style="{StaticResource ActionButton}"/>
                </StackPanel>
            </DockPanel>
        </Border>

        <!-- Log Toggle -->
        <Border Grid.Row="4" Background="#252526" Padding="12,5" BorderBrush="#3E3E3E" BorderThickness="0,1,0,0">
            <ToggleButton x:Name="btnToggleLog" Content="&#x25B6; Show Log" FontSize="12"
                          Background="Transparent" Foreground="#AAAAAA" BorderThickness="0"
                          Cursor="Hand" HorizontalAlignment="Left" Padding="4,2"/>
        </Border>

        <!-- Log Area (collapsed by default) -->
        <Border x:Name="logPanel" Grid.Row="5" Background="#1A1A1A" Padding="8"
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
$txtDrivePath      = $window.FindName("txtDrivePath")
$txtStatus         = $window.FindName("txtStatus")
$txtSummary        = $window.FindName("txtSummary")
$progressBar       = $window.FindName("progressBar")
$dgTools           = $window.FindName("dgTools")
$btnSelectUpdates  = $window.FindName("btnSelectUpdates")
$btnDeselectAll    = $window.FindName("btnDeselectAll")
$btnUpdateSelected = $window.FindName("btnUpdateSelected")
$btnRefresh        = $window.FindName("btnRefresh")
$btnScanNewTools   = $window.FindName("btnScanNewTools")
$btnClose          = $window.FindName("btnClose")
$btnToggleLog      = $window.FindName("btnToggleLog")
$logPanel          = $window.FindName("logPanel")
$txtLog            = $window.FindName("txtLog")

# ─── State ───────────────────────────────────────────────────────────────────
$script:ToolItems = [System.Collections.ObjectModel.ObservableCollection[ToolItem]]::new()
$dgTools.ItemsSource = $script:ToolItems
$txtDrivePath.Text = "Drive: $script:DriveRoot"

# ─── Category Map: derive display category from path prefix ─────────────────
$script:CategoryMap = @{
    '01_Acquisition' = 'Acquisition'
    '02_Analysis'    = 'Analysis'
    '03_Network'     = 'Network'
    '04_Memory'      = 'Memory'
    '05_Registry'    = 'Registry'
    '06_Mobile'      = 'Mobile'
    '07_Malware'     = 'Malware'
    '08_Utilities'   = 'Utilities'
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

# ─── Helper: Append to Log (thread-safe) ────────────────────────────────────
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "HH:mm:ss"
    $line = "[$timestamp] $Message`r`n"
    $txtLog.Dispatcher.Invoke([Action]{
        $txtLog.AppendText($line)
        $txtLog.ScrollToEnd()
    })
}

# ─── Helper: Update Status Text (thread-safe) ───────────────────────────────
function Set-StatusText {
    param([string]$Text)
    $txtStatus.Dispatcher.Invoke([Action]{ $txtStatus.Text = $Text })
}

# ─── Helper: Update Progress Bar (thread-safe) ──────────────────────────────
function Set-Progress {
    param([double]$Value, [bool]$Indeterminate = $false)
    $progressBar.Dispatcher.Invoke([Action]{
        $progressBar.IsIndeterminate = $Indeterminate
        $progressBar.Value = $Value
    })
}

# ─── Helper: Update Summary Counts ──────────────────────────────────────────
function Update-Summary {
    $upToDate  = @($script:ToolItems | Where-Object { $_.StatusKey -eq "UpToDate"        }).Count
    $available = @($script:ToolItems | Where-Object { $_.StatusKey -eq "UpdateAvailable" }).Count
    $manual    = @($script:ToolItems | Where-Object { $_.StatusKey -eq "ManualCheck"     }).Count
    $errors    = @($script:ToolItems | Where-Object { $_.StatusKey -eq "Error"           }).Count
    $total     = $script:ToolItems.Count
    $txtSummary.Dispatcher.Invoke([Action]{
        $parts = @("$total tools")
        if ($upToDate  -gt 0) { $parts += "$upToDate current"  }
        if ($available -gt 0) { $parts += "$available updates" }
        if ($manual    -gt 0) { $parts += "$manual manual"     }
        if ($errors    -gt 0) { $parts += "$errors errors"     }
        $txtSummary.Text = $parts -join " | "
    })
}

# ─── Helper: Test internet connectivity ──────────────────────────────────────
function Test-InternetConnection {
    try {
        $request = [System.Net.WebRequest]::Create("https://api.github.com")
        $request.Timeout = 5000
        $request.Method  = "HEAD"
        $request.Headers.Add("User-Agent", "DFIR-Updater/1.0")
        $response = $request.GetResponse()
        $response.Close()
        return $true
    } catch {
        return $false
    }
}

# ─── Background Check for Updates ────────────────────────────────────────────
function Start-UpdateCheck {
    # Disable buttons during check
    $btnRefresh.IsEnabled        = $false
    $btnUpdateSelected.IsEnabled = $false
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

    # ── Run the actual version checks in a background runspace ──
    $runspace = [RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions  = "ReuseThread"
    $runspace.Open()

    $runspace.SessionState.PSVariable.Set("DriveRoot",   $script:DriveRoot)
    $runspace.SessionState.PSVariable.Set("ModulePath",  $script:ModulePath)
    $runspace.SessionState.PSVariable.Set("ConfigPath",  $script:ConfigPath)
    $runspace.SessionState.PSVariable.Set("HasModule",   $script:HasModule)
    $runspace.SessionState.PSVariable.Set("ToolItems",   $script:ToolItems)
    $runspace.SessionState.PSVariable.Set("Dispatcher",  $window.Dispatcher)

    $psCmd = [PowerShell]::Create()
    $psCmd.Runspace = $runspace

    [void]$psCmd.AddScript({
        # Check internet first
        $hasInternet = $true
        try {
            $req = [System.Net.WebRequest]::Create("https://api.github.com")
            $req.Timeout = 5000
            $req.Method  = "HEAD"
            $req.Headers.Add("User-Agent", "DFIR-Updater/1.0")
            $resp = $req.GetResponse()
            $resp.Close()
        } catch {
            $hasInternet = $false
        }

        if (-not $hasInternet) {
            $Dispatcher.Invoke([Action]{
                foreach ($item in $ToolItems) {
                    $item.LatestVersion = "No Internet"
                    $item.Status        = "No connection"
                    $item.StatusKey     = "Error"
                }
            })
            return @{ Success = $false; Error = "NoInternet" }
        }

        # Use the module if available
        if ($HasModule) {
            try {
                . $ModulePath

                $results = Get-AllUpdateStatus -ConfigPath $ConfigPath

                # Map results back to the UI items
                $Dispatcher.Invoke([Action]{
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

                        # Determine status
                        if ($r.UpdateAvailable -eq $true) {
                            $matchItem.Status    = "Update available"
                            $matchItem.StatusKey = "UpdateAvailable"
                        } elseif ($r.UpdateAvailable -eq $false) {
                            $matchItem.Status    = "Up to date"
                            $matchItem.StatusKey = "UpToDate"
                        } elseif ($r.SourceType -eq 'web') {
                            $matchItem.LatestVersion = "N/A"
                            $matchItem.Status        = "Check manually  ?"
                            $matchItem.StatusKey     = "ManualCheck"
                        } elseif ($r.Notes -and $r.Notes -match 'error|fail') {
                            $matchItem.LatestVersion = "Error"
                            $matchItem.Status        = "Error checking"
                            $matchItem.StatusKey     = "Error"
                        } else {
                            $matchItem.LatestVersion = "N/A"
                            $matchItem.Status        = "Check manually  ?"
                            $matchItem.StatusKey     = "ManualCheck"
                        }
                    }
                }.GetNewClosure())

                return @{ Success = $true; Count = @($results).Count }
            } catch {
                $errMsg = $_.Exception.Message
                $Dispatcher.Invoke([Action]{
                    foreach ($item in $ToolItems) {
                        if ($item.StatusKey -eq "Checking") {
                            $item.LatestVersion = "Error"
                            $item.Status        = "Module error"
                            $item.StatusKey     = "Error"
                        }
                    }
                }.GetNewClosure())
                return @{ Success = $false; Error = $errMsg }
            }
        }
        else {
            # No module: simulate with sample results for preview mode
            $Dispatcher.Invoke([Action]{
                foreach ($item in $ToolItems) {
                    Start-Sleep -Milliseconds 100
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
            })
            return @{ Success = $true; Count = $ToolItems.Count; Preview = $true }
        }
    })

    $handle = $psCmd.BeginInvoke()

    # ── DispatcherTimer to poll for runspace completion without blocking the UI ──
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $timer.Tag = @{ Handle = $handle; Command = $psCmd; Runspace = $runspace }

    $timer.Add_Tick({
        $info = $this.Tag
        if ($info.Handle.IsCompleted) {
            $this.Stop()

            try {
                $result = $info.Command.EndInvoke($info.Handle)
            } catch { }

            # Log any runspace errors
            if ($info.Command.Streams.Error.Count -gt 0) {
                foreach ($err in $info.Command.Streams.Error) {
                    Write-Log "RUNSPACE ERROR: $($err.ToString())"
                }
            }

            $info.Command.Dispose()
            $info.Runspace.Close()

            # Re-enable buttons
            $btnRefresh.IsEnabled        = $true
            $btnUpdateSelected.IsEnabled = $true
            $btnSelectUpdates.IsEnabled  = $true

            Set-Progress -Value 100 -Indeterminate $false
            Update-Summary

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
    })

    $timer.Start()
}

# ─── Background Update Execution ─────────────────────────────────────────────
function Start-SelectedUpdates {
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

    # Disable buttons
    $btnRefresh.IsEnabled        = $false
    $btnUpdateSelected.IsEnabled = $false
    $btnSelectUpdates.IsEnabled  = $false
    $btnDeselectAll.IsEnabled    = $false

    Set-StatusText "Updating tools..."
    Set-Progress -Value 0 -Indeterminate $false
    Write-Log "Starting update for $($selected.Count) tool(s)..."

    # Expand log panel automatically
    $btnToggleLog.IsChecked = $true
    $logPanel.Visibility = [System.Windows.Visibility]::Visible
    $btnToggleLog.Content = [char]0x25BC + " Hide Log"

    # Build data to pass into the runspace
    $updateJobs = @()
    foreach ($item in $selected) {
        $updateJobs += @{
            Name        = $item.Name
            DownloadUrl = $item.DownloadUrl
            ToolPath    = $item.ToolPath
            InstallType = $item.InstallType
        }
    }

    $runspace = [RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions  = "ReuseThread"
    $runspace.Open()

    $runspace.SessionState.PSVariable.Set("DriveRoot",   $script:DriveRoot)
    $runspace.SessionState.PSVariable.Set("ModulePath",  $script:ModulePath)
    $runspace.SessionState.PSVariable.Set("HasModule",   $script:HasModule)
    $runspace.SessionState.PSVariable.Set("ToolItems",   $script:ToolItems)
    $runspace.SessionState.PSVariable.Set("UpdateJobs",  $updateJobs)
    $runspace.SessionState.PSVariable.Set("Dispatcher",  $window.Dispatcher)

    $psCmd = [PowerShell]::Create()
    $psCmd.Runspace = $runspace

    [void]$psCmd.AddScript({
        if ($HasModule) {
            . $ModulePath
        }

        $successCount = 0
        $failCount    = 0
        $idx          = 0

        foreach ($job in $UpdateJobs) {
            $idx++
            $name = $job.Name

            # Mark as "Updating..." on UI
            $Dispatcher.Invoke([Action]{
                $item = $ToolItems | Where-Object { $_.Name -eq $name } | Select-Object -First 1
                if ($item) { $item.Status = "Updating..." }
            }.GetNewClosure())

            $success = $false
            $message = ""

            if ($HasModule) {
                # Use Install-ToolUpdate from the module
                $installPath = Join-Path $DriveRoot $job.ToolPath

                if ([string]::IsNullOrWhiteSpace($job.DownloadUrl)) {
                    $message = "No download URL for '$name'."
                } elseif ($job.InstallType -eq 'manual') {
                    # Open browser for manual installs
                    try {
                        Start-Process $job.DownloadUrl -ErrorAction Stop
                        $success = $true
                        $message = "Opened download page for '$name'."
                    } catch {
                        $message = "Failed to open URL for '$name': $_"
                    }
                } else {
                    try {
                        $result = Install-ToolUpdate -ToolName $name `
                                                     -DownloadUrl $job.DownloadUrl `
                                                     -InstallPath $installPath `
                                                     -InstallType $job.InstallType `
                                                     -Confirm:$false
                        $success = $result.Success
                        $message = $result.Message
                    } catch {
                        $message = "Update failed for '$name': $_"
                    }
                }
            } else {
                # Preview mode: simulate
                Start-Sleep -Milliseconds (Get-Random -Minimum 500 -Maximum 1500)
                $success = ((Get-Random -Minimum 0 -Maximum 10) -lt 8)
                $message = if ($success) { "Simulated success." } else { "Simulated failure." }
            }

            if ($success) {
                $successCount++
                $Dispatcher.Invoke([Action]{
                    $item = $ToolItems | Where-Object { $_.Name -eq $name } | Select-Object -First 1
                    if ($item) {
                        if ($item.LatestVersion -and $item.LatestVersion -notin @("N/A","Error","No Internet","Checking...")) {
                            $item.CurrentVersion = $item.LatestVersion
                        }
                        $item.Status    = "Up to date"
                        $item.StatusKey = "UpToDate"
                        $item.IsSelected = $false
                    }
                }.GetNewClosure())
            } else {
                $failCount++
                $Dispatcher.Invoke([Action]{
                    $item = $ToolItems | Where-Object { $_.Name -eq $name } | Select-Object -First 1
                    if ($item) {
                        $item.Status    = "Update failed"
                        $item.StatusKey = "Error"
                    }
                }.GetNewClosure())
            }
        }

        return @{ Success = $successCount; Failed = $failCount; Total = $UpdateJobs.Count }
    })

    $handle = $psCmd.BeginInvoke()

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(300)
    $timer.Tag = @{ Handle = $handle; Command = $psCmd; Runspace = $runspace }

    $timer.Add_Tick({
        $info = $this.Tag

        if ($info.Handle.IsCompleted) {
            $this.Stop()

            $result = $null
            try {
                $result = $info.Command.EndInvoke($info.Handle)
            } catch { }

            # Log runspace errors
            if ($info.Command.Streams.Error.Count -gt 0) {
                foreach ($err in $info.Command.Streams.Error) {
                    Write-Log "UPDATE ERROR: $($err.ToString())"
                }
            }

            $info.Command.Dispose()
            $info.Runspace.Close()

            # Re-enable buttons
            $btnRefresh.IsEnabled        = $true
            $btnUpdateSelected.IsEnabled = $true
            $btnSelectUpdates.IsEnabled  = $true
            $btnDeselectAll.IsEnabled    = $true

            Set-Progress -Value 100 -Indeterminate $false

            $s = 0; $f = 0
            if ($result -and $result.Count -gt 0) {
                $r = $result[0]
                if ($r -is [hashtable]) {
                    $s = $r.Success; $f = $r.Failed
                }
            }

            Set-StatusText "Update complete."
            Update-Summary
            Write-Log "Update complete: $s succeeded, $f failed."

            [System.Windows.MessageBox]::Show(
                "$s tool(s) updated successfully.`n$f tool(s) failed.",
                "Update Complete",
                [System.Windows.MessageBoxButton]::OK,
                $(if ($f -gt 0) { [System.Windows.MessageBoxImage]::Warning } else { [System.Windows.MessageBoxImage]::Information })
            )
        } else {
            # Show per-tool progress while running
            $updatingName = ($script:ToolItems | Where-Object { $_.Status -eq "Updating..." } | Select-Object -First 1).Name
            if ($updatingName) {
                Set-StatusText "Updating: $updatingName ..."
            }
        }
    })

    $timer.Start()
}

# ─── Wire Up Event Handlers ─────────────────────────────────────────────────

# Select All Updates
$btnSelectUpdates.Add_Click({
    foreach ($item in $script:ToolItems) {
        if ($item.StatusKey -eq "UpdateAvailable") {
            $item.IsSelected = $true
        }
    }
})

# Deselect All
$btnDeselectAll.Add_Click({
    foreach ($item in $script:ToolItems) {
        $item.IsSelected = $false
    }
})

# Update Selected
$btnUpdateSelected.Add_Click({
    Start-SelectedUpdates
})

# Refresh
$btnRefresh.Add_Click({
    Start-UpdateCheck
})

# Scan for New Tools
$btnScanNewTools.Add_Click({
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

# Close
$btnClose.Add_Click({
    $window.Close()
})

# Toggle Log panel
$btnToggleLog.Add_Checked({
    $logPanel.Visibility = [System.Windows.Visibility]::Visible
    $btnToggleLog.Content = [char]0x25BC + " Hide Log"
})

$btnToggleLog.Add_Unchecked({
    $logPanel.Visibility = [System.Windows.Visibility]::Collapsed
    $btnToggleLog.Content = [char]0x25B6 + " Show Log"
})

# ─── Window Loaded: Kick Off Initial Check ──────────────────────────────────
$window.Add_Loaded({
    Write-Log "DFIR Drive Updater initialized."
    Write-Log "Drive root: $script:DriveRoot"
    if (-not $script:HasModule) {
        Write-Log "WARNING: Update-Checker module not found. Running in preview mode."
    }
    Start-UpdateCheck
})

# ─── Show the Window ────────────────────────────────────────────────────────
[void]$window.ShowDialog()
