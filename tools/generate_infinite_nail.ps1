Add-Type -AssemblyName System.Drawing

$size = 24
$bitmap = [System.Drawing.Bitmap]::new($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)

$transparent = [System.Drawing.Color]::Transparent
$black = [System.Drawing.Color]::Black
$white = [System.Drawing.Color]::White

for ($y = 0; $y -lt $size; $y++) {
    for ($x = 0; $x -lt $size; $x++) {
        $bitmap.SetPixel($x, $y, $transparent)
    }
}

# A broad, stepped nail head. The horizontal lugs keep its fastener silhouette.
$rows = @(
    '........OOOOOOOO........',
    '......OOOOOOOOOOOO......',
    '....OOOWWWWWWWWWWOOO....',
    '...OOWWWWWWWWWWWWWWOO...',
    '..OWWWWWWWWWWWWWWWWWWO..',
    '.OWWWWWWWWWWWWWWWWWWWWO.',
    'OWWWWWWWWWWWWWWWWWWWWWWO',
    'OWWWWWWWWWWWWWWWWWWWWWWO',
    'OWWWWWWWWWWWWWWWWWWWWWWO',
    'OWWWWWWWWWWWWWWWWWWWWWWO',
    'OWWWWWWWWWWWWWWWWWWWWWWO',
    'OWWWWWWWWWWWWWWWWWWWWWWO',
    'OWWWWWWWWWWWWWWWWWWWWWWO',
    'OWWWWWWWWWWWWWWWWWWWWWWO',
    'OWWWWWWWWWWWWWWWWWWWWWWO',
    'OWWWWWWWWWWWWWWWWWWWWWWO',
    '.OWWWWWWWWWWWWWWWWWWWWO.',
    '..OWWWWWWWWWWWWWWWWWWO..',
    '...OOWWWWWWWWWWWWWWOO...',
    '....OOOWWWWWWWWWWOOO....',
    '......OOOOOOOOOOOO......',
    '........OOOOOOOO........'
)

$palette = @{
    'O' = $black
    'W' = $white
}

for ($y = 0; $y -lt $rows.Count; $y++) {
    for ($x = 0; $x -lt $rows[$y].Length; $x++) {
        $key = [string]$rows[$y][$x]
        if ($palette.ContainsKey($key)) {
            $bitmap.SetPixel($x, $y, $palette[$key])
        }
    }
}

$infinity = @(
    '..BBB......BBB..',
    '.BB.BB....BB.BB.',
    'BB...BB..BB...BB',
    'B.....BBBB.....B',
    'B.....BBBB.....B',
    'BB...BB..BB...BB',
    '.BB.BB....BB.BB.',
    '..BBB......BBB..'
)

for ($y = 0; $y -lt $infinity.Count; $y++) {
    for ($x = 0; $x -lt $infinity[$y].Length; $x++) {
        $symbol = $infinity[$y][$x]
        if ($symbol -eq 'B') {
            $bitmap.SetPixel($x + 4, $y + 8, $black)
        }
    }
}

$output = Join-Path $PSScriptRoot '..\actor\nail\asset\infinite_nail.png'
$outputPath = [System.IO.Path]::GetFullPath($output)
$bitmap.Save($outputPath, [System.Drawing.Imaging.ImageFormat]::Png)
$bitmap.Dispose()
