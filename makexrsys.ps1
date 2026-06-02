#Requires -Version 7
<#
.SYNOPSIS
Xiaoran System Image Builder

.DESCRIPTION
Build Windows image file with xrsys-osc, drivers and custom configurations.
#>

param(
    # Setting the target version to make
    [string]$Target,

    # Add Full Drivers
    [switch]$FullDrv,

    # Set as the latest version
    [switch]$Latest
)

$ErrorActionPreference = 'Stop'
$Server = "https://list.xrgzs.top"

# wimlib 日志限速输出函数
function Invoke-Wimlib {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $rateLimitedPatterns = @(
        'Creating files',
        'Extracting file data',
        'Applying metadata to files',
        'iB scanned',
        'Archiving file data'
    )

    $lastOutputTime = [DateTime]::MinValue
    $lastMonitorTime = [DateTime]::MinValue
    $logFile = ".\wimlib_temp.log"
    $readPosition = 0

    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -PassThru -NoNewWindow -RedirectStandardOutput $logFile

    while (!$process.HasExited) {
        Start-Sleep -Milliseconds 100
        if (Test-Path $logFile) {
            $stream = [System.IO.File]::Open($logFile, 'Open', 'Read', 'ReadWrite')
            $reader = New-Object System.IO.StreamReader($stream)
            $stream.Seek($readPosition, 'Begin') | Out-Null

            while ($null -ne ($line = $reader.ReadLine())) {
                $readPosition = $stream.Position
                $shouldRateLimit = $false
                foreach ($pattern in $rateLimitedPatterns) {
                    if ($line -match [regex]::Escape($pattern)) {
                        $shouldRateLimit = $true
                        break
                    }
                }

                if ($shouldRateLimit) {
                    $now = [DateTime]::UtcNow
                    if (($now - $lastOutputTime).TotalSeconds -ge 15) {
                        if ($line) { Write-Host $line }
                        $lastOutputTime = $now
                    }
                } else {
                    if ($line) { Write-Host $line }
                }
            }

            $reader.Close()
            $stream.Close()
        }

        # 每30秒输出 CPU 和内存占用
        $now = [DateTime]::UtcNow
        if (($now - $lastMonitorTime).TotalSeconds -ge 30) {
            $lastMonitorTime = $now
            $cpu = (Get-CimInstance Win32_Processor).LoadPercentage
            $os = Get-CimInstance Win32_OperatingSystem
            $totalMem = [math]::Round((Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum / 1GB, 2)
            $freeMem = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
            $usedMem = [math]::Round($totalMem - $freeMem, 2)
            $memPercent = [math]::Round(($usedMem / $totalMem) * 100, 1)
            Write-Host "[资源监控] CPU: ${cpu}% | 内存: ${usedMem}/${totalMem} GB (${memPercent}%)" -ForegroundColor DarkGray
        }
    }

    # 输出剩余内容
    if (Test-Path $logFile) {
        $stream = [System.IO.File]::Open($logFile, 'Open', 'Read', 'ReadWrite')
        $reader = New-Object System.IO.StreamReader($stream)
        $stream.Seek($readPosition, 'Begin') | Out-Null
        while ($null -ne ($line = $reader.ReadLine())) {
            if ($line) { Write-Host $line }
        }
        $reader.Close()
        $stream.Close()
        Remove-Item $logFile -ErrorAction SilentlyContinue
    }

    return $process.ExitCode
}

# 计时器
$script:StepTimers = @{}

# 监控函数：输出系统状态和耗时
function Write-Status {
    param(
        [string]$Step,
        [string]$Status
    )
    $time = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, 'China Standard Time').ToString('yyyy-MM-dd HH:mm:ss')
    $os = Get-CimInstance Win32_OperatingSystem
    $totalMem = [math]::Round((Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum / 1GB, 2)
    $freeMem = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
    $usedMem = [math]::Round($totalMem - $freeMem, 2)
    $memPercent = [math]::Round(($usedMem / $totalMem) * 100, 1)

    $cDrive = Get-Volume -DriveLetter C -ErrorAction SilentlyContinue
    $dDrive = Get-Volume -DriveLetter D -ErrorAction SilentlyContinue
    $cFree = if ($cDrive) { [math]::Round($cDrive.SizeRemaining / 1GB, 2) } else { "N/A" }
    $dFree = if ($dDrive) { [math]::Round($dDrive.SizeRemaining / 1GB, 2) } else { "N/A" }

    # 计时逻辑
    $duration = ""
    if ($Status -eq "开始") {
        $script:StepTimers[$Step] = [DateTime]::UtcNow
    } elseif (($Status -eq "完成" -or $Status -eq "结束") -and $script:StepTimers.ContainsKey($Step)) {
        $elapsed = [DateTime]::UtcNow - $script:StepTimers[$Step]
        $duration = " | 耗时: {0:hh\:mm\:ss}" -f $elapsed
        $script:StepTimers.Remove($Step)
    }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "[$time] $Step - $Status$duration" -ForegroundColor Yellow
    Write-Host "内存: ${usedMem}/${totalMem} GB (${memPercent}%)" -ForegroundColor White
    Write-Host "C盘可用: ${cFree} GB | D盘可用: ${dFree} GB" -ForegroundColor White
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
}

# 获取网络信息函数
function Write-NetworkInfo {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "网络信息" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Green

    # 获取 Azure 区域（通过 IMDS）
    try {
        $metadata = Invoke-RestMethod -Headers @{"Metadata"="true"} -Uri "http://169.254.169.254/metadata/instance?api-version=2021-02-01" -TimeoutSec 2
        Write-Host "Azure 区域: $($metadata.compute.location)" -ForegroundColor White
        Write-Host "VM 大小: $($metadata.compute.vmSize)" -ForegroundColor White
    } catch {
        Write-Host "Azure 区域: 不可用（非 Azure 环境）" -ForegroundColor Gray
    }

    # 获取 IPv4
    try {
        $ipv4 = Invoke-WebRequest -Uri "https://4.itdog.cn" -TimeoutSec 5 -UseBasicParsing | Select-Object -ExpandProperty Content
        $ipv4 = $ipv4.Trim()
        Write-Host "IPv4: $ipv4" -ForegroundColor White
    } catch {
        Write-Host "IPv4: 获取失败" -ForegroundColor Red
    }

    # 获取 IPv6
    try {
        $ipv6 = Invoke-WebRequest -Uri "https://6.itdog.cn" -TimeoutSec 5 -UseBasicParsing | Select-Object -ExpandProperty Content
        $ipv6 = $ipv6.Trim()
        Write-Host "IPv6: $ipv6" -ForegroundColor White
    } catch {
        Write-Host "IPv6: 获取失败或不支持" -ForegroundColor Gray
    }

    # 获取 IP 归属地
    try {
        $geo = Invoke-RestMethod -Uri "https://myip.ipip.net/json" -TimeoutSec 5
        if ($geo.ret -eq "ok") {
            Write-Host "归属地: $($geo.data.location -join ' ')" -ForegroundColor White
        }
    } catch {
        Write-Host "归属地: 获取失败" -ForegroundColor Gray
    }

    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
}

function Invoke-Aria2Download {
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Uri,

        [Parameter(Position = 1)]
        [string]$Destination,

        [Parameter(Position = 2)]
        [string]$Name,
        
        [switch]$Big,

        [string[]]$Options = @()
    )
    
    function Get-RedirectedUrl {
        param(
            [Parameter(Mandatory, ValueFromPipeline)][string]$Uri,
            [string]$UserAgent = "aria2/1.37.0"
        )
        try {
            while ($true) {
                $req = [System.Net.WebRequest]::Create($Uri)
                $req.UserAgent = $UserAgent
                $req.AllowAutoRedirect = $false
                $res = $req.GetResponse()
                $loc = $res.GetResponseHeader('Location')
                $res.Close()
                if ($loc) { $Uri = $loc } else { return $Uri }
            }
        } catch { return $Uri }
    }
    
    function Get-Aria2Error($exitcode) {
        $codes = @{
            0  = 'All downloads were successful'
            1  = 'An unknown error occurred'
            2  = 'Timeout'
            3  = 'Resource was not found'
            4  = 'Aria2 saw the specified number of "resource not found" error. See --max-file-not-found option'
            5  = 'Download aborted because download speed was too slow. See --lowest-speed-limit option'
            6  = 'Network problem occurred.'
            7  = 'There were unfinished downloads. This error is only reported if all finished downloads were successful and there were unfinished downloads in a queue when aria2 exited by pressing Ctrl-C by an user or sending TERM or INT signal'
            8  = 'Remote server did not support resume when resume was required to complete download'
            9  = 'There was not enough disk space available'
            10 = 'Piece length was different from one in .aria2 control file. See --allow-piece-length-change option'
            11 = 'Aria2 was downloading same file at that moment'
            12 = 'Aria2 was downloading same info hash torrent at that moment'
            13 = 'File already existed. See --allow-overwrite option'
            14 = 'Renaming file failed. See --auto-file-renaming option'
            15 = 'Aria2 could not open existing file'
            16 = 'Aria2 could not create new file or truncate existing file'
            17 = 'File I/O error occurred'
            18 = 'Aria2 could not create directory'
            19 = 'Name resolution failed'
            20 = 'Aria2 could not parse Metalink document'
            21 = 'FTP command failed'
            22 = 'HTTP response header was bad or unexpected'
            23 = 'Too many redirects occurred'
            24 = 'HTTP authorization failed'
            25 = 'Aria2 could not parse bencoded file (usually ".torrent" file)'
            26 = '".torrent" file was corrupted or missing information that aria2 needed'
            27 = 'Magnet URI was bad'
            28 = 'Bad/unrecognized option was given or unexpected option argument was given'
            29 = 'The remote server was unable to handle the request due to a temporary overloading or maintenance'
            30 = 'Aria2 could not parse JSON-RPC request'
            31 = 'Reserved. Not used'
            32 = 'Checksum validation failed'
        }
        if ($null -eq $codes[$exitcode]) {
            return 'An unknown error occurred'
        }
        return $codes[$exitcode]
    }

    # aria2 options
    $Options += @(
        '--no-conf=true'
        '--continue'
        '--allow-overwrite=true'
        '--summary-interval=0'
        '--remote-time=true'
        '--retry-wait=5'
        '--check-certificate=false'
    )

    # set task info
    $Uri = Get-RedirectedUrl -Uri $Uri
    $Options += "`"$Uri`""
    if ($Destination) {
        $Options += "--dir=`"$Destination`""
    }
    if ($Name) {
        $Options += "--out=`"$Name`""
    }
    if ($Big) {
        $Options += @(
            '-s16'
            '-x16'
        )
    }

    # build aria2 command
    $aria2 = "& .\bin\aria2c.exe $($Options -join ' ')"

    # handle aria2 console output
    Write-Host '正在使用 aria2 下载 ...' -ForegroundColor Green
    Write-Host "  命令: $aria2" -ForegroundColor Cyan
    Invoke-Command ([scriptblock]::Create($aria2))

    # handle aria2 error
    Write-Host ''
    if ($LASTEXITCODE -gt 0) {
        Write-Error "Download failed! (Error $LASTEXITCODE) $(Get-Aria2Error $lastexitcode)"
    }
}

# set original system info
switch ($Target) {
    "w1126h1a64" {
        $obj = Invoke-RestMethod -Uri "$Server/d/pxy/System/MSUpdate/11/26H1/latest_arm64.json"
        $osUrl = "$Server/d/pxy/System/MSUpdate/11/26H1/" + $obj.os_version + '/' + $obj.name
        $osMd5 = $obj.hash.md5
        $osFile = $obj.name
        $osIndex = 4
        $osVer = $obj.os_ver
        $osVersion = $obj.os_version
        $osArch = $obj.os_arch
        $sysVer = "XRSYS_Win11_26H1_Pro_ARM64_CN_Full"
        $sysVerCN = "潇然系统_Win11_26H1_专业_ARM64_完整"
    }
    "w1126h164" {
        $obj = Invoke-RestMethod -Uri "$Server/d/pxy/System/MSUpdate/11/26H1/latest_x64.json"
        $osUrl = "$Server/d/pxy/System/MSUpdate/11/26H1/" + $obj.os_version + '/' + $obj.name
        $osMd5 = $obj.hash.md5
        $osFile = $obj.name
        $osIndex = 4
        $osVer = $obj.os_ver
        $osVersion = $obj.os_version
        $osArch = $obj.os_arch
        $sysVer = "XRSYS_Win11_26H1_Pro_x64_CN_Full"
        $sysVerCN = "潇然系统_Win11_26H1_专业_x64_完整"
    }
    "w1125h2a64" {
        $obj = Invoke-RestMethod -Uri "$Server/d/pxy/System/MSUpdate/11/25H2/latest_arm64.json"
        $osUrl = "$Server/d/pxy/System/MSUpdate/11/25H2/" + $obj.os_version + '/' + $obj.name
        $osMd5 = $obj.hash.md5
        $osFile = $obj.name
        $osIndex = 4
        $osVer = $obj.os_ver
        $osVersion = $obj.os_version
        $osArch = $obj.os_arch
        $sysVer = "XRSYS_Win11_25H2_Pro_ARM64_CN_Full"
        $sysVerCN = "潇然系统_Win11_25H2_专业_ARM64_完整"
    }
    "w1125h264" {
        $obj = Invoke-RestMethod -Uri "$Server/d/pxy/System/MSUpdate/11/25H2/latest_x64.json"
        $osUrl = "$Server/d/pxy/System/MSUpdate/11/25H2/" + $obj.os_version + '/' + $obj.name
        $osMd5 = $obj.hash.md5
        $osFile = $obj.name
        $osIndex = 4
        $osVer = $obj.os_ver
        $osVersion = $obj.os_version
        $osArch = $obj.os_arch
        $sysVer = "XRSYS_Win11_25H2_Pro_x64_CN_Full"
        $sysVerCN = "潇然系统_Win11_25H2_专业_x64_完整"
    }
    "w1123h2a64" {
        $obj = Invoke-RestMethod -Uri "$Server/d/pxy/System/MSUpdate/11/23H2/latest_arm64.json"
        $osUrl = "$Server/d/pxy/System/MSUpdate/11/23H2/" + $obj.os_version + '/' + $obj.name
        $osMd5 = $obj.hash.md5
        $osFile = $obj.name
        $osIndex = 4
        $osVer = $obj.os_ver
        $osVersion = $obj.os_version
        $osArch = $obj.os_arch
        $sysVer = "XRSYS_Win11_23H2_Pro_ARM64_CN_Full"
        $sysVerCN = "潇然系统_Win11_23H2_专业_ARM64_完整"
    }
    "w1123h264" {
        # $obj = Get-OsBySearch -Path "/潇然工作室/System/Win11" -Search "MSUpdate_Win11_23H2*.esd"
        # $osUrl = $obj.osurl
        # $osFile = $obj.osfile
        $obj = Invoke-RestMethod -Uri "$Server/d/pxy/System/MSUpdate/11/23H2/latest_x64.json"
        $osUrl = "$Server/d/pxy/System/MSUpdate/11/23H2/" + $obj.os_version + '/' + $obj.name
        $osMd5 = $obj.hash.md5
        $osFile = $obj.name
        $osIndex = 4
        $osVer = $obj.os_ver
        $osVersion = $obj.os_version
        $osArch = $obj.os_arch
        $sysVer = "XRSYS_Win11_23H2_Pro_x64_CN_Full"
        $sysVerCN = "潇然系统_Win11_23H2_专业_x64_完整"
    }
    "w1022h264" {
        # $obj = Get-OsBySearch -Path "/潇然工作室/System/Win10" -Search "MSUpdate_Win10_22H2*.esd"
        # $osUrl = $obj.osurl
        # $osFile = $obj.osfile
        $obj = Invoke-RestMethod -Uri "$Server/d/pxy/System/MSUpdate/10/22H2/latest_x64.json"
        $osUrl = "$Server/d/pxy/System/MSUpdate/10/22H2/" + $obj.os_version + '/' + $obj.name
        $osMd5 = $obj.hash.md5
        $osFile = $obj.name
        $osIndex = 4
        $osVer = $obj.os_ver
        $osVersion = $obj.os_version
        $osArch = $obj.os_arch
        $sysVer = "XRSYS_Win10_22H2_Pro_x64_CN_Full"
        $sysVerCN = "潇然系统_Win10_22H2_专业_x64_完整"
    }
    "w11lt2464" {
        $obj = Invoke-RestMethod -Uri "$Server/d/pxy/System/MSUpdate/11/LTSC2024/latest_x64.json"
        $osUrl = "$Server/d/pxy/System/MSUpdate/11/LTSC2024/" + $obj.os_version + '/' + $obj.name
        $osMd5 = $obj.hash.md5
        $osFile = $obj.name
        $osIndex = 1
        $osVer = $obj.os_ver
        $osVersion = $obj.os_version
        $osArch = $obj.os_arch
        $sysVer = "XRSYS_Win11_LTSC2024_EntS_x64_CN_Full"
        $sysVerCN = "潇然系统_Win11_LTSC2024_企业S_x64_完整"
    }
    "w11lt24a64" {
        $obj = Invoke-RestMethod -Uri "$Server/d/pxy/System/MSUpdate/11/LTSC2024/latest_arm64.json"
        $osUrl = "$Server/d/pxy/System/MSUpdate/11/LTSC2024/" + $obj.os_version + '/' + $obj.name
        $osMd5 = $obj.hash.md5
        $osFile = $obj.name
        $osIndex = 1
        $osVer = $obj.os_ver
        $osVersion = $obj.os_version
        $osArch = $obj.os_arch
        $sysVer = "XRSYS_Win11_LTSC2024_EntS_ARM64_CN_Full"
        $sysVerCN = "潇然系统_Win11_LTSC2024_企业S_ARM64_完整"
    }
    "w10lt2164" {
        $obj = Invoke-RestMethod -Uri "$Server/d/pxy/System/MSUpdate/10/LTSC2021/latest_x64.json"
        $osUrl = "$Server/d/pxy/System/MSUpdate/10/LTSC2021/" + $obj.os_version + '/' + $obj.name
        $osMd5 = $obj.hash.md5
        $osFile = $obj.name
        $osIndex = 1
        $osVer = $obj.os_ver
        $osVersion = $obj.os_version
        $osArch = $obj.os_arch
        $sysVer = "XRSYS_Win10_LTSC2021_EntS_x64_CN_Full"
        $sysVerCN = "潇然系统_Win10_LTSC2021_企业S_x64_完整"
    }
    "w10lt1964" {
        $obj = Invoke-RestMethod -Uri "$Server/d/pxy/System/MSUpdate/10/LTSC2019/latest_x64.json"
        $osUrl = "$Server/d/pxy/System/MSUpdate/10/LTSC2019/" + $obj.os_version + '/' + $obj.name
        $osMd5 = $obj.hash.md5
        $osFile = $obj.name
        $osIndex = 1
        $osVer = $obj.os_ver
        $osVersion = $obj.os_version
        $osArch = $obj.os_arch
        $sysVer = "XRSYS_Win10_LTSC2019_EntS_x64_CN_Full"
        $sysVerCN = "潇然系统_Win10_LTSC2019_企业S_x64_完整"
    }
    "w10lt1664" {
        $obj = Invoke-RestMethod -Uri "$Server/d/pxy/System/MSUpdate/10/LTSB2016/latest_x64.json"
        $osUrl = "$Server/d/pxy/System/MSUpdate/10/LTSB2016/" + $obj.os_version + '/' + $obj.name
        $osMd5 = $obj.hash.md5
        $osFile = $obj.name
        $osIndex = 1
        $osVer = $obj.os_ver
        $osVersion = $obj.os_version
        $osArch = $obj.os_arch
        $sysVer = "XRSYS_Win10_LTSB2016_EntS_x64_CN_Full"
        $sysVerCN = "潇然系统_Win10_LTSB2016_企业S_x64_完整"
    }
    "w7ult64" {
        $obj = (Invoke-RestMethod https://c.xrgzs.top/OSList.json).'【更新】7_SP1_IE11_自选_64位_无驱动_原版无接管'
        $osMd5 = $obj.md5
        $osUrl = $obj.osurl2
        $osFile = $obj.osfile
        $osIndex = 5
        $osVer = '7'
        $osVersion = ($obj.osfile -split '_')[-2]
        $osArch = 'x64'
        $sysVer = "XRSYS_Win7_SP1_Ult_x64_CN_Full"
        $sysVerCN = "潇然系统_Win7_SP1_旗舰_x64_完整"
        Invoke-WebRequest https://c.xrgzs.top/unattend/764bit.xml -OutFile .\unattend.xml
    }
    Default {
        Write-Error "Unknown version."
    }
}

if ($FullDrv) {
    if ($osArch -eq "x64" -and [float]$osVersion -ge 16299.0) {
        # DCH x64
        $osdrvurl = "$Server/d/pxy/System/Driver/DrvCeo_Mod/Drvceo_Win10_Win11_x64_Lite.iso"
    } elseif ($osArch -eq "x64" -and [float]$osVersion -ge 10240.0) {
        # noDCH x64
        $osdrvurl = "$Server/d/pxy/System/Driver/DrvCeo_Mod/Drvceo_Win10_noDCH_x64_Lite.iso"
    } elseif ($osArch -eq "x64" -and [float]$osVersion -ge 7600.0) {
        # Win7 x64
        $osdrvurl = "$Server/d/pxy/System/Driver/DrvCeo_Mod/Drvceo_Win7x64_Lite.iso"
    } elseif ($osArch -eq "x86" -and [float]$osVersion -ge 7600.0) {
        # Win7 x86
        $osdrvurl = "$Server/d/pxy/System/Driver/DrvCeo_Mod/Drvceo_Win7x86_Lite.iso"
    } else {
        Write-Error "Cannot match related driver iso."
    }
    $sysVer = $sysVer + "_DrvCeo"
    $sysVerCN = $sysVerCN + "_驱动总裁"
}

# dealosdriver
if ($null -eq $osdrvurl) {
    if ($osArch -eq "x64" -and [float]$osVersion -ge 19041.0) {
        $osdrvurl = "$Server/d/pxy/System/Driver/DP/NET/NET10x64.iso"
    } elseif ($osArch -eq "arm64" -and [float]$osVersion -ge 19041.0) {
        $osdrvurl = "$Server/d/pxy/System/Driver/DP/NET/NET10a64.iso"
    } elseif ($osArch -eq "x64" -and [float]$osVersion -ge 10240.0) {
        $osdrvurl = "$Server/d/pxy/System/Driver/DP/DPWin10x64.iso"
    } elseif ($osArch -eq "x64" -and [float]$osVersion -ge 7600.0) {
        $osdrvurl = "$Server/d/pxy/System/Driver/DP/DPWin7x64.iso"
    } elseif ($osArch -eq "x86" -and [float]$osVersion -ge 7600.0) {
        $osdrvurl = "$Server/d/pxy/System/Driver/DP/DPWin7x86.iso"
    } else {
        Write-Error "Cannot match related driver iso."
    }
    $sysVer = $sysVer + "_Net"
    $sysVerCN = $sysVerCN + "_主板驱动"
}

# set version
Set-TimeZone -Id "China Standard Time" -PassThru
$sysDateFull = Get-Date
$sysDate = $sysDateFull | Get-Date -Format "yyyy.MM.dd"
$sysFile = "${sysver}_${sysdate}_${osversion}"

# remove temporaty files
Remove-Item -Path ".\temp\" -Recurse -ErrorAction SilentlyContinue
New-Item -Path ".\bin\" -ItemType "directory" -ErrorAction SilentlyContinue
New-Item -Path ".\temp\" -ItemType "directory" -ErrorAction SilentlyContinue

# 获取网络信息
Write-NetworkInfo

# Installing dependencies
function Test-Hashes {
    param (
        [hashtable]$Hashes,
        [string]$Algorithm
    )
    return $Hashes.GetEnumerator() | ForEach-Object {
        $file = $_.Key
        $expectedHash = $_.Value
        Write-Host -ForegroundColor Blue "正在校验 $file 的 $Algorithm 哈希 ..."
        Write-Host -ForegroundColor Gray "期望值: $expectedHash"
        $actualHash = (Get-FileHash -Path $file -Algorithm $Algorithm).Hash
        Write-Host -ForegroundColor Gray "实际值: $actualHash"
        if ($actualHash -ne $expectedHash) {
            # return $false
            Write-Error "$file hash not match."
        } else {
            Write-Host -ForegroundColor Green "$file 哈希校验通过。"
        }
    }
}
function Test-SHA256 ([hashtable]$Hashes) { return Test-Hashes -Hashes $Hashes -Algorithm "SHA256" }
function Test-MD5 ([hashtable]$Hashes) { return Test-Hashes -Hashes $Hashes -Algorithm "MD5" }

if (-not (Test-Path -Path ".\bin\rclone.conf")) {
    Write-Error "rclone conf not found"
}
if (-not (Test-Path -Path "C:\Program Files\7-Zip\7z.exe")) {
    Write-Error "7-zip not found, please install it manually!"
}
if (-not (Test-Path -Path ".\bin\aria2c.exe")) {
    Write-Host "未找到 aria2c，正在下载..."
    Invoke-WebRequest -Uri 'https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-win-64bit-build1.zip' -OutFile ".\temp\aria2.zip"
    Expand-Archive -Path ".\temp\aria2.zip" -DestinationPath ".\temp" -Force
    Move-Item -Path ".\temp\aria2-1.37.0-win-64bit-build1\aria2c.exe" -Destination ".\bin\aria2c.exe" -Force
}
Test-SHA256 @{ 
    ".\bin\aria2c.exe" = "BE2099C214F63A3CB4954B09A0BECD6E2E34660B886D4C898D260FEBFE9D70C2" 
}
if (-not (Test-Path -Path ".\bin\wimlib-imagex.exe")) {
    Write-Host "未找到 wimlib-imagex，正在下载..."
    Invoke-WebRequest -Uri 'https://github.com/user-attachments/files/24684304/wimlib-1.14.4-windows-x86_64-bin.zip' -OutFile ".\temp\wimlib.zip"
    Expand-Archive -Path ".\temp\wimlib.zip" -DestinationPath ".\temp\wimlib" -Force
    Copy-Item -Path ".\temp\wimlib\wimlib-imagex.exe" -Destination ".\bin\wimlib-imagex.exe"
    Copy-Item -Path ".\temp\wimlib\libwim-15.dll" -Destination ".\bin\libwim-15.dll"
}
Test-SHA256 @{ 
    ".\bin\wimlib-imagex.exe" = "401BF99D6DEC2B749B464183F71D146327AE0856A968C309955F71A0C398A348"
    ".\bin\libwim-15.dll"     = "6480B53D4ECD4423AF9E100FE15E3D2C3D114EFF33FBA07977E46C1AB124342E"
}
if (-not (Test-Path -Path ".\bin\rclone.exe")) {
    Write-Host "未找到 rclone，正在下载..."
    Invoke-WebRequest -Uri 'https://downloads.rclone.org/rclone-current-windows-amd64.zip' -outfile .\temp\rclone.zip
    Expand-Archive -Path .\temp\rclone.zip -DestinationPath .\temp\ -Force
    Copy-Item -Path .\temp\rclone-*-windows-amd64\rclone.exe -Destination .\bin\rclone.exe
}

Write-Host "正在下载原版系统镜像..."
Write-Status -Step "下载系统镜像" -Status "开始"
Remove-Item -Path $osFile -Force -ErrorAction SilentlyContinue
Invoke-Aria2Download -Uri $osUrl -Name $osFile -Big
Write-Status -Step "下载系统镜像" -Status "完成"

Write-Host "正在校验原版系统镜像哈希..."
Write-Status -Step "验证镜像哈希" -Status "开始"
if ($osMd5) {
    Test-MD5 @{ $osFile = $osMd5 }
}

$osFileext = [System.IO.Path]::GetExtension("$osFile")
$osFilename = [System.IO.Path]::GetFileNameWithoutExtension("$osFile")
Write-Status -Step "验证镜像哈希" -Status "完成"

# extract iso
if ($osFileext -eq ".iso") {
    Write-Status -Step "解压ISO镜像" -Status "开始"
    ."C:\Program Files\7-Zip\7z.exe" e -y "$osFile" sources\install.wim
    if (Test-Path -Path "install.wim") {
        Write-Host "ISO 解压成功！"
        $osFile = "install.wim"
        $osFilename = "install"
        $osFileext = ".wim"
    } else {
        ."C:\Program Files\7-Zip\7z.exe" e -y "$osFile" sources\install.esd
        if (Test-Path -Path "install.esd") {
            Write-Host "ESD 解压成功！"
            $osFile = "install.esd"
            $osFilename = "install"
            $osFileext = ".esd"
        } else {
            Write-Error "extract wim or esd failed!"
        }
    }
    Write-Status -Step "解压ISO镜像" -Status "完成"
}
# convert esd to wim
# if ($osFileext -eq ".esd") {
#     .\bin\wimlib-imagex.exe export "$osFile" all "$osFilename.wim" --compress fast
# }

# make xrsys image
# Create virtual disk
$vhdfile = Join-Path -Path (Get-Location) -ChildPath "sys.vhdx"
Remove-Item $vhdfile -ErrorAction SilentlyContinue
Write-Status -Step "创建虚拟磁盘" -Status "开始"
@"
CREATE VDISK FILE="$vhdfile" MAXIMUM=102400 TYPE=EXPANDABLE
SELECT VDISK FILE="$vhdfile"
ATTACH VDISK
CREATE PARTITION PRIMARY
FORMAT FS=NTFS QUICK
ASSIGN LETTER=S
"@ | diskpart.exe
if ($?) { Write-Host "虚拟磁盘创建成功！" } else { Write-Error "虚拟磁盘创建失败！" }
$mountDir = "S:"
Write-Status -Step "创建虚拟磁盘" -Status "完成"

# extract imagefile use wimlib-imagex
Write-Host "正在释放 $osFile，请稍候..."
Write-Status -Step "释放镜像(wimlib apply)" -Status "开始"
Invoke-Wimlib -FilePath ".\bin\wimlib-imagex.exe" -Arguments @("apply", "$osFile", $osIndex, "$mountDir")
Write-Status -Step "释放镜像(wimlib apply)" -Status "完成"
# inject deploy
Write-Status -Step "注入部署文件" -Status "开始"
Expand-Archive -Path ".\injectdeploy.zip" -DestinationPath "$mountDir" -Force
Invoke-Aria2Download -Uri "$Server/d/pxy/Xiaoran%20Studio/Onekey/Config/osc.exe" -Destination $mountDir -Name "osc.exe"
Copy-Item -Path ".\injectdeploy.bat" -Destination "$mountDir" -Force
if ($sysArch -eq "arm64") {
    Invoke-WebRequest "https://c.xrgzs.top/unattend/arm64.xml" -OutFile ".\unattend.xml"
}
Copy-Item -Path ".\unattend.xml" -Destination "$mountDir" -Force
# & "$mountDir\injectdeploy.bat" /S
# GBK 转 UTF-8 后执行
$gbk = [System.Text.Encoding]::GetEncoding(936)
$gbkContent = [System.IO.File]::ReadAllText("$mountDir\injectdeploy.bat", $gbk)
$utf8bom = New-Object System.Text.UTF8Encoding $true
[System.IO.File]::WriteAllText("$mountDir\injectdeploy_utf8.bat", $gbkContent, $utf8bom)
cmd.exe /c "$mountDir\injectdeploy_utf8.bat" /S
Remove-Item -Path "$mountDir\injectdeploy_utf8.bat" -ErrorAction SilentlyContinue
if ($?) { Write-Host "部署文件注入成功！" } else { Write-Error "部署文件注入失败！" }
Remove-Item -Path "$mountDir\injectdeploy.bat" -ErrorAction SilentlyContinue
Write-Status -Step "注入部署文件" -Status "完成"

# add drivers
Write-Status -Step "下载并添加驱动" -Status "开始"
Invoke-Aria2Download -Uri $osdrvurl -Destination ".\temp" -Name "drivers.iso" -Big
if ($?) { Write-Host "驱动下载成功！" } else { Write-Error "驱动下载失败！" }
$isopath = Resolve-Path -Path ".\temp\drivers.iso"
# $isomount = (Mount-DiskImage -ImagePath $isopath -PassThru | Get-Volume).DriveLetter
# Copy-Item -Path "${isomount}:\" -Destination "$mountDir\Windows\WinDrive" -Recurse -Force -ErrorAction SilentlyContinue 
# Dismount-DiskImage -ImagePath $isopath 
."C:\Program Files\7-Zip\7z.exe" x -r -y ".\temp\drivers.iso" -o"$mountDir\Windows\WinDrive"
Remove-Item -Path $isopath -ErrorAction SilentlyContinue 
Write-Status -Step "下载并添加驱动" -Status "完成"


Write-Status -Step "下载并添加软件包" -Status "开始"
# add software pack
if ([int]$osVer -ge 10) {
    # add pwsh runtime Windows 10+
    $pwshver = (Invoke-RestMethod https://raw.githubusercontent.com/PowerShell/PowerShell/master/tools/metadata.json).ReleaseTag -replace '^v'
    Invoke-Aria2Download -Uri "https://github.com/PowerShell/PowerShell/releases/download/v$pwshver/PowerShell-$pwshver-win-$osArch.msi" -Destination "$mountDir\Windows\Setup\Set\osc\runtime\PWSH" -Name "PowerShell-$pwshver-win.msi" -Big
  
    # add edge runtime Windows 10+ 
    New-Item -Path ".\temp\Edge" -ItemType "directory" -ErrorAction SilentlyContinue
    $isEdgeProviderExist = Test-Path -Path "$mountDir\Windows\System32\Dism\EdgeProvider.dll"
    if (!$isEdgeProviderExist) {
        Invoke-Aria2Download -Uri "$Server/d/pxy/System/Windows/Win10/Res/EdgeProvider/26100_$osArch.zip" -Destination ".\temp\Edge" -Name "EdgeProvider.zip"
        Expand-Archive -Path ".\temp\Edge\EdgeProvider.zip" -DestinationPath ".\temp\Edge" -Force
        Rename-Item -Path "$mountDir\Windows\System32\Dism\DismProv.dll" -NewName "DismProv.dll.bak" -Force
        Copy-Item -Path ".\temp\Edge\EdgeProvider.dll" -Destination "$mountDir\Windows\System32\Dism\EdgeProvider.dll" -Force
        Copy-Item -Path ".\temp\Edge\DismProv.dll" -Destination "$mountDir\Windows\System32\Dism\DismProv.dll" -Force
    }
    Invoke-Aria2Download -Uri "https://github.com/xrgzs/MSUpdate.Edge/releases/latest/download/Edge_$osArch.wim" -Destination ".\temp\Edge" -Name "Edge.wim" -Big
    DISM.exe /Image:"$mountDir" /Remove-Edge
    DISM.exe /Image:"$mountDir" /Add-Edge /SupportPath:".\temp\Edge"
    if ($?) {
        Write-Host "Edge 运行时添加成功！"
    } else {
        # use old method if add edge runtime failed
        $msedge = (Invoke-RestMethod https://raw.githubusercontent.com/Bush2021/edge_installer/main/data.json)."msedge-stable-win-$osArch"
        $msedgeUrl = "https://github.com/Bush2021/edge_installer/releases/download/$($msedge.version)/$($msedge.文件名)"
        Invoke-Aria2Download -Uri $msedgeUrl -Destination "$mountDir\Windows\Setup\Set\osc\runtime\Edge" -Name $msedge.文件名 -Big
    }
    if (!$isEdgeProviderExist) {
        Remove-Item -Path "$mountDir\Windows\System32\Dism\EdgeProvider.dll" -ErrorAction SilentlyContinue
        if (Test-Path -Path "$mountDir\Windows\System32\Dism\DismProv.dll.bak") {
            Remove-Item -Path "$mountDir\Windows\System32\Dism\DismProv.dll" -ErrorAction SilentlyContinue
            Rename-Item -Path "$mountDir\Windows\System32\Dism\DismProv.dll.bak" -NewName "DismProv.dll" -Force
        }
    }
} else {
    # add edge runtime Windows 8.1-
    Invoke-Aria2Download -Uri "$Server/d/pxy/Software/Edge/109/MicrosoftEdge_X64_109.0.1518.78_Stable.exe" -Destination "$mountDir\Windows\Setup\Set\osc\runtime\Edge" -Name "MicrosoftEdge_X64_109.0.1518.78_Stable.exe" -Big
    # add pwsh runtime Windows 8.1-
    Invoke-Aria2Download -Uri "$Server/d/pxy/Software/PowerShell/PowerShell-7.2.24-win-x64.msi" -Destination "$mountDir\Windows\Setup\Set\osc\runtime\PWSH" -Name "PowerShell-7.2.24-win-x64.msi" -Big
}

# add runtimes
Invoke-Aria2Download -Uri "$Server/d/pxy/Xiaoran%20Studio/Tools/Soft/MSVCRedist.AIO.exe" -Destination "$mountDir\Windows\Setup\Set\osc\runtime" -Name "MSVCRedist.AIO.exe" -Big
Invoke-Aria2Download -Uri "https://aka.ms/dotnet/8.0/windowsdesktop-runtime-win-$osArch.exe" -Destination "$mountDir\Windows\Setup\Set\osc\runtime\DotNet" -Name "8.0-windowsdesktop-runtime-win-$osArch.exe" -Big
if ([int]$osVer -ge 10) {
    Invoke-Aria2Download -Uri "https://aka.ms/dotnet/10.0/windowsdesktop-runtime-win-$osArch.exe" -Destination "$mountDir\Windows\Setup\Set\osc\runtime\DotNet" -Name "10.0-windowsdesktop-runtime-win-$osArch.exe" -Big
}
# https://blogs.windows.com/windows-insider/2025/10/08/announcing-windows-11-insider-preview-build-27965-canary-channel/
if ([float]$osVersion -ge 27965.0) {
    Invoke-Aria2Download -Uri "https://go.microsoft.com/fwlink/?linkid=2337635" -Destination "$mountDir\Windows\Setup\Set\osc\runtime\DotNet" -Name "3.5-dotnet.exe" -Big
}

# add another softwares
Invoke-Aria2Download -Uri "$Server/d/pxy/Xiaoran%20Studio/Tools/Tools.exe" -Destination "$mountDir\Windows\Setup\Set\Run" -Name "常用工具.exe" -Big
Invoke-Aria2Download -Uri "$Server/d/pxy/Xiaoran%20Studio/Tools/Office2016%E5%AD%97%E4%BD%93.exe" -Destination "$mountDir\Windows\Setup\Set\Run" -Name "办公字体.exe" -Big
Invoke-Aria2Download -Uri "$Server/d/pxy/Xiaoran%20Studio/Tools/Soft/Bandizip.exe" -Destination "$mountDir\Windows\Setup\Set\Run" -Name "Bandizip.exe" -Big
Write-Status -Step "下载并添加软件包" -Status "完成"

Write-Status -Step "处理预装Appx" -Status "开始"
# remove preinstalled appx
if ([int]$osVer -ge 10) {
    # 单次过滤 + 管道移除，避免 37 次独立 DISM 操作和重复过滤
    $appPatterns = @(
        'clipchamp.clipchamp',
        'Microsoft.549981C3F5F10',
        'microsoft.microsoftteams',
        'microsoft.skypeapp',
        'microsoft.todos',
        'microsoft.bingnews',
        'microsoft.bingweather',
        'microsoft.bingsearch',
        'microsoft.windowscommunicationsapps',
        'microsoft.gethelp',
        'microsoft.getstarted',
        'microsoft.microsoft3dviewer',
        'microsoft.microsoftofficehub',
        'microsoft.copilot',
        'microsoft.microsoftsolitairecollection',
        'microsoft.microsoftstickynotes',
        'microsoft.mixedreality.portal',
        'microsoft.mspaint',
        'microsoft.office.onenote',
        'microsoft.OutlookForWindows',
        'microsoft.people',
        'microsoft.powerautomatedesktop',
        'microsoft.windowsfeedbackhub',
        'Microsoft.StartExperiencesApp',
        'microsoft.windowsmaps',
        'microsoft.yourphone',
        'microsoft.zunemusic',
        'microsoft.zunevideo',
        'microsoft.xboxapp',
        'Microsoft.Wallet',
        'MicrosoftCorporationII.MicrosoftFamily',
        'MicrosoftTeams',
        'MicrosoftWindows.Client.WebExperience',
        'Microsoft.WidgetsPlatformRuntime',
        'Microsoft.Windows.DevHome',
        'MSTeams',
        'Microsoft.XboxGamingOverlay',
        'Microsoft.XboxSpeechToTextOverlay',
        'Microsoft.XboxIdentityProvider',
        'Microsoft.Xbox.TCUI'
    )
    Get-AppxProvisionedPackage -Path "$mountDir" |
        Where-Object {
            $pkg = $_.PackageName.ToLower()
            foreach ($pat in $appPatterns) { if ($pkg -like "*$($pat.ToLower())*") { return $true } }
            return $false
        } |
        Remove-AppxProvisionedPackage -Path "$mountDir" -ErrorAction SilentlyContinue
    # disable default wd
    Get-WindowsOptionalFeature -Path "$mountDir" | Where-Object { $_.FeatureName -like "*Defender*" } | Disable-WindowsOptionalFeature

    # remove onedrive
    try {
        Remove-WindowsCapability -Path "$mountDir" -Name "Microsoft-Windows-OneDrive-Setup-Package" 
        Remove-WindowsCapability -Path "$mountDir" -Name "Microsoft-Windows-OneDrive-Setup-WOW64-Package" 
    } catch {
        Write-Host "未找到 OneDrive，跳过..."
    }

    # remove recall
    Get-WindowsOptionalFeature -Path "$mountDir" | Where-Object { $_.FeatureName -like "*Recall*" } | Disable-WindowsOptionalFeature -Remove

    # remove webview2 fod (hidden), do this in cleanupcomponents stage
    # Remove-WindowsCapability -Path "$mountDir" -Name "Edge.WebView2.Platform~~~~" -ErrorAction SilentlyContinue

    # remove defender sense client
    try {
        Get-WindowsCapability -Path "$mountDir" | Where-Object { $_.Name -like "*Sense.Client*" } | Remove-WindowsCapability -Path "$mountDir"
    } catch {
        Write-Host "未找到 Defender Sense Client，跳过..."
    }
}
Write-Status -Step "处理预装Appx" -Status "完成"

# write version
"${sysvercn}_${sysdate} 
${sysver}_${sysdate}
" | Out-File -FilePath "$mountDir\Windows\Version.txt" -Encoding gbk

# capture system image
# Write-Host "Packing $sysFile.wim, please wait..."
# New-WindowsImage -ImagePath ".\$sysFile.wim" -CapturePath "$mountDir" -Name $sysVer -Description $sysVerCN
Write-Status -Step "捕获镜像(wimlib capture)" -Status "开始"
Invoke-Wimlib -FilePath ".\bin\wimlib-imagex.exe" -Arguments @("capture", "$mountDir", "$sysFile.esd", "$sysVer", "$sysVerCN", "--solid", "--compress=lzms:34", "--threads=6", "--solid-chunk-size=128M", "--image-property", "DISPLAYNAME=$sysVer", "--image-property", "DISPLAYDESCRIPTION=$sysVerCN")
if ($?) { Write-Host "镜像捕获成功！" } else { Write-Error "镜像捕获失败！" }
Write-Status -Step "捕获镜像(wimlib capture)" -Status "完成"

# clean up mount dir
# Dismount-DiskImage -Path "$mountDir" -Discard
# @"
# SELECT VDISK FILE="$vhdfile"
# DETACH VDISK
# "@  | diskpart.exe
# if ($?) { Write-Host "Clean Up Successfully!" } else { Write-Error "Clean Up Failed!" }
# Remove-Item $vhdfile -Force -ErrorAction SilentlyContinue

# convert to esd
# .\bin\wimlib-imagex.exe export "$sysFile.wim" all "$sysFile.esd" --solid
# if ($?) { Write-Host "Convert Successfully!"} else {Write-Error "Convert Failed!"}

Write-Status -Step "生成文件校验和" -Status "开始"
# Get file information
$sysFileByte = (Get-ItemProperty ".\$sysFile.esd").Length
$sysFileSize = [Math]::Round($sysFileByte / 1024 / 1024 / 1024, 2)
Write-Host "文件大小: $sysFileSize GB ($sysFileByte 字节)"
# 单次读取文件，同时计算 MD5 和 SHA256，避免重复 IO
$filePath = ".\$sysFile.esd"
$md5 = [System.Security.Cryptography.MD5]::Create()
$sha256 = [System.Security.Cryptography.SHA256]::Create()
$stream = [System.IO.File]::OpenRead($filePath)
$buffer = [byte[]]::new(1MB)
while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
    $null = $md5.TransformBlock($buffer, 0, $read, $null, 0)
    $null = $sha256.TransformBlock($buffer, 0, $read, $null, 0)
}
$null = $md5.TransformFinalBlock([byte[]]::new(0), 0, 0)
$null = $sha256.TransformFinalBlock([byte[]]::new(0), 0, 0)
$sysFileMD5 = [BitConverter]::ToString($md5.Hash).Replace('-', '').ToLower()
$sysFileSHA256 = [BitConverter]::ToString($sha256.Hash).Replace('-', '').ToLower()
$stream.Close(); $md5.Dispose(); $sha256.Dispose()
@{
    "sys" = @{
        "ver"      = [string]$sysVer
        "vercn"    = $sysVerCN
        "date"     = $sysDate
        "datefull" = $sysDateFull
        "file"     = "$sysFile.esd"
        "size"     = "$sysFileSize GB"
        "byte"     = $sysFileByte
        "md5"      = $sysFileMD5
        "sha256"   = $sysFileSHA256
        "url"      = "$Server/d/pxy/Xiaoran%20Studio/System/Nightly/$sysDate/$sysFile.esd"
    }
    "os"  = @{
        "arch"    = $osArch
        "ver"     = $osVer
        "version" = $osVersion
        "file"    = $osFile
        "index"   = $osIndex
    }
} | ConvertTo-Json -OutVariable jsonContent | Out-File -FilePath ".\$sysFile.json" -Encoding utf8
Write-Host $jsonContent
Write-Status -Step "生成文件校验和" -Status "完成"

# Publish image
Write-Status -Step "上传镜像到网盘" -Status "开始"
.\bin\rclone.exe copy "$sysFile.esd" "zhipin:/Share/Xiaoran Studio/System/Nightly/$sysDate" --progress --onedrive-chunk-size 250M
if ($?) { Write-Host "上传成功！" } else { Write-Error "上传失败！" }
.\bin\rclone.exe copy "$sysFile.json" "zhipin:/Share/Xiaoran Studio/System/Nightly/$sysDate" --progress
# Set latest
if ($Latest) {
    .\bin\rclone.exe copyto "$sysFile.json" "zhipin:/Share/Xiaoran Studio/System/Nightly/$sysVer.json" --progress
}
Write-Status -Step "上传镜像到网盘" -Status "完成"
Write-Status -Step "全部完成" -Status "成功"