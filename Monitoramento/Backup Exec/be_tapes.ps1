[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Import-Module BEMCLI -ErrorAction Stop

$libraries = Get-BERoboticLibraryDevice
$medias = Get-BEMedia

$result = @()

foreach ($library in $libraries) {

    if (-not $library.Name) { continue }

    $scratchMedia = @()

    foreach ($media in $medias) {

        if (-not $media.Name) { continue }

        if ($media.LocationName -ne $library.Name) { continue }

        if ([string]$media.MediaSet -ne "Scratch Media") { continue }

        if ($media.IsCleaningMedia) { continue }

        $scratchMedia += $media
    }

    $scratchMediaFreeCount = @($scratchMedia).Count

    $result += [PSCustomObject]@{
        LibraryName           = $library.Name
        ScratchMediaFreeCount = $scratchMediaFreeCount
    }
}

$result | ConvertTo-Json -Depth 3