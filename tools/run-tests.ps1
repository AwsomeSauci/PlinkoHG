[CmdletBinding()]
param(
    [string]$Lua = 'luajit',
    [string]$DefoldJar,
    [string]$JavaPath,
    [switch]$Profile,
    [ValidateRange(5, 300)]
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if ($Profile -and -not $DefoldJar) { throw '-Profile requires -DefoldJar for the real headless engine.' }

function Invoke-BackgroundProcess {
    param([string]$Executable, [string[]]$Arguments, [string]$LogName, [int]$Timeout)
    $stdoutPath = Join-Path $projectRoot ".internal/$LogName.stdout.log"
    $stderrPath = Join-Path $projectRoot ".internal/$LogName.stderr.log"
    # These arguments go directly to CreateProcess, never through a shell.
    $quotedArguments = @($Arguments | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' })
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Executable
    $startInfo.Arguments = $quotedArguments -join ' '
    $startInfo.WorkingDirectory = $projectRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw "Unable to start $LogName." }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $timedOut = -not $process.WaitForExit($Timeout * 1000)
        if ($timedOut) { $process.Kill() }
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        [System.IO.File]::WriteAllText($stdoutPath, $stdout)
        [System.IO.File]::WriteAllText($stderrPath, $stderr)
        if ($timedOut) { throw "$LogName exceeded $Timeout seconds. Logs: $stdoutPath and $stderrPath" }
        $log = $stdout + $stderr
        if ($process.ExitCode -ne 0) {
            Write-Host $log
            throw "$LogName failed with exit code $($process.ExitCode)."
        }
        return $log
    } finally {
        $process.Dispose()
    }
}

Push-Location $projectRoot
try {
    foreach ($suite in @('tests/domain_spec.lua', 'tests/rewards_spec.lua', 'tests/application_spec.lua', 'tests/flight_spec.lua', 'tests/mvp_spec.lua', 'tests/storage_spec.lua', 'tests/async_persistence_spec.lua', 'tests/renderer_spec.lua')) {
        & $Lua $suite
        if ($LASTEXITCODE -ne 0) { throw "$suite failed with exit code $LASTEXITCODE." }
    }
    if (-not $DefoldJar) { return }

    $jarPath = (Resolve-Path -LiteralPath $DefoldJar).Path
    if (-not $JavaPath) {
        $runtimeDirectory = Get-ChildItem -LiteralPath (Split-Path -Parent $jarPath) -Directory |
            Where-Object { $_.Name -like 'jdk-*' } | Sort-Object Name -Descending | Select-Object -First 1
        if ($runtimeDirectory) {
            $JavaPath = Join-Path $runtimeDirectory.FullName 'bin/java.exe'
        } else {
            $JavaPath = (Get-Command java -ErrorAction Stop).Source
        }
    }
    $javaExecutable = (Resolve-Path -LiteralPath $JavaPath).Path
    New-Item -ItemType Directory -Path (Join-Path $projectRoot '.internal') -Force | Out-Null
    Write-Host 'Building isolated GUI integration suite with the headless engine...'
    $buildArguments = @('-cp', $jarPath, 'com.dynamo.bob.Bob', '--root', $projectRoot,
        '--output', 'build/qa-headless', '--platform', 'x86_64-win32',
        '--settings', 'tests/runtime/game.project', '--variant', 'headless', '--archive',
        '--bundle-output', 'bundles/qa-headless', 'build', 'bundle')
    $null = Invoke-BackgroundProcess $javaExecutable $buildArguments 'qa-build' 300

    # Bob's headless variant has no desktop window, input capture or audio device.
    # This bootstrap has no SaveStore dependency and never reads player progress.
    $bundlePath = Join-Path $projectRoot 'bundles/qa-headless/PlinkoHG-Integration'
    $enginePath = Join-Path $bundlePath 'PlinkoHGIntegration.exe'
    $log = Invoke-BackgroundProcess $enginePath @((Join-Path $bundlePath 'game.projectc')) 'qa-engine' $TimeoutSeconds
    Write-Host $log
    if ($log -match '(?m)^ERROR:' -or $log -notmatch '\[Plinko QA\] SUCCESS: real engine integration checks passed') {
        throw 'Engine integration suite did not finish successfully. See .internal/qa-engine.*.log.'
    }
    if ($Profile) {
        $profileDirectory = Join-Path $projectRoot ('.internal/profile-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $profileDirectory | Out-Null
        $profileArguments = @('--config=qa.profile=1', ('--config=qa.directory=' + $profileDirectory.Replace('\', '/')),
            (Join-Path $bundlePath 'game.projectc'))
        $profileLog = Invoke-BackgroundProcess $enginePath $profileArguments 'qa-profile' 60
        Write-Host $profileLog
        if ($profileLog -match '(?m)^ERROR:' -or $profileLog -notmatch '\[Plinko PROFILE\] SUCCESS:') {
            throw 'Runtime profile failed. See .internal/qa-profile.*.log.'
        }
    }
    & (Join-Path $PSScriptRoot 'check-storage.ps1') -DefoldJar $jarPath -JavaPath $javaExecutable
} finally {
    Pop-Location
}
