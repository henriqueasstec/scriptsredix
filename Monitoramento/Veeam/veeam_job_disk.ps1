# Garante output correto no PS7
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $PSStyle.OutputRendering = 'PlainText'
}

# Localiza CorePath (64-bit e fallback WOW6432Node)
$regPaths = @(
    "HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication\",
    "HKLM:\SOFTWARE\WOW6432Node\Veeam\Veeam Backup and Replication\"
)

$InstallPath = foreach ($path in $regPaths) {
    if (Test-Path $path) {
        (Get-ItemProperty -Path $path -ErrorAction Stop).CorePath
        break
    }
}

if (-not $InstallPath) {
    throw "Não foi possível localizar o CorePath do Veeam no registro."
}

# Prioriza CorePath no binding de DLLs
$env:PATH = "$InstallPath;$env:PATH"

# Carrega assemblies principais do CorePath
@(
    "Veeam.Backup.Common.dll",
    "Veeam.Backup.Core.dll",
    "Veeam.Backup.Configuration.dll"
) | ForEach-Object {
    $full = Join-Path $InstallPath $_
    if (Test-Path $full) {
        [System.Reflection.Assembly]::LoadFrom($full) | Out-Null
    }
}

Import-Module Veeam.Backup.PowerShell -ErrorAction Stop -WarningAction SilentlyContinue

# Cache de repositórios
$script:AllBackupRepositories       = @()
$script:AllScaleOutRepositories     = @()
$script:AllObjectStorageRepositories = @()

try { $script:AllBackupRepositories = @(Get-VBRBackupRepository -WarningAction SilentlyContinue) } catch {}
try { $script:AllScaleOutRepositories = @(Get-VBRBackupRepository -ScaleOut -WarningAction SilentlyContinue) } catch {}
try {
    if (Get-Command Get-VBRObjectStorageRepository -ErrorAction SilentlyContinue) {
        $script:AllObjectStorageRepositories = @(Get-VBRObjectStorageRepository -WarningAction SilentlyContinue)
    }
} catch {}

function Get-SafeMemberValue {
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    if ($null -eq $Object) { return $null }

    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }

    $method = $Object.PSObject.Methods[$Name]
    if ($method -and $method.OverloadDefinitions.Count -gt 0) {
        try { return $Object.$Name() } catch { return $null }
    }

    return $null
}

function Find-RepositoryById {
    param($Id)

    if (-not $Id) { return $null }

    foreach ($repo in @(
        $script:AllBackupRepositories
        $script:AllScaleOutRepositories
        $script:AllObjectStorageRepositories
    )) {
        if ($repo.Id -eq $Id) { return $repo }
    }

    return $null
}

function Test-IsScaleOutRepository {
    param($Repository)

    if ($null -eq $Repository) { return $false }
    if ($Repository.PSObject.Properties['Extent'] -or $Repository.PSObject.Properties['Extents']) { return $true }

    $repoId = Get-SafeMemberValue -Object $Repository -Name 'Id'
    if ($repoId -and ($script:AllScaleOutRepositories | Where-Object Id -eq $repoId)) { return $true }

    $repoType    = [string](Get-SafeMemberValue -Object $Repository -Name 'Type')
    $typeDisplay = [string](Get-SafeMemberValue -Object $Repository -Name 'TypeDisplay')
    $name        = [string](Get-SafeMemberValue -Object $Repository -Name 'Name')

    return (
        $repoType -match 'ScaleOut|SOBR' -or
        $typeDisplay -match 'Scale.?Out|SOBR' -or
        $name -match '^SOBR[_\-]'
    )
}

