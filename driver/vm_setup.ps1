# vm_setup.ps1 - run INSIDE THE TEST VM, as Administrator. It refuses to run anywhere else.
#
#   .\vm_setup.ps1 enable    turn on test signing in the VM, then reboot the VM
#   .\vm_setup.ps1 install   sign the driver with a throwaway test certificate and start it
#   .\vm_setup.ps1 remove    stop and delete the driver
#
# Copy mmonet.sys, drvtest.exe and this script to one folder in the VM.
param([Parameter(Mandatory)][ValidateSet('enable', 'install', 'remove')][string]$Action)
$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an Administrator PowerShell inside the VM.'
}

# Guard against running on a real PC: this changes boot security settings.
$system = Get-CimInstance Win32_ComputerSystem
if ($system.Model -notmatch 'Virtual|VMware|VirtualBox|KVM|QEMU') {
    throw "Refusing to run: this doesn't look like a VM (model: '$($system.Model)')."
}

$service = 'mmonet'
$sys = Join-Path $PSScriptRoot 'mmonet.sys'

switch ($Action) {
    'enable' {
        bcdedit /set testsigning on
        if ($LASTEXITCODE) { throw 'bcdedit failed. If Secure Boot is on, turn it off in the VM settings.' }
        Write-Host 'Test signing is on. Reboot the VM, then run: .\vm_setup.ps1 install'
    }
    'install' {
        $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object Subject -eq 'CN=MmoNet Test' | Select-Object -First 1
        if (-not $cert) {
            $cert = New-SelfSignedCertificate -Subject 'CN=MmoNet Test' -Type CodeSigningCert `
                -CertStoreLocation Cert:\LocalMachine\My -HashAlgorithm SHA256
            foreach ($storeName in 'Root', 'TrustedPublisher') {
                $store = [Security.Cryptography.X509Certificates.X509Store]::new($storeName, 'LocalMachine')
                $store.Open('ReadWrite')
                $store.Add($cert)
                $store.Close()
            }
        }
        $signature = Set-AuthenticodeSignature -FilePath $sys -Certificate $cert -HashAlgorithm SHA256
        Write-Host "Signature status: $($signature.Status)"

        $target = Join-Path $env:SystemRoot 'System32\drivers\mmonet.sys'
        Copy-Item $sys $target -Force
        if (-not (Get-Service $service -ErrorAction SilentlyContinue)) {
            sc.exe create $service type= kernel start= demand binPath= "System32\drivers\mmonet.sys" | Out-Host
        }
        sc.exe start $service | Out-Host
        Write-Host 'Now run: .\drvtest.exe'
    }
    'remove' {
        sc.exe stop $service | Out-Host
        sc.exe delete $service | Out-Host
        Remove-Item (Join-Path $env:SystemRoot 'System32\drivers\mmonet.sys') -ErrorAction SilentlyContinue
        Write-Host 'Driver removed. A clean stop and removal also proves that unload works.'
    }
}
