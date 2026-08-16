[CmdletBinding()]
param(
    [ValidateRange(72, 600)]
    [int]$Dpi = 300
)

$ErrorActionPreference = "Stop"

$DiagramDir = [System.IO.Path]::GetFullPath($PSScriptRoot)
$DocsDir = [System.IO.Path]::GetFullPath((Join-Path $DiagramDir ".."))
$SocSourcePath = Join-Path $DiagramDir "cpu-soc-arch.tex"
$CoreSourcePath = Join-Path $DiagramDir "cpu-micro-arch.tex"
$BuildDir = Join-Path $DocsDir "build\cpu-architecture"
$SocBuildDir = Join-Path $BuildDir "soc"
$CoreBuildDir = Join-Path $BuildDir "micro"
$AssetsDir = Join-Path $DocsDir "assets"
$PdfPath = Join-Path $AssetsDir "cpu-architecture.pdf"
$SocPngPath = Join-Path $AssetsDir "cpu-soc-overview.png"
$CorePngPath = Join-Path $AssetsDir "cpu-core-microarchitecture.png"

function Resolve-RequiredCommand {
    param(
        [Parameter(Mandatory)]
        [string[]]$Names
    )

    foreach ($name in $Names) {
        $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) {
            return $command.Source
        }
    }

    throw "Required command was not found: $($Names -join ', ')."
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & $Command @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($exitCode -ne 0) {
        $diagnostics = ($output | Select-Object -Last 40 | Out-String).Trim()
        if ($diagnostics) {
            Write-Host $diagnostics
        }
        throw "Command '$Command' failed with exit code $exitCode."
    }
}

function Build-TikzPdf {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$OutputDirectory
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        throw "TikZ source does not exist: $SourcePath"
    }

    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    Invoke-Checked -Command $latexmk -Arguments @(
        "-xelatex",
        "-interaction=nonstopmode",
        "-halt-on-error",
        "-file-line-error",
        "-outdir=$OutputDirectory",
        $SourcePath
    )

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($SourcePath)
    $builtPdfPath = Join-Path $OutputDirectory "$baseName.pdf"
    if (-not (Test-Path -LiteralPath $builtPdfPath -PathType Leaf)) {
        throw "Expected PDF was not generated: $builtPdfPath"
    }

    return $builtPdfPath
}

$latexmk = Resolve-RequiredCommand -Names @("latexmk.exe", "latexmk")
$pdftoppm = Resolve-RequiredCommand -Names @("pdftoppm.exe", "pdftoppm")
$pdfunite = Resolve-RequiredCommand -Names @("pdfunite.exe", "pdfunite")

New-Item -ItemType Directory -Path $BuildDir -Force | Out-Null
New-Item -ItemType Directory -Path $AssetsDir -Force | Out-Null

$socPdfPath = Build-TikzPdf -SourcePath $SocSourcePath -OutputDirectory $SocBuildDir
$corePdfPath = Build-TikzPdf -SourcePath $CoreSourcePath -OutputDirectory $CoreBuildDir

$combinedPdfPath = Join-Path $BuildDir "cpu-architecture.pdf"
if (Test-Path -LiteralPath $combinedPdfPath -PathType Leaf) {
    Remove-Item -LiteralPath $combinedPdfPath -Force
}
Invoke-Checked -Command $pdfunite -Arguments @(
    $socPdfPath,
    $corePdfPath,
    $combinedPdfPath
)
Copy-Item -LiteralPath $combinedPdfPath -Destination $PdfPath -Force

$renderDir = Join-Path $BuildDir "render"
New-Item -ItemType Directory -Path $renderDir -Force | Out-Null
$socPrefix = Join-Path $renderDir "cpu-soc-overview"
$corePrefix = Join-Path $renderDir "cpu-core-microarchitecture"

Invoke-Checked -Command $pdftoppm -Arguments @(
    "-f", "1",
    "-singlefile",
    "-png",
    "-r", "$Dpi",
    $socPdfPath,
    $socPrefix
)

Invoke-Checked -Command $pdftoppm -Arguments @(
    "-f", "1",
    "-singlefile",
    "-png",
    "-r", "$Dpi",
    $corePdfPath,
    $corePrefix
)

$renderedSocPath = "$socPrefix.png"
$renderedCorePath = "$corePrefix.png"
foreach ($renderedPath in @($renderedSocPath, $renderedCorePath)) {
    if (-not (Test-Path -LiteralPath $renderedPath -PathType Leaf)) {
        throw "Expected PNG was not generated: $renderedPath"
    }
}

Move-Item -LiteralPath $renderedSocPath -Destination $SocPngPath -Force
Move-Item -LiteralPath $renderedCorePath -Destination $CorePngPath -Force

Write-Host "Generated: $PdfPath"
Write-Host "Generated: $SocPngPath"
Write-Host "Generated: $CorePngPath"