function Resolve-RepositoryObjectFromJob {
    param($Job)

    if ($null -eq $Job) { return $null }

    foreach ($name in 'GetTargetRepository','FindTargetRepository','GetBackupTargetRepository','GetRepository') {
        $value = Get-SafeMemberValue -Object $Job -Name $name
        if ($value) { return $value }
    }

    foreach ($name in 'TargetRepository','BackupRepository','Repository','RepositoryRef','Target') {
        $value = Get-SafeMemberValue -Object $Job -Name $name
        if ($value -and ($value.PSObject.Properties['Id'] -or $value.PSObject.Properties['Name'])) {
            return $value
        }
    }

    foreach ($name in 'RepositoryId','TargetRepositoryId') {
        $repoId = Get-SafeMemberValue -Object $Job -Name $name
        $repo = Find-RepositoryById -Id $repoId
        if ($repo) { return $repo }
    }

    $jobOptions = $null
    foreach ($name in 'GetOptions','Options') {
        $jobOptions = Get-SafeMemberValue -Object $Job -Name $name
        if ($jobOptions) { break }
    }

    if ($jobOptions) {
        foreach ($containerName in 'BackupStorageOptions','StorageOptions','TargetOptions','Options') {
            $container = Get-SafeMemberValue -Object $jobOptions -Name $containerName
            if (-not $container) { continue }

            foreach ($idName in 'RepositoryId','TargetRepositoryId') {
                $repo = Find-RepositoryById -Id (Get-SafeMemberValue -Object $container -Name $idName)
                if ($repo) { return $repo }
            }

            foreach ($repoName in 'Repository','TargetRepository') {
                $repoObj = Get-SafeMemberValue -Object $container -Name $repoName
                if ($repoObj) { return $repoObj }
            }
        }
    }

    return $null
}

function Get-ObjectStorageLabel {
    param($Repository)

    $repoName    = [string](Get-SafeMemberValue -Object $Repository -Name 'Name')
    $repoType    = [string](Get-SafeMemberValue -Object $Repository -Name 'Type')
    $typeDisplay = [string](Get-SafeMemberValue -Object $Repository -Name 'TypeDisplay')

    foreach ($value in @($repoName, $repoType, $typeDisplay)) {
        if ($value -match 'S3|AWS') {
            return 'Amazon S3'
        }
    }

    foreach ($name in 'BucketName','Bucket','ContainerName','Container','ObjectStorageType','CloudType') {
        $value = [string](Get-SafeMemberValue -Object $Repository -Name $name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            if ($value -match 'S3|AWS') {
                return 'Amazon S3'
            }
            return 'Object Storage'
        }
    }

    return 'Object Storage'
}

function Get-RepositoryTargetString {
    param($Repository)

    if ($null -eq $Repository) { return $null }

    foreach ($name in 'Path','FriendlyPath','MountPath','Folder','SharePath') {
        $value = Get-SafeMemberValue -Object $Repository -Name $name
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            return [string]$value
        }
    }

    if ((Get-SafeMemberValue -Object $Repository -Name 'IsObjectStorageRepository') -eq $true) {
        return Get-ObjectStorageLabel -Repository $Repository
    }

    foreach ($name in 'BucketName','Bucket','ContainerName','Container','ObjectStorageType','CloudType') {
        $value = Get-SafeMemberValue -Object $Repository -Name $name
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            return Get-ObjectStorageLabel -Repository $Repository
        }
    }

    return $null
}

function Get-RepositoryKind {
    param($Repository)

    if ($null -eq $Repository) { return 'Unknown' }

    $typeNames   = @($Repository.PSObject.TypeNames) -join ' | '
    $repoType    = [string](Get-SafeMemberValue -Object $Repository -Name 'Type')
    $typeDisplay = [string](Get-SafeMemberValue -Object $Repository -Name 'TypeDisplay')

    if (Test-IsScaleOutRepository -Repository $Repository) {
        return 'SOBR'
    }

    if ((Get-SafeMemberValue -Object $Repository -Name 'IsObjectStorageRepository') -eq $true) {
        return 'Object Storage'
    }

    foreach ($name in 'BucketName','Bucket','ContainerName','Container','ObjectStorageType','CloudType') {
        $value = Get-SafeMemberValue -Object $Repository -Name $name
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            return 'Object Storage'
        }
    }

    if ($typeNames -match 'ObjectStorage') {
        return 'Object Storage'
    }

    if (
        (Get-SafeMemberValue -Object $Repository -Name 'IsLinuxHardened') -eq $true -or
        $repoType -match 'LinuxHardened' -or
        $typeDisplay -eq 'Hardened'
    ) {
        return 'Hardened Linux'
    }

    foreach ($name in 'IsHardenedRepository','IsImmutable','UseImmutability','EnableImmutability','ImmutabilityEnabled') {
        if ((Get-SafeMemberValue -Object $Repository -Name $name) -eq $true) {
            return 'Hardened Linux'
        }
    }

    $server = $null
    foreach ($name in 'Server','Host','RepositoryHost') {
        $server = Get-SafeMemberValue -Object $Repository -Name $name
        if ($server) { break }
    }

    if ($server) {
        foreach ($name in 'Type','Platform','OSPlatform') {
            $value = [string](Get-SafeMemberValue -Object $server -Name $name)
            if ($value -match 'Linux') { return 'Linux' }
            if ($value -match 'Windows|Win') { return 'Windows' }
        }
    }

    $path = Get-RepositoryTargetString -Repository $Repository
    if ($path) {
        if ($path -match '^[A-Za-z]:\\') { return 'Windows' }
        if ($path -match '^/')           { return 'Linux' }
        if ($path -match '^\\\\')        { return 'Windows' }
    }

    return 'Unknown'
}

