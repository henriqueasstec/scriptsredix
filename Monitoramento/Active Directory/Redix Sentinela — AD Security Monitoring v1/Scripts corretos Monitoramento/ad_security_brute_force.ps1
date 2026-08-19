# sentinela_ad_brute_force.ps1
# Coleta eventos compativeis com possivel Brute Force via Kerberos e NTLM.
# Cobre Event IDs: 4771 (Kerberos Pre-Auth) e 4625 (NTLM/Logon falho).
# Agrupa por IP + usuario alvo - mesmo IP tentando o mesmo usuario repetidamente.
# Retorna JSON via stdout - sem gravacao em arquivo.
# O Zabbix sera responsavel por threshold, trigger e severidade.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$LookbackSeconds = 90
$Now       = Get-Date
$StartTime = $Now.AddSeconds(-$LookbackSeconds)

# Normaliza IPv6-mapped para IPv4 puro (::ffff:192.168.x.x -> 192.168.x.x)
function Normalize-IPAddress {
    param([string]$ip)
    if ([string]::IsNullOrWhiteSpace($ip)) { return $ip }
    if ($ip -match '^::ffff:(\d+\.\d+\.\d+\.\d+)$') { return $matches[1] }
    return $ip
}

# --- Coleta eventos 4771 - Kerberos Pre-Authentication failures ---------------
$kerberosEvents = @()
try {
    $rawKerberos = Get-WinEvent -FilterHashtable @{
        LogName   = 'Security'
        Id        = 4771
        StartTime = $StartTime
    } -ErrorAction Stop

    $kerberosEvents = foreach ($event in $rawKerberos) {
        $xml  = [xml]$event.ToXml()
        $data = @{}
        foreach ($d in $xml.Event.EventData.Data) { $data[$d.Name] = $d.'#text' }

        $targetUserName = $data['TargetUserName']
        $clientAddress  = Normalize-IPAddress $data['IpAddress']
        $failureCode    = $data['FailureCode']

        if ([string]::IsNullOrWhiteSpace($clientAddress)) {
            $clientAddress = Normalize-IPAddress $data['ClientAddress']
        }
        if ([string]::IsNullOrWhiteSpace($failureCode)) {
            $failureCode = $data['Status']
        }

        if (
            $failureCode -in @('0x18', '0x12') -and
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
                Protocol       = 'kerberos'
                EventId        = 4771
            }
        }
    }
} catch { }

# --- Coleta eventos 4625 - NTLM / Logon failures -----------------------------
$ntlmEvents = @()
try {
    $rawNtlm = Get-WinEvent -FilterHashtable @{
        LogName   = 'Security'
        Id        = 4625
        StartTime = $StartTime
    } -ErrorAction Stop

    $ntlmEvents = foreach ($event in $rawNtlm) {
        $xml  = [xml]$event.ToXml()
        $data = @{}
        foreach ($d in $xml.Event.EventData.Data) { $data[$d.Name] = $d.'#text' }

        $targetUserName = $data['TargetUserName']
        $clientAddress  = Normalize-IPAddress $data['IpAddress']
        $failureCode    = $data['SubStatus']
        $logonType      = $data['LogonType']
        $authPackage    = $data['AuthenticationPackageName']

        if ([string]::IsNullOrWhiteSpace($clientAddress)) {
            $clientAddress = Normalize-IPAddress $data['WorkstationName']
        }

        if (
            $failureCode -in @('0xC000006A', '0xC0000064') -and
            $logonType -in @('3', '10') -and
            -not [string]::IsNullOrWhiteSpace($targetUserName) -and
            -not [string]::IsNullOrWhiteSpace($clientAddress) -and
            $targetUserName -notmatch '\$$' -and
            $targetUserName -ne 'ANONYMOUS LOGON' -and
            $targetUserName -ne '-' -and
            $clientAddress -ne '::1' -and
            $clientAddress -ne '127.0.0.1' -and
            $clientAddress -ne '-'
        ) {
            [PSCustomObject]@{
                TimeCreated    = $event.TimeCreated
                TargetUserName = $targetUserName
                ClientAddress  = $clientAddress
                FailureCode    = $failureCode
                Protocol       = 'ntlm'
                EventId        = 4625
                LogonType      = $logonType
                AuthPackage    = $authPackage
            }
        }
    }
} catch { }

# --- Combina todos os eventos -------------------------------------------------
$allEvents = @($kerberosEvents) + @($ntlmEvents) | Where-Object { $_ -ne $null }

if ($allEvents.Count -eq 0) {
    [PSCustomObject]@{
        generated_at      = $Now.ToString("s")
        collection_start  = $StartTime.ToString("s")
        collection_end    = $Now.ToString("s")
        lookback_seconds  = $LookbackSeconds
        metric_name       = "max_attempts_per_target"
        metric_value      = 0
        client_address    = $null
        target_user       = $null
        event_count       = 0
        attempt_count     = 0
        first_seen        = $null
        last_seen         = $null
        by_protocol       = [PSCustomObject]@{ kerberos = 0; ntlm = 0 }
    } | ConvertTo-Json -Depth 5
    exit 0
}

# --- Agrupa por IP + usuario alvo ---------------------------------------------
$groups = $allEvents |
    Group-Object ClientAddress, TargetUserName |
    ForEach-Object {
        $groupEvents   = $_.Group | Sort-Object TimeCreated
        $kerberosCount = ($_.Group | Where-Object { $_.Protocol -eq 'kerberos' } | Measure-Object).Count
        $ntlmCount     = ($_.Group | Where-Object { $_.Protocol -eq 'ntlm'     } | Measure-Object).Count
        [PSCustomObject]@{
            ClientAddress  = $_.Group[0].ClientAddress
            TargetUser     = $_.Group[0].TargetUserName
            AttemptCount   = $_.Group.Count
            KerberosCount  = $kerberosCount
            NtlmCount      = $ntlmCount
            FirstSeen      = ($groupEvents | Select-Object -First 1).TimeCreated
            LastSeen       = ($groupEvents | Select-Object -Last 1).TimeCreated
        }
    } | Sort-Object AttemptCount -Descending

$topGroup = $groups | Select-Object -First 1

[PSCustomObject]@{
    generated_at      = $Now.ToString("s")
    collection_start  = $StartTime.ToString("s")
    collection_end    = $Now.ToString("s")
    lookback_seconds  = $LookbackSeconds
    metric_name       = "max_attempts_per_target"
    metric_value      = $topGroup.AttemptCount
    client_address    = $topGroup.ClientAddress
    target_user       = $topGroup.TargetUser
    event_count       = $allEvents.Count
    attempt_count     = $topGroup.AttemptCount
    first_seen        = if ($topGroup.FirstSeen) { $topGroup.FirstSeen.ToString("s") } else { $null }
    last_seen         = if ($topGroup.LastSeen)  { $topGroup.LastSeen.ToString("s")  } else { $null }
    by_protocol       = [PSCustomObject]@{
        kerberos = $topGroup.KerberosCount
        ntlm     = $topGroup.NtlmCount
    }
} | ConvertTo-Json -Depth 5
exit 0
