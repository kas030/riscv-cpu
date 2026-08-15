[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script from an elevated Windows PowerShell session."
}

$sshd = Get-Service -Name sshd -ErrorAction SilentlyContinue
if (-not $sshd) {
    $capability = Get-WindowsCapability -Online -Name "OpenSSH.Server*" |
        Select-Object -First 1
    if (-not $capability) {
        throw "The OpenSSH Server Windows capability is unavailable on this system."
    }
    if ($capability.State -ne "Installed") {
        Write-Host "Installing $($capability.Name)..."
        $installResult = Add-WindowsCapability -Online -Name $capability.Name
        $installResult | Out-Host
        if ($installResult.RestartNeeded) {
            throw "OpenSSH Server installation requires a Windows restart. Restart and run this script again."
        }
    }
}

$sshd = Get-Service -Name sshd -ErrorAction SilentlyContinue
if (-not $sshd) {
    $sshdExecutable = "$env:WINDIR\System32\OpenSSH\sshd.exe"
    if (-not (Test-Path -LiteralPath $sshdExecutable -PathType Leaf)) {
        throw "OpenSSH Server files are missing after installation."
    }
    & $sshdExecutable -t
    if ($LASTEXITCODE -ne 0) {
        throw "OpenSSH Server configuration validation failed."
    }
    New-Service `
        -Name sshd `
        -BinaryPathName ('"' + $sshdExecutable + '"') `
        -DisplayName "OpenSSH SSH Server" `
        -Description "Secure Shell Server" `
        -StartupType Automatic | Out-Null
}

Set-Service -Name sshd -StartupType Automatic
Start-Service -Name sshd

$rule = Get-NetFirewallRule -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -eq "OpenSSH-Server-In-TCP" -or
        $_.DisplayName -like "*OpenSSH*Server*"
    }
if (-not $rule) {
    $rule = New-NetFirewallRule `
        -Name "OpenSSH-Server-In-TCP" `
        -DisplayName "OpenSSH SSH Server (local subnet only)" `
        -Enabled True `
        -Direction Inbound `
        -Protocol TCP `
        -Action Allow `
        -LocalPort 22 `
        -RemoteAddress LocalSubnet `
        -Profile Any
} else {
    Enable-NetFirewallRule -InputObject $rule
    Set-NetFirewallRule -InputObject $rule -Profile Any
    $rule | Get-NetFirewallAddressFilter |
        Set-NetFirewallAddressFilter -RemoteAddress LocalSubnet
}

$sshd = Get-Service -Name sshd
Write-Host "OpenSSH Server: $($sshd.Status), startup type: $($sshd.StartType)"
Write-Host "TCP 22 is allowed only from a directly connected local subnet."
Write-Host "Use 'ipconfig' to find the Windows address reachable from the Ubuntu VM."
