# README animation 5: ten simulated players on one plan (tools/readme-race.js -> tools/readme-data/personas.json).
# A shared clock runs; each lane fills with that player's progress to 60 and finishes when its own playthrough does.
# usage: powershell -File tools/readme-race.ps1 [out.gif]
param([string]$Out = 'docs/img/personas.gif')
. (Join-Path $PSScriptRoot 'readme-kit.ps1')
$ROOT = Split-Path $PSScriptRoot -Parent
$j = Get-Content (Join-Path $PSScriptRoot 'readme-data/personas.json') -Raw | ConvertFrom-Json
$ps = @($j.personas); $np = $ps.Count
$W = 760; $H = 64 + 18 + $np * 34 + 46
$maxA = ($ps | Measure-Object -Property actions -Maximum).Maximum
$frames = New-Object System.Collections.Generic.List[System.Drawing.Bitmap]
$laneX = 250; $laneW = $W - $laneX - 96
$total = 70
function LevelAt($pp, [double]$frac) { $lv = @($pp.levels); $i = [Math]::Min(60, [int][Math]::Floor($frac * 60)); [int]$lv[$i] }
for ($fi = 0; $fi -le $total + 14; $fi++) {
  $fr = New-Frame $W $H; $g = $fr.g
  $clock = [Math]::Min(1.0, $fi / $total) * $maxA
  $done = @($ps | Where-Object { $clock -ge $_.actions }).Count
  if ($fi -le $total) { Caption $g $W 'SIMULATED' $K.violet "Ten players, one plan: the $($j.plan) 1-60" 'A bot plays the real addon from the card: each one plays it differently' }
  else { Caption $g $W 'ALL 60' $K.green "$done of $np reached 60 - no check broken" 'Every route is played like this before it ships: card, arrow and map pins must agree at every step' }
  for ($i = 0; $i -lt $np; $i++) {
    $pp = $ps[$i]; $y = 82 + $i * 34
    $frac = [Math]::Min(1.0, $clock / $pp.actions); $lv = LevelAt $pp $frac; $fin = $frac -ge 1
    $g.DrawString($pp.persona, $FONTS.cap, (Brush $K.text), 18, [float]$y)
    $g.DrawString($pp.about, $FONTS.small, (Brush $K.sub), 18, [float]($y + 17))
    # the lane: its length is how much work this player's playthrough is; the fill is how far they are
    $len = $laneW * $pp.actions / $maxA
    Card $g $laneX ($y + 8) ([float]$len) 14 $K.panel2 7
    $c = if ($fin) { $K.green } else { Mix $K.violet $K.blue ($lv / 60.0) }
    if ($frac -gt 0) { Card $g $laneX ($y + 8) ([float][Math]::Max(8, $len * $frac)) 14 $c 7 }
    if ($fin) { [void](Chip $g ($laneX + $len + 8) ($y + 4) '60' $K.bg $K.green $FONTS.chip) }
    else { $g.DrawString("$lv", $FONTS.chip, (Brush $K.text), [float]($laneX + $len * $frac + 6), [float]($y + 7)) }
  }
  $g.DrawString(('{0:N0} actions' -f [int]$clock), $FONTS.small, (Brush $K.faint), [float]$laneX, [float]($H - 30))
  $g.DrawString('lane length = how much each one had to do', $FONTS.small, (Brush $K.faint), [float]($W - 300), [float]($H - 30))
  $g.Dispose(); $frames.Add($fr.bmp)
}
Save-Frames $frames (Join-Path $ROOT $Out) 6 400 @{ 0 = 80 }
