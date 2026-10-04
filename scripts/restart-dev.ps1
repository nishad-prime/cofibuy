param(
    [switch]$Quiet
)

# Restarts the Vite dev server on a fixed port.
#
# Stopping by port rather than by process name matters: `Get-Process` has no
# CommandLine property in Windows PowerShell 5.1, so a name filter silently
# matches nothing and the stale server keeps the port while the new one exits.

$ErrorActionPreference = 'Stop'
$Port = 5173
$Project = Split-Path -Parent $PSScriptRoot

$listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
foreach ($processId in ($listener | Select-Object -ExpandProperty OwningProcess -Unique)) {
    Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 2

# A stash or branch switch can leave Vite unable to resolve the `@` alias until
# its module graph is rebuilt, so drop the pre-bundle cache too.
Remove-Item (Join-Path $Project 'node_modules\.vite') -Recurse -Force -ErrorAction SilentlyContinue

Start-Process -WindowStyle Hidden -FilePath 'npx.cmd' `
    -ArgumentList 'vite', "--port", $Port, '--strictPort' `
    -WorkingDirectory $Project

for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:$Port" -UseBasicParsing -TimeoutSec 5
        if ($response.StatusCode -eq 200) {
            if (-not $Quiet) { Write-Output "dev server ready on http://localhost:$Port" }
            exit 0
        }
    } catch {
        # keep polling
    }
}

Write-Error "dev server did not come up on port $Port"
exit 1