#Requires -Version 5.1
<#
.SYNOPSIS
  Scan this Windows PC and write a detailed configuration workbook (.xlsx).

.EXAMPLE
  .\Scan-ComputerConfiguration.ps1
  .\Scan-ComputerConfiguration.ps1 -OutputPath .\out\my-pc.xlsx
#>
[CmdletBinding()]
param(
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Continue"
$Root = $PSScriptRoot
. (Join-Path $Root "lib\XlsxWriter.ps1")

function Get-Safe {
    param($ScriptBlock, $Default = $null)
    try { return & $ScriptBlock } catch { return $Default }
}

function ConvertTo-RowTable {
    param(
        [object[]]$Objects,
        # OrderedDictionary: propertyName -> Chinese header
        $Columns
    )
    $props = @($Columns.Keys)
    $headers = foreach ($p in $props) { [string]$Columns[$p] }
    $rows = New-Object System.Collections.Generic.List[object]
    $rows.Add([string[]]$headers) | Out-Null
    foreach ($obj in @($Objects)) {
        if ($null -eq $obj) { continue }
        $line = foreach ($p in $props) {
            $v = $obj.$p
            if ($null -eq $v) { "" }
            elseif ($v -is [datetime]) { $v.ToString("yyyy-MM-dd HH:mm:ss") }
            elseif ($v -is [bool]) { if ($v) { "是" } else { "否" } }
            elseif ($v -is [array]) { ($v | ForEach-Object { "$_" }) -join "; " }
            else { [string]$v }
        }
        $rows.Add([string[]]@($line)) | Out-Null
    }
    return , $rows.ToArray()
}

function ConvertTo-KvRows {
    param($Map)
    $rows = New-Object System.Collections.Generic.List[object]
    $rows.Add([string[]]@("项目", "值")) | Out-Null
    foreach ($k in $Map.Keys) {
        $rows.Add([string[]]@([string]$k, [string]$Map[$k])) | Out-Null
    }
    return , $rows.ToArray()
}

function Get-GpuModelInfo {
    param($Controller)

    $name = [string]$Controller.Name
    $caption = [string]$Controller.Caption
    $videoProc = [string]$Controller.VideoProcessor
    $compat = [string]$Controller.AdapterCompatibility
    $pnpId = [string]$Controller.PNPDeviceID

    $pnpName = ""
    if ($pnpId) {
        $pnpName = [string](Get-Safe {
            (Get-CimInstance Win32_PnPEntity -Filter ("DeviceID='{0}'" -f ($pnpId -replace '\\', '\\')) -ErrorAction Stop).Name
        } "")
        if (-not $pnpName) {
            $pnpName = [string](Get-Safe {
                $all = Get-PnpDevice -ErrorAction SilentlyContinue |
                    Where-Object { $_.InstanceId -eq $pnpId -or $_.InstanceId -like ($pnpId + '*') } |
                    Select-Object -First 1
                if ($all) { $all.FriendlyName }
            } "")
        }
    }

    # Prefer the richest non-generic string as "型号"
    $candidates = @($pnpName, $name, $caption, $videoProc) | Where-Object {
        $_ -and $_.Trim() -ne "" -and $_ -notmatch '^\s*Microsoft Basic Display'
    }
    $model = if ($candidates.Count) { $candidates[0].Trim() } else { $name }

    # Strip trailing "WDDM" noise sometimes appended
    $model = ($model -replace '\s+', ' ').Trim()

    $isBasic = ($model -match 'Basic Display|基本显示') -or ($name -match 'Basic Display')
    $vendorHint = $compat
    if (-not $vendorHint) {
        if ($model -match 'NVIDIA|GeForce|Quadro|RTX|GTX') { $vendorHint = "NVIDIA" }
        elseif ($model -match 'AMD|Radeon|ATI') { $vendorHint = "AMD" }
        elseif ($model -match 'Intel|UHD|Iris|Arc') { $vendorHint = "Intel" }
    }

    [pscustomobject]@{
        Model        = $model
        Name         = $name
        Caption      = $caption
        VideoProcessor = $videoProc
        PnPName      = $pnpName
        Vendor       = $vendorHint
        IsBasic      = $isBasic
        PNPDeviceID  = $pnpId
    }
}

Write-Host "[scan] collecting system inventory..."

$cs = Get-Safe { Get-CimInstance Win32_ComputerSystem }
$os = Get-Safe { Get-CimInstance Win32_OperatingSystem }
$bios = Get-Safe { Get-CimInstance Win32_BIOS }
$bb = Get-Safe { Get-CimInstance Win32_BaseBoard }
$cpu = @(Get-Safe { Get-CimInstance Win32_Processor } @())
$memMods = @(Get-Safe { Get-CimInstance Win32_PhysicalMemory } @())
$disks = @(Get-Safe { Get-CimInstance Win32_DiskDrive } @())
$vols = @(Get-Safe { Get-CimInstance Win32_LogicalDisk } @())
$gpu = @(Get-Safe { Get-CimInstance Win32_VideoController } @())
$nics = @(Get-Safe { Get-CimInstance Win32_NetworkAdapter | Where-Object { $_.PhysicalAdapter -eq $true } } @())
$nicCfg = @(Get-Safe { Get-CimInstance Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -eq $true } } @())
$monitors = @(Get-Safe { Get-CimInstance Win32_DesktopMonitor } @())
$sound = @(Get-Safe { Get-CimInstance Win32_SoundDevice } @())
$battery = @(Get-Safe { Get-CimInstance Win32_Battery } @())
$cdrom = @(Get-Safe { Get-CimInstance Win32_CDROMDrive } @())
$printers = @(Get-Safe { Get-CimInstance Win32_Printer -ErrorAction Stop } @())
$shares = @(Get-Safe { Get-CimInstance Win32_Share -ErrorAction Stop } @())
$services = @(Get-Safe { Get-Service -ErrorAction Stop | Select-Object Name, DisplayName, Status, StartType } @())
$hotfixes = @(Get-Safe { Get-HotFix -ErrorAction Stop | Sort-Object InstalledOn -Descending } @())
$tz = Get-Safe { Get-TimeZone }
$psVer = $PSVersionTable.PSVersion.ToString()
$parts = @(Get-Safe { Get-CimInstance Win32_DiskPartition } @())
$usb = @(Get-Safe {
    Get-PnpDevice -ErrorAction SilentlyContinue |
      Where-Object { $_.InstanceId -like 'USB*' } |
      Select-Object Status, Class, FriendlyName, InstanceId, Manufacturer, Service
} @())

