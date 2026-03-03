# Ver el XML completo del sitio FTP
$configPath = "C:\Windows\System32\inetsrv\config\applicationHost.config"
$config = [xml](Get-Content $configPath)
$sitio = $config.configuration.'system.applicationHost'.sites.site | Where-Object { $_.name -eq "FTP-Servidor" }
$sitio.OuterXml
