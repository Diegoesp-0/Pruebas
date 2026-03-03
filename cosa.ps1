Import-Module WebAdministration

# Corregir el protocolo a ftp
Set-ItemProperty "IIS:\Sites\FTP-Servidor" -Name enabledProtocols -Value "ftp"

# Verificar el modo de aislamiento
Set-ItemProperty "IIS:\Sites\FTP-Servidor" -Name ftpServer.userIsolation.mode -Value 3

# Verificar autenticacion
Set-ItemProperty "IIS:\Sites\FTP-Servidor" -Name ftpServer.security.authentication.anonymousAuthentication.enabled -Value $true
Set-ItemProperty "IIS:\Sites\FTP-Servidor" -Name ftpServer.security.authentication.basicAuthentication.enabled -Value $true

# Sin SSL
Set-ItemProperty "IIS:\Sites\FTP-Servidor" -Name ftpServer.security.ssl.controlChannelPolicy -Value 0
Set-ItemProperty "IIS:\Sites\FTP-Servidor" -Name ftpServer.security.ssl.dataChannelPolicy -Value 0

Restart-Service FTPSVC -Force
Start-Sleep -Seconds 2

# Confirmar
(Get-ItemProperty "IIS:\Sites\FTP-Servidor").enabledProtocols
(Get-ItemProperty "IIS:\Sites\FTP-Servidor" -Name ftpServer.userIsolation.mode).Value
