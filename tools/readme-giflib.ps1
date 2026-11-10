# Shared by the README animation scripts: save a list of bitmaps as a looping GIF (GDI+ multi-frame save; the frame
# delay goes in PropertyItem 0x5100 on the first frame, the loop count in 0x5101).
Add-Type -AssemblyName System.Drawing
function Save-Gif($imgs, [string]$outPath, [int]$delayCs = 7, [int]$lastCs = 250, $holdAt = @{}) {
  # frames as PNG, then tools/gifenc.js: one palette, only the changed rectangle per frame (GDI+'s own GIF writer
  # stored every frame in full, dithered - 7 MB for 40 frames of a map)
  $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('fr-gif-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force $dir | Out-Null
  for ($k = 0; $k -lt $imgs.Count; $k++) { $imgs[$k].Save((Join-Path $dir ('frame-{0:D3}.png' -f $k)), [System.Drawing.Imaging.ImageFormat]::Png) }
  $hold = ($holdAt.Keys | ForEach-Object { "$($_):$($holdAt[$_])" }) -join ','
  $outFull = [System.IO.Path]::GetFullPath($outPath)
  & node (Join-Path $PSScriptRoot 'gifenc.js') $dir $outFull $delayCs $lastCs $hold
  Remove-Item -Recurse -Force $dir
}
# both continents from the zone images, dimmed (tools/readme-world.js gives the layout)
function New-WorldBackground($j, [int]$W, [int]$H) {
  $bg = New-Object System.Drawing.Bitmap $W, $H
  $g = [System.Drawing.Graphics]::FromImage($bg); $g.InterpolationMode = 'HighQualityBicubic'
  $g.Clear([System.Drawing.Color]::FromArgb(255, 14, 18, 30))
  foreach ($z in $j.zones) {
    $img = [System.Drawing.Image]::FromFile($z.png)
    $g.DrawImage($img, [float]$z.x, [float]$z.y, [float]$z.w, [float]$z.h); $img.Dispose()
  }
  # dim, so the route reads on top
  $g.FillRectangle((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(120, 10, 12, 20))), 0, 0, $W, $H)
  $f = New-Object System.Drawing.Font 'Segoe UI', 10, ([System.Drawing.FontStyle]::Bold)
  foreach ($p in $j.panels) { $g.DrawString($p.name, $f, (New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(200, 220, 220, 230))), [float]($p.x + 4), [float]($H - 22)) }
  $g.Dispose()
  # softened (drawn at half size and back): flat areas compress far better in a GIF than the terrain's fine detail
  $half = New-Object System.Drawing.Bitmap ([int]($W / 2)), ([int]($H / 2)); $gh = [System.Drawing.Graphics]::FromImage($half); $gh.InterpolationMode = 'HighQualityBilinear'; $gh.DrawImage($bg, 0, 0, [int]($W / 2), [int]($H / 2)); $gh.Dispose()
  $soft = New-Object System.Drawing.Bitmap $W, $H; $gs = [System.Drawing.Graphics]::FromImage($soft); $gs.InterpolationMode = 'HighQualityBilinear'; $gs.DrawImage($half, 0, 0, $W, $H); $gs.Dispose()
  return $soft
}
