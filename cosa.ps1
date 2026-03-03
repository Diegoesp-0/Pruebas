# 1. Ver configuración actual con appcmd
Write-Host "Configuración actual:" -ForegroundColor Yellow
& "$env:SystemRoot\System32\inetsrv\appcmd.exe" list config "FTP-Servidor" -section:system.ftpServer/security/ssl

# 2. Deshabilitar SSL con appcmd
Write-Host "`nDeshabilitando SSL..." -ForegroundColor Yellow
& "$env:SystemRoot\System32\inetsrv\appcmd.exe" set config "FTP-Servidor" -section:system.ftpServer/security/ssl /controlChannelPolicy:"SslDisable" /commit:site
& "$env:SystemRoot\System32\inetsrv\appcmd.exe" set config "FTP-Servidor" -section:system.ftpServer/security/ssl /dataChannelPolicy:"SslDisable" /commit:site

# 3. Verificar que cambió
Write-Host "`nVerificando nueva configuración:" -ForegroundColor Yellow
& "$env:SystemRoot\System32\inetsrv\appcmd.exe" list config "FTP-Servidor" -section:system.ftpServer/security/ssl

# 4. Reiniciar servicios
Write-Host "`nReiniciando servicios..." -ForegroundColor Yellow
Stop-WebSite -Name "FTP-Servidor" -ErrorAction SilentlyContinue
Restart-Service FTPSVC -Force
Start-WebSite -Name "FTP-Servidor"

# 5. Verificar con PowerShell nuevamente
Write-Host "`nVerificación final con PowerShell:" -ForegroundColor Yellow
Get-ItemProperty "IIS:\Sites\FTP-Servidor" -Name ftpServer.security.ssl | Format-List controlChannelPolicy, dataChannelPolicy
