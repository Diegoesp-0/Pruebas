# Ver como esta el sitio en el config real
$config = [xml](Get-Content "C:\Windows\System32\inetsrv\config\applicationHost.config")
$config.configuration.'system.applicationHost'.sites.site | Where-Object { $_.name -eq "FTP-Servidor" } | Select-Object -ExpandProperty ftpServer
