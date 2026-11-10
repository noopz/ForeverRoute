# README animation 2: how the planner picks a zone's quests (tools/readme-quests.js -> tools/readme-data/*-quests.json).
# Four beats: every quest given in the zone by XP; the ones not worth it or not possible struck out with the reason;
# the ones for later; the kept ones pulled together.
# usage: powershell -File tools/readme-quests.ps1 [data.json] [out.gif]
param([string]$Data = 'tools/readme-data/duskwood-quests.json', [string]$Out = 'docs/img/quest-pick.gif')
. (Join-Path $PSScriptRoot 'readme-kit.ps1')
$ROOT = Split-Path $PSScriptRoot -Parent
$j = Get-Content (Join-Path $ROOT $Data) -Raw | ConvertFrom-Json
$W = 680; $H = 420
$rows = @($j.rows); $nr = $rows.Count
$maxXp = ($rows | Measure-Object -Property xp -Maximum).Maximum
$top = 80; $rh = 19.5; $barX = 300; $barW = 170
$statusColor = @{ done = $K.green; cut = $K.red; later = $K.gold }
$frames = New-Object System.Collections.Generic.List[System.Drawing.Bitmap]
# the kept rows' final order (top), for the last beat
$keptIdx = @{}; $kk = 0; for ($i = 0; $i -lt $nr; $i++) { if ($rows[$i].status -eq 'done') { $keptIdx[$i] = $kk; $kk++ } }
function Frame([int]$fi) {
  $fr = New-Frame $W $H; $g = $fr.g
  # beats (frame ranges)
  $b1 = [Math]::Min(1.0, $fi / 22.0)                       # rows arrive
  $b2 = [Math]::Max(0.0, [Math]::Min(1.0, ($fi - 30) / 18.0)) # cut
  $b3 = [Math]::Max(0.0, [Math]::Min(1.0, ($fi - 56) / 14.0)) # later
  $b4 = [Math]::Max(0.0, [Math]::Min(1.0, ($fi - 78) / 16.0)) # kept
  if ($fi -lt 30) { Caption $g $W 'THE ZONE' $K.violet "$($j.zone) at level $($j.level): every quest given here" 'Sorted by XP - each one is simulated: kills, drops, walking, the trip back' }
  elseif ($fi -lt 56) { Caption $g $W 'CUT' $K.red 'Not worth it, or not possible' 'Too many kills, elites, bad drop rates, objectives somewhere else, chains not started' }
  elseif ($fi -lt 78) { Caption $g $W 'LATER' $K.gold 'Not yet' 'Over the level gate (two above you): picked up on a later visit' }
  else { Caption $g $W 'KEPT' $K.green "$($j.totals.done) quests on this leg" ('About {0:N0} XP, done in one pass through the zone''s hubs' -f $j.totals.xpDone) }
  for ($i = 0; $i -lt $nr; $i++) {
    $r = $rows[$i]
    $appear = Ease ([Math]::Max(0.0, [Math]::Min(1.0, $b1 * 1.6 - $i * 0.04)))
    if ($appear -le 0) { continue }
    $y = $top + $i * $rh
    $alpha = 255
    $struck = 0; $lateMark = 0
    if ($r.status -eq 'cut') { $struck = Ease $b2; if ($b4 -gt 0) { $alpha = [int](Lerp 255 0 (Ease $b4)) } elseif ($b2 -ge 1) { $alpha = 140 } }
    if ($r.status -eq 'later') { $lateMark = Ease $b3; if ($b4 -gt 0) { $alpha = [int](Lerp 255 0 (Ease $b4)) } elseif ($b3 -ge 1) { $alpha = 160 } }
    if ($r.status -eq 'done' -and $b4 -gt 0) { $y = Lerp $y ($top + $keptIdx[$i] * $rh) (Ease $b4) }
    $alpha = [int]($alpha * $appear); if ($alpha -le 2) { continue }
    $x0 = 18 + (1 - $appear) * -16
    # name and level
    $nameC = Alpha $K.text $alpha
    $g.DrawString($r.name, $FONTS.body, (Brush $nameC), [float]$x0, [float]$y)
    $nw = $g.MeasureString($r.name, $FONTS.body).Width
    $g.DrawString("[$($r.level)]", $FONTS.small, (Brush (Alpha $K.faint $alpha)), [float]($x0 + $nw), [float]($y + 2))
    if ($struck -gt 0) { $g.DrawLine((Pen (Alpha $K.red $alpha) 2), [float]($x0), [float]($y + 10), [float]($x0 + ($nw + 22) * $struck), [float]($y + 10)) }
    # the XP bar: neutral, then the color of what happened to it
    $bw = $barW * ($r.xp / $maxXp) * $appear
    $bc = Mix $K.panel2 $K.line 0.5
    if ($r.status -eq 'cut') { $bc = Mix $bc $K.red $struck } elseif ($r.status -eq 'later') { $bc = Mix $bc $K.gold $lateMark } elseif ($b4 -gt 0) { $bc = Mix $bc $K.green (Ease $b4) }
    Card $g $barX ($y + 4) ([float][Math]::Max(4, $bw)) 11 (Alpha $bc $alpha) 5
    $g.DrawString(('{0:N0}' -f $r.xp), $FONTS.small, (Brush (Alpha $K.sub $alpha)), [float]($barX + $bw + 6), [float]($y + 1))
    # the verdict chip
    $cx = 548
    if ($r.status -eq 'cut' -and $struck -gt 0.6) { [void](Chip $g $cx ($y + 1) $r.reason (Alpha $K.bg $alpha) (Alpha $K.red $alpha) $FONTS.small) }
    if ($r.status -eq 'later' -and $lateMark -gt 0.6) { [void](Chip $g $cx ($y + 1) $r.reason (Alpha $K.bg $alpha) (Alpha $K.gold $alpha) $FONTS.small) }
    if ($r.status -eq 'done' -and $b4 -gt 0.5) { [void](Chip $g $cx ($y + 1) 'this leg' (Alpha $K.bg ([int](255 * (Ease (($b4 - 0.5) * 2))))) (Alpha $K.green ([int](255 * (Ease (($b4 - 0.5) * 2))))) $FONTS.small) }
  }
  # more kept than shown: say so under the list
  $more = $j.totals.done - $kk
  if ($b4 -gt 0.6 -and $more -gt 0) { $g.DrawString("+ $more more quests on this leg", $FONTS.small, (Brush (Alpha $K.sub ([int](255 * (Ease (($b4 - 0.6) / 0.4)))))), 20, [float]($top + $kk * $rh + 4)) }
  # the tally
  $done = $j.totals.done; $cut = $j.totals.cut; $later = $j.totals.later
  $ty = $H - 30
  $x = 18; foreach ($t in @(@('kept', $done, $K.green, $b4), @('cut', $cut, $K.red, $b2), @('later', $later, $K.gold, $b3))) {
    if ($t[3] -le 0) { continue }
    $x += (Chip $g $x $ty ("{0} {1}" -f $t[1], $t[0]) $K.bg (Alpha $t[2] ([int](255 * (Ease $t[3])))) $FONTS.chip) + 8
  }
  $g.Dispose(); $frames.Add($fr.bmp)
}
for ($fi = 0; $fi -le 100; $fi++) { Frame $fi }
Save-Frames $frames (Join-Path $ROOT $Out) 5 450 @{ 29 = 140; 55 = 140; 77 = 150 }