function Format-StandaloneRepositoryDetail {
    param($Repository)

    if ($null -eq $Repository) {
        return "Disk [ Unknown ( Unknown: Unknown ) ]"
    }

    $repoName = [string](Get-SafeMemberValue -Object $Repository -Name 'Name')
    if ([string]::IsNullOrWhiteSpace($repoName)) {
        $repoName = 'Unknown'
    }

    $repoKind = Get-RepositoryKind -Repository $Repository
    $target   = Get-RepositoryTargetString -Repository $Repository

    if ($repoKind -eq 'Object Storage' -and [string]::IsNullOrWhiteSpace($target)) {
        $target = 'Object Storage'
    }

    if ([string]::IsNullOrWhiteSpace($target)) {
        $target = 'Unknown'
    }

    $prefix = 'Disk'
    if ($repoKind -eq 'Object Storage' -and $target -eq 'Amazon S3') {
        $prefix = 'S3'
    }

    return "$prefix [ $repoName ( $repoKind`: $target ) ]"
}

function Format-SobrExtentItem {
    param($Extent)

    if ($null -eq $Extent) { return $null }

    $repo = $null
    foreach ($name in 'Repository','Extent','RepositoryRef') {
        $repo = Get-SafeMemberValue -Object $Extent -Name $name
        if ($repo) { break }
    }
    if (-not $repo) { $repo = $Extent }

    $repoName = [string](Get-SafeMemberValue -Object $repo -Name 'Name')
    if ([string]::IsNullOrWhiteSpace($repoName)) { $repoName = 'Unknown' }

    $target = Get-RepositoryTargetString -Repository $repo
    if ([string]::IsNullOrWhiteSpace($target)) { $target = 'Unknown' }

    return "(${repoName}: $target)"
}

