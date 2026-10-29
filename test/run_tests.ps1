# Run the tests in the given files, or all of them
#
#   .\test\run_tests.ps1                      # all tests
#   .\test\run_tests.ps1 render_tests.vim     # one file
#
# $env:VIMPRG selects the Vim to test.

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

# Use $env:VIMPRG or find it in PATH
$vim = $env:VIMPRG
if (-not $vim) { $vim = (Get-Command vim -ErrorAction SilentlyContinue).Source }
if (-not $vim -or -not (Test-Path $vim)) {
  Write-Output "ERROR: vim ($vim) not found."
  exit 1
}

# Keep the tests away from the user's Windows Terminal and its settings
$testHome = Join-Path ([IO.Path]::GetTempPath()) "wt-scrollback-tests-$PID"
New-Item -ItemType Directory $testHome | Out-Null
$env:LOCALAPPDATA = $testHome
Remove-Item Env:WT_SESSION -ErrorAction SilentlyContinue

$allTests = @(
  'settings_tests.vim'
  'setup_tests.vim'
  'font_tests.vim'
  'render_tests.vim'
  'pager_tests.vim'
  'helper_tests.vim'
)
$testsToRun = if ($args.Count) { $args } else { $allTests }

# Align the results of all the files after the longest test name
$width = (Select-String -Path $testsToRun -Pattern 'def g:(Test_\w*)' |
  ForEach-Object { $_.Matches[0].Groups[1].Value.Length } | Measure-Object -Maximum).Maximum

$failed = $false
try {
  foreach ($testfile in $testsToRun) {
    Write-Output "===> Running: $testfile"
    Remove-Item results.txt -ErrorAction SilentlyContinue
    $vimArgs = '-u', 'NONE', '-U', 'NONE', '-i', 'NONE', '--noplugin', '-N',
      '-c', "`"let g:TestName='$testfile'`"", '-c', "`"let g:TestNameWidth=$width`"", '-S', 'runner.vim'
    $proc = Start-Process $vim -ArgumentList $vimArgs -WindowStyle Hidden -PassThru
    if (-not $proc.WaitForExit(120000)) { $proc.Kill() }

    if (-not (Test-Path results.txt)) {
      Write-Host '[FAIL]' -ForegroundColor Red -NoNewline
      Write-Host " Test results file 'results.txt' not found."
      $failed = $true
      continue
    }
    # [PASS] in green and [FAIL] in red
    foreach ($line in Get-Content results.txt -Encoding UTF8) {
      if ($line -match '^(.*)\[(PASS|FAIL)\](.*)$') {
        Write-Host $Matches[1] -NoNewline
        Write-Host "[$($Matches[2])]" -ForegroundColor $(if ($Matches[2] -eq 'PASS') { 'Green' } else { 'Red' }) -NoNewline
        Write-Host $Matches[3]
      } else {
        Write-Host $line
      }
    }
    if (Select-String -Path results.txt -Pattern '\[FAIL\]' -Quiet) { $failed = $true }
    Remove-Item results.txt
  }
} finally {
  Remove-Item -Recurse -Force $testHome -ErrorAction SilentlyContinue
}

if ($failed) {
  Write-Host 'RESULT: Some tests FAILED.' -ForegroundColor Red
  exit 1
}
Write-Host 'RESULT: All tests passed.' -ForegroundColor Green
