# sentinela_pai.ps1
# Script orquestrador (script "pai") do Sentinela.
# Chamado pela Tarefa Agendada a cada 60 segundos. Responsavel por:
#   1. Rodar ad_privileged_groups_get.ps1, comparar <GRUPO>.txt com
#      <GRUPO>.previous.txt e, em caso de divergencia, rodar
#      ad_privileged_groups_logs.ps1 e enviar e-mail de alerta.
#   2. Rodar ad_brute_force_full.ps1, ler brute_force_status.txt e,
#      se metric_value > threshold, enviar e-mail de alerta.
# Este script decide a acao (e-mail). Os scripts filhos so coletam dados.

#region Configuracao
$BinPath  = "C:\Program Files\Sentinela\bin"
$TempPath = "C:\Program Files\Sentinela\temp"

$PrivilegedGroupsPath = Join-Path $TempPath "privilegedGroups"
$BruteForceStatusFile = Join-Path $TempPath "bruteForce\brute_force_status.txt"

$GetScript        = Join-Path $BinPath "ad_privileged_groups_get.ps1"
$LogsScript       = Join-Path $BinPath "ad_privileged_groups_logs.ps1"
$BruteForceScript = Join-Path $BinPath "ad_brute_force_full.ps1"

# Threshold do brute force - tentativas no metric_value acima disso geram alerta
$BruteForceThreshold = 10

# Destinatarios do alerta - adicionar mais e-mails neste array
$EmailRecipients = @(
    "henrique.santos@redix.com.br"
)

# Configuracao SMTP (Gmail)
# SmtpAppPassword = senha de app do Gmail (16 caracteres, sem espacos), em texto
# plano por decisao do Henrique - nao precisa de seguranca adicional por enquanto.
$SmtpServer      = "smtp.gmail.com"
$SmtpPort        = 587
$SmtpFromAddress = "monitoramentoredix@gmail.com"
$SmtpAppPassword = "iofkaopdgxghxjzd"
#endregion

#region Funcao: template HTML do e-mail
function New-AlertHtml {
    param(
        [string]$Title,
        [string[]]$FactsHtml,
        [string]$LogsHtml
    )

    $generatedAt = Get-Date -Format "dd/MM/yyyy HH:mm:ss"

    return @"
<html>
<body style="font-family:Segoe UI, Arial, sans-serif; background-color:#f2f2f2; padding:24px; margin:0;">
  <table style="max-width:620px; margin:0 auto; background:#ffffff; border-radius:8px; border:1px solid #e0e0e0; overflow:hidden; border-collapse:collapse;">
    <tr>
      <td style="background-color:#1f2d3d; color:#ffffff; padding:18px 24px;">
        <span style="font-size:17px; font-weight:600;">Sentinela AD</span><br/>
        <span style="font-size:13px; color:#cbd5e1;">Alerta de seguranca</span>
      </td>
    </tr>
    <tr>
      <td style="padding:20px 24px 4px 24px;">
        <h2 style="margin:0 0 14px 0; font-size:16px; color:#1f2d3d;">$Title</h2>
        <table style="width:100%; border-collapse:collapse; font-size:13px; color:#333;">
          $($FactsHtml -join "`n          ")
        </table>
      </td>
    </tr>
    <tr>
      <td style="padding:8px 24px 20px 24px;">
        <div style="font-size:13px; font-weight:600; color:#555; border-bottom:1px solid #eee; padding-bottom:6px; margin-bottom:10px;">Logs</div>
        $LogsHtml
      </td>
    </tr>
    <tr>
      <td style="background-color:#fafafa; padding:12px 24px; font-size:11px; color:#999;">
        Gerado automaticamente em $generatedAt - Sentinela AD
      </td>
    </tr>
  </table>
</body>
</html>
"@
}
#endregion

#region Funcao: envio de e-mail
function Send-AlertEmail {
    param(
        [string]$Subject,
        [string]$HtmlBody
    )

    $securePassword = ConvertTo-SecureString -String $SmtpAppPassword -AsPlainText -Force
    $credential     = New-Object System.Management.Automation.PSCredential($SmtpFromAddress, $securePassword)

    try {
        Send-MailMessage -SmtpServer $SmtpServer -Port $SmtpPort -UseSsl `
            -From $SmtpFromAddress -To $EmailRecipients `
            -Subject $Subject -Body $HtmlBody -BodyAsHtml `
            -Encoding ([System.Text.Encoding]::UTF8) `
            -Credential $credential -ErrorAction Stop
    } catch {
        Write-Error "Falha ao enviar e-mail '$Subject': $($_.Exception.Message)"
    }
}
#endregion

#region 1. Grupos privilegiados - GET + diff + alerta
try {
    & $GetScript
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "ad_privileged_groups_get.ps1 retornou exit code $LASTEXITCODE - seguindo com os arquivos disponiveis."
    }
} catch {
    Write-Error "Falha ao executar ad_privileged_groups_get.ps1: $($_.Exception.Message)"
}

try {
    $currentFiles = Get-ChildItem -Path $PrivilegedGroupsPath -Filter '*.txt' -File -ErrorAction Stop |
        Where-Object { $_.Name -notlike '*.previous.txt' }
} catch {
    $currentFiles = @()
}

