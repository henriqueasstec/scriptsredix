# Garante output correto no PS7
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $PSStyle.OutputRendering = 'PlainText'
}

# Localiza CorePath (64-bit e fallback WOW6432Node)
$regPaths = @(
    "HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication\",
    "HKLM:\SOFTWARE\WOW6432Node\Veeam\Veeam Backup and Replication\"
)

$InstallPath = $null
foreach ($path in $regPaths) {
    if (Test-Path $path) {
        $InstallPath = (Get-ItemProperty -Path $path -ErrorAction Stop).CorePath
        break
    }
}

if (-not $InstallPath) {
    throw "Não foi possível localizar o CorePath do Veeam no registro."
}

# Prioriza CorePath no binding de DLLs
$env:PATH = "$InstallPath;$env:PATH"

# Carrega assemblies principais do CorePath para evitar mismatch
$assemblies = @(
    "Veeam.Backup.Common.dll",
    "Veeam.Backup.Core.dll",
    "Veeam.Backup.Configuration.dll"
)

foreach ($asm in $assemblies) {
    $full = Join-Path $InstallPath $asm
    if (Test-Path $full) {
        [System.Reflection.Assembly]::LoadFrom($full) | Out-Null
    }
}

# Importa módulo
Import-Module Veeam.Backup.PowerShell -ErrorAction Stop -WarningAction SilentlyContinue

# Busca Tape Jobs
$TAPEJOBS = Get-VBRTapeJob -WarningAction SilentlyContinue

foreach ($TAPEJOB in $TAPEJOBS) {

    $JOBSESSION = $null
    try {
        $JOBSESSION = [Veeam.Backup.Core.CBackupSession]::FindLastByJob($TAPEJOB.Id)
    } catch {
        $JOBSESSION = $null
    }

    # RuntimeSeconds
    $RuntimeSeconds = 0
    if ($null -ne $JOBSESSION -and
        $JOBSESSION.CreationTime -and
        $JOBSESSION.EndTime -and
        $JOBSESSION.EndTime -gt $JOBSESSION.CreationTime) {
        $RuntimeSeconds = [int](($JOBSESSION.EndTime - $JOBSESSION.CreationTime).TotalSeconds)
    }

    # Regra de Storage para Tape
    $MediaPoolName = $null

    # 1) Pool principal / full / GFS
    if ($null -ne $TAPEJOB.FullBackupMediaPool) {
        $MediaPoolName = $TAPEJOB.FullBackupMediaPool.Name
    }

    # 2) Fallback para incremental
    if ([string]::IsNullOrWhiteSpace($MediaPoolName) -and $null -ne $TAPEJOB.IncrementalBackupMediaPool) {
        $MediaPoolName = $TAPEJOB.IncrementalBackupMediaPool.Name
    }

    # 3) Fallback para Target
    if ([string]::IsNullOrWhiteSpace($MediaPoolName) -and $null -ne $TAPEJOB.Target) {
        if ($TAPEJOB.Target.PSObject.Properties.Match('Name').Count -gt 0) {
            $MediaPoolName = $TAPEJOB.Target.Name
        } else {
            $MediaPoolName = [string]$TAPEJOB.Target
        }
    }

    # 4) Fallback final
    if ([string]::IsNullOrWhiteSpace($MediaPoolName)) {
        $MediaPoolName = "Unknown"
    }

    $StorageDetail = "Tape (Media Pool: $MediaPoolName)"

    if ($null -ne $JOBSESSION) {
        [PSCustomObject]@{
            JobName          = $JOBSESSION.JobName
            ScheduleEnabled  = $TAPEJOB.Enabled
            Platform         = $JOBSESSION.Platform
            JobType          = $JOBSESSION.JobTypeString
            CreationTime     = $JOBSESSION.CreationTime
            EndTime          = $JOBSESSION.EndTime
            State            = $JOBSESSION.State
            BaseProgress     = $JOBSESSION.BaseProgress
            Result           = $JOBSESSION.Result
            RuntimeSeconds   = $RuntimeSeconds
            StorageDetail    = $StorageDetail
        }
    }
}