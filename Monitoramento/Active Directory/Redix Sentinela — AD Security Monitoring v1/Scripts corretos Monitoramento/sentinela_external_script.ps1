param (   
    [parameter()][switch]$CPU,
    [parameter()][switch]$MEM,
    [parameter()][switch]$UPDATE,
    [parameter()][switch]$RDP,
    [parameter()][switch]$RDP_CPU,
    [parameter()][switch]$RDP_MEM,
    [parameter()][switch]$RDP_USER,
    [parameter()][switch]$AD_PRIV_GROUP_LOGS,
    [Parameter(Mandatory=$false)][switch]$SqlServer,
    [string]$redixpass
)

# Variáveis
# Importa variáveis Redix
. "C:\Program Files\Sentinela\etc\redixdef.ps1"

###FAILBACK###
if ([string]::IsNullOrEmpty($binDir)) { 
    $binDir = "C:\Program Files\Sentinela\bin" 
}
if ([string]::IsNullOrEmpty($etcDir)) { 
    $etcDir = "C:\Program Files\Sentinela\etc" 
}
if ([string]::IsNullOrEmpty($sbinDir)) { 
    $sbinDir = "C:\Program Files\Sentinela\sbin" 
}
if ([string]::IsNullOrEmpty($tempDir)) { 
    $tempDir = "C:\Program Files\Sentinela\temp" 
}

#####Funções####
. "C:\Program Files\Sentinela\etc\redixfunctions.ps1"

if ($CPU){
    . $binDir\uso_recurso.ps1 -CPU
}
if ($MEM){
    . $binDir\uso_recurso.ps1 -MEM
}
if ($RDP) {
    & "$binDir\rdp.ps1"
}
if ($RDP_CPU) {
    & "$binDir\rdp.ps1" -CPU
}
if ($RDP_MEM) {
    & "$binDir\rdp.ps1" -MEM
}
if ($AD_PRIV_GROUP_LOGS) {
    & "$binDir\ad_security_privileged_groups_logs.ps1"
}
if ($RDP_USER) {
    & "$binDir\rdp.ps1" -USER
}
if ($UPDATE){
    . $binDir\sentinela_update.ps1 -redixpass $redixpass -SqlServer:$SqlServer
}