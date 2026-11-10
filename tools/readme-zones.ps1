# README animation 3: how the campaign picks the next zone (tools/readme-zones.js -> tools/readme-data/zone-choice.json).
# Two decisions in a row: the candidate zones race as XP-per-hour bars (each one a full simulated leg), the best lights
# up, and on the world map the route jumps there.
# usage: powershell -File tools/readme-zones.ps1 [out.gif]
param([string]$Out = 'docs/img/zone-choice.gif')
. (Join-Path $PSScriptRoot 'readme-kit.ps1')
$ROOT = Split-Path $PSScriptRoot -Parent
$j = Get-Content (Join-Path $PSScriptRoot 'readme-data/zone-choice.json') -Raw | ConvertFrom-Json
$layout = Get-Content (Join-Path $PSScriptRoot 'readme-data/world-layout.json') -Raw | ConvertFrom-Json
foreach ($z in $layout.zones) { $z.png = Join-Path $ROOT $z.png }
$W = 760; $H = 420
# the world map, small, on the right
$world = New-WorldBackground $layout ([int]$layout.W) ([int]$layout.H)
$mapW = 300; $s = $mapW / $layout.W; $mapH = $layout.H * $s; $mx = $W - $mapW - 16; $my = 76 + (($H - 76 - 16) - $mapH) / 2
function M($p) { @(($mx + $p.x * $s), ($my + $p.y * $s)) }
$frames = New-Object System.Collections.Generic.List[System.Drawing.Bitmap]
$visited = New-Object System.Collections.Generic.List[object]
function Frame($d, [int]$fi, [int]$di) {
  $fr = New-Frame $W $H; $g = $fr.g
  $grow = Ease ([Math]::Min(1.0, $fi / 16.0))
  $win = Ease ([Math]::Max(0.0, [Math]::Min(1.0, ($fi - 20) / 8.0)))
  $fly = Ease ([Math]::Max(0.0, [Math]::Min(1.0, ($fi - 30) / 14.0)))
  if ($fi -lt 20) { Caption $g $W 'WHERE NEXT?' $K.violet "Level $($d.level), leaving $($d.from)" "$($d.evaluated) zones fit this level: each one is planned as a whole leg and timed" }
  elseif ($fi -lt 30) { Caption $g $W 'BEST' $K.green "$($d.pick.zone): the most XP per hour" "Quests already done count for less; the trip there is part of the time" }
  else { Caption $g $W 'GO' $K.blue "$($d.pick.zone), level $($d.pick.from) to $($d.pick.to)" "$($d.pick.steps) steps - then the same question again" }
  # the bars
  $cands = @($d.cands); $max = ($cands | Measure-Object -Property xph -Maximum).Maximum
  for ($i = 0; $i -lt $cands.Count; $i++) {
    $c = $cands[$i]; $y = 92 + $i * 58
    $t = Ease ([Math]::Max(0.0, [Math]::Min(1.0, $grow * 1.4 - $i * 0.08)))
    $isPick = $c.zone -eq $d.pick.zone
    $dim = if ($win -gt 0 -and -not $isPick) { [int](Lerp 255 110 $win) } else { 255 }
    $g.DrawString($c.zone, $FONTS.cap, (Brush (Alpha $K.text $dim)), 18, [float]$y)
    $g.DrawString(("{0} turn-ins  {2}  {1} h" -f $c.turnins, $c.hours, [char]0x00B7), $FONTS.small, (Brush (Alpha $K.sub $dim)), 18, [float]($y + 21))
    $bx = 200; $bwMax = $mx - $bx - 90
    $bw = [Math]::Max(4, $bwMax * $c.xph / $max * $t)
    $col = Mix $K.line $K.blue 0.55; if ($isPick) { $col = Mix $col $K.green $win }
    Card $g $bx ($y + 6) ([float]$bw) 16 (Alpha $col $dim) 8
    if ($t -gt 0.2) { $g.DrawString(('{0:N0} XP/h' -f [int]($c.xph * $t)), $FONTS.small, (Brush (Alpha $K.text $dim)), [float]($bx + $bw + 8), [float]($y + 6)) }
  }
  # the map: past route, candidates, you, and the jump to the pick
  $g.DrawImage($world, [float]$mx, [float]$my, [float]$mapW, [float]$mapH)
  $g.DrawRectangle((Pen $K.line 1), [float]$mx, [float]$my, [float]$mapW, [float]$mapH)
  for ($v = 1; $v -lt $visited.Count; $v++) { $a = M $visited[$v - 1]; $b = M $visited[$v]; $g.DrawLine((Pen (Alpha $K.gold 150) 2), [float]$a[0], [float]$a[1], [float]$b[0], [float]$b[1]) }
  foreach ($c in $cands) { if ($c.at) { $p = M $c.at; $isPick = $c.zone -eq $d.pick.zone; $cc = if ($isPick -and $win -gt 0) { Mix $K.blue $K.green $win } else { Alpha $K.blue ([int](Lerp 220 90 $win)) }; Dot $g $p[0] $p[1] ([float](4 + 2 * $grow)) $cc (Alpha $K.bg 255) 1.5 } }
  $a = M $d.fromAt; $b = M $d.pick.at
  if ($fly -gt 0) {
    # an arc from where you are to the pick
    $mxp = ($a[0] + $b[0]) / 2; $myp = [Math]::Min($a[1], $b[1]) - 40
    $pts = New-Object System.Collections.Generic.List[System.Drawing.PointF]
    for ($q = 0; $q -le 20; $q++) { $t = $q / 20 * $fly; $x = (1 - $t) * (1 - $t) * $a[0] + 2 * (1 - $t) * $t * $mxp + $t * $t * $b[0]; $y = (1 - $t) * (1 - $t) * $a[1] + 2 * (1 - $t) * $t * $myp + $t * $t * $b[1]; $pts.Add((New-Object System.Drawing.PointF ([float]$x), ([float]$y))) }
    $pen = Pen $K.text 2; $pen.DashPattern = @(3, 3); $g.DrawLines($pen, $pts.ToArray())
    $head = $pts[$pts.Count - 1]; Glow $g $head.X $head.Y 6 $K.text; Dot $g $head.X $head.Y 5 $K.text (Alpha $K.bg 255) 2
  } else { Glow $g $a[0] $a[1] 6 $K.text; Dot $g $a[0] $a[1] 5 $K.text (Alpha $K.bg 255) 2 }
  if ($fly -ge 1) { [void](Chip $g ([Math]::Min($W - 130, $b[0] + 10)) ($b[1] - 26) $d.pick.zone $K.bg $K.green $FONTS.small) }
  $g.DrawString('decision ' + ($di + 1) + ' of 2', $FONTS.small, (Brush $K.faint), 18, [float]($H - 24))
  $g.Dispose(); $frames.Add($fr.bmp)
}
$di = 0
foreach ($d in $j.decisions) {
  if ($visited.Count -eq 0) { $visited.Add($d.fromAt) }
  for ($fi = 0; $fi -le 48; $fi++) { Frame $d $fi $di }
  $visited.Add($d.pick.at); $di++
}
Save-Frames $frames (Join-Path $ROOT $Out) 6 450 @{ 19 = 140; 29 = 140; 48 = 170; 68 = 140; 78 = 140 }
