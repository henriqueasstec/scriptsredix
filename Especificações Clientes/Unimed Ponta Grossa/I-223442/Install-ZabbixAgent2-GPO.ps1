# Install-ZabbixAgent2-GPO.ps1
$ErrorActionPreference = 'Stop'

$ZabbixServer = 'zabbix.unimedpg.com.br'
$Share        = '\\unimedpg.local\SYSVOL\unimedpg.local\scripts\zabbix-agent2'
$MsiName      = 'zabbix_agent2-7.4.9-windows-amd64-openssl.msi'

$OldAgentDir = 'C:\Program Files\Zabbix Agent'
$OldConf     = 'C:\Program Files\Zabbix Agent\zabbix_agentd.conf'

$InstallDir  = 'C:\Program Files\Zabbix Agent 2'
$LocalDir    = 'C:\Windows\Temp\ZabbixAgent2Deploy'
$DeployLog   = 'C:\Windows\Temp\zabbix_agent2_gpo_deploy.log'
$MsiLog      = 'C:\Windows\Temp\zabbix_agent2_msi_install.log'
$ConfFile    = Join-Path $LocalDir 'zabbix_agent2.conf'
$DestConf    = Join-Path $InstallDir 'zabbix_agent2.conf'
$LocalMsi    = Join-Path $LocalDir $MsiName

$MaxDeployLogSizeMB = 5
$KeepLogDays        = 30

function Initialize-DeployLog {
    if (Test-Path $DeployLog) {
        $logFile = Get-Item $DeployLog -ErrorAction SilentlyContinue

        if ($logFile -and $logFile.Length -gt ($MaxDeployLogSizeMB * 1MB)) {
            Remove-Item $DeployLog -Force -ErrorAction SilentlyContinue
        }
    }

    Get-ChildItem 'C:\Windows\Temp' -Filter 'zabbix_agent_old_uninstall_*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$KeepLogDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Write-DeployLog {
    param([string]$Message)

    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message" |
        Out-File -FilePath $DeployLog -Append -Encoding utf8
}

function Test-IsSentinela {
    param($ServiceOrApp)

    $name        = "$($ServiceOrApp.Name)"
    $displayName = "$($ServiceOrApp.DisplayName)"
    $pathName    = "$($ServiceOrApp.PathName)"
    $uninstall   = "$($ServiceOrApp.UninstallString)"
    $installLoc  = "$($ServiceOrApp.InstallLocation)"

    return (
        $name        -match 'Sentinela' -or
        $displayName -match 'Sentinela' -or
        $pathName    -match 'Sentinela' -or
        $uninstall   -match 'Sentinela' -or
        $installLoc  -match 'Sentinela'
    )
}

function Get-MainZabbixAgent2Service {
    Get-CimInstance Win32_Service |
        Where-Object {
            -not (Test-IsSentinela $_) -and
            (
                $_.DisplayName -eq 'Zabbix Agent 2' -or
                $_.Name -eq 'Zabbix Agent 2'
            )
        } |
        Select-Object -First 1
}

function Get-ZabbixConfValue {
    param(
        [string]$Path,
        [string]$Key
    )

    if (-not (Test-Path $Path)) {
        return $null
    }

    $pattern = "^\s*$([regex]::Escape($Key))\s*=\s*(.+?)\s*$"

    $line = Get-Content $Path -ErrorAction SilentlyContinue |
        Where-Object {
            $_ -match $pattern -and $_ -notmatch '^\s*#'
        } |
        Select-Object -Last 1

    if ($line -match $pattern) {
        return $Matches[1].Trim()
    }

    return $null
}

