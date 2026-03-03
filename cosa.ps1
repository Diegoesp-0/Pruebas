# Ver el log de errores de IIS FTP en tiempo real
Get-EventLog -LogName System -Source "*ftpsvc*" -Newest 10

# Y tambien
Get-EventLog -LogName Application -Newest 20 | Where-Object {$_.Message -like "*ftp*" -or $_.Message -like "*diego*"}

Import-Module WebAdministration

# Ver configuracion de aislamiento
Get-ItemProperty "IIS:\Sites\FTP-Servidor" | Select-Object *

# Ver el modo de aislamiento especificamente  
(Get-ItemProperty "IIS:\Sites\FTP-Servidor" -Name ftpServer.userIsolation.mode).Value
