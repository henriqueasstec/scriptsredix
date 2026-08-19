# ad_dcsync_4662.ps1
# Coleta eventos compatíveis com possível DCSync via Event ID 4662.
# O script não define ataque, severidade ou resposta.
# O Zabbix será responsável por threshold, trigger e severidade.

$LookbackSeconds = 90

$ReplicationIndicators = @(
    'Replicating Directory Changes',
    'Replicating Directory Changes All',
    'Replicating Directory Changes In Filtered Set',
    '1131f6aa-9c07-11d1-f79f-00c04fc2dcd2',
    '1131f6ad-9c07-11d1-f79f-00c04fc2dcd2',
    '89e95b76-444d-4c62-991a-0facbeda640c',
    '9923a32a-3607-11d2-b9be-0000f87a36b2'
)

$Now = Get-Date
$StartTime = $Now.AddSeconds(-$LookbackSeconds)

# Coleta porte da empresa com base em usuários ativos no AD
try {
    $activeUserCount = (Get-ADUser -Filter { Enabled -eq $true } -ErrorAction Stop | Measure-Object).Count
} catch {
    $activeUserCount = 0
}

$companySize = if ($activeUserCount -lt 50)   { "small" }
               elseif ($activeUserCount -le 500) { "medium" }
               else                              { "large" }

try {
    $events = Get-WinEvent -FilterHashtable @{
        LogName   = 'Security'
        Id        = 4662
        StartTime = $StartTime
    } -ErrorAction Stop

    $parsedEvents = foreach ($event in $events) {
        $xml = [xml]$event.ToXml()
        $data = @{}

        foreach ($d in $xml.Event.EventData.Data) {
            $data[$d.Name] = $d.'#text'
        }

        $subjectUserName   = $data['SubjectUserName']
        $subjectDomainName = $data['SubjectDomainName']
        $objectName        = $data['ObjectName']
        $objectType        = $data['ObjectType']
        $accessMask        = $data['AccessMask']
        $properties        = $data['Properties']

        $hasReplicationIndicator = $false

        foreach ($indicator in $ReplicationIndicators) {
            if ($properties -match [regex]::Escape($indicator)) {
                $hasReplicationIndicator = $true
                break
            }
        }

        if (
            $accessMask -eq '0x100' -and
            $hasReplicationIndicator -eq $true -and
            -not [string]::IsNullOrWhiteSpace($subjectUserName) -and
            $subjectUserName -notmatch '\$$' -and
            $subjectUserName -notmatch '^MSOL_' -and
            $subjectUserName -notmatch '^NT AUT' -and
            $subjectDomainName -ne 'Window Manager'
        ) {
            [PSCustomObject]@{
                TimeCreated       = $event.TimeCreated
                SubjectUserName   = $subjectUserName
                SubjectDomainName = $subjectDomainName
                ObjectName        = $objectName
                ObjectType        = $objectType
                AccessMask        = $accessMask
                Properties        = $properties
            }
        }
    }

    if (-not $parsedEvents) {
        $result = [PSCustomObject]@{
            detection_name     = "AD - Possible DCSync via Directory Replication Rights"
            mitre              = "T1003.006"
            generated_at       = $Now.ToString("s")
            collection_start   = $StartTime.ToString("s")
            collection_end     = $Now.ToString("s")
            lookback_seconds   = $LookbackSeconds
            company_size       = $companySize
            active_user_count  = $activeUserCount
            metric_name        = "dcsync_suspicious_count"
            metric_value       = 0
            subject_user       = $null
            subject_domain     = $null
            event_count        = 0
            first_seen         = $null
            last_seen          = $null
            objects            = @()
            access_mask        = $null
            properties         = @()
        }

        $result | ConvertTo-Json -Compress -Depth 5
        exit 0
    }

    $orderedEvents = $parsedEvents | Sort-Object TimeCreated
    $topSubject = $parsedEvents |
        Group-Object SubjectUserName, SubjectDomainName |
        Sort-Object Count -Descending |
        Select-Object -First 1

    $topGroupEvents = $topSubject.Group

    $objects = $topGroupEvents.ObjectName |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique

    $propertiesList = $topGroupEvents.Properties |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique

    $result = [PSCustomObject]@{
        detection_name     = "AD - Possible DCSync via Directory Replication Rights"
        mitre              = "T1003.006"
        generated_at       = $Now.ToString("s")
        collection_start   = $StartTime.ToString("s")
        collection_end     = $Now.ToString("s")
        lookback_seconds   = $LookbackSeconds
        company_size       = $companySize
        active_user_count  = $activeUserCount
        metric_name        = "dcsync_suspicious_count"
        metric_value       = $parsedEvents.Count
        subject_user       = $topGroupEvents[0].SubjectUserName
        subject_domain     = $topGroupEvents[0].SubjectDomainName
        event_count        = $parsedEvents.Count
        first_seen         = ($orderedEvents | Select-Object -First 1).TimeCreated.ToString("s")
        last_seen          = ($orderedEvents | Select-Object -Last 1).TimeCreated.ToString("s")
        objects            = $objects
        access_mask        = "0x100"
        properties         = $propertiesList
    }

    $result | ConvertTo-Json -Compress -Depth 5
    exit 0
}
catch {
    $result = [PSCustomObject]@{
        detection_name    = "AD - Possible DCSync via Directory Replication Rights"
        mitre             = "T1003.006"
        generated_at      = $Now.ToString("s")
        collection_start  = $StartTime.ToString("s")
        collection_end    = $Now.ToString("s")
        lookback_seconds  = $LookbackSeconds
        company_size      = $companySize
        active_user_count = $activeUserCount
        metric_name       = "dcsync_suspicious_count"
        metric_value      = 0
        error             = $_.Exception.Message
    }

    $result | ConvertTo-Json -Compress -Depth 5
    exit 0
}