foreach ($file in $currentFiles) {

    $groupName    = $file.BaseName
    $currentPath  = $file.FullName
    $previousPath = Join-Path $PrivilegedGroupsPath "$groupName.previous.txt"

    # Sem baseline anterior (primeira execucao do grupo) - so registra, nao alerta
    if (-not (Test-Path -Path $previousPath)) {
        continue
    }

    $currentMembers  = @(Get-Content -Path $currentPath  -ErrorAction SilentlyContinue)
    $previousMembers = @(Get-Content -Path $previousPath -ErrorAction SilentlyContinue)

    $diff = Compare-Object -ReferenceObject $previousMembers -DifferenceObject $currentMembers

    if (-not $diff) {
        continue
    }

    $added   = @($diff | Where-Object { $_.SideIndicator -eq '=>' } | Select-Object -ExpandProperty InputObject)
    $removed = @($diff | Where-Object { $_.SideIndicator -eq '<=' } | Select-Object -ExpandProperty InputObject)

    # Roda o script de detalhe (logs). Falha aqui NAO pode bloquear o e-mail -
    # a prioridade e nunca perder o alerta de que o grupo mudou.
    $logsHtml = "<p style='color:#999; font-size:12px; margin:0;'>Não foi possível coletar os logs detalhados desta alteração.</p>"

    try {
        $logsRaw  = & $LogsScript 2>$null
        $logsJson = $logsRaw | ConvertFrom-Json -ErrorAction Stop

        if ($logsJson.changes -and @($logsJson.changes).Count -gt 0) {
            $rows = foreach ($c in $logsJson.changes) {
                "<tr style='font-size:12px;'>" +
                "<td style='padding:4px 8px; border-bottom:1px solid #eee;'>$($c.time)</td>" +
                "<td style='padding:4px 8px; border-bottom:1px solid #eee;'>$($c.action)</td>" +
                "<td style='padding:4px 8px; border-bottom:1px solid #eee;'>$($c.group)</td>" +
                "<td style='padding:4px 8px; border-bottom:1px solid #eee;'>$($c.member)</td>" +
                "<td style='padding:4px 8px; border-bottom:1px solid #eee;'>$($c.performed_by)</td>" +
                "</tr>"
            }

            $logsHtml = "<table style='width:100%; border-collapse:collapse;'>" +
                "<tr style='font-size:12px; font-weight:600; color:#555;'>" +
                "<td style='padding:4px 8px;'>Hora</td><td style='padding:4px 8px;'>Ação</td>" +
                "<td style='padding:4px 8px;'>Grupo</td><td style='padding:4px 8px;'>Membro</td>" +
                "<td style='padding:4px 8px;'>Executado por</td></tr>" +
                ($rows -join "") + "</table>"
        } else {
            $logsHtml = "<p style='color:#999; font-size:12px; margin:0;'>O log de eventos não retornou detalhes dentro da janela monitorada.</p>"
        }
    } catch {
        # mantem o $logsHtml padrao de falha definido acima - fluxo de alerta segue
    }

    $facts = New-Object System.Collections.Generic.List[string]
    $facts.Add("<tr><td style='padding:4px 0; font-weight:600; width:160px;'>Grupo</td><td>$groupName</td></tr>")

    foreach ($u in $added) {
        $facts.Add("<tr><td style='padding:4px 0; font-weight:600;'>Usuário adicionado</td><td style='color:#1a7a3c;'>$u</td></tr>")
    }
    foreach ($u in $removed) {
        $facts.Add("<tr><td style='padding:4px 0; font-weight:600;'>Usuário removido</td><td style='color:#b02a2a;'>$u</td></tr>")
    }

    $html = New-AlertHtml -Title "Modificação no grupo $groupName" -FactsHtml $facts -LogsHtml $logsHtml

    Send-AlertEmail -Subject "[Sentinela AD] Modificação no grupo $groupName" -HtmlBody $html
}
#endregion

#region 2. Brute force - coleta + threshold + alerta
try {
    & $BruteForceScript
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "ad_brute_force_full.ps1 retornou exit code $LASTEXITCODE."
    }
} catch {
    Write-Error "Falha ao executar ad_brute_force_full.ps1: $($_.Exception.Message)"
}

try {
    $bruteForceData = Get-Content -Path $BruteForceStatusFile -Raw -ErrorAction Stop |
        ConvertFrom-Json -ErrorAction Stop

    if ($bruteForceData.metric_value -gt $BruteForceThreshold) {

        $facts = @(
            "<tr><td style='padding:4px 0; font-weight:600; width:160px;'>IP de origem</td><td>$($bruteForceData.client_address)</td></tr>"
            "<tr><td style='padding:4px 0; font-weight:600;'>Usuário alvo</td><td>$($bruteForceData.target_user)</td></tr>"
            "<tr><td style='padding:4px 0; font-weight:600;'>Tentativas (janela de $($bruteForceData.lookback_seconds)s)</td><td style='color:#b02a2a;'>$($bruteForceData.metric_value)</td></tr>"
            "<tr><td style='padding:4px 0; font-weight:600;'>Kerberos / NTLM</td><td>$($bruteForceData.by_protocol.kerberos) / $($bruteForceData.by_protocol.ntlm)</td></tr>"
            "<tr><td style='padding:4px 0; font-weight:600;'>Primeira / última tentativa</td><td>$($bruteForceData.first_seen) - $($bruteForceData.last_seen)</td></tr>"
        )

        $logsHtml = "<pre style='font-size:11px; background:#f7f7f7; padding:10px; border-radius:4px; white-space:pre-wrap;'>$($bruteForceData | ConvertTo-Json -Depth 5)</pre>"

        $html = New-AlertHtml -Title "Possível Brute Force detectado" -FactsHtml $facts -LogsHtml $logsHtml

        Send-AlertEmail -Subject "[Sentinela AD] Possível Brute Force - $($bruteForceData.client_address)" -HtmlBody $html
    }
} catch {
    Write-Error "Falha ao avaliar status de brute force em '$BruteForceStatusFile': $($_.Exception.Message)"
}
#endregion