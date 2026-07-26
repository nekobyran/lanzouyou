# Compatibility name for people who already used the project-specific entry.
# The maintained command implementation is Invoke-FlutterClient.ps1.
& (Join-Path $PSScriptRoot 'Invoke-FlutterClient.ps1') @args
exit $LASTEXITCODE
