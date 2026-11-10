# README animation 1: one leg of a plan, as the planner simulates it. The camera follows a walk through Westfall (the
# real path on the walk map, tools/route-map.js -> tools/readme-data/westfall-leg.json); each stop is called out as it
# happens (pick up, objective, hand in) under a caption saying what the planner is doing.
# usage: powershell -File tools/readme-leg.ps1 [out.gif]
param([string]$Out = 'docs/img/plan-leg.gif')
. (Join-Path $PSScriptRoot 'readme-kit.ps1')
$ROOT = Split-Path $PSScriptRoot -Parent
$j = Get-Content (Join-Path $PSScriptRoot 'readme-data/westfall-leg.json') -Raw | ConvertFrom-Json
$raw = [System.Drawing.Bitmap]::FromFile((Join-Path $ROOT $j.base))
# softened (a third of the size and back): the terrain's fine detail compresses badly and isn't the point here
$sm = New-Object System.Drawing.Bitmap ([int]($raw.Width / 6)), ([int]($raw.Height / 6)); $gs = [System.Drawing.Graphics]::FromImage($sm); $gs.InterpolationMode = 'HighQualityBilinear'; $gs.DrawImage($raw, 0, 0, $sm.Width, $sm.Height); $gs.Dispose()
$base = New-Object System.Drawing.Bitmap $raw.Width, $raw.Height; $gb = [System.Drawing.Graphics]::FromImage($base); $gb.InterpolationMode = 'HighQualityBicubic'; $gb.DrawImage($sm, 0, 0, $raw.Width, $raw.Height); $gb.Dispose()
$W = 680; $H = 420
# the walk as one polyline in map percent, and the point index where each stop is reached
$WALK = New-Object System.Collections.Generic.List[double[]]
$stopAt = @{}
$WALK.Add([double[]]@([double]$j.stops[0].x, [double]$j.stops[0].y)); $stopAt[0] = 0
$si = 0
foreach ($seg in $j.segs) {
  foreach ($p in $seg.pts) { $WALK.Add([double[]]@([double]$p[0], [double]$p[1])) }
  while ($si + 1 -lt $j.stops.Count) {
    $si++; $s = $j.stops[$si]; $last = $WALK[$WALK.Count - 1]; $stopAt[$si] = $WALK.Count - 1
    if ([Math]::Abs($s.x - $last[0]) + [Math]::Abs($s.y - $last[1]) -lt 2.5) { break }
  }
}
while ($si + 1 -lt $j.stops.Count) { $si++; $stopAt[$si] = $WALK.Count - 1 }
$n = $j.stops.Count
$kindOf = @{ accept = @{ c = $K.gold; badge = 'PICK UP'; t = 'Pick up the quests'; s = 'At a hub the planner takes every quest worth doing, all at once' }
  obj = @{ c = $K.red; badge = 'OBJECTIVES'; t = 'One loop through the objectives'; s = 'Nearest first; kills and loot that share ground are done together' }
  turnin = @{ c = $K.green; badge = 'HAND IN'; t = 'Back to hand them in'; s = 'XP, rewards, and the next quests from the same people' } }
