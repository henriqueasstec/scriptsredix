# ad_privileged_groups_4728.ps1
# Coleta alteracoes em grupos privilegiados do Active Directory.
# Monitora adicoes e remocoes em grupos com adminCount = 1, exceto os grupos
# de conta de maquina (mesma exclusao usada no script de GET/snapshot).
# Este script e chamado pelo script pai somente quando o GET detecta diferenca
# entre a coleta atual e a anterior. O lookback de 90s cobre o intervalo de
# 60s entre execucoes do GET, com margem para o tempo de execucao.
# O script nao define acao, severidade ou threshold - isso fica com o script pai.

$LookbackSeconds = 90

$Now = Get-Date
$StartTime = $Now.AddSeconds(-$LookbackSeconds)

# Mapeamento de Event ID para acao e tipo de grupo
$EventMap = @{
    4728 = @{ Action = 'added';   GroupType = 'global'    }
    4729 = @{ Action = 'removed'; GroupType = 'global'    }
    4732 = @{ Action = 'added';   GroupType = 'local'     }
    4733 = @{ Action = 'removed'; GroupType = 'local'     }
    4756 = @{ Action = 'added';   GroupType = 'universal' }
    4757 = @{ Action = 'removed'; GroupType = 'universal' }
}

# Coleta porte da empresa com base em usuarios ativos no AD
try {
    $activeUserCount = (Get-ADUser -Filter { Enabled -eq $true } -ErrorAction Stop | Measure-Object).Count
} catch {
    $activeUserCount = 0
}

$companySize = if ($activeUserCount -lt 50)      { "small" }
               elseif ($activeUserCount -le 500)  { "medium" }
               else                               { "large" }

# Grupos a EXCLUIR do monitoramento, por RID/SID - mesma lista usada no script de GET/snapshot.
# Motivo: membros sao contas de maquina, nao de usuario.
#   516 = Domain Controllers
#   521 = Read-only Domain Controllers
#   498 = Enterprise Read-only Domain Controllers (so existe no dominio raiz da floresta)
#   517 = Cert Publishers (membros sao contas de computador dos servidores CA)
$ExcludedGroupRids = @(516, 521, 498, 517)

# Coleta dinamica dos grupos privilegiados via adminCount = 1, removendo os grupos de maquina
try {
    $domainSid    = (Get-ADDomain -ErrorAction Stop).DomainSID.Value
    $excludedSids = $ExcludedGroupRids | ForEach-Object { "$domainSid-$_" }

    $privilegedGroups = Get-ADGroup -Filter { adminCount -eq 1 } -Properties SID -ErrorAction Stop |
        Where-Object { $excludedSids -notcontains $_.SID.Value } |
        Select-Object -ExpandProperty Name
} catch {
    $privilegedGroups = @()
}

try {
    $events = Get-WinEvent -FilterHashtable @{
        LogName   = 'Security'
        Id        = @(4728, 4729, 4732, 4733, 4756, 4757)
        StartTime = $StartTime
    } -ErrorAction Stop

    $changes = foreach ($event in $events) {
        $xml = [xml]$event.ToXml()
        $data = @{}

        foreach ($d in $xml.Event.EventData.Data) {
            $data[$d.Name] = $d.'#text'
        }

        $memberName        = $data['MemberName']
        $targetGroupName   = $data['TargetUserName']
        $performedBy       = $data['SubjectUserName']
        $performedByDomain = $data['SubjectDomainName']
        $memberDomain      = $data['SubjectDomainName']
        $eventId           = $event.Id

        # Extrai apenas o CN do MemberName (formato: CN=nome,CN=Users,DC=...)
        if ($memberName -match '^CN=([^,]+)') {
            $memberName = $matches[1]
        }

        # Filtra apenas grupos privilegiados
        if ($privilegedGroups -notcontains $targetGroupName) {
            continue
        }

        # Ignora acoes executadas pelo proprio sistema
        if (
            [string]::IsNullOrWhiteSpace($performedBy) -or
            $performedBy -match '\$$' -or
            $performedBy -eq 'SYSTEM'
        ) {
            continue
        }

        $action    = $EventMap[$eventId].Action
        $groupType = $EventMap[$eventId].GroupType

        [PSCustomObject]@{
            time               = $event.TimeCreated.ToString("s")
            event_id           = $eventId
            action             = $action
            group_type         = $groupType
            member             = $memberName
            group              = $targetGroupName
            performed_by       = $performedBy
            performed_by_domain = $performedByDomain
        }
    }

    # Garante que $changes seja sempre array
    $changesArray = @($changes | Where-Object { $_ -ne $null })

    if ($changesArray.Count -eq 0) {
        $result = [PSCustomObject]@{
            detection_name    = "AD - Privileged Group Membership Change"
            mitre             = "T1098"
            generated_at      = $Now.ToString("s")
            collection_start  = $StartTime.ToString("s")
            collection_end    = $Now.ToString("s")
            lookback_seconds  = $LookbackSeconds
            company_size      = $companySize
            active_user_count = $activeUserCount
            metric_name       = "privileged_group_changes"
            metric_value      = 0
            changes           = @()
        }

        $result | ConvertTo-Json -Compress -Depth 5
        exit 0
    }

    $result = [PSCustomObject]@{
        detection_name    = "AD - Privileged Group Membership Change"
        mitre             = "T1098"
        generated_at      = $Now.ToString("s")
        collection_start  = $StartTime.ToString("s")
        collection_end    = $Now.ToString("s")
        lookback_seconds  = $LookbackSeconds
        company_size      = $companySize
        active_user_count = $activeUserCount
        metric_name       = "privileged_group_changes"
        metric_value      = $changesArray.Count
        changes           = $changesArray
    }

    $result | ConvertTo-Json -Compress -Depth 5
    exit 0
}
catch {
    $result = [PSCustomObject]@{
        detection_name    = "AD - Privileged Group Membership Change"
        mitre             = "T1098"
        generated_at      = $Now.ToString("s")
        collection_start  = $StartTime.ToString("s")
        collection_end    = $Now.ToString("s")
        lookback_seconds  = $LookbackSeconds
        company_size      = $companySize
        active_user_count = $activeUserCount
        metric_name       = "privileged_group_changes"
        metric_value      = 0
        error             = $_.Exception.Message
    }

    $result | ConvertTo-Json -Compress -Depth 5
    exit 0
}