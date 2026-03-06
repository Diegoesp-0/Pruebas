$configFile = "$env:SystemRoot\System32\inetsrv\config\applicationHost.config"
[xml]$xml = Get-Content $configFile
$xml.configuration.'system.applicationHost'.sites.site | 
    Where-Object { $_.name -eq "ServidorFTP" } | 
    Select-Object -ExpandProperty OuterXml


Import-Module WebAdministration

# Eliminar sitio corrupto
& "$env:SystemRoot\System32\inetsrv\appcmd.exe" delete site "ServidorFTP"

# Recrear limpio sin doble configuracion SSL
New-WebFtpSite -Name "ServidorFTP" -Port 21 -PhysicalPath "C:\ftp" -Force

# Isolation
Set-ItemProperty "IIS:\Sites\ServidorFTP" -Name "ftpServer.userIsolation.mode" -Value 3

# Autenticacion
Set-ItemProperty "IIS:\Sites\ServidorFTP" `
    -Name "ftpServer.security.authentication.basicAuthentication.enabled" -Value $true
Set-ItemProperty "IIS:\Sites\ServidorFTP" `
    -Name "ftpServer.security.authentication.anonymousAuthentication.enabled" -Value $true

# SSL - solo UNA vez, con SslAllow
Set-ItemProperty "IIS:\Sites\ServidorFTP" `
    -Name "ftpServer.security.ssl.controlChannelPolicy" -Value "SslAllow"
Set-ItemProperty "IIS:\Sites\ServidorFTP" `
    -Name "ftpServer.security.ssl.dataChannelPolicy" -Value "SslAllow"

# Autorizacion
Clear-WebConfiguration "/system.ftpServer/security/authorization" `
    -PSPath "IIS:\" -Location "ServidorFTP" -ErrorAction SilentlyContinue

Add-WebConfiguration "/system.ftpServer/security/authorization" `
    -PSPath "IIS:\" -Location "ServidorFTP" `
    -Value @{ accessType="Allow"; users="?"; roles=""; permissions=1 }

Add-WebConfiguration "/system.ftpServer/security/authorization" `
    -PSPath "IIS:\" -Location "ServidorFTP" `
    -Value @{ accessType="Allow"; users="*"; roles=""; permissions=3 }

# Reiniciar y arrancar
Stop-Service ftpsvc -Force
Start-Sleep -Seconds 3
Start-Service ftpsvc
Start-Sleep -Seconds 3

& "$env:SystemRoot\System32\inetsrv\appcmd.exe" start site "ServidorFTP"
& "$env:SystemRoot\System32\inetsrv\appcmd.exe" list site "ServidorFTP"
