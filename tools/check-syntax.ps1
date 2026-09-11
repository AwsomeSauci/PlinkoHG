param([string]$Lua = 'luajit')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
Push-Location $projectRoot
try {
    $sourceFiles = @(rg --files scripts config main tests tools -g '*.lua' -g '*.script' -g '*.gui_script' -g '*.render_script')
    if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate Lua sources with rg.' }
    & $Lua tools/check_syntax.lua @sourceFiles
    if ($LASTEXITCODE -ne 0) { throw 'Lua syntax compilation failed.' }
} finally {
    Pop-Location
}
