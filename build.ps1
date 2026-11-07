# build.ps1 - assemble and link the server, and compile the benchmark tools.
#   powershell -ExecutionPolicy Bypass -File build.ps1
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$out  = Join-Path $root 'build'
New-Item -ItemType Directory -Force $out | Out-Null

$vs  = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -property installationPath
$vc  = Get-ChildItem "$vs\VC\Tools\MSVC" | Sort-Object Name | Select-Object -Last 1
$bin = "$($vc.FullName)\bin\Hostx64\x64"
$sdk = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\Lib" |
       Where-Object { Test-Path "$($_.FullName)\um\x64\kernel32.lib" } |
       Sort-Object Name | Select-Object -Last 1

$objs = @()
foreach ($name in 'util', 'sim', 'tier', 'net', 'main') {
    $obj = "$out\$name.obj"
    & "$bin\ml64.exe" /nologo /c /W3 /Zi /I "$root\src" /Fo $obj "$root\src\$name.asm"
    if ($LASTEXITCODE) { throw "assembling $name.asm failed" }
    $objs += $obj
}

# No C runtime: /NODEFAULTLIB plus a custom entry point. Only Windows DLLs are linked.
# /INCREMENTAL:NO matters: incremental linking sends every call and code address through a
# jump table, which costs an extra jmp on hot paths and would break self-patching.
& "$bin\link.exe" /nologo /DEBUG /INCREMENTAL:NO /ENTRY:start /SUBSYSTEM:CONSOLE /NODEFAULTLIB `
    /OUT:"$out\mmoserver.exe" /LIBPATH:"$($sdk.FullName)\um\x64" `
    @objs kernel32.lib ws2_32.lib synchronization.lib
if ($LASTEXITCODE) { throw 'linking failed' }

# Trace build: same code plus per-tick timing, written to trace.bin. See bench/diagnose.py.
$traceDir = "$out\trace"
New-Item -ItemType Directory -Force $traceDir | Out-Null
$traceObjs = @("$out\util.obj", "$out\sim.obj", "$out\tier.obj")
foreach ($name in 'net', 'main') {
    $obj = "$traceDir\$name.obj"
    & "$bin\ml64.exe" /nologo /c /W3 /DTRACE /I "$root\src" /Fo $obj "$root\src\$name.asm"
    if ($LASTEXITCODE) { throw "assembling trace $name.asm failed" }
    $traceObjs += $obj
}
& "$bin\link.exe" /nologo /ENTRY:start /SUBSYSTEM:CONSOLE /NODEFAULTLIB `
    /OUT:"$out\mmoserver_trace.exe" /LIBPATH:"$($sdk.FullName)\um\x64" `
    @traceObjs kernel32.lib ws2_32.lib synchronization.lib
if ($LASTEXITCODE) { throw 'linking trace build failed' }

# Kernel driver and its test tool. Building is safe; only ever load it inside a VM.
$drv = "$out\driver"
New-Item -ItemType Directory -Force $drv | Out-Null
& "$bin\lib.exe" /nologo /machine:x64 /def:"$root\driver\ntoskrnl.def" /out:"$drv\ntoskrnl.lib"
if ($LASTEXITCODE) { throw 'creating ntoskrnl import library failed' }
& "$bin\ml64.exe" /nologo /c /W3 /Fo "$drv\mmonet.obj" "$root\driver\mmonet.asm"
if ($LASTEXITCODE) { throw 'assembling driver failed' }
& "$bin\link.exe" /nologo /DRIVER /SUBSYSTEM:NATIVE /ENTRY:DriverEntry /NODEFAULTLIB /RELEASE `
    /OUT:"$drv\mmonet.sys" "$drv\mmonet.obj" "$drv\ntoskrnl.lib"
if ($LASTEXITCODE) { throw 'linking driver failed' }
& "$bin\ml64.exe" /nologo /c /W3 /Fo "$drv\drvtest.obj" "$root\driver\drvtest.asm"
if ($LASTEXITCODE) { throw 'assembling drvtest failed' }
& "$bin\link.exe" /nologo /ENTRY:start /SUBSYSTEM:CONSOLE /NODEFAULTLIB `
    /OUT:"$drv\drvtest.exe" /LIBPATH:"$($sdk.FullName)\um\x64" "$drv\drvtest.obj" kernel32.lib
if ($LASTEXITCODE) { throw 'linking drvtest failed' }
Copy-Item "$root\driver\vm_setup.ps1" "$drv\vm_setup.ps1" -Force
if (Test-Path "$root\tests\test_driver.c") {
    & clang -O1 -o "$out\test_driver.exe" "$root\tests\test_driver.c" "$drv\mmonet.obj"
    if ($LASTEXITCODE) { throw 'test_driver failed to build' }
    & clang -O1 -DTEST_IMAGE -o "$out\test_driver_image.exe" "$root\tests\test_driver.c"
    if ($LASTEXITCODE) { throw 'test_driver_image failed to build' }
    # Compiling this is the test: it checks the driver's offsets against the driver headers.
    $ddk = Join-Path (Split-Path (Split-Path (Get-Command clang).Source)) 'include\ddk'
    & clang -fsyntax-only -I $ddk "$root\tests\check_offsets.c"
    if ($LASTEXITCODE) { throw 'check_offsets failed: see the compiler errors above' }
}

# Tests link the real kernels from sim.obj and check them against brute force.
if (Test-Path "$root\tests\test_sim.c") {
    & clang -O2 -o "$out\test_sim.exe" "$root\tests\test_sim.c" "$out\sim.obj"
    if ($LASTEXITCODE) { throw 'test_sim failed to build' }
}

# Benchmark tools only: these are C and are not part of the server.
if (Test-Path "$root\bench\baseline.c") {
    & clang -O3 -march=native -o "$out\baseline_c.exe" "$root\bench\baseline.c"
    if ($LASTEXITCODE) { throw 'baseline failed' }
    & clang -O3 -march=native -DUSE_INTRINSICS -o "$out\baseline_intrin.exe" "$root\bench\baseline.c"
    if ($LASTEXITCODE) { throw 'baseline (intrinsics) failed' }
}
if (Test-Path "$root\tools\loadgen.c") {
    & clang -O2 -o "$out\loadgen.exe" "$root\tools\loadgen.c" -lws2_32
    if ($LASTEXITCODE) { throw 'loadgen failed' }
}
Write-Host "build ok: $out\mmoserver.exe ($((Get-Item "$out\mmoserver.exe").Length) bytes)"
