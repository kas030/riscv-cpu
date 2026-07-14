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

function Merge-Cover {
    param(
        [Parameter(Mandatory)][string]$CoverPath,
        [Parameter(Mandatory)][string]$BodyPath,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$TempDir
    )

    if (-not (Test-Path -LiteralPath $CoverPath -PathType Leaf)) {
        throw "Cover file does not exist: $CoverPath"
    }

    $coverForTex = $CoverPath.Replace("\", "/")
    $bodyForTex = $BodyPath.Replace("\", "/")
    $mergeTex = Join-Path $TempDir "merge.tex"
    $mergeSource = @"
\documentclass[a4paper]{article}
\usepackage{pdfpages}
\pagestyle{empty}
\begin{document}
\includepdf[pages=-,fitpaper=true,pagecommand={\thispagestyle{empty}}]{\detokenize{$coverForTex}}
\includepdf[pages=-,fitpaper=true,pagecommand={\thispagestyle{empty}}]{\detokenize{$bodyForTex}}
\end{document}
"@
    Set-Content -LiteralPath $mergeTex -Value $mergeSource -Encoding UTF8

    Invoke-Checked -Command "xelatex" -Arguments @(
        "-interaction=nonstopmode",
        "-halt-on-error",
        "-output-directory=$TempDir",
        $mergeTex
    )

    Move-Item -LiteralPath (Join-Path $TempDir "merge.pdf") -Destination $OutputPath -Force
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
        $bodyPath = Join-Path $tempDir "$Name-body.pdf"
        $outputPath = Join-Path $BuildDir "$Name.pdf"

        Push-Location $DocsDir
        try {
            Invoke-Checked -Command "pandoc" -Arguments @(
                "$Name.md",
                "--defaults=$DefaultsFile",
                "--output=$bodyPath"
            )
        }
        finally {
            Pop-Location
        }

        $coverPath = Get-CoverPath -SourcePath $sourcePath
        if ($coverPath) {
            Merge-Cover -CoverPath $coverPath -BodyPath $bodyPath -OutputPath $outputPath -TempDir $tempDir
        }
        else {
            Move-Item -LiteralPath $bodyPath -Destination $outputPath -Force
        }

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
