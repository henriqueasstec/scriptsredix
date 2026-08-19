param (
    [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
    [string]$hostname,
    [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
    [string]$proxy,
    [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
    [string]$redixpass,
    [Parameter(Mandatory=$false, ValueFromPipeline=$true)]
    [string]$svcuser, 
    [Parameter(Mandatory=$false, ValueFromPipeline=$true)]
    [string]$svcpassword,  
    [Parameter(Mandatory=$false, ValueFromPipeline=$true)]
    [string]$port,
    [parameter()][switch]$Uninstall
)

# Variáveis
$SentinelaAgentFolder = "C:\Program Files\Sentinela"

$binDir =  "$SentinelaAgentFolder" + "\bin"
$sbinDir =  "$SentinelaAgentFolder" + "\sbin"
$etcDir =  "$SentinelaAgentFolder" + "\etc"
$tempDir =  "$SentinelaAgentFolder" + "\temp"
$customDir =  "$SentinelaAgentFolder" + "\custom"

$sqlbinDir = $customDir + "\sql_server\bin"
$sqletcDir = $customDir + "\sql_server\etc"
$sqltempDir = $customDir + "\sql_server\temp"



# Funções
function WebClient {
    [CmdletBinding()]
    param (
        [switch]$Download,
        [switch]$Read,
        [string]$URL,
        [string]$Destination,
        [string]$User,
        [string]$Password
    )

    # Ignore SSL certificate errors
    Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;

public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint srvPoint, X509Certificate certificate, WebRequest request, int certificateProblem) {
        return true;
    }
}
"@
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy

    # Instancia o namespace do NetFramework chamado WebClient, responsável por realizar operações como um WebClient
    $webClient = New-Object System.Net.WebClient

    if ($User) {
        # Converte a senha em segura, para autenticar, em seguida converte o usuário e senha em um objeto seguro
        $webPassword = ConvertTo-SecureString $Password -AsPlainText -Force
        $webClient.Credentials = New-Object System.Management.Automation.PSCredential($User, $webPassword)
    }

    # Tenta realizar o download do arquivo, caso falhe apresenta mensagem de erro
    if ($Download) {
        try {
            $webClient.DownloadFile($URL, $Destination)
            Write-Host "Download successful: $Destination"
        }
        catch {
            Write-Host "Problema para obter o arquivo solicitado `n"
            Write-Host $_.Exception.Message
        }  
    }

    # Tenta realizar a leitura do arquivo informado, caso falhe retorna mensagem de erro
    if ($Read) {
        try {
            $content = $webClient.DownloadString($URL)
            Write-Host "File content:"
            Write-Host $content
        }
        catch {
            Write-Host "Problema para ler o arquivo solicitado `n"
            Write-Host $_.Exception.Message
        }
    }
}


function Unzip-File {
    param (
        [string]$Path,
        [string]$DestinationPath
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    foreach ($entry in $zip.Entries) {
        $fullPath = [System.IO.Path]::Combine($DestinationPath, $entry.FullName)
        
        # Check if the entry is effectively a directory (ends with "/")
        if ($entry.FullName -notmatch '/$') {
            # It's a file, ensure the directory path exists
            $dirPath = [System.IO.Path]::GetDirectoryName($fullPath)
            if (-not (Test-Path $dirPath)) {
                New-Item -ItemType Directory -Force -Path $dirPath > $null
            }
            # Extract the file
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $fullPath, $true)
        } else {
            # The entry is a directory, ensure it's created
            if (-not (Test-Path $fullPath)) {
                New-Item -ItemType Directory -Force -Path $fullPath > $null
            }
        }
    }
    $zip.Dispose()
}


function remove-sentinela{
    Write-Host -ForegroundColor Green "Desinstalando versão anterior `n"
    $service=get-service  -DisplayName *sentinela*
    if ([bool]$service){
    if (($service).Status -eq "Running"){     
         stop-service -DisplayName *sentinela* -Force
        }
         $SENTINELAPROC=Get-Process | Where-Object {$_.Path -match "Sentinela"}
         if ( $SENTINELAPROC -eq $true){
             $SENTINELAPROC | Stop-Process -Force -ErrorAction SilentlyContinue
         }
         $svcsentinela = Get-WmiObject -Class Win32_Service | Where-Object {$_.PathName -match "sentinela"}
         if ($svcsentinela -ne $null){
             $svcsentinela.Delete()
         }
         get-childItem "HKLM:SYSTEM\CurrentControlSet\Services\EventLog\Application\" | Where-Object {$_.name -match "Sentinela"} | Remove-Item -Force -ErrorAction SilentlyContinue
        
    }
    Start-Sleep -Seconds 5
    Write-Host -ForegroundColor Green "Validando e renomeando diretóio $SentinelaAgentFolder `n"
     if ((Test-Path $SentinelaAgentFolder) -eq $true){
        if ((Test-Path 'C:\Program Files\Sentinela_old') -eq $true){
             Remove-Item  'C:\Program Files\Sentinela_old' -Force -Recurse
            }
        try{
           Rename-Item -Path $SentinelaAgentFolder "Sentinela_old" -Force
        }catch{
             Write-Host "Erro para renomear diretório $SentinelaAgentFolder, valide as permissões ou locks no diretório `n"
         exit    
         }    
    }   
}

    

if ([bool]$Uninstall){
    remove-sentinela
    exit
    }


#Transformar hostname para minúsculas
$hostname = $hostname.ToLower()

Write-Host -ForegroundColor Green "Iniciando a instalação do Sentinela agent"
    if ($port -eq $null -or $port -eq "0" -or ![bool]$port) {
    $port=11050
    }


[Net.ServicePointManager]::SecurityProtocol
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Set-ExecutionPolicy -ExecutionPolicy Bypass -Force 
[SecureString]$passsecure= ConvertTo-SecureString -String $redixpass -AsPlainText -Force
$redixcred = new-object -typename System.Management.Automation.PSCredential -argumentlist "sentinela", $passsecure

$testconnection=Test-NetConnection monitoramento-tools.redix.com.br -Port 443
    if ($testconnection.TcpTestSucceeded -eq $false){
       Write-Host -ForegroundColor Red "Falha na comunicação com servidores de download Redix, valide a comunicação externa do servidor e repita a operação."       
       exit 
    }


Write-Host -ForegroundColor Green "Fazendo Download do agente"
if ((Test-Path $env:USERPROFILE\Downloads\sentinela_agent.zip) -eq $true){
    try{
        Remove-Item $env:USERPROFILE\Downloads\sentinela_agent.zip -Force
    
    }catch{
        Write-Host -ForegroundColor Red "Falha para remover $env:USERPROFILE\Downloads\sentinela_agent.zip, valide locks e permissões no arquivo."
        exit 
    }

}

WebClient -Download -URL "https://monitoramento-tools.redix.com.br/downloads/windows/sentinela_agent.zip" -Destination "$env:USERPROFILE\Downloads\sentinela_agent.zip" -User "sentinela" -Password $redixpass

if ((Test-Path $SentinelaAgentFolder) -eq $false){
    New-Item -ItemType Directory -Path $SentinelaAgentFolder -Force | Out-Null
}
else{
     remove-sentinela 
     Write-Host -ForegroundColor Yellow "Sentinela Agent será reinstalado validar conteúdo do diretório C:\Program Files\Sentinela_old"     
    }


try{
    Unzip-File -Path "$env:USERPROFILE\Downloads\sentinela_agent.zip" -DestinationPath $SentinelaAgentFolder -Force
}catch{
    Write-Host "Erro para descomprimir arquivos em $SentinelaAgentFolder, valide as permissões ou locks no diretório"
    exit
}


Write-Host -ForegroundColor Green "Baixando arquivos de configuração"
Start-Sleep -Seconds 5

WebClient -Download -URL "https://monitoramento-tools.redix.com.br/fontes/zabbix_windows/stable/conf/sentinela_agent.conf" -Destination "$etcDir\sentinela_agent.conf" -User "sentinela" -Password $redixpass
WebClient -Download -URL "https://monitoramento-tools.redix.com.br/fontes/zabbix_windows/stable/conf/sentinela_agentd.psk" -Destination "$etcDir\sentinela_agentd.psk" -User "sentinela" -Password $redixpass
WebClient -Download -URL "https://monitoramento-tools.redix.com.br/fontes/zabbix_windows/stable/UserParameter/win_custom_userparameter.conf" -Destination "$etcDir\user_parameters\win_custom_userparameter.conf" -User "sentinela" -Password $redixpass


Write-Host -ForegroundColor Green "Adicionando Regra de Firewall."
$firewallrule=Get-NetFirewallRule | Where-Object {$_.ElementName -match "Sentinela"}

    if ($firewallrule -eq $null){
        New-NetFirewallRule -DisplayName "Redix Sentinela Agent TCP inbound connection" -Direction Inbound -LocalPort $port -Protocol TCP -Action Allow
        New-NetFirewallRule -DisplayName "Redix Sentinela Agent TCP outbound connection" -Direction Outbound -RemotePort 10051 -Protocol TCP -Action Allow
		New-NetFirewallRule -Name "Allow_ICMPv4_In" -DisplayName "Allow ICMPv4 Inbound" -Protocol ICMPv4 -IcmpType Any -Direction Inbound -Action Allow
		New-NetFirewallRule -Name "Allow_ICMPv4_Out" -DisplayName "Allow ICMPv4 Outbound" -Protocol ICMPv4 -IcmpType Any -Direction Outbound -Action Allow
    }

Write-Host -ForegroundColor Green "Criando serviço no Windows"

. "$sbinDir\sentinela_agent.exe" -c "$etcDir\sentinela_agent.conf" -i --multiple-agents 
    

$servicename = Get-WmiObject win32_service | Where-Object {$_.PathName -match "sentinela"} | Select-Object -ExpandProperty name
    if ($servicename -ne $null){
        cmd /c sc config "$servicename" displayname= "Sentinela Agent"
        cmd /c sc description "$servicename" "Serviço de monitoramento Redix."
        cmd /c sc failure "$servicename" reset= 86400 actions= restart/60000/restart/60000/""/0
        if ([bool]$svcuser -and [bool]$password){
            cmd /c sc config "$servicename" obj= "$svcuser" password= "$svcpassword"        
		} elseif ($svcuser) {
            cmd /c sc config "$servicename" obj= "$svcuser"
        }
        $regautodelay=get-childItem "HKLM:SYSTEM\CurrentControlSet\Services\" | Where-Object {$_.name -match "Sentinela"}
    
            if ($regautodelay -ne $null){
                $regautodelay  | set-ItemProperty -Name "DelayedAutostart" -Value "1" -Force
            }
            else{
                $regautodelay  | new-ItemProperty -Name "DelayedAutostart" -Value "1" -Force
            }

        (Get-Content "$($etcDir)\sentinela_agent.conf") -replace “hostname=Sentinela”, “Hostname=$hostname" | Set-Content "$($etcDir)\sentinela_agent.conf" -Force
          
        (Get-Content "$($etcDir)\sentinela_agent.conf") -replace "monitoramento.redix.com.br", ("$proxy") | Set-Content "$($etcDir)\sentinela_agent.conf" -force

        Remove-Item "$env:USERPROFILE\Downloads\sentinela_agent.zip"
    }
    else {
         Write-Host -ForegroundColor red "Erro ao criar serviço, validar logs" 
    }


Write-Host -ForegroundColor Green "Validando instalação do SQL Server"
try {
    $instances = Get-Item 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction SilentlyContinue | Select-Object property
    if ($null -eq $instances) {
        Write-Host "Nenhuma instância do SQL Server encontrada."
    } else {
        Write-Host "Instâncias do SQL Server encontradas:"
        foreach ($instance in $instances.PSObject.Properties) {
            Write-Host -ForegroundColor Cyan "Nome da Instância: $($instance.Value)"            
        }
    Write-Host -ForegroundColor Green "Iniciando download de Scripts SQL SERVER"
    New-Item -Path "$customDir\sql_server\" -ItemType Directory -Force | Out-Null
    if (Test-Path "$env:USERPROFILE\Downloads\sql_server.zip"){
           try{
                Remove-Item "$env:USERPROFILE\Downloads\sql_server.zip" -Force
                WebClient -Download -URL "https://monitoramento-tools.redix.com.br/downloads/windows/sql_server.zip" -Destination "$env:USERPROFILE\Downloads\sql_server.zip" -User "sentinela" -Password $redixpass               
                 
            }catch{
                Write-Host -ForegroundColor Red "Falha para remover $env:USERPROFILE\Downloads\sql_server.zip, valide locks e permissões no arquivo."
                exit                     
            }
    }else{
        WebClient -Download -URL "https://monitoramento-tools.redix.com.br/downloads/windows/sql_server.zip" -Destination "$env:USERPROFILE\Downloads\sql_server.zip" -User "sentinela" -Password $redixpass        
    }
    try{
        Unzip-File -Path "$env:USERPROFILE\Downloads\sql_server.zip" -DestinationPath "$customdir\sql_server" -Force
        Remove-Item "$env:USERPROFILE\Downloads\sql_server.zip" -Force        
    }catch{
        Write-Host -ForegroundColor Red "Erro para descomprimir arquivos em $SentinelaAgentFolder, valide as permissões ou locks no diretório"
        exit
 }

    # Restaura redixdef.ps1 customizado da instalação anterior, se existir
    $oldRedixDef = "C:\Program Files\Sentinela_old\custom\sql_server\etc\redixdef.ps1"
    if (Test-Path $oldRedixDef) {
        Write-Host -ForegroundColor Green "Restaurando redixdef.ps1 customizado da instalação anterior"
        try {
            Copy-Item -Path $oldRedixDef -Destination "$sqletcDir\redixdef.ps1" -Force
        } catch {
            Write-Host -ForegroundColor Red "Falha ao restaurar redixdef.ps1 customizado, valide manualmente em $oldRedixDef"
        }
    } else {
        Write-Host -ForegroundColor Yellow "Nenhum redixdef.ps1 customizado encontrado na instalação anterior, mantendo padrão do pacote"
    }

    Write-Host -ForegroundColor Green "Iniciando atualização de Scripts SQL SERVER"
    try{
        . $binDir\sentinela_update.ps1 -redixpass $redixpass -SqlServer
    }catch{
        Write-Host -ForegroundColor Red "Erro para baixar arquivos em $customdir, valide as permissões no diretório e/ou permissões necessárias no firewall do cliente"
        exit
    }
}
} catch {
    Write-Host "Erro ao acessar o Registro do Windows para buscar instâncias do SQL Server."
    exit
}

Write-Host -ForegroundColor Green "Iniciando o Sentinela Agent"
try{
    Start-Service -DisplayName "Sentinela Agent"
}
catch{
    Write-Host "Erro ao tentar iniciar o serviço: $($_.Exception.Message)"
}
Get-Service -DisplayName "Sentinela Agent" | ft -AutoSize -Wrap

#Atualização de scripts
Write-Host -ForegroundColor Green "Atualizando fontes."
. $binDir\sentinela_update.ps1 -redixpass $redixpass