$nicRows = foreach ($n in $nics) {
    $cfg = $nicCfg | Where-Object { $_.Index -eq $n.DeviceID -or $_.Description -eq $n.Name } | Select-Object -First 1
    [pscustomobject]@{
        Name            = $n.Name
        NetConnectionID = $n.NetConnectionID
        MACAddress      = $n.MACAddress
        AdapterType     = $n.AdapterType
        Speed           = $n.Speed
        Manufacturer    = $n.Manufacturer
        PNPDeviceID     = $n.PNPDeviceID
        IPAddress       = if ($cfg) { ($cfg.IPAddress -join "; ") } else { "" }
        IPSubnet        = if ($cfg) { ($cfg.IPSubnet -join "; ") } else { "" }
        DefaultIPGateway= if ($cfg) { ($cfg.DefaultIPGateway -join "; ") } else { "" }
        DHCPEnabled     = if ($cfg) { $cfg.DHCPEnabled } else { "" }
        DHCPServer      = if ($cfg) { $cfg.DHCPServer } else { "" }
        DNSServerSearchOrder = if ($cfg) { ($cfg.DNSServerSearchOrder -join "; ") } else { "" }
    }
}

$totalRamGB = if ($cs.TotalPhysicalMemory) {
    [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
} else { "" }

$gpuInfos = @($gpu | ForEach-Object { Get-GpuModelInfo -Controller $_ })
$primaryGpu = $gpuInfos | Where-Object { -not $_.IsBasic } | Select-Object -First 1
if (-not $primaryGpu -and $gpuInfos.Count) { $primaryGpu = $gpuInfos[0] }

$summary = [ordered]@{
    "扫描时间"           = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    "计算机名"           = $env:COMPUTERNAME
    "当前用户"           = "$env:USERDOMAIN\$env:USERNAME"
    "整机厂商"           = $cs.Manufacturer
    "整机型号"           = $cs.Model
    "系统类型"           = $cs.SystemType
    "域/工作组"          = if ($cs.PartOfDomain) { $cs.Domain } else { $cs.Workgroup }
    "操作系统"           = $os.Caption
    "系统版本"           = $os.Version
    "系统内部版本"       = $os.BuildNumber
    "系统架构"           = $os.OSArchitecture
    "安装日期"           = if ($os.InstallDate) { $os.InstallDate.ToString("yyyy-MM-dd HH:mm:ss") } else { "" }
    "上次启动"           = if ($os.LastBootUpTime) { $os.LastBootUpTime.ToString("yyyy-MM-dd HH:mm:ss") } else { "" }
    "时区"               = if ($tz) { "$($tz.DisplayName) ($($tz.Id))" } else { "" }
    "处理器型号"         = if ($cpu) { $cpu[0].Name.Trim() } else { "" }
    "逻辑处理器数"       = $cs.NumberOfLogicalProcessors
    "物理处理器数"       = $cs.NumberOfProcessors
    "内存总量(GB)"       = $totalRamGB
    "内存条数"           = $memMods.Count
    "硬盘数量"           = $disks.Count
    "显卡型号"           = if ($primaryGpu) { $primaryGpu.Model } else { "" }
    "显卡数量"           = $gpu.Count
    "PowerShell"         = $psVer
    "BIOS"               = "$($bios.Manufacturer) $($bios.SMBIOSBIOSVersion)"
    "BIOS序列号"         = $bios.SerialNumber
    "主板"               = "$($bb.Manufacturer) $($bb.Product)"
    "主板序列号"         = $bb.SerialNumber
}

$memTypeMap = @{
    0="未知"; 1="其它"; 2="DRAM"; 3="同步DRAM"; 4="缓存DRAM"; 5="EDO"; 6="EDRAM"
    7="VRAM"; 8="SRAM"; 9="RAM"; 10="ROM"; 11="Flash"; 12="EEPROM"; 13="FEPROM"
    14="EPROM"; 15="CDRAM"; 16="3DRAM"; 17="SDRAM"; 18="SGRAM"; 19="RDRAM"
    20="DDR"; 21="DDR2"; 22="DDR2 FB-DIMM"; 24="DDR3"; 25="FBD2"; 26="DDR4"; 34="DDR5"
}

$memRows = foreach ($m in $memMods) {
    $mt = $m.MemoryType
    $mtName = if ($memTypeMap.ContainsKey([int]$mt)) { $memTypeMap[[int]$mt] } else { [string]$mt }
    [pscustomobject]@{
        BankLabel        = $m.BankLabel
        DeviceLocator    = $m.DeviceLocator
        CapacityGB       = if ($m.Capacity) { [math]::Round($m.Capacity / 1GB, 2) } else { "" }
        SpeedMHz         = $m.Speed
        Manufacturer     = $m.Manufacturer
        PartNumber       = ($m.PartNumber -replace '\s+$', '')
        SerialNumber     = $m.SerialNumber
        FormFactor       = $m.FormFactor
        MemoryType       = $mtName
        ConfiguredClock  = $m.ConfiguredClockSpeed
        DataWidth        = $m.DataWidth
        TotalWidth       = $m.TotalWidth
    }
}

$diskRows = foreach ($d in $disks) {
    [pscustomobject]@{
        Index          = $d.Index
        Model          = $d.Model
        InterfaceType  = $d.InterfaceType
        MediaType      = $d.MediaType
        SizeGB         = if ($d.Size) { [math]::Round($d.Size / 1GB, 2) } else { "" }
        Partitions     = $d.Partitions
        SerialNumber   = ($d.SerialNumber -replace '\s+$', '')
        FirmwareRevision = $d.FirmwareRevision
        Status         = $d.Status
        PNPDeviceID    = $d.PNPDeviceID
    }
}

$volRows = foreach ($v in $vols) {
    [pscustomobject]@{
        DeviceID     = $v.DeviceID
        VolumeName   = $v.VolumeName
        FileSystem   = $v.FileSystem
        DriveType    = $v.DriveType
        SizeGB       = if ($v.Size) { [math]::Round($v.Size / 1GB, 2) } else { "" }
        FreeGB       = if ($v.FreeSpace) { [math]::Round($v.FreeSpace / 1GB, 2) } else { "" }
        Compressed   = $v.Compressed
        Description  = $v.Description
    }
}

$cpuRows = foreach ($c in $cpu) {
    [pscustomobject]@{
        Name                      = ($c.Name -replace '\s+', ' ').Trim()
        Manufacturer              = $c.Manufacturer
        Description               = $c.Description
        NumberOfCores             = $c.NumberOfCores
        NumberOfLogicalProcessors = $c.NumberOfLogicalProcessors
        MaxClockSpeedMHz          = $c.MaxClockSpeed
        CurrentClockSpeedMHz      = $c.CurrentClockSpeed
        L2CacheSizeKB             = $c.L2CacheSize
        L3CacheSizeKB             = $c.L3CacheSize
        SocketDesignation         = $c.SocketDesignation
        VirtualizationFirmwareEnabled = $c.VirtualizationFirmwareEnabled
        ProcessorId               = $c.ProcessorId
    }
}

$gpuRows = foreach ($g in $gpu) {
    $info = Get-GpuModelInfo -Controller $g
    $ramMb = ""
    if ($g.AdapterRAM -and $g.AdapterRAM -gt 0 -and $g.AdapterRAM -lt ([uint32]::MaxValue)) {
        $ramMb = [math]::Round($g.AdapterRAM / 1MB, 0)
    }
    [pscustomobject]@{
        Model              = $info.Model
        Vendor             = $info.Vendor
        Name               = $info.Name
        VideoProcessor     = $info.VideoProcessor
        PnPName            = $info.PnPName
        AdapterRAM_MB      = $ramMb
        DriverVersion      = $g.DriverVersion
        DriverDate         = $g.DriverDate
        VideoModeDescription = $g.VideoModeDescription
        CurrentHorizontalResolution = $g.CurrentHorizontalResolution
        CurrentVerticalResolution   = $g.CurrentVerticalResolution
        CurrentRefreshRate = $g.CurrentRefreshRate
        AdapterCompatibility = $g.AdapterCompatibility
        IsBasic            = $info.IsBasic
        PNPDeviceID        = $g.PNPDeviceID
        Status             = $g.Status
    }
}

Write-Host "[scan] enumerating installed programs..."
$uninstPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
)
$apps = foreach ($path in $uninstPaths) {
    Get-ItemProperty $path -ErrorAction SilentlyContinue | ForEach-Object {
        $dn = $_.PSObject.Properties['DisplayName']
        if (-not $dn -or [string]::IsNullOrWhiteSpace([string]$dn.Value)) { return }
        [pscustomobject]@{
            DisplayName     = [string]$dn.Value
            DisplayVersion  = [string]$_.DisplayVersion
            Publisher       = [string]$_.Publisher
            InstallDate     = [string]$_.InstallDate
            InstallLocation = [string]$_.InstallLocation
            Hive            = $path.Split('\')[0]
        }
    }
}
$apps = @($apps | Sort-Object DisplayName -Unique)

$runKeys = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
)
$autorun = foreach ($rk in $runKeys) {
    $item = Get-ItemProperty $rk -ErrorAction SilentlyContinue
    if (-not $item) { continue }
    $item.PSObject.Properties |
      Where-Object { $_.Name -notmatch '^PS' } |
      ForEach-Object {
        [pscustomobject]@{ Hive = $rk; Name = $_.Name; Command = [string]$_.Value }
      }
}

