# ad_password_spray_4771.ps1
# Coleta eventos compatíveis com possível Password Spraying via Event ID 4771.
# O script não define ataque, severidade ou threshold.
# O Zabbix será responsável por intervalo de coleta, threshold e trigger.

$LookbackSeconds = 90

$Now = Get-Date
$StartTime = $Now.AddSeconds(-$LookbackSeconds)

# Coleta porte da empresa com base em usuários ativos no AD
try {
    $activeUserCount = (Get-ADUser -Filter { Enabled -eq $true } -ErrorAction Stop | Measure-Object).Count
} catch {
    $activeUserCount = 0
}

$companySize = if ($activeUserCount -lt 50)      { "small" }
               elseif ($activeUserCount -le 500)  { "medium" }
               else                               { "large" }

try {
    $events = Get-WinEvent -FilterHashtable @{
        LogName   = 'Security'
        Id        = 4771
        StartTime = $StartTime
    } -ErrorAction Stop

    $parsedEvents = foreach ($event in $events) {
        $xml = [xml]$event.ToXml()
        $data = @{}

        foreach ($d in $xml.Event.EventData.Data) {
            $data[$d.Name] = $d.'#text'
        }

        $targetUserName = $data['TargetUserName']
        $clientAddress  = $data['IpAddress']
        $failureCode    = $data['FailureCode']

        if ([string]::IsNullOrWhiteSpace($clientAddress)) {
            $clientAddress = $data['ClientAddress']
        }

        if ([string]::IsNullOrWhiteSpace($failureCode)) {
            $failureCode = $data['Status']
        }

        if (
            $failureCode -eq '0x18' -and
            -not [string]::IsNullOrWhiteSpace($targetUserName) -and
            -not [string]::IsNullOrWhiteSpace($clientAddress) -and
            $targetUserName -notmatch '\$$' -and
            $clientAddress -ne '::1' -and
            $clientAddress -ne '127.0.0.1'
        ) {
            [PSCustomObject]@{
                TimeCreated    = $event.TimeCreated
                TargetUserName = $targetUserName
                ClientAddress  = $clientAddress
                FailureCode    = $failureCode
            }
        }
    }

    if (-not $parsedEvents) {
        $result = [PSCustomObject]@{
            detection_name      = "AD - Possible Password Spraying via Kerberos Pre-Authentication Failures"
            mitre               = "T1110.003"
            generated_at        = $Now.ToString("s")
            collection_start    = $StartTime.ToString("s")
            collection_end      = $Now.ToString("s")
            lookback_seconds    = $LookbackSeconds
            company_size        = $companySize
            active_user_count   = $activeUserCount
            metric_name         = "max_distinct_users"
            metric_value        = 0
            client_address      = $null
            event_count         = 0
            distinct_user_count = 0
            first_seen          = $null
            last_seen           = $null
            failure_code        = "0x18"
            target_users        = @()
        }

        $result | ConvertTo-Json -Compress -Depth 4
        exit 0
    }

    $groups = $parsedEvents |
        Group-Object ClientAddress |
        ForEach-Object {
            $users = $_.Group.TargetUserName | Sort-Object -Unique
            $orderedEvents = $_.Group | Sort-Object TimeCreated

            [PSCustomObject]@{
                ClientAddress     = $_.Group[0].ClientAddress
                EventCount        = $_.Group.Count
                DistinctUserCount = $users.Count
                FirstSeen         = ($orderedEvents | Select-Object -First 1).TimeCreated
                LastSeen          = ($orderedEvents | Select-Object -Last 1).TimeCreated
                TargetUsers       = $users
                FailureCode       = "0x18"
            }
        } |
        Sort-Object DistinctUserCount -Descending

    $topGroup = $groups | Select-Object -First 1

    if (-not $topGroup) {
        $result = [PSCustomObject]@{
            detection_name      = "AD - Possible Password Spraying via Kerberos Pre-Authentication Failures"
            mitre               = "T1110.003"
            generated_at        = $Now.ToString("s")
            collection_start    = $StartTime.ToString("s")
            collection_end      = $Now.ToString("s")
            lookback_seconds    = $LookbackSeconds
            company_size        = $companySize
            active_user_count   = $activeUserCount
            metric_name         = "max_distinct_users"
            metric_value        = 0
            client_address      = $null
            event_count         = 0
            distinct_user_count = 0
            first_seen          = $null
            last_seen           = $null
            failure_code        = "0x18"
            target_users        = @()
        }

        $result | ConvertTo-Json -Compress -Depth 4
        exit 0
    }

    $result = [PSCustomObject]@{
        detection_name      = "AD - Possible Password Spraying via Kerberos Pre-Authentication Failures"
        mitre               = "T1110.003"
        generated_at        = $Now.ToString("s")
        collection_start    = $StartTime.ToString("s")
        collection_end      = $Now.ToString("s")
        lookback_seconds    = $LookbackSeconds
        company_size        = $companySize
        active_user_count   = $activeUserCount
        metric_name         = "max_distinct_users"
        metric_value        = $topGroup.DistinctUserCount
        client_address      = $topGroup.ClientAddress
        event_count         = $topGroup.EventCount
        distinct_user_count = $topGroup.DistinctUserCount
        first_seen          = if ($topGroup.FirstSeen) { $topGroup.FirstSeen.ToString("s") } else { $null }
        last_seen           = if ($topGroup.LastSeen) { $topGroup.LastSeen.ToString("s") } else { $null }
        failure_code        = $topGroup.FailureCode
        target_users        = $topGroup.TargetUsers
    }

    $result | ConvertTo-Json -Compress -Depth 4
    exit 0
}
catch {
    $errorTime  = if ($Now)       { $Now }       else { Get-Date }
    $errorStart = if ($StartTime) { $StartTime } else { $errorTime.AddSeconds(-90) }

    $result = [PSCustomObject]@{
        detection_name    = "AD - Possible Password Spraying via Kerberos Pre-Authentication Failures"
        mitre             = "T1110.003"
        generated_at      = $errorTime.ToString("s")
        collection_start  = $errorStart.ToString("s")
        collection_end    = $errorTime.ToString("s")
        lookback_seconds  = $LookbackSeconds
        company_size      = $companySize
        active_user_count = $activeUserCount
        metric_name       = "max_distinct_users"
        metric_value      = 0
        error             = $_.Exception.Message
    }

    $result | ConvertTo-Json -Compress -Depth 4
    exit 0
}