function KindOf($kind) { if ($kindOf[$kind]) { $kindOf[$kind] } else { $kindOf.obj } }
function Label($s) {
  $t = [string]$s.label
  $t = $t -replace '^accept ', '' -replace '^turnin ', ''
  if ($s.k -eq 'accept') { $t = 'Accept ' + $t } elseif ($s.k -eq 'turnin') { $t = 'Hand in ' + $t }
  if ($t.Length -gt 40) { $t = $t.Substring(0, 39) + '...' }
  $t
}
# the timeline: walk to each stop (frames by distance), then a short beat at it
$timeline = New-Object System.Collections.Generic.List[object]
for ($i = 1; $i -lt $n; $i++) {
  $a = $stopAt[$i - 1]; $b = $stopAt[$i]
  $len = 0; for ($q = $a + 1; $q -le $b; $q++) { $len += [Math]::Sqrt([Math]::Pow($WALK[$q][0] - $WALK[$q - 1][0], 2) + [Math]::Pow($WALK[$q][1] - $WALK[$q - 1][1], 2)) }
  $steps = [int][Math]::Max(2, [Math]::Min(7, $len / 3))
  for ($f = 1; $f -le $steps; $f++) { $timeline.Add(@{ stop = $i - 1; walkTo = $i; t = (Ease ($f / $steps)) }) }
  for ($f = 0; $f -lt 2; $f++) { $timeline.Add(@{ stop = $i; beat = $f }) }
}
# where you are on the polyline for a timeline entry
function Pos($e) {
  if ($null -ne $e.walkTo) {
    $a = $stopAt[$e.walkTo - 1]; $b = $stopAt[$e.walkTo]; $x = Lerp $a $b $e.t
    $i0 = [int][Math]::Floor($x); $i1 = [Math]::Min($b, $i0 + 1); $fr = $x - $i0
    return @((Lerp $WALK[$i0][0] $WALK[$i1][0] $fr), (Lerp $WALK[$i0][1] $WALK[$i1][1] $fr), $x)
  }
  $q = $stopAt[$e.stop]; return @($WALK[$q][0], $WALK[$q][1], [double]$q)
}
# the camera: center (map %) and the width of map it shows (%), eased toward where the action is
$cam = @{ x = 50.0; y = 45.0; w = 70.0 }
$xs = @($j.stops | ForEach-Object { $_.x }); $ys = @($j.stops | ForEach-Object { $_.y })
$all = @{ x = (($xs | Measure-Object -Average).Average); y = (($ys | Measure-Object -Average).Average); w = [Math]::Max(((($xs | Measure-Object -Max).Maximum) - (($xs | Measure-Object -Min).Minimum)) * 1.35, ((($ys | Measure-Object -Max).Maximum) - (($ys | Measure-Object -Min).Minimum)) * 1.35 * $W / $H) }
$aspect = $base.Height / $base.Width
function ToScreen($mx, $my) {
  $vw = $cam.w; $vh = $vw * ($H / $W) / $aspect
  @( (($mx - ($cam.x - $vw / 2)) / $vw * $W), (($my - ($cam.y - $vh / 2)) / $vh * $H) )
}
function DrawMap($g) {
  $vw = $cam.w; $vh = $vw * ($H / $W) / $aspect
  $src = New-Object System.Drawing.RectangleF ([float](($cam.x - $vw / 2) / 100 * $base.Width)), ([float](($cam.y - $vh / 2) / 100 * $base.Height)), ([float]($vw / 100 * $base.Width)), ([float]($vh / 100 * $base.Height))
  $g.DrawImage($base, (New-Object System.Drawing.RectangleF 0, 0, $W, $H), $src, [System.Drawing.GraphicsUnit]::Pixel)
  $g.FillRectangle((Brush (Alpha $K.bg 150)), 0, 0, $W, $H)
}
$frames = New-Object System.Collections.Generic.List[System.Drawing.Bitmap]
$levels = @($j.stops | ForEach-Object { if ($_.level) { [int]$_.level } else { 0 } })
$walked = 0.0
function Render($e, [string]$mode, [double]$fade) {
  $fr = New-Frame $W $H; $g = $fr.g
  DrawMap $g
  $pos = Pos $e; $upto = $pos[2]
  # the whole leg, faint (where you're headed), then the walk so far bright
  $pts = New-Object System.Collections.Generic.List[System.Drawing.PointF]
  foreach ($p in $WALK) { $s = ToScreen $p[0] $p[1]; $pts.Add((New-Object System.Drawing.PointF ([float]$s[0]), ([float]$s[1]))) }
  $dash = Pen (Alpha $K.text 70) 1.6; $dash.DashPattern = @(3, 4); $g.DrawLines($dash, $pts.ToArray())
  $last = [int][Math]::Floor($upto)
  if ($last -ge 1) {
    $done = $pts.GetRange(0, $last + 1); $here = ToScreen $pos[0] $pos[1]; $done.Add((New-Object System.Drawing.PointF ([float]$here[0]), ([float]$here[1])))
    $g.DrawLines((Pen (Alpha $K.blue 70) 9), $done.ToArray()); $g.DrawLines((Pen $K.blue 3.2), $done.ToArray())
  }
  # stops: ahead hollow, reached filled in their color
  $reached = if ($null -ne $e.walkTo) { $e.walkTo - 1 } else { $e.stop }
  for ($i = 0; $i -lt $n; $i++) {
    $s = $j.stops[$i]; $sc = ToScreen $s.x $s.y; $c = (KindOf $s.k).c
    if ($i -le $reached) { Dot $g $sc[0] $sc[1] 6.5 $c (Alpha $K.bg 255) 2 } else { Dot $g $sc[0] $sc[1] 5 (Alpha $K.bg 160) (Alpha $c 170) 1.6 }
  }
  # you
  $me = ToScreen $pos[0] $pos[1]; Glow $g $me[0] $me[1] 7 $K.text; Dot $g $me[0] $me[1] 6 $K.text (Alpha $K.bg 255) 2
  # the stop just reached: a pulse and its callout
  if ($mode -eq 'walk' -and $null -ne $e.beat) {
    $s = $j.stops[$reached]; $sc = ToScreen $s.x $s.y; $kc = (KindOf $s.k).c
    if ($null -ne $e.beat) { $r = 9 + 6 * $e.beat; $g.DrawEllipse((Pen (Alpha $kc (200 - 60 * $e.beat)) 2.5), $sc[0] - $r, $sc[1] - $r, 2 * $r, 2 * $r) }
    $txt = Label $s; $tw = $g.MeasureString($txt, $FONTS.chip).Width + 14
    $cx = [Math]::Min($W - $tw - 10, [Math]::Max(10, $sc[0] + 14)); $cy = [Math]::Min($H - 100, [Math]::Max(76, $sc[1] - 30))
    [void](Chip $g $cx $cy $txt $K.bg $kc)
  }
  # caption: what the planner is doing now (the kind of the stop you're heading to or at)
  if ($mode -eq 'intro') { Caption $g $W 'THE PLANNER' $K.violet 'A leg of the plan, simulated' 'Westfall at level 11: every step is played out to time it and order it' $fade }
  elseif ($mode -eq 'outro') { Caption $g $W 'DONE' $K.violet "$n stops, $([Math]::Round($j.yards / 1000, 1)) km on the walk map" 'One leg of a 1-60 plan; the next one starts where this ends' $fade }
  else {
    $target = if ($null -ne $e.walkTo) { $j.stops[$e.walkTo] } else { $j.stops[$e.stop] }
    # change the caption only at a stop of another kind (not mid-walk), so a caption stays up for a run of stops
    if ($null -eq $script:capKind -or ($null -ne $e.beat -and $target.k -ne $script:capKind)) { $script:capKind = $target.k }
    $kk = KindOf $script:capKind; Caption $g $W $kk.badge $kk.c $kk.t $kk.s 1
  }
  # the HUD: level, XP within the leg, progress
  Card $g 14 ($H - 82) 230 68 (Alpha $K.panel 235) 12 $K.line
  $lv = $levels[[Math]::Max(0.0, $reached)]; if ($lv -le 0) { $lv = 11 }
  $g.DrawString("Level $lv", $FONTS.cap, (Brush $K.text), 26, ($H - 74))
  $g.DrawString("step $([Math]::Min($n, $reached + 1)) of $n", $FONTS.small, (Brush $K.sub), 150, ($H - 72))
  $pr = ($reached + 1) / $n; Card $g 26 ($H - 44) 206 10 $K.panel2 5; if ($pr -gt 0) { Card $g 26 ($H - 44) ([float](206 * $pr)) 10 $K.violet 5 }
  $g.DrawString('Westfall', $FONTS.small, (Brush $K.faint), ($W - 70), ($H - 22))
  $g.Dispose(); $frames.Add($fr.bmp)
}
# intro: the whole leg, then ease in
$cam.x = $all.x; $cam.y = $all.y; $cam.w = $all.w
for ($f = 0; $f -lt 10; $f++) { Render $timeline[0] 'intro' ([Math]::Min(1.0, ($f + 1) / 4)) }
$holds = @{ 9 = 150 }
$script:capKind = $null
foreach ($e in $timeline) {
  $pos = Pos $e
  $nextStop = if ($null -ne $e.walkTo) { $j.stops[$e.walkTo] } else { $j.stops[[Math]::Min($n - 1, $e.stop + 1)] }
  $tx = ($pos[0] + $nextStop.x) / 2; $ty = ($pos[1] + $nextStop.y) / 2
  $span = [Math]::Max([Math]::Abs($pos[0] - $nextStop.x), [Math]::Abs($pos[1] - $nextStop.y) * $W / $H)
  $tw = [Math]::Max(36, [Math]::Min(56, $span * 1.8))
  # hold still while you and the next stop are well inside the view; else pan there over a few frames
  $sme = ToScreen $pos[0] $pos[1]; $snx = ToScreen $nextStop.x $nextStop.y
  $inside = { param($s) $s[0] -gt $W * 0.1 -and $s[0] -lt $W * 0.9 -and $s[1] -gt 90 -and $s[1] -lt $H - 100 }
  # a pan is 6 eased frames that land exactly, then the camera is still (a camera always drifting a little
  # repainted every frame: a 6 MB GIF)
  if (-not $script:pan -and (-not ((& $inside $sme) -and (& $inside $snx)) -or $cam.w -gt 60)) { $script:pan = @{ from = @{ x = $cam.x; y = $cam.y; w = $cam.w }; to = @{ x = $tx; y = $ty; w = $tw }; k = 0 } }
  if ($script:pan) {
    $script:pan.k++; $t = Ease ($script:pan.k / 6)
    $cam.x = Lerp $script:pan.from.x $script:pan.to.x $t; $cam.y = Lerp $script:pan.from.y $script:pan.to.y $t; $cam.w = Lerp $script:pan.from.w $script:pan.to.w $t
    if ($script:pan.k -ge 6) { $script:pan = $null }
  }
  Render $e 'walk' 1
  # the last beat at a stop: hold it, so its callout can be read (about 3/4 of a second)
  if ($null -ne $e.beat -and $e.beat -eq 1) { $holds[$frames.Count - 1] = 70 }
}
# outro: back out to the whole leg, hold
$endE = $timeline[$timeline.Count - 1]
for ($f = 0; $f -lt 12; $f++) { $t = Ease (($f + 1) / 12); $cam.x = Lerp $cam.x $all.x $t; $cam.y = Lerp $cam.y $all.y $t; $cam.w = Lerp $cam.w $all.w $t; Render $endE 'outro' 1 }
Save-Frames $frames (Join-Path $ROOT $Out) 6 400 $holds
