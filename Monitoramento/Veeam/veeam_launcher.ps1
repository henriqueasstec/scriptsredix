param([string]$Script)

$ErrorActionPreference = "Stop"

# Identifica a versão do Veeam
$CorePath = (Get-ItemProperty 'HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication').CorePath
$Versao = (Get-Item (Join-Path $CorePath 'Veeam.Backup.Service.exe')).VersionInfo.FileMajorPart

# Seleciona o PowerShell pelo registro
if ($Versao -ge 13) {

    $Reg = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\PowerShellCore\InstalledVersions\31ab5147-9a97-4452-8443-d9709f0516e1'
    $PS = Join-Path $Reg.InstallLocation 'pwsh.exe'

} else {

    $Reg = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\PowerShell\3\PowerShellEngine'
    $PS = Join-Path $Reg.ApplicationBase 'powershell.exe'

}

# Verifica se o PowerShell existe
if (-not (Test-Path $PS)) {
    throw "PowerShell nao encontrado: $PS"
}

# Executa a coleta
& $PS -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $Script)
exit $LASTEXITCODE