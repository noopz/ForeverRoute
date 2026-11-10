# README animation: a zone as the planner sees it (tools/readme-graph.js -> tools/readme-data/<zone>-graph.json).
# Beats: the hubs; every quest as a spoke from its giver out to its objective; the chains between quests; the pruning
# (cut, with the reason, and the ones for later); then the plan walking its loops through what's left.
# usage: powershell -File tools/readme-graph.ps1 [data.json] [out.gif]
param([string]$Data = 'tools/readme-data/duskwood-graph.json', [string]$Out = 'docs/img/zone-graph.gif')
. (Join-Path $PSScriptRoot 'readme-kit.ps1')
$ROOT = Split-Path $PSScriptRoot -Parent
$gd = Get-Content (Join-Path $ROOT $Data) -Raw | ConvertFrom-Json
$raw = [System.Drawing.Bitmap]::FromFile((Join-Path $ROOT ("terrain/area{0}.png" -f $gd.zoneId)))
$small = New-Object System.Drawing.Bitmap ([int]($raw.Width / 6)), ([int]($raw.Height / 6)); $gs = [System.Drawing.Graphics]::FromImage($small); $gs.InterpolationMode = 'HighQualityBilinear'; $gs.DrawImage($raw, 0, 0, $small.Width, $small.Height); $gs.Dispose()
$W = 760; $H = 480; $mapTop = 64
# the map fills the frame below the caption, aspect kept
$mapScale = [Math]::Min($W / $raw.Width, ($H - $mapTop) / $raw.Height); $mapW = $raw.Width * $mapScale; $mapH = $raw.Height * $mapScale
$mapX = ($W - $mapW) / 2; $mapY = $mapTop + (($H - $mapTop) - $mapH) / 2
function MapPt($x, $y) { @(($mapX + $x / 100 * $mapW), ($mapY + $y / 100 * $mapH)) }
$bg = New-Object System.Drawing.Bitmap $W, $H; $gb = [System.Drawing.Graphics]::FromImage($bg); $gb.InterpolationMode = 'HighQualityBicubic'; $gb.Clear($K.bg)
$gb.DrawImage($small, [float]$mapX, [float]$mapY, [float]$mapW, [float]$mapH); $gb.FillRectangle((Brush (Alpha $K.bg 165)), 0, 0, $W, $H); $gb.Dispose()
$quests = @($gd.quests); $hubs = @($gd.hubs); $order = @($gd.order)
$byId = @{}; foreach ($q in $quests) { $byId[[string]$q.id] = $q }
$cutOnes = @($quests | Where-Object { $_.status -eq 'cut' }); $laterOnes = @($quests | Where-Object { $_.status -eq 'later' -or $_.status -eq 'carried' }); $doneOnes = @($quests | Where-Object { $_.status -eq 'done' })
# a quest's two ends on screen: its giver, and its objective (or the giver, when the objective isn't here)
function Ends($q) { $a = MapPt $q.giver.x $q.giver.y; $b = if ($q.obj) { MapPt $q.obj.x $q.obj.y } else { $a }; @($a, $b) }
function Spoke($g, $q, [double]$t, $col, [float]$wid) {
  $e = Ends $q; $a = $e[0]; $b = $e[1]; if ($t -le 0) { return }
  $mx = ($a[0] + $b[0]) / 2 - ($b[1] - $a[1]) * 0.18; $my = ($a[1] + $b[1]) / 2 + ($b[0] - $a[0]) * 0.18
  $pts = New-Object System.Collections.Generic.List[System.Drawing.PointF]
  if ($q.path) {
    $pp = @($q.path); $nTake = [Math]::Max(2, [int][Math]::Ceiling($pp.Count * $t))
    for ($s = 0; $s -lt [Math]::Min($nTake, $pp.Count); $s++) { $sp = MapPt $pp[$s][0] $pp[$s][1]; $pts.Add((New-Object System.Drawing.PointF ([float]$sp[0]), ([float]$sp[1]))) }
    if ($pts.Count -ge 2) { $g.DrawLines((Pen $col $wid), $pts.ToArray()) }
    if ($t -ge 1) { Dot $g $b[0] $b[1] 3.6 $col (Alpha $K.bg 255) 1.2 }
    return
  }
  for ($s = 0; $s -le 16; $s++) { $u = $s / 16 * $t; $x = (1 - $u) * (1 - $u) * $a[0] + 2 * (1 - $u) * $u * $mx + $u * $u * $b[0]; $y = (1 - $u) * (1 - $u) * $a[1] + 2 * (1 - $u) * $u * $my + $u * $u * $b[1]; $pts.Add((New-Object System.Drawing.PointF ([float]$x), ([float]$y))) }
  $g.DrawLines((Pen $col $wid), $pts.ToArray())
  if ($t -ge 1 -and $q.obj) { Dot $g $b[0] $b[1] 3.6 $col (Alpha $K.bg 255) 1.2 }
}
$frames = New-Object System.Collections.Generic.List[System.Drawing.Bitmap]
$BEAT = @{ hubs = 0; spokes = 12; chains = 36; prune = 50; plan = 72; end = 118 }
function Seg([int]$fi, [int]$a, [int]$b) { Ease ([Math]::Max(0.0, [Math]::Min(1.0, ($fi - $a) / [double]($b - $a)))) }
for ($fi = 0; $fi -le $BEAT.end; $fi++) {
  $fr = New-Frame $W $H; $g = $fr.g; $g.DrawImage($bg, 0, 0)
  $pHub = Seg $fi 0 10; $pSpoke = Seg $fi $BEAT.spokes ($BEAT.chains - 4); $pChain = Seg $fi $BEAT.chains ($BEAT.prune - 2); $pPrune = Seg $fi $BEAT.prune ($BEAT.plan - 4); $pPlan = Seg $fi $BEAT.plan ($BEAT.end - 10)
  # spokes: every quest, then pruned
  for ($i = 0; $i -lt $quests.Count; $i++) {
    $q = $quests[$i]; $t = [Math]::Max(0.0, [Math]::Min(1.0, $pSpoke * 1.6 - $i / [double]$quests.Count * 0.6))
    $col = Alpha (Mix $K.blue $K.text 0.3) 150; $wid = 1.6
    if ($pPrune -gt 0) {
      if ($q.status -eq 'cut') { $col = Alpha $K.red ([int](Lerp 200 35 $pPrune)) }
      elseif ($q.status -eq 'done') { $col = Alpha $K.green ([int](Lerp 150 230 $pPrune)); $wid = 2.2 }
      else { $col = Alpha $K.gold ([int](Lerp 170 70 $pPrune)) }
    }
    if ($pPlan -gt 0 -and $q.status -ne 'done') { $col = Alpha $col.R 0 } # (hidden below)
    if ($pPlan -gt 0 -and $q.status -ne 'done') { continue }
    if ($pPlan -gt 0) { $col = Alpha $K.green ([int](Lerp 230 60 $pPlan)) }
    Spoke $g $q $t $col $wid
  }
  # chains: gold links from a quest to the one it opens
  if ($pChain -gt 0 -and $pPlan -lt 0.5) {
    foreach ($c in $gd.chains) {
      $a = $byId[[string]$c[0]]; $b = $byId[[string]$c[1]]; if (-not ($a -and $b)) { continue }
      $ea = (Ends $a)[1]; $eb = (Ends $b)[1]
      $al = [int](220 * $pChain * (1 - $pPlan * 2)); if ($pPrune -gt 0 -and ($a.status -eq 'cut' -or $b.status -eq 'cut')) { $al = [int]($al * (1 - $pPrune)) }
      $pen = Pen (Alpha $K.violet $al) 2; $pen.DashPattern = @(2, 2)
      $g.DrawLine($pen, [float]$ea[0], [float]$ea[1], [float]($ea[0] + ($eb[0] - $ea[0]) * $pChain), [float]($ea[1] + ($eb[1] - $ea[1]) * $pChain))
    }
  }
  # the plan: its loops through what's left
  if ($pPlan -gt 0 -and $order.Count -gt 1) {
    $upto = $pPlan * ($order.Count - 1); $last = [int][Math]::Floor($upto)
    $pts = New-Object System.Collections.Generic.List[System.Drawing.PointF]
    for ($s = 0; $s -le $last; $s++) {
      if ($s -gt 0 -and $order[$s].path) { foreach ($wp in @($order[$s].path)) { $p = MapPt $wp[0] $wp[1]; $pts.Add((New-Object System.Drawing.PointF ([float]$p[0]), ([float]$p[1]))) } }
      else { $p = MapPt $order[$s].x $order[$s].y; $pts.Add((New-Object System.Drawing.PointF ([float]$p[0]), ([float]$p[1]))) }
    }
    if ($last + 1 -lt $order.Count) {
      # part of the next leg, along its path
      $f = $upto - $last; $nxt = $order[$last + 1]
      if ($nxt.path) { $pp = @($nxt.path); $nTake = [int][Math]::Floor($pp.Count * $f); for ($s = 0; $s -lt $nTake; $s++) { $p = MapPt $pp[$s][0] $pp[$s][1]; $pts.Add((New-Object System.Drawing.PointF ([float]$p[0]), ([float]$p[1]))) } }
      else { $a = MapPt $order[$last].x $order[$last].y; $b = MapPt $nxt.x $nxt.y; $pts.Add((New-Object System.Drawing.PointF ([float](Lerp $a[0] $b[0] $f)), ([float](Lerp $a[1] $b[1] $f)))) }
    }
    if ($pts.Count -ge 2) { $g.DrawLines((Pen (Alpha $K.blue 80) 8), $pts.ToArray()); $g.DrawLines((Pen $K.blue 3), $pts.ToArray()) }
    for ($s = 0; $s -le $last; $s++) { $p = MapPt $order[$s].x $order[$s].y; $c = if ($order[$s].k -eq 'accept') { $K.gold } elseif ($order[$s].k -eq 'turnin') { $K.green } else { $K.red }; Dot $g $p[0] $p[1] 4.5 $c (Alpha $K.bg 255) 1.5 }
    $hd = $pts[$pts.Count - 1]; Glow $g $hd.X $hd.Y 6 $K.text; Dot $g $hd.X $hd.Y 5.5 $K.text (Alpha $K.bg 255) 2
  }
  # hubs
  foreach ($hub in $hubs) {
    $p = MapPt $hub.x $hub.y; $r = (7 + [Math]::Min(8, $hub.npcs)) * $pHub
    if ($r -gt 0.5) { Glow $g $p[0] $p[1] $r $K.text; Dot $g $p[0] $p[1] $r (Alpha $K.panel2 230) $K.text 2 }
    if ($pHub -ge 1) { [void](Chip $g ($p[0] + $r + 4) ($p[1] - 10) $hub.name $K.bg (Alpha $K.text 230) $FONTS.small) }
  }
  # the pruning reasons: a few, where they happen
  if ($pPrune -gt 0.25 -and $pPlan -lt 0.3) {
    $al = [int](255 * [Math]::Min(1.0, ($pPrune - 0.25) * 2) * (1 - $pPlan * 3))
    # one chip per reason, nudged down until it overlaps no other
    $shown = 0; $usedTxt = @{}; $boxes = New-Object System.Collections.Generic.List[System.Drawing.RectangleF]
    foreach ($hb in $hubs) { $hp = MapPt $hb.x $hb.y; $boxes.Add((New-Object System.Drawing.RectangleF ([float]($hp[0] - 14)), ([float]($hp[1] - 14)), ([float]($g.MeasureString($hb.name, $FONTS.small).Width + 50)), 28)) } # the hub labels too
    foreach ($q in ($cutOnes + ($laterOnes | Sort-Object xp -Descending | Select-Object -First 2))) {
      if ($shown -ge 4 -or $al -le 0) { break }
      $e = Ends $q; $b = $e[1]; $txt = if ($q.status -eq 'cut') { $q.why } else { "level $($q.level): later" }
      if ($usedTxt[$txt]) { continue }; $usedTxt[$txt] = $true
      $c = if ($q.status -eq 'cut') { $K.red } else { $K.gold }
      $cw = $g.MeasureString($txt, $FONTS.small).Width + 14; $cx = [Math]::Min($W - $cw - 8, $b[0] + 8); $cy = $b[1] + 6
      for ($try = 0; $try -lt 8; $try++) { $box = New-Object System.Drawing.RectangleF ([float]$cx), ([float]$cy), ([float]$cw), 22; $hit = $false; foreach ($o in $boxes) { if ($o.IntersectsWith($box)) { $hit = $true } }; if (-not $hit) { break }; $cy += 24 }
      $boxes.Add((New-Object System.Drawing.RectangleF ([float]$cx), ([float]$cy), ([float]$cw), 22))
      [void](Chip $g $cx $cy $txt (Alpha $K.bg $al) (Alpha $c $al) $FONTS.small); $shown++
    }
  }
  # captions and the tally
  $nAll = $quests.Count; $nCut = $cutOnes.Count; $nLater = $laterOnes.Count; $nDone = $doneOnes.Count
  if ($fi -lt $BEAT.spokes) { Caption $g $W 'THE ZONE' $K.violet "$($gd.zone) at level $($gd.level): the hubs" 'Where quest givers stand together - towns and camps you come back to' }
  elseif ($fi -lt $BEAT.chains) { Caption $g $W 'SPOKES' $K.blue "$nAll quests: each one a trip out from its giver" 'Out to where you do it, and back to hand it in - far spokes cost the most' }
  elseif ($fi -lt $BEAT.prune) { Caption $g $W 'CHAINS' $K.violet 'Some only open after another' 'A cheap first step stays when the payoff is further down the chain' }
  elseif ($fi -lt $BEAT.plan) { Caption $g $W 'PRUNE' $K.red "$nCut cut, $nLater for later, $nDone on this leg" 'Weighed by XP against the walk, kills and drops; what can''t be done yet waits' }
  else { Caption $g $W 'THE PLAN' $K.green "One pass: $($order.Count) stops through the hubs" 'Objectives that share ground done together, back to a hub to hand in' }
  $g.Dispose(); $frames.Add($fr.bmp)
}
Save-Frames $frames (Join-Path $ROOT $Out) 6 500 @{ 11 = 140; 35 = 150; 49 = 150; 71 = 170 }
