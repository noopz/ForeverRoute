param([string]$In, [string]$Out, [int]$Scale = 2)
Add-Type -AssemblyName System.Drawing
$j = Get-Content $In -Raw | ConvertFrom-Json
$base = [System.Drawing.Bitmap]::FromFile($j.base)
# crop to the route (+ margin), keeping the aspect of yards
$xs = @($j.stops | ForEach-Object { $_.x }); $ys = @($j.stops | ForEach-Object { $_.y })
$cx0 = [Math]::Max(0, ($xs | Measure-Object -Minimum).Minimum - 6); $cx1 = [Math]::Min(100, ($xs | Measure-Object -Maximum).Maximum + 6)
$cy0 = [Math]::Max(0, ($ys | Measure-Object -Minimum).Minimum - 6); $cy1 = [Math]::Min(100, ($ys | Measure-Object -Maximum).Maximum + 6)
$srcRect = New-Object System.Drawing.RectangleF ([float]($cx0 / 100 * $base.Width)), ([float]($cy0 / 100 * $base.Height)), ([float](($cx1 - $cx0) / 100 * $base.Width)), ([float](($cy1 - $cy0) / 100 * $base.Height))
$H = 1100; $W = [int]($H * $srcRect.Width / $srcRect.Height); $side = 380
$bmp = New-Object System.Drawing.Bitmap ($W + $side), $H
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'; $g.InterpolationMode = 'HighQualityBicubic'
$g.Clear([System.Drawing.Color]::FromArgb(255, 18, 20, 26))
$g.DrawImage($base, (New-Object System.Drawing.RectangleF 0, 0, $W, $H), $srcRect, [System.Drawing.GraphicsUnit]::Pixel)
# darken the base slightly so the route pops
$g.FillRectangle((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(70, 0, 0, 0))), 0, 0, $W, $H)
function P($x, $y) { New-Object System.Drawing.PointF ([float](($x - $cx0) / ($cx1 - $cx0) * $W)), ([float](($y - $cy0) / ($cy1 - $cy0) * $H)) }
$kc = @{ accept = [System.Drawing.Color]::FromArgb(255, 245, 196, 66); turnin = [System.Drawing.Color]::FromArgb(255, 110, 220, 120); obj = [System.Drawing.Color]::FromArgb(255, 190, 140, 255); bonus = [System.Drawing.Color]::FromArgb(255, 90, 200, 255); fp = [System.Drawing.Color]::FromArgb(255, 120, 200, 255); bind = [System.Drawing.Color]::FromArgb(255, 120, 200, 255); train = [System.Drawing.Color]::FromArgb(255, 255, 140, 90); grind = [System.Drawing.Color]::FromArgb(255, 255, 110, 110) }
$def = [System.Drawing.Color]::FromArgb(255, 220, 220, 230)
# path: dark casing + bright line, colour fading from cyan (start) to orange (end)
$nseg = [Math]::Max(1, $j.segs.Count)
for ($i = 0; $i -lt $j.segs.Count; $i++) {
  $sgm = $j.segs[$i]; $pts = @($sgm.pts | ForEach-Object { P $_[0] $_[1] })
  if ($pts.Count -lt 2) { continue }
  $t = $i / $nseg
  $c = [System.Drawing.Color]::FromArgb(235, [int](80 + 175 * $t), [int](220 - 80 * $t), [int](255 - 200 * $t))
  $case = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(200, 0, 0, 0)), 6
  $pen = New-Object System.Drawing.Pen $c, 3
  if ($sgm.straight) { $pen.DashStyle = 'Dash' }
  $case.LineJoin = 'Round'; $pen.LineJoin = 'Round'
  $g.DrawLines($case, $pts); $g.DrawLines($pen, $pts)
}
# stops: group stops that share a spot so labels don't pile up
$font = New-Object System.Drawing.Font 'Segoe UI', 9, ([System.Drawing.FontStyle]::Bold)
$small = New-Object System.Drawing.Font 'Segoe UI', 9
$big = New-Object System.Drawing.Font 'Segoe UI', 15, ([System.Drawing.FontStyle]::Bold)
$white = [System.Drawing.Brushes]::White; $black = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 12, 12, 16))
$groups = @()
foreach ($s in $j.stops) {
  $hit = $null
  foreach ($gr in $groups) { if ([Math]::Abs($gr.x - $s.x) -lt 0.9 -and [Math]::Abs($gr.y - $s.y) -lt 0.9) { $hit = $gr; break } }
  if ($hit) { $hit.items += $s } else { $groups += [pscustomobject]@{ x = $s.x; y = $s.y; items = @($s) } }
}
foreach ($gr in $groups) {
  $p = P $gr.x $gr.y; $r = 11
  $k = $gr.items[0].k; $c = $kc[$k]; if (-not $c) { $c = $def }
  $g.FillEllipse($black, $p.X - $r - 2, $p.Y - $r - 2, 2 * $r + 4, 2 * $r + 4)
  $g.FillEllipse((New-Object System.Drawing.SolidBrush $c), $p.X - $r, $p.Y - $r, 2 * $r, 2 * $r)
  $num = "$($gr.items[0].n)"; if ($gr.items.Count -gt 1) { $num = "$($gr.items[0].n)" }
  $sz = $g.MeasureString($num, $font); $g.DrawString($num, $font, $black, $p.X - $sz.Width / 2, $p.Y - $sz.Height / 2)
  if ($gr.items.Count -gt 1) {
    $extra = "+" + ($gr.items.Count - 1)
    $g.DrawString($extra, $small, $black, $p.X + $r + 1, $p.Y - $r - 1); $g.DrawString($extra, $small, $white, $p.X + $r, $p.Y - $r - 2)
  }
}
# side panel: title + step list
$x0 = $W + 16; $y = 14
$g.DrawString("$($j.zone) leg", $big, $white, $x0, $y); $y += 30
$sub = "steps $($j.from)-$($j.to)  $([char]0xB7)  level $($j.lvlFrom) -> $($j.lvlTo)  $([char]0xB7)  $([Math]::Round($j.yards / 1000, 1))k yd on foot"
$g.DrawString($sub, $small, (New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 150, 160, 180))), $x0, $y); $y += 24
foreach ($gr in $groups) {
  foreach ($s in $gr.items) {
    if ($y -gt $H - 30) { break }
    $c = $kc[$s.k]; if (-not $c) { $c = $def }
    $g.FillEllipse((New-Object System.Drawing.SolidBrush $c), $x0, $y + 4, 8, 8)
    $txt = "$($s.n). $($s.label)"; if ($txt.Length -gt 46) { $txt = $txt.Substring(0, 45) + [char]0x2026 }
    $g.DrawString($txt, $small, $white, $x0 + 12, $y); $y += 15
  }
}
if ($j.elsewhere.Count -gt 0 -and $y -lt $H - 40) {
  $y += 6; $g.DrawString("Also in this leg (other zones):", $font, (New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 150, 160, 180))), $x0, $y); $y += 16
  foreach ($s in $j.elsewhere) { if ($y -gt $H - 20) { break }; $txt = "$($s.n). $($s.k) $($s.label) ($($s.zone))"; if ($txt.Length -gt 50) { $txt = $txt.Substring(0, 49) + [char]0x2026 }; $g.DrawString($txt, $small, $white, $x0 + 12, $y); $y += 15 }
}
# legend
$ly = $H - 22; $lx = 12
foreach ($k in 'accept', 'obj', 'turnin', 'bonus') { $g.FillEllipse((New-Object System.Drawing.SolidBrush $kc[$k]), $lx, $ly + 3, 10, 10); $g.DrawString($k, $font, $white, $lx + 13, $ly); $lx += 80 }
$g.DrawString("path: cyan = start -> orange = end (terrain + building aware)", $small, $white, $lx + 10, $ly)
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose(); $base.Dispose()
"wrote $Out"
