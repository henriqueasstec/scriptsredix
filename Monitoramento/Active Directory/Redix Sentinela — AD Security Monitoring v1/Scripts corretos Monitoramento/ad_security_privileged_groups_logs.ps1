# sentinela_ad_privileged_groups_logs.ps1
# Coleta alteracoes em grupos privilegiados do Active Directory
# via Event IDs 4728/4729 (global), 4732/4733 (local), 4756/4757 (universal).
# Chamado via external script no Zabbix quando alteracao e detectada.
# Retorna JSON via stdout com todas as alteracoes da janela.
# Exclui os mesmos grupos de maquina que o script de snapshot.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$LookbackSeconds = 90
$Now       = Get-Date
$StartTime = $Now.AddSeconds(-$LookbackSeconds)

# Mapeamento Event ID -> acao e tipo de grupo
$EventMap = @{
    4728 = @{ Action = 'added';   GroupType = 'global'    }
    4729 = @{ Action = 'removed'; GroupType = 'global'    }
    4732 = @{ Action = 'added';   GroupType = 'local'     }
    4733 = @{ Action = 'removed'; GroupType = 'local'     }
    4756 = @{ Action = 'added';   GroupType = 'universal' }
    4757 = @{ Action = 'removed'; GroupType = 'universal' }
}

# Grupos a EXCLUIR - mesmos RIDs do script de snapshot
$ExcludedGroupRids = @(516, 521, 498, 517)

# Coleta SIDs excluidos
try {
    $domainSid    = (Get-ADDomain -ErrorAction Stop).DomainSID.Value
    $excludedSids = $ExcludedGroupRids | ForEach-Object { "$domainSid-$_" }

    $privilegedGroups = Get-ADGroup -Filter { adminCount -eq 1 } -Properties SID -ErrorAction Stop |
        Where-Object { $excludedSids -notcontains $_.SID.Value } |
        Select-Object -ExpandProperty Name
} catch {
    $privilegedGroups = @()
}

# Coleta eventos
try {
    $events = Get-WinEvent -FilterHashtable @{
        LogName   = 'Security'
        Id        = @(4728, 4729, 4732, 4733, 4756, 4757)
        StartTime = $StartTime
    } -ErrorAction Stop

    $changes = foreach ($event in $events) {
        $xml  = [xml]$event.ToXml()
        $data = @{}
        foreach ($d in $xml.Event.EventData.Data) { $data[$d.Name] = $d.'#text' }

        $memberName        = $data['MemberName']
        $targetGroupName   = $data['TargetUserName']
        $performedBy       = $data['SubjectUserName']
        $performedByDomain = $data['SubjectDomainName']
        $eventId           = $event.Id

        # Extrai apenas o CN do MemberName (formato: CN=nome,CN=Users,DC=...)
        if ($memberName -match '^CN=([^,]+)') { $memberName = $matches[1] }

        # Filtra apenas grupos privilegiados monitorados
        if ($privilegedGroups.Count -gt 0 -and $privilegedGroups -notcontains $targetGroupName) { continue }

        # Nao filtra conta de maquina aqui - alteracao em grupo privilegiado
        # feita por qualquer conta (inclusive sistema) e relevante
        if ([string]::IsNullOrWhiteSpace($performedBy) -or $performedBy -eq '-') { continue }

        [PSCustomObject]@{
            time                = $event.TimeCreated.ToString("s")
            event_id            = $eventId
            action              = $EventMap[$eventId].Action
            group_type          = $EventMap[$eventId].GroupType
            member              = $memberName
            group               = $targetGroupName
            performed_by        = $performedBy
            performed_by_domain = $performedByDomain
        }
    }
} catch {
    $changes = @()
}

$changesArray = [array](@($changes) | Where-Object { $_ -ne $null } | Sort-Object time)

if ($null -eq $changesArray -or $changesArray.Count -eq 0) {
    [PSCustomObject]@{
        generated_at      = $Now.ToString("s")
        collection_start  = $StartTime.ToString("s")
        collection_end    = $Now.ToString("s")
        lookback_seconds  = $LookbackSeconds
        metric_name       = "privileged_group_changes"
        metric_value      = 0
        changes           = @()
    } | ConvertTo-Json -Depth 5
    exit 0
}

[PSCustomObject]@{
    generated_at      = $Now.ToString("s")
    collection_start  = $StartTime.ToString("s")
    collection_end    = $Now.ToString("s")
    lookback_seconds  = $LookbackSeconds
    metric_name       = "privileged_group_changes"
    metric_value      = $changesArray.Count
    changes           = $changesArray
} | ConvertTo-Json -Depth 5
exit 0
