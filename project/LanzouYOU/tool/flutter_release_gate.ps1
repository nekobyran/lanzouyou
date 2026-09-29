param(
  [string]$FileListPath = '',
  [string[]]$Files,
  [int]$MaxAttempts = 2,
  [string]$OutPrefix = 'gate'
)
$ErrorActionPreference = 'Stop'
if ($FileListPath -and (Test-Path $FileListPath)) {
  $Files = Get-Content $FileListPath | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') }
}
if (-not $Files -or $Files.Count -eq 0) {
  $Files = Get-ChildItem -Path test -Filter '*_test.dart' | Sort-Object Name | ForEach-Object { (Resolve-Path -Relative $_.FullName).Replace('\\','/') }
}
$total = 0
$pass = 0
$failures = @()
$rows = @()
foreach ($rel in $Files) {
  $ok = $false
  $last = $null
  for ($attempt = 1; $attempt -le $MaxAttempts -and -not $ok; $attempt++) {
    $safe = (($rel -replace '[\\/:.]','_') -replace '__+','_')
    $jsonPath = ".tmp_${OutPrefix}_${safe}_attempt$attempt.jsonl"
    if (Test-Path $jsonPath) { Remove-Item $jsonPath -Force }
    & flutter test -r json $rel *> $jsonPath
    $exit = $LASTEXITCODE
    $tests = @{}
    $errors = @()
    $errorEvents = @()
    $done = $null
    Get-Content $jsonPath | ForEach-Object {
      if (-not $_) { return }
      try { $o = $_ | ConvertFrom-Json } catch { return }
      if ($o.type -eq 'testStart') { $tests[[int]$o.test.id] = $o.test }
      elseif ($o.type -eq 'error') { $errorEvents += $o }
      elseif ($o.type -eq 'testDone' -and $o.result -eq 'error') {
        $tid = [int]$o.testID
        $t = $tests[$tid]
        $errors += [pscustomobject]@{ id=$tid; name=$t.name; root=$t.root_url; line=$t.root_line }
      } elseif ($o.type -eq 'done') { $done = $o }
    }
    $success = ($exit -eq 0 -and $done -ne $null -and $done.success -eq $true -and $errors.Count -eq 0 -and $errorEvents.Count -eq 0)
    $last = [pscustomobject]@{ file=$rel; attempt=$attempt; exit=$exit; success=($done -ne $null -and $done.success -eq $true); count=$tests.Count; errors=$errors.Count; errorEvents=$errorEvents.Count; json=$jsonPath; errorList=$errors }
    Write-Output ("FILE {0} attempt={1} exit={2} success={3} count={4} errors={5} errorEvents={6}" -f $rel,$attempt,$exit,$last.success,$last.count,$last.errors,$last.errorEvents)
    if ($success) { $ok = $true }
    elseif ($errorEvents.Count -gt 0) { break }
  }
  $total++
  if ($ok) { $pass++ } else { $failures += $last }
  $rows += [pscustomobject]@{ file=$rel; pass=$ok; attempts=($last.attempt); exit=($last.exit); success=($last.success); count=($last.count); errors=($last.errors); errorEvents=($last.errorEvents); json=($last.json) }
}
$summary = [pscustomobject]@{ prefix=$OutPrefix; total=$total; pass=$pass; fail=$failures.Count; failures=($failures | Select-Object file,attempt,exit,success,count,errors,errorEvents,json) }
$summary | ConvertTo-Json -Depth 5 | Set-Content ".tmp_${OutPrefix}_summary.json" -Encoding UTF8
$rows | ConvertTo-Json -Depth 4 | Set-Content ".tmp_${OutPrefix}_rows.json" -Encoding UTF8
Write-Output ("FLUTTER_RELEASE_GATE prefix={0} total={1} pass={2} fail={3}" -f $OutPrefix,$total,$pass,$failures.Count)
foreach ($f in $failures) { Write-Output ("FLUTTER_RELEASE_GATE_FAIL file={0} attempt={1} exit={2} errors={3} errorEvents={4} json={5}" -f $f.file,$f.attempt,$f.exit,$f.errors,$f.errorEvents,$f.json) }
exit $(if ($failures.Count -eq 0) { 0 } else { 1 })
