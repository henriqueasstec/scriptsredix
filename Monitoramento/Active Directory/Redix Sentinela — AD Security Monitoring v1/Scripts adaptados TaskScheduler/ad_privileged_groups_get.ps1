# ad_privileged_groups_snapshot.ps1
# Coleta o estado atual (GET) de todos os grupos privilegiados do dominio
# (adminCount = 1), exceto os grupos de conta de maquina (Domain Controllers,
# RODC, Cert Publishers etc).
#
# Para cada grupo, mantem dois arquivos:
#   GroupName.txt           -> coleta da execucao atual (ultima)
#   GroupName.previous.txt  -> coleta da execucao anterior (penultima)
#
# Isso permite que um script "pai" compare ultima x penultima e decida se
# houve alteracao real (e dispare e-mail/outro script). Este script aqui
# NAO compara, NAO decide acao e NAO envia e-mail - so coleta e rotaciona.

$OutputPath = "C:\Program Files\Sentinela\temp\privilegedGroups"

if (-not (Test-Path -Path $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

# Grupos a EXCLUIR do monitoramento, por RID/SID (nao por nome, pois o nome
# vem localizado em pt-BR). Motivo: membros sao contas de maquina, nao de usuario.
#   516 = Domain Controllers
#   521 = Read-only Domain Controllers
#   498 = Enterprise Read-only Domain Controllers (so existe no dominio raiz da floresta)
#   517 = Cert Publishers (membros sao contas de computador dos servidores CA)
$ExcludedGroupRids = @(516, 521, 498, 517)

try {
    $domainSid = (Get-ADDomain -ErrorAction Stop).DomainSID.Value
} catch {
    Write-Error "Falha ao obter o SID do dominio: $($_.Exception.Message)"
    exit 1
}

$excludedSids = $ExcludedGroupRids | ForEach-Object { "$domainSid-$_" }

# Coleta dinamica dos grupos privilegiados via adminCount = 1, removendo os grupos de maquina
try {
    $privilegedGroups = Get-ADGroup -Filter { adminCount -eq 1 } -Properties SID -ErrorAction Stop |
        Where-Object { $excludedSids -notcontains $_.SID.Value }
} catch {
    Write-Error "Falha ao coletar grupos privilegiados: $($_.Exception.Message)"
    exit 1
}

# Nomes de arquivo esperados (atual + anterior) para a coleta de hoje
$expectedFileNames = foreach ($g in $privilegedGroups) {
    $safe = $g.Name -replace '[\\/:*?"<>|]', '_'
    "$safe.txt"
    "$safe.previous.txt"
}

# Remove orfaos (grupo que saiu do filtro ou foi desprotegido) - cobre tanto
# .txt quanto .previous.txt, ja que o filtro de extensao pega os dois
try {
    Get-ChildItem -Path $OutputPath -Filter '*.txt' -File -ErrorAction Stop |
        Where-Object { $expectedFileNames -notcontains $_.Name } |
        Remove-Item -Force -ErrorAction SilentlyContinue
} catch {
    # pasta vazia ou sem arquivos .txt ainda - normal na primeira execucao
}

$failedGroups = @()

foreach ($group in $privilegedGroups) {

    $groupName = $group.Name
    $safeName  = $groupName -replace '[\\/:*?"<>|]', '_'

    $currentPath  = Join-Path -Path $OutputPath -ChildPath "$safeName.txt"
    $previousPath = Join-Path -Path $OutputPath -ChildPath "$safeName.previous.txt"

    try {
        # Rotaciona: o que era "atual" na execucao anterior passa a ser "anterior" agora
        if (Test-Path -Path $currentPath) {
            Copy-Item -Path $currentPath -Destination $previousPath -Force -ErrorAction Stop
        }

        # Get-ADGroupMember pode lancar erro terminante se o grupo tiver um membro
        # com SID orfao (objeto excluido/foreign security principal nao resolvido).
        # Quando isso ocorre, a coleta desse grupo fica vazia nesta execucao
        # (o .previous.txt acima ja preserva o estado anterior intacto).
        try {
            $members = Get-ADGroupMember -Identity $group.DistinguishedName -ErrorAction Stop
        } catch {
            $members = @()
        }

        $memberNames = foreach ($member in $members) {
            if ($member.SamAccountName) {
                $member.SamAccountName
            } else {
                $member.Name
            }
        }

        $memberNames = $memberNames | Sort-Object

        Set-Content -Path $currentPath -Value $memberNames -Encoding UTF8 -ErrorAction Stop
    } catch {
        $failedGroups += [PSCustomObject]@{
            Group = $groupName
            Path  = $currentPath
            Error = $_.Exception.Message
        }
    }
}

if ($failedGroups.Count -gt 0) {
    Write-Warning "Falha ao processar $($failedGroups.Count) grupo(s). Verifique permissao de escrita em '$OutputPath' para a conta que executa o script."
    $failedGroups | ForEach-Object { Write-Warning "  - $($_.Group): $($_.Error)" }
    exit 1
}

exit 0