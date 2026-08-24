###### Inicio Modulos #####
Function Compress-7zip {
    Param(
        [string]$Destination,
        [string]$Source
    )
    
    # Caminho direto para o executável conforme solicitado
    $7z = "C:\Program Files\7-Zip\7z.exe"
    
    # Verifica se o executável do 7z existe no caminho especificado
    if (Test-Path $7z) {
        $Extension = "7z"
        # Executa a compressão
        Start-Process $7z -ArgumentList "a", "-t$Extension", "$Destination.7z", "$Source" -Wait -RedirectStandardOutput "$Destination.log"
    }
    else {
        # Caso o 7zip não esteja no C:\Program Files, gera log de erro
        "Erro: 7z.exe nao encontrado em $7z. Impossivel executar a compressao." > "$Destination.log"
        Write-Host "Erro: Executável do 7-Zip não encontrado." -ForegroundColor Red
    }
}

Function Retention {
    param (
        [string]$Destination,
        [int]$RetentionDays
    )
    $Date = (get-date).ToString("dd-MM-yyyy")
    $ListZipFiles = Get-ChildItem -Path $Destination | Where-Object {$_.Name -like "*7z"} | Sort-Object -Property LastWriteTime
    $ZipFilesOldest = $ListZipFiles | Where-Object {$_.LastWriteTime -lt ([datetime]::Today.AddDays(-$RetentionDays))}
    $ZipFilesNewest = $ListZipFiles | Where-Object {$_.LastWriteTime -gt ([datetime]::Today.AddDays(-$RetentionDays))}

    if ($RetentionDays -lt 30) {
        $RetentionFiles = $RetentionDays
    }
    else {
        $RetentionFiles = ("{0:N0}" -f (($RetentionDays / 1) + 1))
    }

    if ($null -ne $ListZipFiles) {
        if ($ZipFilesNewest.Count -ge $RetentionFiles) {
            echo "Os seguintes arquivamentos foram apagados na data $Date `n" > "$Destination\RemoveItens_$date.log"
            foreach ($file in $ZipFilesOldest.FullName) {
                Remove-Item -Path $file -Force
                echo "`n $file" >> "$Destination\RemoveItens_$date.log" 
            }
        }
        else {
            if ($ListZipFiles.Count -ge $RetentionFiles) {
                $FilesCount = ($ListZipFiles.Count - $RetentionFiles)
                echo "Os seguintes arquivamentos foram apagados na data $Date `n" > "$Destination\RemoveItens_$date.log"
                foreach ($file in ($ListZipFiles | Select-Object -First $FilesCount).Fullname) {
                    Remove-Item -Path $file -Force
                    echo "`n $file" >> "$Destination\RemoveItens_$date.log" 
                }
            }
        }
    }
}
###### Fim Modulos #####

###### Inicio Script ######

$EventPath = "C:\Windows\System32\Winevt\Logs"
$SecurityEventList = Get-ChildItem $EventPath | Where-Object {$_.Name -like "Archive*security*"}
$Destination = "$EventPath\Arquivamento_Security"

# Cria diretórios se não existirem
if (!(Test-Path $Destination)) {
    New-Item -Path $Destination -ItemType "Directory"
}

if (!(Test-Path "C:\Windows\Temp\Arquivamento_Security")) {
    New-Item -Path "C:\Windows\Temp\Arquivamento_Security" -ItemType "Directory"
}

foreach ($SecurityEvent in $SecurityEventList) {
    $DateWrite = ($SecurityEvent.LastWriteTime).ToString("dd-MM-yyyy-HH-mm-ss-fff")
    $Date = ($SecurityEvent.LastWriteTime)
    $NameLog = $SecurityEvent.Name
    $FileName = ("Archive-Security-" + $DateWrite)
    $Source = $SecurityEvent.FullName
    
    if (Test-Path $EventPath) {
        # Move para pasta temporária para processamento
        Move-Item -Path $Source -Destination "C:\Windows\Temp\Arquivamento_Security"
        
        # Chama a função de compressão (agora com caminho fixo)
        Compress-7zip -Source "C:\Windows\Temp\Arquivamento_Security\$NameLog" -Destination "C:\Windows\Temp\Arquivamento_Security\$FileName"
        
        # Preserva a data original nos arquivos gerados
        if (Test-Path "C:\Windows\Temp\Arquivamento_Security\$FileName.7z") {
            Set-ItemProperty -Path "C:\Windows\Temp\Arquivamento_Security\$FileName.7z" -Name LastWriteTime -Value $Date
            Set-ItemProperty -Path "C:\Windows\Temp\Arquivamento_Security\$FileName.log" -Name LastWriteTime -Value $Date
            
            # Move para o destino final
            Move-Item -Path "C:\Windows\Temp\Arquivamento_Security\$FileName.7z" -Destination $Destination -Force
            Move-Item -Path "C:\Windows\Temp\Arquivamento_Security\$FileName.log" -Destination $Destination -Force
            
            # Limpeza do arquivo original após confirmar que o .7z existe no destino
            if (Test-Path "$Destination\$FileName.7z") {
                Remove-Item "C:\Windows\Temp\Arquivamento_Security\$NameLog" -Force       
            }
        }
    }
}

# Executa a retenção
if ($Destination) {
    Retention -Destination $Destination -RetentionDays 31
}