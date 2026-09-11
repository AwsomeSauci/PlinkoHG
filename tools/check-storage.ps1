[CmdletBinding()]
param([Parameter(Mandatory)][string]$DefoldJar, [Parameter(Mandatory)][string]$JavaPath)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$jar = (Resolve-Path -LiteralPath $DefoldJar).Path
$java = (Resolve-Path -LiteralPath $JavaPath).Path
Push-Location $projectRoot
try {
    New-Item -ItemType Directory -Path (Join-Path $projectRoot '.internal') -Force | Out-Null
    & $java -cp $jar com.dynamo.bob.Bob --root $projectRoot --output build/qa-storage --platform x86_64-win32 --settings tests/storage_runtime/game.project --variant headless --archive --bundle-output bundles/qa-storage build bundle *> .internal/storage-build.log
    if ($LASTEXITCODE -ne 0) { throw 'Storage QA build failed: .internal/storage-build.log' }
    $bundle = Join-Path $projectRoot 'bundles/qa-storage/PlinkoStorageQA'
    # Each process gets disposable fixture paths. No player save directory is used.
    foreach ($lockedSlots in @(@('a', 'b'), @('a'), @('b'))) {
        $directory = Join-Path $projectRoot ('.internal/storage-qa-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $directory | Out-Null
        $start = New-Object System.Diagnostics.ProcessStartInfo
        $start.FileName = Join-Path $bundle 'PlinkoStorageQA.exe'
        $start.Arguments = '"--config=storage_qa.directory=' + $directory.Replace('\', '/') + '" "' + (Join-Path $bundle 'game.projectc') + '"'
        $start.WorkingDirectory = $projectRoot
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $start
        $handles = @()
        $started = $false
        try {
            if (-not $process.Start()) { throw 'Cannot start storage QA headless engine' }
            $started = $true
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            foreach ($flag in @('ready', 'loaded')) {
                $deadline = [DateTime]::UtcNow.AddSeconds(15)
                while (-not (Test-Path -LiteralPath (Join-Path $directory $flag))) {
                    if ($process.HasExited -or [DateTime]::UtcNow -ge $deadline) { throw "Storage QA did not reach $flag. Log: $directory/engine.log" }
                    Start-Sleep -Milliseconds 25
                }
                if ($flag -eq 'ready') {
                    foreach ($slot in $lockedSlots) {
                        $handles += [IO.File]::Open((Join-Path $directory "session-v3-$slot"), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
                    }
                    [IO.File]::WriteAllText((Join-Path $directory 'locked'), 'ready')
                } else {
                    foreach ($handle in $handles) { $handle.Dispose() }
                    $handles = @()
                    [IO.File]::WriteAllText((Join-Path $directory 'unlocked'), 'ready')
                }
            }
            if (-not $process.WaitForExit(15000)) { throw 'Storage QA timed out' }
            $log = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
            [IO.File]::WriteAllText((Join-Path $directory 'engine.log'), $log)
            if ($process.ExitCode -ne 0 -or $log -notmatch '\[Storage QA\] SUCCESS:') { throw "Storage QA failed: $directory/engine.log" }
            Write-Output "Storage QA passed with locked slots: $($lockedSlots -join ', ')"
        } finally {
            foreach ($handle in $handles) { $handle.Dispose() }
            if ($started) {
                if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
                [IO.File]::WriteAllText((Join-Path $directory 'engine.log'),
                    $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult())
            }
            $process.Dispose()
        }
    }
} finally {
    Pop-Location
}
