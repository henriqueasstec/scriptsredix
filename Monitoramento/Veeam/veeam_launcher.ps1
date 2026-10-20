param([string]$Script)

# Identifica a versão do Veeam
$CorePath = (Get-ItemProperty 'HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication').CorePath
$Versao = (Get-Item (Join-Path $CorePath 'Veeam.Backup.Service.exe')).VersionInfo.FileMajorPart

# Seleciona o PowerShell
if ($Versao -ge 13) {
    $PS = "C:\Program Files\PowerShell\7\pwsh.exe"
} else {
    $PS = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
}

# Executa o script de coleta
& $PS -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $Script)
exit $LASTEXITCODE