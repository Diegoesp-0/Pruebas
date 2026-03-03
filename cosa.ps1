$configPath = "C:\Windows\System32\inetsrv\config\applicationHost.config"

# Leer y mostrar solo las lineas del sitio FTP
$lines = Get-Content $configPath
$lines | Select-String -Pattern "FTP-Servidor" -Context 5,5
