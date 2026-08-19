# sentinela_ad_privileged_groups.ps1
# Coleta o estado atual de todos os grupos privilegiados do dominio
# (adminCount = 1).
# Para grupos normalmente compostos por contas de maquina, ignora membros computer.
# Retorna JSON via stdout com metric_value e lista de membros por grupo.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$LookbackSeconds = 90
$Now       = Get-Date
$StartTime = $Now.AddSeconds(-$LookbackSeconds)

# Grupos com tratamento especial por RID:
# 516 = Domain Controllers
# 521 = Read-only Domain Controllers
# 498 = Enterprise Read-only Domain Controllers
# 517 = Cert Publishers
# Nesses grupos, membros do tipo computer serao ignorados.
$MachineLikeGroupRids = @(516, 521, 498, 517)

# Coleta SID do dominio para montar SIDs dos grupos com tratamento especial
try {
    $domainSid = (Get-ADDomain -ErrorAction Stop).DomainSID.Value
    $machineLikeGroupSids = $MachineLikeGroupRids | ForEach-Object { "$domainSid-$_" }
} catch {
    $result = [PSCustomObject]@{
        generated_at      = $Now.ToString("s")
        collection_start  = $StartTime.ToString("s")
        collection_end    = $Now.ToString("s")
        lookback_seconds  = $LookbackSeconds
        metric_name       = "privileged_group_member_count"
        metric_value      = 0
        error             = $_.Exception.Message
        groups            = @()
    }

    $result | ConvertTo-Json -Depth 5
    exit 1
}

# Coleta todos os grupos privilegiados via adminCount = 1
try {
    $privilegedGroups = Get-ADGroup -Filter { adminCount -eq 1 } -Properties SID -ErrorAction Stop
} catch {
    $result = [PSCustomObject]@{
        generated_at      = $Now.ToString("s")
        collection_start  = $StartTime.ToString("s")
        collection_end    = $Now.ToString("s")
        lookback_seconds  = $LookbackSeconds
        metric_name       = "privileged_group_member_count"
        metric_value      = 0
        error             = $_.Exception.Message
        groups            = @()
    }

    $result | ConvertTo-Json -Depth 5
    exit 1
}

# Coleta membros de cada grupo
$groupSnapshots = foreach ($group in $privilegedGroups) {
    try {
        $members = Get-ADGroupMember -Identity $group.DistinguishedName -ErrorAction Stop
    } catch {
        $members = @()
    }

    # Para os grupos especiais, ignora membros do tipo computer
    if ($machineLikeGroupSids -contains $group.SID.Value) {
        $members = @($members | Where-Object { $_.objectClass -ne "computer" })
    }

    $memberNames = foreach ($member in $members) {
        if ($member.SamAccountName) { $member.SamAccountName }
        else                        { $member.Name }
    }

    $memberNames = @($memberNames | Sort-Object)

    [PSCustomObject]@{
        group        = $group.Name
        member_count = $memberNames.Count
        members      = $memberNames
    }
}

$groupsArray  = [array](@($groupSnapshots) | Where-Object { $_ -ne $null })
$totalMembers = ($groupsArray | Measure-Object -Property member_count -Sum).Sum

if ($null -eq $totalMembers) {
    $totalMembers = 0
}

[PSCustomObject]@{
    generated_at      = $Now.ToString("s")
    collection_start  = $StartTime.ToString("s")
    collection_end    = $Now.ToString("s")
    lookback_seconds  = $LookbackSeconds
    metric_name       = "privileged_group_member_count"
    metric_value      = $totalMembers
    group_count       = $groupsArray.Count
    groups            = $groupsArray
} | ConvertTo-Json -Depth 5

exit 0