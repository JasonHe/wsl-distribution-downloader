@echo off
setlocal

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$file = '%~f0'; $text = Get-Content -Raw -LiteralPath $file; $marker = '### POWERSHELL ###'; $idx = $text.LastIndexOf($marker); if ($idx -lt 0) { Write-Host 'ERROR: PowerShell payload marker was not found.'; exit 1 }; $script = $text.Substring($idx + $marker.Length); Invoke-Expression $script"
set "exitCode=%ERRORLEVEL%"
endlocal & exit /b %exitCode%

### POWERSHELL ###
$ErrorActionPreference = 'Stop'

function Get-WslDistroInfo {
    $lxssKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'

    if (-not (Test-Path -LiteralPath $lxssKey)) {
        return @()
    }

    $items = foreach ($key in Get-ChildItem -LiteralPath $lxssKey) {
        $props = Get-ItemProperty -LiteralPath $key.PSPath
        $name = [string]$props.DistributionName
        $basePath = [string]$props.BasePath

        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        $vhdPath = $null
        $vhdExists = $false
        $isSparse = $null

        if (-not [string]::IsNullOrWhiteSpace($basePath)) {
            $expandedBasePath = [Environment]::ExpandEnvironmentVariables($basePath)
            $candidate = Join-Path -Path $expandedBasePath -ChildPath 'ext4.vhdx'
            if (Test-Path -LiteralPath $candidate) {
                $vhdPath = (Resolve-Path -LiteralPath $candidate).Path
                $vhdItem = Get-Item -LiteralPath $vhdPath
                $vhdExists = $true
                $isSparse = (($vhdItem.Attributes -band [IO.FileAttributes]::SparseFile) -ne 0)
            }
        }

        [pscustomobject]@{
            Name      = $name
            BasePath  = $basePath
            VhdPath   = $vhdPath
            VhdExists = $vhdExists
            IsSparse  = $isSparse
        }
    }

    return @($items | Sort-Object -Property Name)
}

function Format-SparseState {
    param([object]$Value, [bool]$VhdExists)

    if (-not $VhdExists) {
        return 'No VHDX'
    }

    if ($Value -eq $true) {
        return 'Sparse'
    }

    if ($Value -eq $false) {
        return 'Not sparse'
    }

    return 'Unknown'
}

function Get-StateColor {
    param([string]$State)

    switch ($State) {
        'Sparse' { return 'Green' }
        'Not sparse' { return 'Yellow' }
        'No VHDX' { return 'Red' }
        default { return 'DarkYellow' }
    }
}

function Write-Rule {
    Write-Host '--------------------------------------------------------------------------' -ForegroundColor DarkGray
}

function Write-Title {
    Clear-Host
    Write-Host '==========================================================================' -ForegroundColor DarkCyan
    Write-Host ' WSL Sparse VHDX Converter' -ForegroundColor Cyan
    Write-Host '==========================================================================' -ForegroundColor DarkCyan
    Write-Host ''
}

function Write-StatusText {
    param(
        [Parameter(Mandatory)]
        [string]$State,
        [int]$Width = 12
    )

    $color = Get-StateColor -State $State
    Write-Host $State.PadRight($Width) -ForegroundColor $color -NoNewline
}

function Write-DistroRow {
    param(
        [string]$Prefix,
        [string]$Mark,
        [object]$Distro,
        [int]$Number = 0
    )

    $state = Format-SparseState -Value $Distro.IsSparse -VhdExists $Distro.VhdExists
    $vhd = if ($Distro.VhdExists) { 'Found' } else { 'Missing' }
    $numberText = if ($Number -gt 0) { $Number.ToString().PadLeft(2) } else { '  ' }

    Write-Host ("{0} {1} {2}  {3,-24} " -f $Prefix, $Mark, $numberText, $Distro.Name) -NoNewline
    Write-StatusText -State $state -Width 12
    Write-Host (" {0,-8}" -f $vhd)
}

function Read-Mode {
    $cursor = 0
    $items = @(
        [pscustomobject]@{ Label = 'Enable sparse'; Value = $true; Description = 'Set selected VHDX files to sparse mode' },
        [pscustomobject]@{ Label = 'Disable sparse'; Value = $false; Description = 'Set selected VHDX files to non-sparse mode' },
        [pscustomobject]@{ Label = 'Exit'; Value = $null; Description = 'Close this tool' }
    )

    while ($true) {
        Write-Title
        Write-Host 'Choose operation mode.'
        Write-Host ''
        Write-Rule
        Write-Host ("{0} {1,-18} {2}" -f ' ', 'Mode', 'Description') -ForegroundColor Gray
        Write-Rule

        for ($i = 0; $i -lt $items.Count; $i++) {
            $prefix = if ($i -eq $cursor) { '>' } else { ' ' }
            Write-Host ("{0} {1,-18} {2}" -f $prefix, $items[$i].Label, $items[$i].Description)
        }

        Write-Rule
        Write-Host 'Up/Down Move | Enter Confirm | Esc Exit' -ForegroundColor DarkGray

        $key = [Console]::ReadKey($true)

        switch ($key.Key) {
            'UpArrow' {
                if ($cursor -le 0) {
                    $cursor = $items.Count - 1
                }
                else {
                    $cursor--
                }
            }
            'DownArrow' {
                if ($cursor -ge ($items.Count - 1)) {
                    $cursor = 0
                }
                else {
                    $cursor++
                }
            }
            'Enter' {
                return $items[$cursor].Value
            }
            'Escape' {
                return $null
            }
        }
    }
}

