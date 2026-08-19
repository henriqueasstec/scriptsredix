# ad_brute_force_full.ps1
# Coleta eventos compatíveis com possível Brute Force via Kerberos e NTLM.
# Cobre Event IDs: 4771 (Kerberos Pre-Auth) e 4625 (NTLM/Logon falho).
# Agrupa por IP + usuário alvo — mesmo IP tentando o mesmo usuário repetidamente.
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

# Normaliza IPv6-mapped para IPv4 puro (::ffff:192.168.x.x ? 192.168.x.x)
function Normalize-IPAddress {
    param([string]$ip)
    if ([string]::IsNullOrWhiteSpace($ip)) { return $ip }
    if ($ip -match '^::ffff:(\d+\.\d+\.\d+\.\d+)$') { return $matches[1] }
    return $ip
}

# --- Coleta eventos 4771 — Kerberos Pre-Authentication failures ---------------
$kerberosEvents = @()
try {
    $rawKerberos = Get-WinEvent -FilterHashtable @{
        LogName   = 'Security'
        Id        = 4771
        StartTime = $StartTime
    } -ErrorAction Stop

    $kerberosEvents = foreach ($event in $rawKerberos) {
        $xml = [xml]$event.ToXml()
        $data = @{}
        foreach ($d in $xml.Event.EventData.Data) {
            $data[$d.Name] = $d.'#text'
        }

        $targetUserName = $data['TargetUserName']
        $clientAddress  = Normalize-IPAddress $data['IpAddress']
        $failureCode    = $data['FailureCode']

        if ([string]::IsNullOrWhiteSpace($clientAddress)) {
            $clientAddress = Normalize-IPAddress $data['ClientAddress']
        }
        if ([string]::IsNullOrWhiteSpace($failureCode)) {
            $failureCode = $data['Status']
        }

        # Aceita os failure codes relevantes para brute force Kerberos:
        # 0x18 = senha errada (usuário válido)
        # 0x12 = conta desabilitada/expirada
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
} catch {
    # Sem eventos 4771 na janela — normal
}

# --- Coleta eventos 4625 — NTLM / Logon failures -----------------------------
$ntlmEvents = @()
try {
    $rawNtlm = Get-WinEvent -FilterHashtable @{
        LogName   = 'Security'
        Id        = 4625
        StartTime = $StartTime
    } -ErrorAction Stop

    $ntlmEvents = foreach ($event in $rawNtlm) {
        $xml = [xml]$event.ToXml()
        $data = @{}
        foreach ($d in $xml.Event.EventData.Data) {
            $data[$d.Name] = $d.'#text'
        }

        $targetUserName = $data['TargetUserName']
        $clientAddress  = Normalize-IPAddress $data['IpAddress']
        $failureCode    = $data['SubStatus']
        $logonType      = $data['LogonType']
        $authPackage    = $data['AuthenticationPackageName']

        if ([string]::IsNullOrWhiteSpace($clientAddress)) {
            $clientAddress = Normalize-IPAddress $data['WorkstationName']
        }

        # Aceita os failure codes relevantes para brute force NTLM:
        # 0xC000006A = senha errada (usuário válido)
        # 0xC0000064 = usuário inexistente (enumeração)
        # LogonType 3  = rede (SMB, WinRM)
        # LogonType 10 = RemoteInteractive (RDP)
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
} catch {
    # Sem eventos 4625 na janela — normal
}

# --- Combina todos os eventos -------------------------------------------------
$allEvents = @($kerberosEvents) + @($ntlmEvents) |
    Where-Object { $_ -ne $null }

if ($allEvents.Count -eq 0) {
    $result = [PSCustomObject]@{
        detection_name    = "AD - Possible Brute Force via Kerberos and NTLM Failures"
        mitre             = "T1110.001"
        generated_at      = $Now.ToString("s")
        collection_start  = $StartTime.ToString("s")
        collection_end    = $Now.ToString("s")
        lookback_seconds  = $LookbackSeconds
        company_size      = $companySize
        active_user_count = $activeUserCount
        metric_name       = "max_attempts_per_target"
        metric_value      = 0
        client_address    = $null
        target_user       = $null
        event_count       = 0
        attempt_count     = 0
        first_seen        = $null
        last_seen         = $null
        by_protocol       = [PSCustomObject]@{
            kerberos = 0
            ntlm     = 0
        }
    }

    $result | ConvertTo-Json -Compress -Depth 5
    exit 0
}

# --- Agrupa por IP + usuário alvo ---------------------------------------------
$groups = $allEvents |
    Group-Object ClientAddress, TargetUserName |
    ForEach-Object {
        $groupEvents   = $_.Group | Sort-Object TimeCreated
        $kerberosCount = ($_.Group | Where-Object { $_.Protocol -eq 'kerberos' } | Measure-Object).Count
        $ntlmCount     = ($_.Group | Where-Object { $_.Protocol -eq 'ntlm' }     | Measure-Object).Count

        [PSCustomObject]@{
            ClientAddress  = $_.Group[0].ClientAddress
            TargetUser     = $_.Group[0].TargetUserName
            AttemptCount   = $_.Group.Count
            KerberosCount  = $kerberosCount
            NtlmCount      = $ntlmCount
            FirstSeen      = ($groupEvents | Select-Object -First 1).TimeCreated
            LastSeen       = ($groupEvents | Select-Object -Last 1).TimeCreated
        }
    } |
    Sort-Object AttemptCount -Descending

$topGroup = $groups | Select-Object -First 1

$result = [PSCustomObject]@{
    detection_name    = "AD - Possible Brute Force via Kerberos and NTLM Failures"
    mitre             = "T1110.001"
    generated_at      = $Now.ToString("s")
    collection_start  = $StartTime.ToString("s")
    collection_end    = $Now.ToString("s")
    lookback_seconds  = $LookbackSeconds
    company_size      = $companySize
    active_user_count = $activeUserCount
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
}

$result | ConvertTo-Json -Compress -Depth 5
exit 0