param([Parameter(Mandatory = $true)][string]$Script)

$ErrorActionPreference = "Stop"
$Etapa = "Inicializacao"

try {
    # Verifica se o script de coleta existe
    $Etapa = "Validacao do script"
    $ScriptPath = Join-Path $PSScriptRoot $Script

    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        throw "Script nao encontrado: $ScriptPath"
    }

    # Identifica a versao do Veeam pelo executavel
    $Etapa = "Identificacao do Veeam"
    $CorePath = (Get-ItemProperty 'HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication').CorePath

    if (-not $CorePath) {
        throw "Caminho de instalacao do Veeam nao encontrado."
    }

    $VeeamExe = Join-Path $CorePath 'Veeam.Backup.Service.exe'
    $InfoVeeam = (Get-Item -LiteralPath $VeeamExe).VersionInfo
    $Versao = $InfoVeeam.FileMajorPart
    $VersaoMenor = $InfoVeeam.FileMinorPart

    # Seleciona o PowerShell conforme a versao do Veeam
    $Etapa = "Identificacao do PowerShell"

    if ($Versao -ge 13) {
        $Executavel = "pwsh.exe"
    } else {
        $Executavel = "powershell.exe"
    }

    # Encontra o executavel pelo PATH
    $PowerShell = (Get-Command $Executavel -CommandType Application -ErrorAction Stop).Source

    # Valida a versao do PowerShell 7 pela versao do executavel
    if ($Versao -ge 13) {
        $Etapa = "Validacao da versao do PowerShell"
        $InfoPS = (Get-Item -LiteralPath $PowerShell).VersionInfo
        $VersaoPS = [version]::new(
            $InfoPS.ProductMajorPart,
            $InfoPS.ProductMinorPart,
            $InfoPS.ProductBuildPart
        )

        # Requisitos: Veeam 13.0 e Veeam 13.1.1
        if ($Versao -eq 13 -and $VersaoMenor -eq 0) {
            $VersaoMinima = [version]'7.4.13'
        } else {
            $VersaoMinima = [version]'7.6.3'
        }

        if ($VersaoPS -lt $VersaoMinima) {
            throw "Veeam $Versao.$VersaoMenor requer PowerShell $VersaoMinima ou superior. Encontrado: $VersaoPS ($PowerShell)"
        }

        # PowerShell 7 escreve UTF-8; configura o launcher para decodificar corretamente.
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    }

    # Repassa a saida diretamente ao Zabbix, sem capturar 2>&1
    $Etapa = "Execucao da coleta"
    & $PowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ScriptPath

    if ($LASTEXITCODE -ne 0) {
        throw "Falha na coleta $Script (codigo $LASTEXITCODE) utilizando $PowerShell"
    }

    exit 0
}
catch {
    Write-Output "SENTINELA_ERROR [$Etapa] [$Script]: $($_.Exception.Message)"
    exit 1
}