function Read-Selection {
    param(
        [Parameter(Mandatory)]
        [object[]]$Distros,

        [Parameter(Mandatory)]
        [bool]$TargetSparse
    )

    $cursor = 0
    $selected = New-Object bool[] $Distros.Count
    $lastIndex = $Distros.Count + 1

    while ($true) {
        Write-Title
        Write-Host ("Found {0} distribution(s)." -f $Distros.Count)
        Write-Host ("Mode: {0}" -f $(if ($TargetSparse) { 'Enable sparse' } else { 'Disable sparse' }))
        Write-Host ''
        Write-Host 'Select distributions to update.'
        Write-Host ''
        Write-Rule
        Write-Host ("{0} {1} {2}  {3,-24} {4,-12} {5,-8}" -f ' ', '   ', '# ', 'Distribution', 'Sparse', 'VHDX') -ForegroundColor Gray
        Write-Rule

        for ($i = 0; $i -le $lastIndex; $i++) {
            $prefix = if ($i -eq $cursor) { '>' } else { ' ' }

            if ($i -eq 0) {
                $allSelected = ($selected.Count -gt 0 -and -not ($selected -contains $false))
                $mark = if ($allSelected) { '[x]' } else { '[ ]' }
                Write-Host ("{0} {1}      {2}" -f $prefix, $mark, 'Select all')
                continue
            }

            if ($i -eq $lastIndex) {
                Write-Host ("{0}          {1}" -f $prefix, 'Exit')
                continue
            }

            $distroIndex = $i - 1
            $distro = $Distros[$distroIndex]
            $mark = if ($selected[$distroIndex]) { '[x]' } else { '[ ]' }
            Write-DistroRow -Prefix $prefix -Mark $mark -Distro $distro -Number ($distroIndex + 1)
        }

        Write-Rule
        Write-Host 'Up/Down Move | Space Toggle | Enter Confirm | Esc Exit' -ForegroundColor DarkGray

        $key = [Console]::ReadKey($true)

        switch ($key.Key) {
            'UpArrow' {
                if ($cursor -le 0) {
                    $cursor = $lastIndex
                }
                else {
                    $cursor--
                }
            }
            'DownArrow' {
                if ($cursor -ge $lastIndex) {
                    $cursor = 0
                }
                else {
                    $cursor++
                }
            }
            'Spacebar' {
                if ($cursor -eq 0) {
                    $allSelected = ($selected.Count -gt 0 -and -not ($selected -contains $false))
                    for ($i = 0; $i -lt $selected.Count; $i++) {
                        $selected[$i] = -not $allSelected
                    }
                }
                elseif ($cursor -eq $lastIndex) {
                    return $null
                }
                else {
                    $idx = $cursor - 1
                    $selected[$idx] = -not $selected[$idx]
                }
            }
            'Enter' {
                if ($cursor -eq $lastIndex) {
                    return $null
                }

                return @(
                    for ($i = 0; $i -lt $Distros.Count; $i++) {
                        if ($selected[$i]) {
                            $Distros[$i]
                        }
                    }
                )
            }
            'Escape' {
                return $null
            }
        }
    }
}

function Set-WslSparse {
    param(
        [Parameter(Mandatory)]
        [object[]]$Distros,

        [Parameter(Mandatory)]
        [bool]$TargetSparse
    )

    $targetText = if ($TargetSparse) { 'Sparse' } else { 'Not sparse' }
    $targetArg = if ($TargetSparse) { 'true' } else { 'false' }

    Write-Host ''
    Write-Host ("Starting conversion to {0}..." -f $targetText) -ForegroundColor Cyan
    Write-Host ''
    Write-Rule
    Write-Host ("{0,-6} {1,-24} {2,-28} {3}" -f 'Result', 'Distribution', 'Message', 'State') -ForegroundColor Gray
    Write-Rule

    foreach ($distro in $Distros) {
        $state = Format-SparseState -Value $distro.IsSparse -VhdExists $distro.VhdExists

        if ($distro.IsSparse -eq $TargetSparse) {
            Write-Host ("{0,-6} {1,-24} {2,-28} " -f 'SKIP', $distro.Name, 'already in target state') -ForegroundColor Green -NoNewline
            Write-StatusText -State $state
            Write-Host ''
            continue
        }

        if (-not $distro.VhdExists) {
            Write-Host ("{0,-6} {1,-24} {2,-28} " -f 'SKIP', $distro.Name, 'ext4.vhdx not found') -ForegroundColor Red -NoNewline
            Write-StatusText -State $state
            Write-Host ''
            continue
        }

        Write-Host ("{0,-6} {1,-24} {2,-28} " -f 'SET', $distro.Name, 'converting') -ForegroundColor Cyan -NoNewline
        Write-StatusText -State $state
        Write-Host ''
        & wsl.exe --manage $distro.Name --set-sparse $targetArg --allow-unsafe

        if ($LASTEXITCODE -eq 0) {
            $newItem = Get-Item -LiteralPath $distro.VhdPath
            $newSparse = (($newItem.Attributes -band [IO.FileAttributes]::SparseFile) -ne 0)
            $newState = Format-SparseState -Value $newSparse -VhdExists $true
            Write-Host ("{0,-6} {1,-24} {2,-28} " -f 'DONE', $distro.Name, 'conversion completed') -ForegroundColor Green -NoNewline
            Write-StatusText -State $newState
            Write-Host ''
        }
        else {
            Write-Host ("{0,-6} {1,-24} {2,-28} " -f 'FAIL', $distro.Name, ("exit code {0}" -f $LASTEXITCODE)) -ForegroundColor Red -NoNewline
            Write-StatusText -State $state
            Write-Host ''
        }

        Write-Host ''
    }
}

