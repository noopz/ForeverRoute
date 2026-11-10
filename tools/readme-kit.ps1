# The README animations' shared look: one palette, one type style, easing, rounded cards, a caption bar, chips, and
# saving frames as a GIF (tools/readme-giflib.ps1 -> tools/gifenc.js: one palette, only the changed area per frame).
. (Join-Path $PSScriptRoot 'readme-giflib.ps1')
Add-Type -AssemblyName System.Drawing

function C([int]$r, [int]$g, [int]$b, [int]$a = 255) { [System.Drawing.Color]::FromArgb($a, $r, $g, $b) }
$script:K = @{
  bg = (C 13 16 27); panel = (C 22 26 40); panel2 = (C 30 35 52); line = (C 52 58 80)
  text = (C 236 238 245); sub = (C 150 156 178); faint = (C 92 98 120)
  gold = (C 242 181 68); red = (C 232 98 90); green = (C 92 201 122); blue = (C 96 178 255); violet = (C 170 130 255)
}
function Brush($c) { New-Object System.Drawing.SolidBrush $c }
function Pen($c, [float]$ww = 1) { $p = New-Object System.Drawing.Pen $c, $ww; $p.StartCap = 'Round'; $p.EndCap = 'Round'; $p.LineJoin = 'Round'; $p }
function Font([float]$size, [string]$style = 'Regular', [string]$face = 'Segoe UI') {
  if ($style -eq 'Semibold') { return New-Object System.Drawing.Font 'Segoe UI Semibold', $size, ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel) }
  New-Object System.Drawing.Font $face, $size, ([System.Drawing.FontStyle]::$style), ([System.Drawing.GraphicsUnit]::Pixel)
}
$script:FONTS = @{ title = (Font 22 'Bold'); cap = (Font 15 'Semibold'); body = (Font 14); small = (Font 12); big = (Font 34 'Bold'); chip = (Font 12 'Semibold'); num = (Font 13 'Bold') }

# easing and blending
function Ease([double]$t) { if ($t -le 0) { return 0 } if ($t -ge 1) { return 1 } if ($t -lt 0.5) { return 4 * $t * $t * $t } return 1 - [Math]::Pow(-2 * $t + 2, 3) / 2 }
function Lerp([double]$a, [double]$b, [double]$t) { $a + ($b - $a) * $t }
function Mix($c1, $c2, [double]$t) { C ([int](Lerp $c1.R $c2.R $t)) ([int](Lerp $c1.G $c2.G $t)) ([int](Lerp $c1.B $c2.B $t)) ([int](Lerp $c1.A $c2.A $t)) }
function Alpha($c, [int]$a) { C $c.R $c.G $c.B $a }

function New-Frame([int]$W, [int]$H) {
  $bmp = New-Object System.Drawing.Bitmap $W, $H
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'; $g.InterpolationMode = 'HighQualityBilinear'; $g.PixelOffsetMode = 'HighQuality'
  $g.Clear($K.bg)
  return @{ bmp = $bmp; g = $g; W = $W; H = $H }
}
function RoundPath([float]$x, [float]$y, [float]$ww, [float]$hh, [float]$r) {
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d = 2 * $r
  $p.AddArc($x, $y, $d, $d, 180, 90); $p.AddArc($x + $ww - $d, $y, $d, $d, 270, 90)
  $p.AddArc($x + $ww - $d, $y + $hh - $d, $d, $d, 0, 90); $p.AddArc($x, $y + $hh - $d, $d, $d, 90, 90); $p.CloseFigure()
  return $p
}
function Card($g, [float]$x, [float]$y, [float]$ww, [float]$hh, $fill, [float]$r = 10, $border = $null) {
  $p = RoundPath $x $y $ww $hh $r; $g.FillPath((Brush $fill), $p); if ($border) { $g.DrawPath((Pen $border 1), $p) }
}
# a pill with text, left-anchored at x (or right-anchored when $alignRight); returns its width
function Chip($g, [float]$x, [float]$y, [string]$text, $fg, $bg, $font = $FONTS.chip, [switch]$alignRight) {
  $sz = $g.MeasureString($text, $font); $ww = [float]($sz.Width + 14); $hh = [float]($font.Size + 10)
  if ($alignRight) { $x -= $ww }
  Card $g $x $y $ww $hh $bg ($hh / 2)
  $g.DrawString($text, $font, (Brush $fg), [float]($x + 7), [float]($y + 4)); return $ww
}
# the caption bar: a colored step badge, a title and a line under it
function Caption($g, [int]$W, [string]$badge, $badgeColor, [string]$title, [string]$sub, [double]$fade = 1) {
  $g.FillRectangle((Brush (Alpha $K.bg 235)), 0, 0, $W, 64)
  $g.DrawLine((Pen $K.line 1), 0, 64, $W, 64)
  $a = [int](255 * $fade)
  $bw = 0
  if ($badge) { $bw = Chip $g 16 13 $badge (Alpha $K.bg $a) (Alpha $badgeColor $a) $FONTS.chip; $bw += 10 }
  $g.DrawString($title, $FONTS.title, (Brush (Alpha $K.text $a)), [float](16 + $bw), 6)
  if ($sub) { $g.DrawString($sub, $FONTS.small, (Brush (Alpha $K.sub $a)), [float](17 + $bw), 38) }
}
function Dot($g, [float]$x, [float]$y, [float]$r, $fill, $ring = $null, [float]$ringW = 2) {
  $g.FillEllipse((Brush $fill), $x - $r, $y - $r, 2 * $r, 2 * $r)
  if ($ring) { $g.DrawEllipse((Pen $ring $ringW), $x - $r, $y - $r, 2 * $r, 2 * $r) }
}
function Glow($g, [float]$x, [float]$y, [float]$r, $c) {
  foreach ($ring in 3, 2, 1) { $rr = $r * (1 + 0.6 * $ring); Dot $g $x $y $rr (Alpha $c (18 * (4 - $ring))) }
}
function Save-Frames($frames, [string]$outPath, [int]$delayCs, [int]$lastCs, $hold = @{}) {
  # FR_PEEK="20,50" FR_PEEK_DIR=<dir>: those frames as PNG, straight from the renderer (Windows' GIF reader composes
  # the encoder's partial frames wrongly, so frames pulled out of the GIF can't be trusted for a check)
  if ($env:FR_PEEK) { foreach ($n in $env:FR_PEEK.Split(',')) { $i = [int]$n; if ($i -lt $frames.Count) { $frames[$i].Save((Join-Path $env:FR_PEEK_DIR ("peek-$i.png")), [System.Drawing.Imaging.ImageFormat]::Png) } } }
  $imgs = New-Object System.Collections.Generic.List[System.Drawing.Bitmap]
  foreach ($f in $frames) { $imgs.Add($f) }
  Save-Gif $imgs $outPath $delayCs $lastCs $hold
  "{0}: {1} frames, {2} KB" -f $outPath, $imgs.Count, [int]((Get-Item $outPath).Length / 1KB)
}
