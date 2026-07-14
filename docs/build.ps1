[CmdletBinding()]
param(
    [ValidateSet("all", "design", "test", "clean")]
    [string]$Target = "all"
)

$ErrorActionPreference = "Stop"
$DocsDir = [System.IO.Path]::GetFullPath($PSScriptRoot)
$BuildDir = [System.IO.Path]::GetFullPath((Join-Path $DocsDir "build"))
$DefaultsFile = Join-Path $DocsDir "pandoc\report.yaml"

function Assert-Command {
    param([Parameter(Mandatory)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found. Install it and add it to PATH."
    }
}

function Get-CoverPath {
    param([Parameter(Mandatory)][string]$SourcePath)

    $inFrontMatter = $false
    foreach ($line in Get-Content -LiteralPath $SourcePath -Encoding UTF8) {
        if ($line -eq "---") {
            if (-not $inFrontMatter) {
                $inFrontMatter = $true
                continue
            }
            break
        }

        if ($inFrontMatter -and $line -match '^cover:\s*(.+?)\s*$') {
            $coverValue = $Matches[1].Trim().Trim('"').Trim("'")
            return [System.IO.Path]::GetFullPath((Join-Path $DocsDir $coverValue))
        }
    }

    return $null
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command '$Command' failed with exit code $LASTEXITCODE."
    }
}

function Build-Report {
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$AllowMissing
    )

    $sourcePath = Join-Path $DocsDir "$Name.md"
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        if ($AllowMissing) {
            Write-Warning "$Name.md was not found; skipping it."
            return
        }
        throw "Report source file does not exist: $sourcePath"
    }

    New-Item -ItemType Directory -Path $BuildDir -Force | Out-Null
    $tempDir = Join-Path $BuildDir ".tmp-$Name"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    try {
        $temporaryOutputPath = Join-Path $tempDir "$Name.pdf"
        $outputPath = Join-Path $BuildDir "$Name.pdf"
        $coverPath = Get-CoverPath -SourcePath $sourcePath

        if ($coverPath -and -not (Test-Path -LiteralPath $coverPath -PathType Leaf)) {
            throw "Cover file does not exist: $coverPath"
        }

        Push-Location $DocsDir
        try {
            Invoke-Checked -Command "pandoc" -Arguments @(
                "$Name.md",
                "--defaults=$DefaultsFile",
                "--output=$temporaryOutputPath"
            )
        }
        finally {
            Pop-Location
        }

        Move-Item -LiteralPath $temporaryOutputPath -Destination $outputPath -Force

        Write-Host "Generated: $outputPath"
    }
    finally {
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force
        }
    }
}

function Clear-BuildDirectory {
    $expectedPrefix = $DocsDir.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $BuildDir.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean a path outside the docs directory: $BuildDir"
    }

    if (Test-Path -LiteralPath $BuildDir) {
        Remove-Item -LiteralPath $BuildDir -Recurse -Force
        Write-Host "Cleaned: $BuildDir"
    }
}

if ($Target -eq "clean") {
    Clear-BuildDirectory
    exit 0
}

Assert-Command -Name "pandoc"
Assert-Command -Name "xelatex"

switch ($Target) {
    "design" { Build-Report -Name "design-report" }
    "test" { Build-Report -Name "test-report" }
    "all" {
        Build-Report -Name "design-report"
        Build-Report -Name "test-report" -AllowMissing
    }
}
