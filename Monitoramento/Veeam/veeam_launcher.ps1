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
    $Versao = (Get-Item -LiteralPath $VeeamExe).VersionInfo.FileMajorPart

    # Define qual PowerShell utilizar conforme a versao do Veeam
    $Etapa = "Identificacao do PowerShell"

    if ($Versao -ge 13) {
        $Executavel = "pwsh.exe"
    } else {
        $Executavel = "powershell.exe"
    }

    # Localiza o executavel pelo PATH do Windows
    $PowerShell = (Get-Command $Executavel -CommandType Application -ErrorAction Stop).Source

    # Executa o script de coleta
    $Etapa = "Execucao da coleta"
    $Saida = & $PowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ScriptPath 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Falha na coleta (codigo $LASTEXITCODE): $(($Saida | Out-String).Trim())"
    }

    # Retorna o resultado original ao Zabbix
    $Saida
    exit 0

}
catch {
    Write-Output "SENTINELA_ERROR [$Etapa] [$Script]: $($_.Exception.Message)"
    exit 1
}