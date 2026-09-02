# Word and Excel half of the Windows rich-text interop matrix (§8 of
# docs/rich-text-paste-stack-2026-09.md).
#
# Drives real Office over COM, so a pass is a statement about Word and Excel,
# not about a parser we wrote. Pair it with tool/rich_interop_win.dart, which
# drives the real shipping clipboard code.
#
#   powershell -ExecutionPolicy Bypass -File tool/rich_interop_win.ps1 -Mode paste
#   powershell -ExecutionPolicy Bypass -File tool/rich_interop_win.ps1 -Mode word
#   powershell -ExecutionPolicy Bypass -File tool/rich_interop_win.ps1 -Mode excel
#
# paste  our own payload -> Word, each flavor pasted explicitly
# word   Word copies styled text -> Relic captures -> Word pastes it back
# excel  same shape through Excel, which is the case that finds the §8b bug
#
# Every mode does its copy and its paste in ONE process. The clipboard is shared
# machine state, so a run split across two shells can be invalidated by anything
# else that copies in between.
#
# -Replay picks which write path the round-trip modes use:
#   fragment  what ships today: keep the fragment, re-wrap it        (§8b: fails Excel)
#   clean     the candidate fix: whole document, file:/// stripped   (§8b: passes)

param(
  [ValidateSet("paste", "word", "excel")] [string]$Mode = "paste",
  [ValidateSet("fragment", "clean")] [string]$Replay = "fragment"
)

$ErrorActionPreference = "Stop"
$script:failed = 0
function Pass($m) { Write-Host "  PASS  $m" }
function Fail($m) { Write-Host "  FAIL  $m"; $script:failed++ }

$dartMode = if ($Replay -eq "clean") { "replayclean" } else { "roundtrip" }
$wdPasteRTF = 1
$wdPasteHTML = 10

function Invoke-Dart($verb) {
  # No 2>&1 here. PowerShell 5.1 turns a native command's stderr into a
  # NativeCommandError under redirection, and $ErrorActionPreference = "Stop"
  # then aborts a run that succeeded. dart writes "Running build hooks..." to
  # stderr on every invocation, so this bites every time. Let stderr through.
  & dart run tool/rich_interop_win.dart $verb
}

# Paste the current clipboard into a fresh Word doc once per flavor and report
# whether the bold run and the font survived that specific flavor.
function Test-WordPaste($word) {
  foreach ($c in @(@{ N = "RTF"; T = $wdPasteRTF }, @{ N = "HTML"; T = $wdPasteHTML })) {
    $d = $word.Documents.Add()
    try {
      $d.Content.PasteSpecial([ref]$null, [ref]$false, [ref]$null, [ref]$false, [ref]$c.T)
      $text = $d.Content.Text.Trim()
      $r = $d.Range(); $null = $r.Find.Execute("bold")
      $bold = ($r.Find.Found -and $r.Bold -eq -1)
      $font = $d.Range().Font.Name
      if ($text -like "*plain*bold*done*" -and $bold -and $font -eq "Calibri") {
        Pass "$($c.N): '$text', bold kept, font $font"
      } else {
        Fail "$($c.N): '$text', bold=$bold, font=$font"
      }
    } catch {
      Fail "$($c.N): $($_.Exception.Message)"
    } finally {
      $d.Saved = $true; $d.Close([ref]$false)
    }
  }
}

function New-StyledWordDoc($word) {
  $d = $word.Documents.Add()
  $d.Content.Text = "plain bold done"
  $d.Content.Font.Name = "Calibri"
  $d.Content.Font.Size = 14
  $r = $d.Range(); $null = $r.Find.Execute("bold")
  if ($r.Find.Found) { $r.Bold = $true }
  return $d
}

switch ($Mode) {

  "paste" {
    Write-Host "PASTE: our own payload, written by writeRichToClipboard()"
    Invoke-Dart "write"
    $word = New-Object -ComObject Word.Application
    $word.Visible = $false; $word.DisplayAlerts = 0
    try { Test-WordPaste $word } finally { $word.Quit() }
  }

  "word" {
    Write-Host "WORD round trip ($Replay replay)"
    $word = New-Object -ComObject Word.Application
    $word.Visible = $false; $word.DisplayAlerts = 0
    try {
      # Word publishes by delayed rendering, so it has to stay alive until the
      # capture has read the clipboard.
      $src = New-StyledWordDoc $word
      $src.Content.Copy()
      Invoke-Dart $dartMode
      $src.Saved = $true; $src.Close([ref]$false)
      Test-WordPaste $word
    } finally { $word.Quit() }
  }

  "excel" {
    Write-Host "EXCEL round trip ($Replay replay)"
    $xl = New-Object -ComObject Excel.Application
    $xl.Visible = $false; $xl.DisplayAlerts = $false
    try {
      $wb = $xl.Workbooks.Add(); $ws = $wb.Worksheets.Item(1)
      $ws.Range("A1").Value2 = "plain"
      $ws.Range("B1").Value2 = "bold"
      $ws.Range("C1").Value2 = "done"
      $ws.Range("B1").Font.Bold = $true
      $null = $ws.Range("A1:C1").Copy()
      Invoke-Dart $dartMode

      $ws2 = $wb.Worksheets.Add()
      $null = $ws2.Range("A1").Select()
      $ws2.Paste()
      $cells = @($ws2.Range("A1").Value2, $ws2.Range("B1").Value2,
        $ws2.Range("C1").Value2) -join "|"
      # Three separate cells is the whole point: a merged A1 means the table
      # structure was lost with the out-of-fragment wrappers.
      if ($cells -eq "plain|bold|done") {
        Pass "cells survived as $cells"
      } else {
        Fail "cells came through as '$cells' (want plain|bold|done)"
      }
      if ($ws2.Range("B1").Font.Bold) {
        Pass "B1 is still bold"
      } else {
        Fail "B1 lost its bold (the <style> block was dropped)"
      }
      $wb.Saved = $true; $wb.Close($false)
    } finally { $xl.Quit() }
  }
}

if ($script:failed -eq 0) {
  Write-Host "`nAll checks passed."
} else {
  Write-Host "`n$script:failed check(s) failed."
  exit 1
}
