# ad_kerberoasting_4769.ps1
# Coleta eventos compatíveis com possível Kerberoasting via Event ID 4769.
# O script não define ataque, severidade ou threshold.
# O Zabbix será responsável pelo intervalo de coleta, threshold e trigger.

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

# Normaliza IPv6-mapped para IPv4 puro (::ffff:192.168.x.x → 192.168.x.x)
function Normalize-IPAddress {
    param([string]$ip)
    if ([string]::IsNullOrWhiteSpace($ip)) { return $ip }
    if ($ip -match '^::ffff:(\d+\.\d+\.\d+\.\d+)$') { return $matches[1] }
    return $ip
}

try {
    $events = Get-WinEvent -FilterHashtable @{
        LogName   = 'Security'
        Id        = 4769
        StartTime = $StartTime
    } -ErrorAction Stop

    $parsedEvents = foreach ($event in $events) {
        $xml = [xml]$event.ToXml()

        $data = @{}

        foreach ($d in $xml.Event.EventData.Data) {
            $data[$d.Name] = $d.'#text'
        }

        $targetUserName = $data['TargetUserName']
        $serviceName    = $data['ServiceName']
        $clientAddress  = Normalize-IPAddress $data['IpAddress']
        $status         = $data['Status']
        $ticketEncType  = $data['TicketEncryptionType']

        if ([string]::IsNullOrWhiteSpace($clientAddress)) {
            $clientAddress = Normalize-IPAddress $data['ClientAddress']
        }

        if (
            $status -eq '0x0' -and
            $ticketEncType -eq '0x17' -and
            -not [string]::IsNullOrWhiteSpace($targetUserName) -and
            -not [string]::IsNullOrWhiteSpace($serviceName) -and
            -not [string]::IsNullOrWhiteSpace($clientAddress) -and
            $serviceName -notmatch 'krbtgt' -and
            $serviceName -notmatch '\$$' -and
            $targetUserName -notmatch '\$@' -and
            $targetUserName -notmatch '\$$'
        ) {
            [PSCustomObject]@{
                TimeCreated    = $event.TimeCreated
                TargetUserName = $targetUserName
                ClientAddress  = $clientAddress
                ServiceName    = $serviceName
            }
        }
    }

    if (-not $parsedEvents) {
        $result = [PSCustomObject]@{
            detection_name         = "AD - Possible Kerberoasting via RC4 TGS Burst"
            mitre                  = "T1558.003"
            generated_at           = $Now.ToString("s")
            collection_start       = $StartTime.ToString("s")
            collection_end         = $Now.ToString("s")
            lookback_seconds       = $LookbackSeconds
            company_size           = $companySize
            active_user_count      = $activeUserCount
            metric_name            = "max_distinct_services"
            metric_value           = 0
            target_user            = $null
            client_address         = $null
            event_count            = 0
            distinct_service_count = 0
            first_seen             = $null
            last_seen              = $null
            service_names          = @()
        }

        $result | ConvertTo-Json -Compress -Depth 4
        exit 0
    }

    $groups = $parsedEvents |
        Group-Object TargetUserName, ClientAddress |
        ForEach-Object {
            $services = $_.Group.ServiceName | Sort-Object -Unique
            $orderedEvents = $_.Group | Sort-Object TimeCreated

            [PSCustomObject]@{
                TargetUserName       = $_.Group[0].TargetUserName
                ClientAddress        = $_.Group[0].ClientAddress
                EventCount           = $_.Group.Count
                DistinctServiceCount = $services.Count
                FirstSeen            = ($orderedEvents | Select-Object -First 1).TimeCreated
                LastSeen             = ($orderedEvents | Select-Object -Last 1).TimeCreated
                ServiceNames         = $services
            }
        } |
        Sort-Object DistinctServiceCount -Descending

    $topGroup = $groups | Select-Object -First 1

    if (-not $topGroup) {
        $result = [PSCustomObject]@{
            detection_name         = "AD - Possible Kerberoasting via RC4 TGS Burst"
            mitre                  = "T1558.003"
            generated_at           = $Now.ToString("s")
            collection_start       = $StartTime.ToString("s")
            collection_end         = $Now.ToString("s")
            lookback_seconds       = $LookbackSeconds
            company_size           = $companySize
            active_user_count      = $activeUserCount
            metric_name            = "max_distinct_services"
            metric_value           = 0
            target_user            = $null
            client_address         = $null
            event_count            = 0
            distinct_service_count = 0
            first_seen             = $null
            last_seen              = $null
            service_names          = @()
        }

        $result | ConvertTo-Json -Compress -Depth 4
        exit 0
    }

    $result = [PSCustomObject]@{
        detection_name         = "AD - Possible Kerberoasting via RC4 TGS Burst"
        mitre                  = "T1558.003"
        generated_at           = $Now.ToString("s")
        collection_start       = $StartTime.ToString("s")
        collection_end         = $Now.ToString("s")
        lookback_seconds       = $LookbackSeconds
        company_size           = $companySize
        active_user_count      = $activeUserCount
        metric_name            = "max_distinct_services"
        metric_value           = $topGroup.DistinctServiceCount
        target_user            = $topGroup.TargetUserName
        client_address         = $topGroup.ClientAddress
        event_count            = $topGroup.EventCount
        distinct_service_count = $topGroup.DistinctServiceCount
        first_seen             = if ($topGroup.FirstSeen) { $topGroup.FirstSeen.ToString("s") } else { $null }
        last_seen              = if ($topGroup.LastSeen) { $topGroup.LastSeen.ToString("s") } else { $null }
        service_names          = $topGroup.ServiceNames
    }

    $result | ConvertTo-Json -Compress -Depth 4
    exit 0
}
catch {
    $result = [PSCustomObject]@{
        detection_name    = "AD - Possible Kerberoasting via RC4 TGS Burst"
        mitre             = "T1558.003"
        generated_at      = $Now.ToString("s")
        collection_start  = $StartTime.ToString("s")
        collection_end    = $Now.ToString("s")
        lookback_seconds  = $LookbackSeconds
        company_size      = $companySize
        active_user_count = $activeUserCount
        metric_name       = "max_distinct_services"
        metric_value      = 0
        error             = $_.Exception.Message
    }

    $result | ConvertTo-Json -Compress -Depth 4
    exit 0
}