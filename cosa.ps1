Import-Module WebAdministration

$configPath = "C:\Windows\System32\inetsrv\config\applicationHost.config"

# Cambiar a modo sin aislamiento
(Get-Content $configPath -Raw) -replace 'mode="IsolateRootDirectoryOnly"', 'mode="None"' | Set-Content $configPath

# La raiz del sitio es C:\FTP, el usuario diego necesita acceso ahi
icacls "C:\FTP" /grant "diego:(OI)(CI)RX"
icacls "C:\FTP\_general" /grant "diego:(OI)(CI)M"
icacls "C:\FTP\_reprobados" /grant "diego:(OI)(CI)M"
icacls "C:\FTP\_usuarios\diego" /grant "diego:(OI)(CI)F"

Restart-Service FTPSVC -Force
Start-Sleep -Seconds 2

# Confirmar modo
$config = [xml](Get-Content $configPath)
$sitio = $config.configuration.'system.applicationHost'.sites.site | Where-Object { $_.name -eq "FTP-Servidor" }
$sitio.ftpServer.userIsolation.mode
