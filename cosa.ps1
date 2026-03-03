# 1. Verificar que sitios existen actualmente
Write-Host "=== SITIOS EXISTENTES ===" -ForegroundColor Cyan
Get-WebSite | Format-Table Name, State, PhysicalPath, Bindings

# 2. Intentar eliminar el sitio si existe
Write-Host "`n=== ELIMINANDO SITIO FTP (SI EXISTE) ===" -ForegroundColor Yellow
Stop-WebSite -Name "FTP-Servidor" -ErrorAction SilentlyContinue
Remove-WebSite -Name "FTP-Servidor" -ErrorAction SilentlyContinue

# 3. Verificar que se elimino
Write-Host "`n=== VERIFICAR QUE YA NO APAREZCA ===" -ForegroundColor Yellow
$sitio = Get-WebSite | Where-Object { $_.Name -eq "FTP-Servidor" }
if ($sitio) { 
    Write-Host "El sitio aun existe" -ForegroundColor Red
} else { 
    Write-Host "Sitio eliminado correctamente" -ForegroundColor Green
}

# 4. CREAR EL SITIO FTP NUEVO
Write-Host "`n=== CREANDO SITIO FTP NUEVO ===" -ForegroundColor Green
try {
    New-WebFtpSite -Name "FTP-Servidor" -Port 22 -PhysicalPath "C:\FTP" -ErrorAction Stop
    Write-Host "Sitio creado correctamente" -ForegroundColor Green
} catch {
    Write-Host "Error al crear el sitio: $_" -ForegroundColor Red
    exit 1
}

# 5. CONFIGURAR AUTENTICACION
Write-Host "`n=== CONFIGURANDO AUTENTICACION ===" -ForegroundColor Cyan
Set-ItemProperty "IIS:\Sites\FTP-Servidor" -Name ftpServer.security.authentication.anonymousAuthentication.enabled -Value $true
Set-ItemProperty "IIS:\Sites\FTP-Servidor" -Name ftpServer.security.authentication.basicAuthentication.enabled -Value $true
Write-Host "Autenticacion configurada" -ForegroundColor Green

# 6. DESHABILITAR SSL COMPLETAMENTE
Write-Host "`n=== DESHABILITANDO SSL ===" -ForegroundColor Cyan
Set-ItemProperty "IIS:\Sites\FTP-Servidor" -Name ftpServer.security.ssl.controlChannelPolicy -Value "SslDisable"
Set-ItemProperty "IIS:\Sites\FTP-Servidor" -Name ftpServer.security.ssl.dataChannelPolicy -Value "SslDisable"
Write-Host "SSL deshabilitado" -ForegroundColor Green

# 7. VERIFICAR QUE SSL QUEDO DISABLED
Write-Host "`n=== VERIFICANDO SSL ===" -ForegroundColor Cyan
Get-ItemProperty "IIS:\Sites\FTP-Servidor" -Name ftpServer.security.ssl | Format-List controlChannelPolicy, dataChannelPolicy

# 8. CONFIGURAR ABE
Write-Host "`n=== CONFIGURANDO ABE ===" -ForegroundColor Cyan
Set-WebConfigurationProperty -Filter "system.ftpServer/userIsolation" -Name accessBasedEnumeration -Value $true -PSPath "IIS:\" -Location "FTP-Servidor"
Write-Host "ABE configurado" -ForegroundColor Green

# 9. CONFIGURAR REGLAS DE AUTORIZACION
Write-Host "`n=== CONFIGURANDO REGLAS DE AUTORIZACION ===" -ForegroundColor Cyan

Clear-WebConfiguration -PSPath "IIS:\" -Filter "system.ftpServer/security/authorization" -Location "FTP-Servidor" -ErrorAction SilentlyContinue

Add-WebConfiguration -PSPath "IIS:\" -Filter "system.ftpServer/security/authorization" -Location "FTP-Servidor" -Value @{
    accessType = "Allow"
    users = "anonymous"
    permissions = "Read"
}

Add-WebConfiguration -PSPath "IIS:\" -Filter "system.ftpServer/security/authorization" -Location "FTP-Servidor" -Value @{
    accessType = "Allow"
    users = "*"
    permissions = "Read, Write"
}
Write-Host "Reglas de autorizacion configuradas" -ForegroundColor Green

# 10. INICIAR EL SITIO
Write-Host "`n=== INICIANDO SITIO FTP ===" -ForegroundColor Cyan
Start-WebSite -Name "FTP-Servidor"
Write-Host "Sitio iniciado" -ForegroundColor Green

# 11. REINICIAR SERVICIO FTP
Write-Host "`n=== REINICIANDO SERVICIO FTP ===" -ForegroundColor Cyan
Restart-Service FTPSVC -Force
Write-Host "Servicio reiniciado" -ForegroundColor Green

# 12. VERIFICACION FINAL
Write-Host "`n=== VERIFICACION FINAL ===" -ForegroundColor Magenta
Write-Host "`n--- Estado del sitio ---" -ForegroundColor Yellow
Get-WebSite | Where-Object { $_.Name -eq "FTP-Servidor" } | Format-List Name, State, PhysicalPath, Bindings

Write-Host "`n--- Configuracion SSL (debe ser SslDisable) ---" -ForegroundColor Yellow
Get-ItemProperty "IIS:\Sites\FTP-Servidor" -Name ftpServer.security.ssl | Format-List controlChannelPolicy, dataChannelPolicy

Write-Host "`n--- Puertos en escucha ---" -ForegroundColor Yellow
netstat -an | findstr :22

Write-Host "`n=== PROCESO COMPLETADO ===" -ForegroundColor Green
Write-Host "Ya puedes probar la conexion en FileZilla:" -ForegroundColor White
Write-Host "  Protocolo: FTP" -ForegroundColor White
Write-Host "  Servidor: 192.168.100.87" -ForegroundColor White
Write-Host "  Puerto: 22" -ForegroundColor White
Write-Host "  Cifrado: Usar solo FTP plano (inseguro)" -ForegroundColor White
Write-Host "  Usuario: diego (o el que hayas creado)" -ForegroundColor White