function Format-SobrObjectTierItems {
    param(
        $Sobr,
        [string[]]$CandidatePropertyNames
    )

    $items = @()

    foreach ($propName in $CandidatePropertyNames) {
        $propValue = Get-SafeMemberValue -Object $Sobr -Name $propName
        if (-not $propValue) { continue }

        $values = if ($propValue -is [System.Collections.IEnumerable] -and -not ($propValue -is [string])) {
            @($propValue)
        } else {
            @($propValue)
        }

        foreach ($item in $values) {
            $name   = [string](Get-SafeMemberValue -Object $item -Name 'Name')
            $target = Get-RepositoryTargetString -Repository $item

            if ($name -and $target) {
                $items += "(${name}: $target)"
            } elseif ($name) {
                $items += "($name)"
            } else {
                $items += "($item)"
            }
        }
    }

    return @($items | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Format-SobrRepositoryDetail {
    param($Sobr)

    if ($null -eq $Sobr) {
        return 'SOBR [ Unknown ]'
    }

    $sobrName = [string](Get-SafeMemberValue -Object $Sobr -Name 'Name')
    if ([string]::IsNullOrWhiteSpace($sobrName)) { $sobrName = 'Unknown' }

    $parts = @()

    $perfItems = @()
    foreach ($extent in @(Get-SafeMemberValue -Object $Sobr -Name 'Extent')) {
        $item = Format-SobrExtentItem -Extent $extent
        if ($item) { $perfItems += $item }
    }
    if ($perfItems.Count -gt 0) {
        $parts += "Performance: $($perfItems -join ' ')"
    }

    $capacityItems = Format-SobrObjectTierItems -Sobr $Sobr -CandidatePropertyNames @(
        'CapacityExtent','CapacityTier','CapacityRepository','ObjectStorageRepository'
    )
    if ($capacityItems.Count -gt 0) {
        $parts += "Capacity: $($capacityItems -join ' ')"
    }

    if ($parts.Count -eq 0) {
        return "SOBR [ $sobrName ]"
    }

    return "SOBR [ $sobrName | $($parts -join ' | ') ]"
}

function Resolve-StorageDetailFromJob {
    param($Job)

    $repository = Resolve-RepositoryObjectFromJob -Job $Job
    if (-not $repository) { return 'Unknown' }

    if (Test-IsScaleOutRepository -Repository $repository) {
        $repoId   = Get-SafeMemberValue -Object $repository -Name 'Id'
        $repoName = [string](Get-SafeMemberValue -Object $repository -Name 'Name')

        $fullSobr = $null

        if ($repoId) {
            $fullSobr = $script:AllScaleOutRepositories | Where-Object Id -eq $repoId | Select-Object -First 1
        }

        if (-not $fullSobr -and $repoName) {
            $fullSobr = $script:AllScaleOutRepositories | Where-Object Name -eq $repoName | Select-Object -First 1
        }

        if ($fullSobr) {
            return Format-SobrRepositoryDetail -Sobr $fullSobr
        }

        return Format-SobrRepositoryDetail -Sobr $repository
    }

    return Format-StandaloneRepositoryDetail -Repository $repository
}

# Busca jobs
$JOBS = Get-VBRJob -WarningAction SilentlyContinue

foreach ($JOB in $JOBS) {

    # Sessão pode ser null em jobs que nunca rodaram
    $JOBSESSION = $null
    try { $JOBSESSION = $JOB.FindLastSession() } catch {}

    # ScheduleOptions pode ser null em alguns tipos de job
    $SCHEDULE = $null
    try { $SCHEDULE = $JOB.ScheduleOptions } catch {}

    if ($null -ne $JOBSESSION -and $null -ne $JOBSESSION.JobName) {

        $OptionsDailyEnabled        = $null
        $OptionsDailyKind           = $null
        $OptionsDailyDays           = $null
        $StartDateTimeLocal         = $null
        $OptionsMonthlyEnabled      = $null
        $OptionsMonthly             = $null
        $OptionsPeriodicallyEnabled = $null

        if ($SCHEDULE) {
            $StartDateTimeLocal = $SCHEDULE.StartDateTimeLocal

            if ($SCHEDULE.OptionsDaily) {
                $OptionsDailyEnabled = $SCHEDULE.OptionsDaily.Enabled
                $OptionsDailyKind    = $SCHEDULE.OptionsDaily.Kind
                $OptionsDailyDays    = $SCHEDULE.OptionsDaily.DaysSrv
            }

            if ($SCHEDULE.OptionsMonthly) {
                $OptionsMonthlyEnabled = $SCHEDULE.OptionsMonthly.Enabled
                $OptionsMonthly = $SCHEDULE.OptionsMonthly | Select-Object DayOfMonth, DayNumberInMonth, DayOfWeek
            }

            if ($SCHEDULE.OptionsPeriodically) {
                $OptionsPeriodicallyEnabled = $SCHEDULE.OptionsPeriodically.Enabled
            }
        }

        $RuntimeSeconds = 0
        if ($JOBSESSION.CreationTime -and $JOBSESSION.EndTime -and $JOBSESSION.EndTime -gt $JOBSESSION.CreationTime) {
            $RuntimeSeconds = [int](($JOBSESSION.EndTime - $JOBSESSION.CreationTime).TotalSeconds)
        }

        $StorageDetail = 'Unknown'
        try { $StorageDetail = Resolve-StorageDetailFromJob -Job $JOB } catch {}

        [PSCustomObject]@{
            JobName                    = $JOBSESSION.JobName
            ScheduleEnabled            = $JOB.IsScheduleEnabled
            OptionsDailyEnabled        = $OptionsDailyEnabled
            OptionsDailyKind           = $OptionsDailyKind
            OptionsDailyDays           = $OptionsDailyDays
            StartDateTimeLocal         = $StartDateTimeLocal
            OptionsMonthlyEnabled      = $OptionsMonthlyEnabled
            OptionsMonthly             = $OptionsMonthly
            OptionsPeriodicallyEnabled = $OptionsPeriodicallyEnabled
            Platform                   = $JOBSESSION.Platform
            JobTypeString              = $JOBSESSION.JobTypeString
            CreationTime               = $JOBSESSION.CreationTime
            EndTime                    = $JOBSESSION.EndTime
            State                      = $JOBSESSION.State
            BaseProgress               = $JOBSESSION.BaseProgress
            Result                     = $JOBSESSION.Result
            RuntimeSeconds             = $RuntimeSeconds
            StorageDetail              = $StorageDetail
            JobType                    = $JOB.TypeToString
        }
    }
}