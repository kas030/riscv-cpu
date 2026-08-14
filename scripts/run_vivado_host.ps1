[CmdletBinding()]
param(
    [ValidateSet(
        "check",
        "create",
        "build",
        "sim",
        "refresh-ips",
        "recreate-bram",
        "recreate-irom",
        "recreate-pll"
    )]
    [string] $Action = "build",

    [string] $Arg1 = "",
    [string] $Arg2 = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$VivadoArgs = @()
if ($Arg1) {
    $VivadoArgs += $Arg1
}
if ($Arg2) {
    $VivadoArgs += $Arg2
}

function Find-Vivado {
    if ($env:VIVADO_BIN) {
        $configured = $env:VIVADO_BIN
        if (Test-Path -LiteralPath $configured -PathType Container) {
            $configured = Join-Path $configured "vivado.bat"
        }
        if (Test-Path -LiteralPath $configured -PathType Leaf) {
            return (Resolve-Path -LiteralPath $configured).Path
        }
        throw "VIVADO_BIN does not point to an existing Vivado executable: $configured"
    }

    $preferred = @(
        "D:\AMDDesignTools\2025.2.1\Vivado\bin\vivado.bat",
        "C:\Xilinx\Vivado\2025.2.1\bin\vivado.bat"
    )
    foreach ($candidate in $preferred) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    $patterns = @(
        "D:\AMDDesignTools\*\Vivado\bin\vivado.bat",
        "C:\AMDDesignTools\*\Vivado\bin\vivado.bat",
        "D:\Xilinx\Vivado\*\bin\vivado.bat",
        "C:\Xilinx\Vivado\*\bin\vivado.bat"
    )
    $detected = Get-Item -Path $patterns -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending |
        Select-Object -First 1
    if ($detected) {
        return $detected.FullName
    }

    $fromPath = Get-Command vivado.bat -ErrorAction SilentlyContinue
    if ($fromPath) {
        return $fromPath.Source
    }
    throw "Vivado was not found. Set the Windows user environment variable VIVADO_BIN to vivado.bat or its bin directory."
}

$vivado = Find-Vivado
Write-Host "Repository: $repoRoot"
Write-Host "Vivado: $vivado"

if ($Action -eq "check") {
    & $vivado -version
    # Vivado 2025.2.1 prints a valid version banner but returns 1 for -version.
    # Reaching this point proves that the launcher was found and executable.
    exit 0
}

$scriptByAction = @{
    "create"        = "create_project.tcl"
    "build"         = "run_build.tcl"
    "sim"           = "run_sim.tcl"
    "refresh-ips"   = "refresh_ips.tcl"
    "recreate-bram" = "recreate_bram_ip.tcl"
    "recreate-irom" = "recreate_irom_ip.tcl"
    "recreate-pll"  = "recreate_pll_ip.tcl"
}
$tclScript = Join-Path $PSScriptRoot $scriptByAction[$Action]
if (-not (Test-Path -LiteralPath $tclScript -PathType Leaf)) {
    throw "Tcl script was not found: $tclScript"
}

$arguments = @("-mode", "batch", "-source", $tclScript, "-nojournal")
if ($VivadoArgs.Count -gt 0) {
    $arguments += "-tclargs"
    $arguments += $VivadoArgs
}

Set-Location -LiteralPath $repoRoot
Write-Host "Action: $Action $($VivadoArgs -join ' ')"
& $vivado @arguments
$exitCode = $LASTEXITCODE
if ($null -eq $exitCode) {
    $exitCode = 1
}
exit $exitCode
