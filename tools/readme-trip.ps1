# README animation 4: how a trip is found (tools/readme-trip.js -> tools/readme-data/trip.json). The travel network
# fades in; a search ripples out from the start, each stop lighting up when it can first be reached; then the fastest
# trip is traced leg by leg with its minutes.
# usage: powershell -File tools/readme-trip.ps1 [out.gif]
param([string]$Out = 'docs/img/travel.gif')
. (Join-Path $PSScriptRoot 'readme-kit.ps1')
$ROOT = Split-Path $PSScriptRoot -Parent
$j = Get-Content (Join-Path $PSScriptRoot 'readme-data/trip.json') -Raw | ConvertFrom-Json
$layout = Get-Content (Join-Path $PSScriptRoot 'readme-data/world-layout.json') -Raw | ConvertFrom-Json
foreach ($z in $layout.zones) { $z.png = Join-Path $ROOT $z.png }
$W = 760; $H = 460
$world = New-WorldBackground $layout ([int]$layout.W) ([int]$layout.H)
$top = 70; $avW = $W - 236; $avH = $H - $top - 8
$s = [Math]::Min($avW / $layout.W, $avH / $layout.H); $mw = $layout.W * $s; $mh = $layout.H * $s; $mx = $W - $mw - 8; $my = $top + ($avH - $mh) / 2
function M($p) { @(($mx + $p[0] * $s), ($my + $p[1] * $s)) }
# the static layer: map + the network's links, faint
$base = New-Object System.Drawing.Bitmap $W, $H
$gb = [System.Drawing.Graphics]::FromImage($base); $gb.SmoothingMode = 'AntiAlias'; $gb.Clear($K.bg)
$gb.DrawImage($world, [float]$mx, [float]$my, [float]$mw, [float]$mh)
$gb.FillRectangle((Brush (Alpha $K.bg 90)), [float]$mx, [float]$my, [float]$mw, [float]$mh)
$lp = Pen (Alpha $K.text 14) 1
# only the short links (neighbours): every pair in a zone is linked, and drawn all at once they were a white mass
foreach ($e in $j.edges) { $a = M @($e[0], $e[1]); $b = M @($e[2], $e[3]); if ([Math]::Abs($a[0] - $b[0]) + [Math]::Abs($a[1] - $b[1]) -lt 34) { $gb.DrawLine($lp, [float]$a[0], [float]$a[1], [float]$b[0], [float]$b[1]) } }
foreach ($n in $j.nodes) { $p = M $n.at; $gb.FillEllipse((Brush (Alpha $K.text 70)), [float]($p[0] - 1.5), [float]($p[1] - 1.5), 3, 3) }
$gb.Dispose()
$howC = @{ ride = $K.gold; boat = $K.blue; fly = $K.green }
$howW = @{ ride = 'Ride to'; boat = 'Boat to'; fly = 'Fly to' }
$maxT = $j.total * 60 * 1.5
$frames = New-Object System.Collections.Generic.List[System.Drawing.Bitmap]
$legs = @($j.legs)
function Frame([int]$fi) {
  $fr = New-Frame $W $H; $g = $fr.g
  $g.DrawImage($base, 0, 0)
  $intro = Ease ([Math]::Min(1.0, $fi / 8.0))
  $wave = [Math]::Max(0.0, [Math]::Min(1.0, ($fi - 10) / 34.0))
  $trace = [Math]::Max(0.0, ($fi - 48) / 9.0)  # legs traced so far (fractional)
  $why = Ease ([Math]::Max(0.0, [Math]::Min(1.0, ($fi - ($whyAt)) / 8.0)))
  $th = $maxT * (Ease $wave)
  # the search: stops light up as they're reached
  if ($wave -gt 0) {
    # the search tree: each stop reached is linked to the one that reached it first (ride, boat or flight)
    foreach ($n in $j.nodes) {
      if ($null -eq $n.t -or $n.t -gt $th -or -not $n.from) { continue }
      $p = M $n.at; $q0 = M $n.from; $tc = if ($n.how -eq 'boat') { $K.blue } elseif ($n.how -eq 'fly') { $K.green } else { $K.gold }
      $tp = Pen (Alpha $tc 120) 1.4; if ($n.how -ne 'ride') { $tp.DashPattern = @(3, 2) }
      $g.DrawLine($tp, [float]$q0[0], [float]$q0[1], [float]$p[0], [float]$p[1])
    }
    foreach ($n in $j.nodes) {
      if ($null -eq $n.t -or $n.t -gt $th) { continue }
      $p = M $n.at; $age = ($th - $n.t) / ($maxT * 0.08)
      $c = Mix $K.violet $K.blue ([Math]::Min(1.0, $n.t / $maxT * 1.5))
      $r = 2.6 + 3 * [Math]::Max(0.0, 1 - $age)
      Dot $g $p[0] $p[1] ([float]$r) (Alpha $c ([int](Lerp 255 170 ([Math]::Min(1.0, $age)))))
    }
  }
  # the trip, leg by leg
  for ($li = 0; $li -lt $legs.Count; $li++) {
    $part = [Math]::Max(0.0, [Math]::Min(1.0, $trace - $li)); if ($part -le 0) { break }
    $l = $legs[$li]; $c = $howC[$l.how]; $pts = @($l.pts | ForEach-Object { ,(M $_) })
    $tot = 0; for ($q = 1; $q -lt $pts.Count; $q++) { $tot += [Math]::Sqrt([Math]::Pow($pts[$q][0] - $pts[$q - 1][0], 2) + [Math]::Pow($pts[$q][1] - $pts[$q - 1][1], 2)) }
    $want = $tot * (Ease $part); $acc = 0
    $draw = New-Object System.Collections.Generic.List[System.Drawing.PointF]; $draw.Add((New-Object System.Drawing.PointF ([float]$pts[0][0]), ([float]$pts[0][1])))
    for ($q = 1; $q -lt $pts.Count; $q++) {
      $sl = [Math]::Sqrt([Math]::Pow($pts[$q][0] - $pts[$q - 1][0], 2) + [Math]::Pow($pts[$q][1] - $pts[$q - 1][1], 2))
      if ($acc + $sl -ge $want) { $f = if ($sl -gt 0) { ($want - $acc) / $sl } else { 1 }; $draw.Add((New-Object System.Drawing.PointF ([float](Lerp $pts[$q - 1][0] $pts[$q][0] $f)), ([float](Lerp $pts[$q - 1][1] $pts[$q][1] $f)))); break }
      $acc += $sl; $draw.Add((New-Object System.Drawing.PointF ([float]$pts[$q][0]), ([float]$pts[$q][1])))
    }
    if ($draw.Count -ge 2) {
      $pen = Pen $c 3.5; if ($l.how -eq 'boat' -or $l.how -eq 'fly') { $pen.DashPattern = @(2.2, 1.6) }
      $g.DrawLines((Pen (Alpha $c 70) 9), $draw.ToArray()); $g.DrawLines($pen, $draw.ToArray())
      $hd = $draw[$draw.Count - 1]; if ($part -lt 1) { Dot $g $hd.X $hd.Y 5 $K.text (Alpha $K.bg 255) 2 } else { Dot $g $hd.X $hd.Y 4 $c (Alpha $K.bg 255) 1.5 }
    }
  }
  # start and end
  $a = M $j.start.at; $b = M $j.target.at
  Glow $g $a[0] $a[1] 6 $K.text; Dot $g $a[0] $a[1] 6 $K.text (Alpha $K.bg 255) 2
  Dot $g $b[0] $b[1] 7 (Alpha $K.bg 200) $K.green 3
  [void](Chip $g ($a[0] + 10) ($a[1] - 10) $j.start.name $K.bg $K.text $FONTS.small); [void](Chip $g ($b[0] + 10) ($b[1] - 22) $j.target.name $K.bg $K.green $FONTS.small)
  # captions and the side panel
  if ($fi -lt 10) { Caption $g $W 'NETWORK' $K.violet 'One travel network' ("{0} stops: towns, flight masters, docks, zone crossings, with walking distances" -f $j.nodes.Count) $intro }
  elseif ($fi -lt 48) { Caption $g $W 'SEARCH' $K.blue "Searching outward from $($j.start.name)" 'Every stop gets its fastest arrival: roads at your speed, boats, flights you know' }
  elseif ($why -gt 0) { Caption $g $W 'WHY' $K.green 'Why this way' 'The same search, priced every way: the planner and the card take the fastest' }
  else { Caption $g $W 'FASTEST' $K.green ("{0} to {1}: about {2} minutes" -f $j.start.name, $j.target.name, $j.total) "Level $($j.level): the card shows each leg, and the arrow points the way" }
  $px = 16; $py = 84
  if ($wave -gt 0 -and $fi -lt 48) {
    $g.DrawString('searched up to', $FONTS.small, (Brush $K.sub), $px, $py)
    $g.DrawString(("{0} min" -f [int]($th / 60)), $FONTS.big, (Brush $K.text), $px - 2, $py + 16)
    $reached = @($j.nodes | Where-Object { $null -ne $_.t -and $_.t -le $th }).Count
    $g.DrawString("$reached stops reached", $FONTS.small, (Brush $K.sub), $px, $py + 62)
  }
  $why = Ease ([Math]::Max(0.0, [Math]::Min(1.0, ($fi - ($whyAt)) / 8.0)))
  if ($why -gt 0) {
    $alts = @($j.alternatives)
    for ($ai = 0; $ai -lt $alts.Count; $ai++) {
      $a = $alts[$ai]; $y = $py + $ai * 64; $al = [int](255 * [Math]::Max(0.0, [Math]::Min(1.0, $why * 1.5 - $ai * 0.25)))
      if ($al -le 0) { continue }
      $c = if ($a.best) { $K.green } else { $K.red }
      Card $g $px $y 196 54 (Alpha $K.panel $al) 10 (Alpha $c $al)
      $g.DrawString($a.label, $FONTS.small, (Brush (Alpha $K.text $al)), ($px + 10), ($y + 6))
      $g.DrawString(("{0} min" -f $a.min), $FONTS.cap, (Brush (Alpha $c $al)), ($px + 10), ($y + 26))
      $tag = if ($a.best) { 'fastest' } else { '+' + ($a.min - $alts[0].min) + ' min' }
      [void](Chip $g ($px + 186) ($y + 28) $tag (Alpha $K.bg $al) (Alpha $c $al) $FONTS.small -alignRight)
      if (-not $a.best) { $sw = $g.MeasureString(("{0} min" -f $a.min), $FONTS.cap).Width; $g.DrawLine((Pen (Alpha $K.red $al) 2), [float]($px + 10), [float]($y + 37), [float]($px + 12 + $sw), [float]($y + 37)) }
    }
  }
  if ($trace -gt 0 -and $why -le 0) {
    for ($li = 0; $li -lt $legs.Count; $li++) {
      $part = [Math]::Max(0.0, [Math]::Min(1.0, $trace - $li)); if ($part -le 0) { break }
      $l = $legs[$li]; $y = $py + $li * 54; $al = [int](255 * (Ease $part))
      Card $g $px $y 196 46 (Alpha $K.panel $al) 10 (Alpha $K.line $al)
      Dot $g ($px + 16) ($y + 16) 5 (Alpha $howC[$l.how] $al)
      $g.DrawString($howW[$l.how], $FONTS.small, (Brush (Alpha $K.sub $al)), ($px + 28), ($y + 6))
      $name = [string]$l.to; if ($name.Length -gt 22) { $name = $name.Substring(0, 21) + '...' }
      $g.DrawString($name, $FONTS.body, (Brush (Alpha $K.text $al)), ($px + 28), ($y + 22))
      $g.DrawString(("{0} min" -f $l.min), $FONTS.chip, (Brush (Alpha $howC[$l.how] $al)), ($px + 150), ($y + 6))
    }
  }
  $g.Dispose(); $frames.Add($fr.bmp)
}
$whyAt = 48 + 9 * $legs.Count + 14
$last = $whyAt + 30
for ($fi = 0; $fi -le $last; $fi++) { Frame $fi }
Save-Frames $frames (Join-Path $ROOT $Out) 6 500 @{ 9 = 140; 47 = 140; ($whyAt - 1) = 150 }
