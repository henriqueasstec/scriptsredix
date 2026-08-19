# Mantém apenas arquivos dos últimos 15 dias
# Execução: Diariamente às 3:00 via Agendador de Tarefas

$CaminhoLogs = "D:\Geral\TASY_LOGS"
$DiasParaManter = 15
$DataLimite = (Get-Date).AddDays(-$DiasParaManter)

if (Test-Path $CaminhoLogs) {
    Get-ChildItem -Path $CaminhoLogs -File -Recurse | 
        Where-Object { $_.LastWriteTime -lt $DataLimite } | 
        Remove-Item -Force
}