function Confirm-Run {
    param(
        [Parameter(Mandatory)]
        [string]$ModeLabel
    )

    Write-Host ("Press S to run 'wsl --shutdown' first, then run '{0}'." -f $ModeLabel)
    Write-Host ("Press Enter to run '{0}' without shutdown, or Esc to cancel." -f $ModeLabel)

    while ($true) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq 'Escape') {
            return 'Cancel'
        }
        if ($key.Key -eq 'Enter') {
            return 'Run'
        }
        if ($key.Key -eq 'S') {
            return 'ShutdownAndRun'
        }
    }
}

try {
    $distros = Get-WslDistroInfo

    if ($distros.Count -eq 0) {
        Write-Host 'No WSL distributions were found.'
        exit 0
    }

    $targetSparse = Read-Mode

    if ($null -eq $targetSparse) {
        Write-Host 'Exited.'
        exit 0
    }

    $selection = Read-Selection -Distros $distros -TargetSparse $targetSparse

    if ($null -eq $selection) {
        Write-Host 'Exited.'
        exit 0
    }

    if ($selection.Count -eq 0) {
        Write-Host 'No distributions were selected.'
        exit 0
    }

    Write-Title
    $modeLabel = if ($targetSparse) { 'Enable sparse' } else { 'Disable sparse' }
    $targetArg = if ($targetSparse) { 'true' } else { 'false' }
    Write-Host ("Mode: {0}" -f $modeLabel)
    Write-Host ''
    Write-Host 'Selected distributions'
    Write-Rule
    Write-Host ("{0,-24} {1,-12} {2,-8}" -f 'Distribution', 'Sparse', 'VHDX') -ForegroundColor Gray
    Write-Rule
    foreach ($item in $selection) {
        $state = Format-SparseState -Value $item.IsSparse -VhdExists $item.VhdExists
        $vhd = if ($item.VhdExists) { 'Found' } else { 'Missing' }
        Write-Host ("{0,-24} " -f $item.Name) -NoNewline
        Write-StatusText -State $state -Width 12
        Write-Host (" {0,-8}" -f $vhd)
    }
    Write-Host ''
    Write-Host 'Command mode'
    Write-Rule
    Write-Host ("This uses: wsl.exe --manage <distro> --set-sparse {0} --allow-unsafe" -f $targetArg)
    Write-Host ''
    Write-Host 'Warning' -ForegroundColor Yellow
    Write-Rule
    Write-Host 'Microsoft marks this as unsafe on some WSL builds because sparse VHD support can risk data corruption.'
    Write-Host 'The selected VHDX files must not be in use. Use the shutdown option if conversion fails with WSL_E_DISTRO_NOT_STOPPED.'
    Write-Host 'Back up important WSL data before continuing.'
    Write-Host ''

    $runAction = Confirm-Run -ModeLabel $modeLabel

    if ($runAction -eq 'Cancel') {
        Write-Host 'Canceled.'
        exit 0
    }

    if ($runAction -eq 'ShutdownAndRun') {
        Write-Host ''
        Write-Host 'Stopping WSL...' -ForegroundColor Cyan
        & wsl.exe --shutdown
        if ($LASTEXITCODE -ne 0) {
            Write-Host ("FAIL  wsl --shutdown returned exit code {0}" -f $LASTEXITCODE) -ForegroundColor Red
            exit 1
        }
        Start-Sleep -Seconds 2
        Write-Host 'WSL stopped.' -ForegroundColor Green
    }

    Set-WslSparse -Distros $selection -TargetSparse $targetSparse
}
catch {
    Write-Host ''
    Write-Host 'ERROR'
    Write-Host $_.Exception.Message
    exit 1
}
finally {
    Write-Host ''
    Write-Host 'Press any key to close...'
    [void][Console]::ReadKey($true)
}