$sheetList = [ordered]@{
    "汇总" = ConvertTo-KvRows -Map $summary

    "处理器" = @{
        Theme = "cpu"
        Rows = ConvertTo-RowTable -Objects $cpuRows -Columns ([ordered]@{
            Name = "型号"
            Manufacturer = "厂商"
            Description = "描述"
            NumberOfCores = "物理核心"
            NumberOfLogicalProcessors = "逻辑处理器"
            MaxClockSpeedMHz = "最大频率(MHz)"
            CurrentClockSpeedMHz = "当前频率(MHz)"
            L2CacheSizeKB = "L2缓存(KB)"
            L3CacheSizeKB = "L3缓存(KB)"
            SocketDesignation = "插槽"
            VirtualizationFirmwareEnabled = "虚拟化"
            ProcessorId = "处理器ID"
        })
    }

    "内存" = @{
        Theme = "mem"
        Rows = ConvertTo-RowTable -Objects $memRows -Columns ([ordered]@{
            BankLabel = "插槽组"
            DeviceLocator = "位置"
            CapacityGB = "容量(GB)"
            SpeedMHz = "频率(MHz)"
            ConfiguredClock = "配置频率(MHz)"
            Manufacturer = "厂商"
            PartNumber = "型号/料号"
            SerialNumber = "序列号"
            FormFactor = "封装"
            MemoryType = "类型"
            DataWidth = "数据位宽"
            TotalWidth = "总位宽"
        })
    }

    "硬盘" = @{
        Theme = "disk"
        Rows = ConvertTo-RowTable -Objects $diskRows -Columns ([ordered]@{
            Index = "序号"
            Model = "型号"
            InterfaceType = "接口"
            MediaType = "介质"
            SizeGB = "容量(GB)"
            Partitions = "分区数"
            SerialNumber = "序列号"
            FirmwareRevision = "固件"
            Status = "状态"
            PNPDeviceID = "设备ID"
        })
    }

    "显卡" = @{
        Theme = "gpu"
        Rows = ConvertTo-RowTable -Objects $gpuRows -Columns ([ordered]@{
            Model = "型号"
            Vendor = "厂商"
            Name = "控制器名称"
            VideoProcessor = "视频处理器"
            PnPName = "即插即用名称"
            AdapterRAM_MB = "显存(MB)"
            DriverVersion = "驱动版本"
            DriverDate = "驱动日期"
            VideoModeDescription = "当前显示模式"
            CurrentHorizontalResolution = "水平分辨率"
            CurrentVerticalResolution = "垂直分辨率"
            CurrentRefreshRate = "刷新率(Hz)"
            AdapterCompatibility = "适配器兼容"
            IsBasic = "基本显示适配器"
            Status = "状态"
            PNPDeviceID = "设备ID"
        })
    }

    "卷" = ConvertTo-RowTable -Objects $volRows -Columns ([ordered]@{
        DeviceID = "盘符"; VolumeName = "卷标"; FileSystem = "文件系统"; DriveType = "类型"
        SizeGB = "容量(GB)"; FreeGB = "剩余(GB)"; Compressed = "压缩"; Description = "描述"
    })

    "分区" = ConvertTo-RowTable -Objects $parts -Columns ([ordered]@{
        DiskIndex = "磁盘号"; Index = "分区号"; Name = "名称"; Description = "描述"
        Size = "大小(字节)"; Type = "类型"; Bootable = "可引导"; BootPartition = "引导分区"; PrimaryPartition = "主分区"
    })

    "网络" = ConvertTo-RowTable -Objects $nicRows -Columns ([ordered]@{
        Name = "名称"; NetConnectionID = "连接名"; MACAddress = "MAC"
        AdapterType = "类型"; Speed = "速度"; Manufacturer = "厂商"
        IPAddress = "IP地址"; IPSubnet = "子网掩码"; DefaultIPGateway = "网关"
        DHCPEnabled = "DHCP"; DHCPServer = "DHCP服务器"; DNSServerSearchOrder = "DNS"; PNPDeviceID = "设备ID"
    })

    "主板" = ConvertTo-KvRows -Map ([ordered]@{
        "主板厂商" = $(if ($bb) { $bb.Manufacturer } else { "" })
        "主板型号" = $(if ($bb) { $bb.Product } else { "" })
        "主板版本" = $(if ($bb) { $bb.Version } else { "" })
        "主板序列号" = $(if ($bb) { $bb.SerialNumber } else { "" })
        "BIOS厂商" = $(if ($bios) { $bios.Manufacturer } else { "" })
        "BIOS版本" = $(if ($bios) { $bios.SMBIOSBIOSVersion } else { "" })
        "BIOS日期" = $(if ($bios -and $bios.ReleaseDate) { $bios.ReleaseDate.ToString("yyyy-MM-dd") } else { "" })
        "BIOS序列号" = $(if ($bios) { $bios.SerialNumber } else { "" })
        "SMBIOS版本" = $(if ($bios) { "$($bios.SMBIOSMajorVersion).$($bios.SMBIOSMinorVersion)" } else { "" })
    })

    "显示器" = ConvertTo-RowTable -Objects $monitors -Columns ([ordered]@{
        Name = "名称"; DeviceID = "设备ID"; ScreenWidth = "宽度"; ScreenHeight = "高度"
        MonitorType = "类型"; MonitorManufacturer = "厂商"; PNPDeviceID = "PnP"; Status = "状态"
    })

    "音频" = ConvertTo-RowTable -Objects $sound -Columns ([ordered]@{
        Name = "名称"; Manufacturer = "厂商"; Status = "状态"; PNPDeviceID = "设备ID"
    })

    "电池" = ConvertTo-RowTable -Objects $battery -Columns ([ordered]@{
        Name = "名称"; EstimatedChargeRemaining = "剩余电量%"; BatteryStatus = "状态"
        Chemistry = "化学类型"; DesignCapacity = "设计容量"; FullChargeCapacity = "满充容量"
    })

    "光驱" = ConvertTo-RowTable -Objects $cdrom -Columns ([ordered]@{
        Name = "名称"; Drive = "盘符"; MediaType = "介质"; Status = "状态"
    })

    "打印机" = ConvertTo-RowTable -Objects $printers -Columns ([ordered]@{
        Name = "名称"; DriverName = "驱动"; PortName = "端口"; Shared = "共享"; Default = "默认"; Status = "状态"
    })

    "共享" = ConvertTo-RowTable -Objects $shares -Columns ([ordered]@{
        Name = "名称"; Path = "路径"; Description = "描述"; Type = "类型"
    })

    "USB" = ConvertTo-RowTable -Objects $usb -Columns ([ordered]@{
        Status = "状态"; Class = "类别"; FriendlyName = "名称"; Manufacturer = "厂商"; Service = "服务"; InstanceId = "实例ID"
    })

    "开机启动" = ConvertTo-RowTable -Objects $autorun -Columns ([ordered]@{
        Hive = "注册表位置"; Name = "名称"; Command = "命令"
    })

    "更新补丁" = ConvertTo-RowTable -Objects $hotfixes -Columns ([ordered]@{
        HotFixID = "补丁号"; Description = "描述"; InstalledBy = "安装者"; InstalledOn = "安装日期"
    })

    "服务" = ConvertTo-RowTable -Objects $services -Columns ([ordered]@{
        Name = "名称"; DisplayName = "显示名"; Status = "状态"; StartType = "启动类型"
    })

    "已装软件" = ConvertTo-RowTable -Objects $apps -Columns ([ordered]@{
        DisplayName = "名称"; DisplayVersion = "版本"; Publisher = "发布者"
        InstallDate = "安装日期"; InstallLocation = "安装路径"; Hive = "注册表"
    })
}

if (-not $OutputPath) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $hostName = ($env:COMPUTERNAME -replace '[\\/:*?"<>|]', '_')
    $outDir = Join-Path $Root "output"
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    $OutputPath = Join-Path $outDir ("电脑配置-{0}-{1}.xlsx" -f $hostName, $stamp)
} else {
    $parent = Split-Path -Parent $OutputPath
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
}

Write-Host "[scan] writing $OutputPath"
Export-XlsxWorkbook -Path $OutputPath -Sheets $sheetList
Write-Host "[scan] DONE"
Write-Host $OutputPath
