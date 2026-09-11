$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$rules = @{
    domain = @('domain')
    contracts = @('contracts')
    application = @('application', 'domain', 'contracts')
    presentation = @('contracts')
    simulation = @('simulation', 'domain')
    infrastructure = @('infrastructure', 'domain', 'contracts')
    ui = @('ui', 'simulation')
    bootstrap = @('bootstrap', 'application', 'contracts', 'domain', 'infrastructure', 'presentation', 'simulation', 'ui')
}
$violations = @()
$count = 0
$files = @(rg --files (Join-Path $projectRoot 'scripts') -g '*.lua')
if ($LASTEXITCODE -ne 0) { throw 'Cannot enumerate source files.' }
foreach ($file in $files) {
    $relative = $file.Substring($projectRoot.Length + 1).Replace('\', '/')
    $layer = $relative.Split('/')[1]
    $source = [System.IO.File]::ReadAllText($file)
    foreach ($match in [regex]::Matches($source, 'require\s*\(?\s*["'']([^"'']+)["'']')) {
        $dependency = $match.Groups[1].Value
        $count++
        if ($layer -eq 'bootstrap' -and $dependency.StartsWith('config.')) { continue }
        # Presentation formatters may copy domain value data, never execute rewards.
        if ($layer -eq 'ui' -and $dependency -eq 'scripts.domain.rewards.data') { continue }
        if ($layer -eq 'simulation' -and $dependency.StartsWith('scripts.domain.') -and $dependency -ne 'scripts.domain.random') {
            $violations += "$relative must not depend on $dependency"
            continue
        }
        if (-not $dependency.StartsWith('scripts.') -or $rules[$layer] -notcontains $dependency.Split('.')[1]) {
            $violations += "$relative must not depend on $dependency"
        }
    }
    if ($layer -in @('domain', 'contracts', 'application', 'presentation', 'simulation') -and
        $source -match '\b(gui|sys|msg|window|sound|resource|buffer|vmath|go|http|os)\.') {
        $violations += "$relative uses an engine/system API outside an adapter"
    }
}
if ($violations.Count) { throw ($violations -join [Environment]::NewLine) }
Write-Output "Layer dependencies OK: $($files.Count) modules, $count imports. Pure layers have no engine/system API calls."
