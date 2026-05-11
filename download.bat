@echo off
setlocal
chcp 65001 >nul
title WSL Distribution Downloader

set "ROOT=%~dp0"
set "TMP=%ROOT%tmp"
set "PS1=%TMP%\download-runner-%RANDOM%-%RANDOM%.ps1"
set "DOWNLOAD_BAT_PATH=%~f0"
set "DOWNLOAD_PS1_PATH=%PS1%"

if not exist "%TMP%" mkdir "%TMP%" >nul 2>nul

powershell -NoProfile -ExecutionPolicy Bypass -Command "$bat = [System.IO.File]::ReadAllText($env:DOWNLOAD_BAT_PATH, [System.Text.Encoding]::UTF8); $marker = '### POWERSHELL ###'; $pos = $bat.LastIndexOf($marker); if ($pos -lt 0) { throw 'PowerShell marker not found.' }; $code = $bat.Substring($pos + $marker.Length).TrimStart(); Set-Content -LiteralPath $env:DOWNLOAD_PS1_PATH -Value $code -Encoding UTF8"
if errorlevel 1 (
  echo Failed to start the embedded PowerShell script.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" "%ROOT%."
set "ERR=%ERRORLEVEL%"
del "%PS1%" >nul 2>nul

echo.
pause
exit /b %ERR%

### POWERSHELL ###
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$root = [System.IO.Path]::GetFullPath($ProjectRoot)
$distDir = Join-Path $root 'dist'
$tmpDir = Join-Path $root 'tmp'
$binDir = Join-Path $tmpDir 'bin'
$lockFile = Join-Path $tmpDir 'download.lock'
$versionFile = Join-Path $binDir 'version.txt'
$aria2Exe = Join-Path $binDir 'aria2c.exe'
$distributionJsonUrl = 'https://raw.githubusercontent.com/microsoft/WSL/refs/heads/master/distributions/DistributionInfo.json'
$headers = @{ 'User-Agent' = 'download-bat-wsl-distro-downloader' }
$script:ActiveAria2Process = $null
$messages = @{
    UnsupportedArchitecture = 'Unsupported system architecture: {0}'
    DownloadWithAria2 = 'Downloading with aria2c: {0}'
    Aria2DownloadFailed = 'aria2c download failed: {0}'
    DownloadWithPowerShell = 'Downloading with Windows PowerShell: {0}'
    CheckAria2Latest = 'Checking latest aria2c release'
    Aria2Current = 'aria2c is already up to date: {0}'
    Aria2ArmFallback = 'No Windows ARM64 aria2 asset was found in the official Release. Falling back to Windows x64.'
    Aria2NoAsset = 'No usable Windows 64-bit zip was found in the official aria2 GitHub Release.'
    Aria2Downloading = 'Downloading aria2c: {0}'
    Aria2NoExe = 'aria2c.exe was not found in the aria2 zip archive.'
    Aria2Updated = 'aria2c has been updated to: {0}'
    SelectDistro = 'Select WSL distributions to download'
    SelectLegacyDistro = 'Select legacy WSL distributions to download'
    ControlsHint = 'Use Up/Down to move, Space to select, and Enter to continue.'
    SkipSection = 'Skip this section'
    LegacyWarning = 'Warning: legacy Store/Appx packages. No sha256 is available, so verification will be skipped.'
    AppTitle = 'WSL Distribution Downloader'
    SystemArch = 'System architecture: {0}'
    OutputDir = 'Output directory: {0}'
    DownloadIndex = 'Downloading distribution index'
    NoDistro = 'No downloadable distributions are available for {0}.'
    NoSelection = 'No distribution is selected.'
    NoLegacyDistro = 'No legacy distributions are available for {0}.'
    SelectedCount = 'Selected: {0}'
    ConfirmItem = 'Download item'
    Name = 'Name: {0}'
    File = 'File: {0}'
    ValidCache = 'Valid cache'
    CacheHit = 'File already exists and sha256 matches. Skipping download: {0}'
    ExistingMismatch = 'A file with the same name exists, but sha256 does not match. It will be downloaded again.'
    LegacyExistingOverwrite = 'Existing legacy file will be overwritten because no sha256 is available.'
    StartDownload = 'Starting download'
    VerifyHash = 'Verifying sha256'
    SkipHash = 'Skipping sha256 verification because this legacy JSON entry does not provide a hash.'
    HashFailed = 'sha256 verification failed. Actual value: {0}'
    DuplicateTarget = 'Duplicate output file name detected: {0}. Please select only one of the conflicting entries.'
    ExistingInstance = 'Another instance appears to be running in this folder. Close it first, or delete tmp\download.lock if it is stale.'
    QueueSummary = 'Download queue: {0} modern, {1} legacy.'
    FinalSummary = 'Summary: {0} saved, {1} skipped.'
    Complete = 'Complete'
    Saved = 'Saved: {0}'
    Skipped = 'Skipped: {0}'
    Interrupted = 'Interrupted. Active aria2c process has been stopped.'
    StaleAria2Stopped = 'Stopped stale aria2c process from this script: PID {0}'
    Error = 'Error:'
}

function T {
    param(
        [string]$Key,
        [Parameter(ValueFromRemainingArguments = $true)]
        [object[]]$FormatArgs
    )
    $text = $messages[$Key]
    if ($FormatArgs.Count -gt 0) {
        return ($text -f $FormatArgs)
    }
    return $text
}

function Write-Step {
    param([string]$Message)
    Write-Host ''
    Write-Host "== $Message ==" -ForegroundColor Cyan
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Normalize-Sha256 {
    param([string]$Hash)
    if ([string]::IsNullOrWhiteSpace($Hash)) {
        return ''
    }
    return ($Hash.Trim().ToLowerInvariant() -replace '^0x', '')
}

function Test-FileSha256 {
    param(
        [string]$Path,
        [string]$ExpectedHash
    )
    $expected = Normalize-Sha256 $ExpectedHash
    if (-not $expected -or -not (Test-Path -LiteralPath $Path)) {
        return $false
    }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    return $actual -eq $expected
}

function Get-SafeFileName {
    param([string]$Name)
    $safe = $Name.Trim() -replace '\s+', '_'
    foreach ($char in [System.IO.Path]::GetInvalidFileNameChars()) {
        $safe = $safe.Replace([string]$char, '_')
    }
    return $safe
}

function Get-SourceExtension {
    param([string]$Url)
    $path = ([System.Uri]$Url).AbsolutePath
    $fileName = [System.IO.Path]::GetFileName($path)
    $lower = $fileName.ToLowerInvariant()
    foreach ($ext in @('.tar.gz', '.tar.xz', '.appxbundle', '.msixbundle', '.appx', '.msix', '.wsl', '.zip')) {
        if ($lower.EndsWith($ext)) {
            return $ext
        }
    }
    $fallback = [System.IO.Path]::GetExtension($fileName)
    if ([string]::IsNullOrWhiteSpace($fallback)) {
        return '.download'
    }
    return $fallback
}

function Get-SystemArchitecture {
    $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    switch -Regex ($arch) {
        'ARM64' { return @{ Label = 'arm64'; JsonProperty = 'Arm64Url'; Aria2AssetPattern = '(?i)win.*(arm64|aarch64).*\.zip$' } }
        'AMD64|x86_64' { return @{ Label = 'x64'; JsonProperty = 'Amd64Url'; Aria2AssetPattern = '(?i)win.*64.*\.zip$' } }
        default { throw (T 'UnsupportedArchitecture' $arch) }
    }
}

function Join-CommandLineArgument {
    param([string]$Value)
    return '"' + ($Value.Replace('"', '\"')) + '"'
}

function Stop-ActiveAria2Process {
    if ($script:ActiveAria2Process -and -not $script:ActiveAria2Process.HasExited) {
        try {
            Stop-Process -Id $script:ActiveAria2Process.Id -Force -ErrorAction SilentlyContinue
            $script:ActiveAria2Process.WaitForExit(3000) | Out-Null
        }
        catch {
        }
    }
    $script:ActiveAria2Process = $null
}

function Stop-ProjectAria2Processes {
    $pathTokens = @(
        $root.TrimEnd('\'),
        $tmpDir.TrimEnd('\'),
        ($root.TrimEnd('\') -replace '\\', '/'),
        ($tmpDir.TrimEnd('\') -replace '\\', '/')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    try {
        Get-CimInstance Win32_Process -Filter "Name = 'aria2c.exe'" | ForEach-Object {
            $commandLine = [string]$_.CommandLine
            foreach ($token in $pathTokens) {
                if ($commandLine.IndexOf($token, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
                    Write-Host (T 'StaleAria2Stopped' $_.ProcessId) -ForegroundColor Yellow
                    break
                }
            }
        }
    }
    catch {
    }
}

function New-RunLock {
    if (Test-Path -LiteralPath $lockFile) {
        $existingPid = ([System.IO.File]::ReadAllText($lockFile)).Trim()
        if ($existingPid -match '^\d+$' -and (Get-Process -Id ([int]$existingPid) -ErrorAction SilentlyContinue)) {
            throw (T 'ExistingInstance')
        }
    }
    Set-Content -LiteralPath $lockFile -Value $PID -Encoding ASCII
}

function Remove-RunLock {
    Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
}

function Assert-UniqueTargetNames {
    param([object[]]$Items)
    $duplicate = $Items | Group-Object -Property TargetName | Where-Object { $_.Count -gt 1 } | Select-Object -First 1
    if ($duplicate) {
        throw (T 'DuplicateTarget' $duplicate.Name)
    }
}

function Invoke-Aria2WithProgress {
    param(
        [string]$Url,
        [string]$Directory,
        [string]$FileName,
        [string]$Description
    )

    $arguments = @(
        '--allow-overwrite=true',
        '--auto-file-renaming=false',
        '--show-console-readout=true',
        '--console-log-level=warn',
        '--summary-interval=0',
        '--download-result=hide',
        '--file-allocation=none',
        '-x', '16',
        '-s', '16',
        '-k', '1M',
        '-d', $Directory,
        '-o', $FileName,
        $Url
    )
    $argumentLine = ($arguments | ForEach-Object { Join-CommandLineArgument $_ }) -join ' '
    $process = Start-Process -FilePath $aria2Exe -ArgumentList $argumentLine -WorkingDirectory $Directory -NoNewWindow -PassThru
    $script:ActiveAria2Process = $process

    try {
        $process.WaitForExit()
        $process.Refresh()
        Write-Host ''

        $exitCode = $process.ExitCode
        $outFile = Join-Path $Directory $FileName
        if ($null -eq $exitCode -and (Test-Path -LiteralPath $outFile)) {
            $exitCode = 0
        }

        if ($exitCode -ne 0) {
            throw (T 'Aria2DownloadFailed' $Description)
        }
    }
    finally {
        if ($script:ActiveAria2Process -and $script:ActiveAria2Process.Id -eq $process.Id) {
            Stop-ActiveAria2Process
        }
    }
}

function Invoke-Download {
    param(
        [string]$Url,
        [string]$Directory,
        [string]$FileName,
        [string]$Description
    )
    Ensure-Directory $Directory
    $outFile = Join-Path $Directory $FileName
    if (Test-Path -LiteralPath $outFile) {
        Remove-Item -LiteralPath $outFile -Force
    }

    if (Test-Path -LiteralPath $aria2Exe) {
        Write-Host (T 'DownloadWithAria2' $Description)
        Invoke-Aria2WithProgress -Url $Url -Directory $Directory -FileName $FileName -Description $Description
    }
    else {
        Write-Host (T 'DownloadWithPowerShell' $Description)
        Invoke-WebRequest -Uri $Url -OutFile $outFile -Headers $headers
    }
    return $outFile
}

function Update-Aria2 {
    param([hashtable]$Architecture)

    Write-Step (T 'CheckAria2Latest')
    Ensure-Directory $binDir

    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/aria2/aria2/releases/latest' -Headers $headers
    $latestVersion = [string]$release.tag_name

    $asset = $release.assets | Where-Object { $_.name -match $Architecture.Aria2AssetPattern } | Select-Object -First 1
    if (-not $asset -and $Architecture.Label -eq 'arm64') {
        Write-Host (T 'Aria2ArmFallback')
        $asset = $release.assets | Where-Object { $_.name -match '(?i)win.*64.*\.zip$' } | Select-Object -First 1
    }
    if (-not $asset) {
        throw (T 'Aria2NoAsset')
    }

    $desiredVersionRecord = '{0}|{1}' -f $latestVersion, $asset.name
    $currentVersionRecord = if (Test-Path -LiteralPath $versionFile) { ([System.IO.File]::ReadAllText($versionFile)).Trim() } else { '' }

    if ((Test-Path -LiteralPath $aria2Exe) -and $currentVersionRecord -eq $desiredVersionRecord) {
        Write-Host (T 'Aria2Current' $latestVersion)
        return
    }

    Write-Host (T 'Aria2Downloading' $latestVersion)
    $ariaTmp = Join-Path $tmpDir 'aria2'
    $zipPath = Join-Path $tmpDir 'aria2.zip'
    if (Test-Path -LiteralPath $ariaTmp) { Remove-Item -LiteralPath $ariaTmp -Recurse -Force }
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -Headers $headers
    Expand-Archive -LiteralPath $zipPath -DestinationPath $ariaTmp -Force

    $foundExe = Get-ChildItem -LiteralPath $ariaTmp -Recurse -Filter 'aria2c.exe' | Select-Object -First 1
    if (-not $foundExe) {
        throw (T 'Aria2NoExe')
    }

    Copy-Item -LiteralPath $foundExe.FullName -Destination $aria2Exe -Force
    Set-Content -LiteralPath $versionFile -Value $desiredVersionRecord -Encoding ASCII
    Write-Host (T 'Aria2Updated' $latestVersion)
}

function Get-DistributionList {
    param(
        [string]$JsonPath,
        [hashtable]$Architecture
    )
    $json = [System.IO.File]::ReadAllText($JsonPath) | ConvertFrom-Json
    $items = New-Object System.Collections.Generic.List[object]
    $index = 1

    foreach ($group in $json.ModernDistributions.PSObject.Properties) {
        foreach ($entry in @($group.Value)) {
            $urlInfo = $entry.PSObject.Properties[$Architecture.JsonProperty].Value
            if (-not $urlInfo -or [string]::IsNullOrWhiteSpace([string]$urlInfo.Url)) {
                continue
            }

            $safeName = Get-SafeFileName ([string]$entry.FriendlyName)
            $extension = Get-SourceExtension ([string]$urlInfo.Url)
            $targetName = '{0}{1}' -f $safeName, $extension

            $items.Add([pscustomobject]@{
                Index = $index
                Source = 'Modern'
                Group = [string]$group.Name
                Name = [string]$entry.Name
                FriendlyName = [string]$entry.FriendlyName
                Url = [string]$urlInfo.Url
                Sha256 = Normalize-Sha256 ([string]$urlInfo.Sha256)
                TargetName = $targetName
                RequiresHash = $true
                IsDefault = [bool]$entry.Default
            })
            $index++
        }
    }

    return $items
}

function Get-LegacyDistributionList {
    param(
        [string]$JsonPath,
        [hashtable]$Architecture
    )
    $json = [System.IO.File]::ReadAllText($JsonPath) | ConvertFrom-Json
    $items = New-Object System.Collections.Generic.List[object]
    $index = 1

    $urlProperty = if ($Architecture.Label -eq 'arm64') { 'Arm64PackageUrl' } else { 'Amd64PackageUrl' }
    $supportedProperty = if ($Architecture.Label -eq 'arm64') { 'Arm64' } else { 'Amd64' }

    foreach ($entry in @($json.Distributions)) {
        $supported = $entry.PSObject.Properties[$supportedProperty].Value
        $url = [string]$entry.PSObject.Properties[$urlProperty].Value
        if (-not $supported -or [string]::IsNullOrWhiteSpace($url)) {
            continue
        }

        $safeName = Get-SafeFileName ([string]$entry.FriendlyName)
        $extension = Get-SourceExtension $url
        $targetName = '{0}{1}' -f $safeName, $extension

        $items.Add([pscustomobject]@{
            Index = $index
            Source = 'Legacy'
            Group = 'Legacy'
            Name = [string]$entry.Name
            FriendlyName = [string]$entry.FriendlyName
            Url = $url
            Sha256 = ''
            TargetName = $targetName
            RequiresHash = $false
            IsDefault = $false
        })
        $index++
    }

    return $items
}

function Show-SelectionMenu {
    param(
        [object[]]$Items,
        [string]$Title,
        [string]$Warning = '',
        [bool]$AllowEmpty = $false
    )

    $menu = New-Object System.Collections.Generic.List[object]
    $menu.Add([pscustomobject]@{ Type = 'all'; Label = 'Select all'; Item = $null; Selected = $false }) | Out-Null
    foreach ($item in $Items) {
        $label = '{0} [{1}]' -f $item.FriendlyName, $item.Group
        $menu.Add([pscustomobject]@{ Type = 'item'; Label = $label; Item = $item; Selected = $false }) | Out-Null
    }
    $menu.Add([pscustomobject]@{ Type = 'exit'; Label = (T 'SkipSection'); Item = $null; Selected = $false }) | Out-Null

    $cursor = 0
    $notice = ''

    while ($true) {
        Clear-Host
        Write-Host (T 'AppTitle')
        Write-Host (T 'SystemArch' $architecture.Label)
        Write-Host (T 'OutputDir' $distDir)
        Write-Step $Title
        Write-Host (T 'ControlsHint')
        if ($Warning) {
            Write-Host $Warning -ForegroundColor Yellow
            Write-Host ''
        }
        if ($notice) {
            Write-Host $notice -ForegroundColor Yellow
            Write-Host ''
        }

        $selectedCount = @($menu | Where-Object { $_.Type -eq 'item' -and $_.Selected }).Count
        $menu[0].Selected = ($selectedCount -eq $Items.Count)

        for ($i = 0; $i -lt $menu.Count; $i++) {
            $entry = $menu[$i]
            $prefix = if ($i -eq $cursor) { '>' } else { ' ' }
            $box = if ($entry.Selected) { '[*]' } else { '[ ]' }
            $line = '{0} {1} {2}' -f $prefix, $box, $entry.Label

            if ($i -eq $cursor) {
                Write-Host $line -ForegroundColor Black -BackgroundColor Gray
            }
            elseif ($entry.Type -eq 'exit') {
                Write-Host $line -ForegroundColor DarkGray
            }
            else {
                Write-Host $line
            }
        }

        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            'UpArrow' {
                $cursor--
                if ($cursor -lt 0) { $cursor = $menu.Count - 1 }
                $notice = ''
            }
            'DownArrow' {
                $cursor++
                if ($cursor -ge $menu.Count) { $cursor = 0 }
                $notice = ''
            }
            'Spacebar' {
                $entry = $menu[$cursor]
                if ($entry.Type -eq 'all') {
                    $selectAll = -not $entry.Selected
                    foreach ($menuItem in $menu | Where-Object { $_.Type -eq 'item' }) {
                        $menuItem.Selected = $selectAll
                    }
                }
                elseif ($entry.Type -eq 'item') {
                    $entry.Selected = -not $entry.Selected
                }
                elseif ($entry.Type -eq 'exit') {
                    return @()
                }
                $notice = ''
            }
            'Enter' {
                if ($menu[$cursor].Type -eq 'exit') {
                    return @()
                }
                $selected = @($menu | Where-Object { $_.Type -eq 'item' -and $_.Selected } | ForEach-Object { $_.Item })
                if ($selected.Count -gt 0 -or $AllowEmpty) {
                    return $selected
                }
                $notice = T 'NoSelection'
            }
            'Escape' {
                return @()
            }
        }
    }
}

function Cleanup-Tmp {
    Get-ChildItem -LiteralPath $tmpDir -Force | Where-Object { $_.Name -ne 'bin' } | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

[Console]::add_CancelKeyPress({
    param($Sender, $EventArgs)
    $EventArgs.Cancel = $true
    Stop-ActiveAria2Process
    Cleanup-Tmp
    Remove-RunLock
    [Console]::WriteLine()
    [Console]::WriteLine((T 'Interrupted'))
    [Environment]::Exit(130)
})

try {
    Ensure-Directory $distDir
    Ensure-Directory $tmpDir
    Ensure-Directory $binDir
    New-RunLock
    Stop-ProjectAria2Processes

    $architecture = Get-SystemArchitecture
    Write-Host 'WSL Distribution Downloader'
    Write-Host (T 'SystemArch' $architecture.Label)
    Write-Host (T 'OutputDir' $distDir)

    Update-Aria2 -Architecture $architecture

    Write-Step (T 'DownloadIndex')
    $jsonPath = Invoke-Download -Url $distributionJsonUrl -Directory $tmpDir -FileName 'DistributionInfo.json' -Description 'DistributionInfo.json'
    $items = @(Get-DistributionList -JsonPath $jsonPath -Architecture $architecture)
    $legacyItems = @(Get-LegacyDistributionList -JsonPath $jsonPath -Architecture $architecture)
    if ($items.Count -eq 0) {
        throw (T 'NoDistro' $architecture.Label)
    }

    $selectedItems = @(Show-SelectionMenu -Items $items -Title (T 'SelectDistro') -AllowEmpty $true)
    $selectedLegacyItems = @()
    if ($legacyItems.Count -gt 0) {
        $selectedLegacyItems = @(Show-SelectionMenu -Items $legacyItems -Title (T 'SelectLegacyDistro') -Warning (T 'LegacyWarning') -AllowEmpty $true)
    }
    else {
        Write-Step (T 'SelectLegacyDistro')
        Write-Host (T 'NoLegacyDistro' $architecture.Label) -ForegroundColor Yellow
    }

    $downloadQueue = @($selectedItems + $selectedLegacyItems)
    if ($downloadQueue.Count -eq 0) {
        Cleanup-Tmp
        exit 0
    }
    Assert-UniqueTargetNames -Items $downloadQueue

    $modernCount = @($downloadQueue | Where-Object { $_.Source -eq 'Modern' }).Count
    $legacyCount = @($downloadQueue | Where-Object { $_.Source -eq 'Legacy' }).Count
    Write-Step (T 'StartDownload')
    Write-Host (T 'QueueSummary' $modernCount $legacyCount)

    $downloadDir = Join-Path $tmpDir 'download'
    $savedCount = 0
    $skippedCount = 0
    foreach ($selected in $downloadQueue) {
        Write-Step (T 'ConfirmItem')
        Write-Host (T 'Name' $selected.FriendlyName)
        Write-Host (T 'File' $selected.TargetName)
        if ($selected.RequiresHash) {
            Write-Host "SHA256: $($selected.Sha256)"
        }
        else {
            Write-Host 'SHA256: not available'
        }
        Write-Host "URL: $($selected.Url)"

        $targetPath = Join-Path $distDir $selected.TargetName
        if ($selected.RequiresHash -and (Test-FileSha256 -Path $targetPath -ExpectedHash $selected.Sha256)) {
            Write-Step (T 'ValidCache')
            Write-Host (T 'CacheHit' $targetPath)
            Write-Host (T 'Skipped' $selected.TargetName) -ForegroundColor Green
            $skippedCount++
            continue
        }

        if (Test-Path -LiteralPath $targetPath) {
            if ($selected.RequiresHash) {
                Write-Host (T 'ExistingMismatch') -ForegroundColor Yellow
            }
            else {
                Write-Host (T 'LegacyExistingOverwrite') -ForegroundColor Yellow
            }
        }

        Write-Step (T 'StartDownload')
        $downloadedPath = Invoke-Download -Url $selected.Url -Directory $downloadDir -FileName $selected.TargetName -Description $selected.FriendlyName

        if ($selected.RequiresHash) {
            Write-Step (T 'VerifyHash')
            if (-not (Test-FileSha256 -Path $downloadedPath -ExpectedHash $selected.Sha256)) {
                $actual = (Get-FileHash -LiteralPath $downloadedPath -Algorithm SHA256).Hash.ToLowerInvariant()
                throw (T 'HashFailed' $actual)
            }
        }
        else {
            Write-Step (T 'VerifyHash')
            Write-Host (T 'SkipHash') -ForegroundColor Yellow
        }

        Move-Item -LiteralPath $downloadedPath -Destination $targetPath -Force
        Write-Host (T 'Saved' $targetPath) -ForegroundColor Green
        $savedCount++
    }

    Cleanup-Tmp

    Write-Step (T 'Complete')
    Write-Host (T 'FinalSummary' $savedCount $skippedCount)
}
catch {
    Write-Host ''
    Write-Host (T 'Error') -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
finally {
    Stop-ActiveAria2Process
    Remove-RunLock
}