try {
    Initialize-DeployLog

    Write-DeployLog '===== Iniciando deploy do Zabbix Agent 2 via GPO ====='

    New-Item -ItemType Directory -Force -Path $LocalDir | Out-Null

    $sourceMsi = Join-Path $Share $MsiName

    if (-not (Test-Path $sourceMsi)) {
        throw "MSI não encontrado em $sourceMsi"
    }

    # Define o hostname final:
    # 1. Tenta preservar do Agent antigo.
    # 2. Se não existir, tenta preservar do Agent 2 já instalado.
    # 3. Se não existir nenhum dos dois, usa o nome do Windows.
    $OldHostname = Get-ZabbixConfValue -Path $OldConf -Key 'Hostname'
    $ExistingAgent2Hostname = Get-ZabbixConfValue -Path $DestConf -Key 'Hostname'

    if (-not [string]::IsNullOrWhiteSpace($OldHostname)) {
        $FinalHostname = $OldHostname
        Write-DeployLog "Hostname antigo encontrado e preservado: $FinalHostname"
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ExistingAgent2Hostname)) {
        $FinalHostname = $ExistingAgent2Hostname
        Write-DeployLog "Hostname do Agent 2 já instalado preservado: $FinalHostname"
    }
    else {
        $FinalHostname = $env:COMPUTERNAME.ToUpper()
        Write-DeployLog "Hostname não encontrado em configuração anterior. Usando COMPUTERNAME: $FinalHostname"
    }

    # Cria configuração do Agent 2 principal.
    $ConfLines = @(
        'LogType=file'
        "LogFile=$InstallDir\zabbix_agent2.log"
        'LogFileSize=10'
        "Server=$ZabbixServer"
        "ServerActive=$ZabbixServer"
        "Hostname=$FinalHostname"
        'ListenPort=10050'
        'Timeout=3'
        'Include=.\zabbix_agent2.d\plugins.d\*.conf'
    )

    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($ConfFile, $ConfLines, $Utf8NoBom)

    # Para serviços antigos do Zabbix Agent, mas NUNCA toca no Sentinela.
    $oldServices = Get-CimInstance Win32_Service |
        Where-Object {
            -not (Test-IsSentinela $_) -and
            $_.DisplayName -like 'Zabbix Agent*' -and
            $_.DisplayName -notlike 'Zabbix Agent 2*'
        }

    foreach ($svc in $oldServices) {
        Write-DeployLog "Parando serviço antigo: Name=$($svc.Name), DisplayName=$($svc.DisplayName)"
        sc.exe stop "$($svc.Name)" | Out-Null
        Start-Sleep -Seconds 5
    }

    # Remove Agent antigo instalado por MSI, mas NUNCA remove nada com Sentinela.
    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $oldApps = Get-ItemProperty $uninstallRoots -ErrorAction SilentlyContinue |
        Where-Object {
            -not (Test-IsSentinela $_) -and
            $_.DisplayName -match '^Zabbix Agent($| )' -and
            $_.DisplayName -notmatch 'Zabbix Agent 2'
        }

    foreach ($app in $oldApps) {
        $productCode = $null

        if ($app.PSChildName -match '^\{[0-9A-Fa-f-]{36}\}$') {
            $productCode = $app.PSChildName
        }
        elseif ($app.UninstallString -match '\{[0-9A-Fa-f-]{36}\}') {
            $productCode = $Matches[0]
        }

        if ($productCode) {
            $oldLog = "C:\Windows\Temp\zabbix_agent_old_uninstall_$($productCode.Trim('{}')).log"

            Write-DeployLog "Desinstalando Agent antigo: $($app.DisplayName) - $productCode"

            $p = Start-Process msiexec.exe `
                -ArgumentList "/x $productCode /qn /norestart /l*v `"$oldLog`"" `
                -Wait `
                -PassThru

            Write-DeployLog "Uninstall exit code: $($p.ExitCode)"
        }
        else {
            Write-DeployLog "Agent antigo encontrado, mas sem ProductCode MSI: $($app.DisplayName)"
        }
    }

    # Remove serviços antigos órfãos, mas NUNCA remove Sentinela.
    $oldServicesAfter = Get-CimInstance Win32_Service |
        Where-Object {
            -not (Test-IsSentinela $_) -and
            $_.DisplayName -like 'Zabbix Agent*' -and
            $_.DisplayName -notlike 'Zabbix Agent 2*'
        }

    foreach ($svc in $oldServicesAfter) {
        Write-DeployLog "Removendo serviço antigo órfão: Name=$($svc.Name), DisplayName=$($svc.DisplayName)"
        sc.exe delete "$($svc.Name)" | Out-Null
    }

    # Remove forçado a pasta antiga do Zabbix Agent, se sobrar.
    # Isso só remove C:\Program Files\Zabbix Agent.
    # Não remove Sentinela Agent.
    if (Test-Path $OldAgentDir) {
        Write-DeployLog "Removendo pasta antiga do Zabbix Agent: $OldAgentDir"
        Remove-Item $OldAgentDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Verifica se o Agent 2 principal já está instalado.
    # Importante: não considera Zabbix Agent 2 [Sentinela].
    $agent2Service = Get-MainZabbixAgent2Service

    $installedNow = $false

    if (-not $agent2Service) {
        Copy-Item $sourceMsi $LocalMsi -Force

        Write-DeployLog "Instalando Zabbix Agent 2 principal com Hostname=$FinalHostname"

        $args = @(
            "/i `"$LocalMsi`""
            "/qn"
            "/norestart"
            "/l*v `"$MsiLog`""
            "SERVER=$ZabbixServer"
            "SERVERACTIVE=$ZabbixServer"
            "HOSTNAME=$FinalHostname"
            "INSTALLFOLDER=`"$InstallDir`""
            "STARTUPTYPE=delayed"
            "NONMSICONFNAME=`"$ConfFile`""
        ) -join ' '

        $p = Start-Process msiexec.exe -ArgumentList $args -Wait -PassThru

        Write-DeployLog "Install exit code: $($p.ExitCode)"

        if ($p.ExitCode -notin @(0, 3010)) {
            throw "Falha na instalação do MSI. Exit code: $($p.ExitCode)"
        }

        $installedNow = $true
        Start-Sleep -Seconds 2
    }
    else {
        Write-DeployLog "Zabbix Agent 2 principal já instalado: Name=$($agent2Service.Name), DisplayName=$($agent2Service.DisplayName)"
    }

    # Garante que o arquivo final fique com a configuração esperada.
    $configChanged = $true

    if (Test-Path $DestConf) {
        $srcHash = (Get-FileHash $ConfFile).Hash
        $dstHash = (Get-FileHash $DestConf).Hash
        $configChanged = ($srcHash -ne $dstHash)
    }

    if ($configChanged) {
        Write-DeployLog "Atualizando configuração em $DestConf"
        Copy-Item $ConfFile $DestConf -Force
    }
    else {
        Write-DeployLog 'Configuração do Agent 2 já está atualizada. Nenhuma alteração necessária.'
    }

    # Reinicia somente o Agent 2 principal, nunca o Sentinela.
    if ($installedNow -or $configChanged) {
        $agent2Service = Get-MainZabbixAgent2Service

        if ($agent2Service) {
            Write-DeployLog "Configurando serviço principal como delayed-auto: Name=$($agent2Service.Name), DisplayName=$($agent2Service.DisplayName)"
            sc.exe config "$($agent2Service.Name)" start= delayed-auto | Out-Null

            Write-DeployLog "Reiniciando serviço principal: Name=$($agent2Service.Name), DisplayName=$($agent2Service.DisplayName)"
            Restart-Service -Name $agent2Service.Name -Force
        }
        else {
            throw 'Serviço Zabbix Agent 2 principal não encontrado após instalação.'
        }
    }
    else {
        Write-DeployLog 'Serviço do Agent 2 não foi reiniciado porque não houve instalação nem alteração de configuração.'
    }

    # Limpa pasta temporária usada pelo deploy.
    if (Test-Path $LocalDir) {
        Write-DeployLog "Limpando pasta temporária: $LocalDir"
        Remove-Item $LocalDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Remove a tarefa agendada local, caso ela exista.
    $TaskName = 'Deploy Zabbix Agent 2'

    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-DeployLog "Tarefa agendada removida: $TaskName"
    }
    catch {
        Write-DeployLog "Aviso: não foi possível remover a tarefa agendada $TaskName"
    }

    Write-DeployLog 'Deploy concluído com sucesso.'
    exit 0
}
catch {
    Write-DeployLog "ERRO: $($_.Exception.Message)"
    exit 1
}