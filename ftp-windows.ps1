# ftp-windows.ps1 - Script de configuración de FTP Server en Windows Server Core
# Ejecutar como Administrador

# Configuración de colores para mejor visualización
$host.UI.RawUI.ForegroundColor = "Green"
Write-Host "========================================"
Write-Host "Configuración de Servidor FTP Windows"
Write-Host "========================================" -ForegroundColor Green

# 1. Verificar que se ejecuta como administrador
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "Error: Este script debe ejecutarse como Administrador" -ForegroundColor Red
    exit 1
}

# 2. Instalar características de IIS y FTP
Write-Host "`n[1/5] Instalando características de IIS y FTP..." -ForegroundColor Yellow

# Instalar módulos necesarios
Install-WindowsFeature -Name Web-Server -IncludeManagementTools
Install-WindowsFeature -Name Web-Ftp-Server
Install-WindowsFeature -Name Web-Ftp-Service

# 3. Crear estructura de carpetas
Write-Host "[2/5] Creando estructura de carpetas..." -ForegroundColor Yellow

# Crear carpeta principal FTP
$ftpRootPath = "C:\FTP"
$generalPath = "C:\FTP\general"

if (-not (Test-Path $ftpRootPath)) {
    New-Item -ItemType Directory -Path $ftpRootPath -Force
    Write-Host "  - Carpeta C:\FTP creada" -ForegroundColor Green
}

if (-not (Test-Path $generalPath)) {
    New-Item -ItemType Directory -Path $generalPath -Force
    Write-Host "  - Carpeta C:\FTP\general creada" -ForegroundColor Green
}

# 4. Crear usuario local diego
Write-Host "[3/5] Creando usuario FTP..." -ForegroundColor Yellow

$username = "diego"
$password = "Milaneza12345"
$securePassword = ConvertTo-SecureString $password -AsPlainText -Force

# Verificar si el usuario ya existe
$userExists = Get-LocalUser -Name $username -ErrorAction SilentlyContinue

if ($userExists) {
    Write-Host "  - El usuario $username ya existe" -ForegroundColor Yellow
} else {
    New-LocalUser -Name $username -Password $securePassword -FullName "Usuario FTP Diego" -Description "Usuario para acceso FTP"
    Write-Host "  - Usuario $username creado exitosamente" -ForegroundColor Green
}

# 5. Configurar permisos NTFS
Write-Host "[4/5] Configurando permisos NTFS..." -ForegroundColor Yellow

# Eliminar permisos existentes y establecer nuevos
icacls $ftpRootPath /reset /t /q
icacls $ftpRootPath /inheritance:r /t

# Permisos para el usuario diego en carpeta general
icacls $generalPath /grant "${username}:(OI)(CI)M"  # M = Modificar (leer, escribir, eliminar)
icacls $generalPath /grant "IUSR:(OI)(CI)R"  # Acceso anónimo de lectura
icacls $generalPath /grant "Users:(OI)(CI)R"  # Lectura para otros usuarios

Write-Host "  - Permisos configurados correctamente" -ForegroundColor Green

# 6. Configurar Sitio FTP en IIS
Write-Host "[5/5] Configurando sitio FTP en IIS..." -ForegroundColor Yellow

# Importar módulo de IIS
Import-Module WebAdministration

# Configuración del sitio FTP
$ftpSiteName = "FTP_Site"
$ftpPort = 2121

# Verificar si el sitio ya existe y eliminarlo
if (Get-Website -Name $ftpSiteName -ErrorAction SilentlyContinue) {
    Remove-Website -Name $ftpSiteName
    Write-Host "  - Sitio FTP existente eliminado" -ForegroundColor Yellow
}

# Crear nuevo sitio FTP
New-WebFtpSite -Name $ftpSiteName -Port $ftpPort -PhysicalPath $ftpRootPath

# Configurar autenticación
Set-WebConfigurationProperty -Filter "system.ftpServer/security/authentication/anonymousAuthentication" -Name "enabled" -Value $true -PSPath "IIS:\Sites\$ftpSiteName"
Set-WebConfigurationProperty -Filter "system.ftpServer/security/authentication/basicAuthentication" -Name "enabled" -Value $true -PSPath "IIS:\Sites\$ftpSiteName"

# Configurar reglas de autorización
Clear-WebConfiguration -Filter "system.ftpServer/security/authorization" -PSPath "IIS:\Sites\$ftpSiteName"

# Regla para acceso anónimo (solo lectura)
Add-WebConfiguration -Filter "system.ftpServer/security/authorization" -Value @{
    accessType = "Allow"
    users = "?"
    permissions = "Read"
} -PSPath "IIS:\Sites\$ftpSiteName"

# Regla para usuario diego (lectura/escritura)
Add-WebConfiguration -Filter "system.ftpServer/security/authorization" -Value @{
    accessType = "Allow"
    users = $username
    permissions = "Read, Write"
} -PSPath "IIS:\Sites\$ftpSiteName"

# Configurar SSL deshabilitado (para pruebas)
Set-WebConfigurationProperty -Filter "system.ftpServer/security/ssl" -Name "controlChannelPolicy" -Value "SslAllow" -PSPath "IIS:\Sites\$ftpSiteName"

# Iniciar el sitio FTP
Start-WebSite -Name $ftpSiteName

# Configurar firewall
Write-Host "`nConfigurando Firewall..." -ForegroundColor Yellow
New-NetFirewallRule -DisplayName "FTP Port 2121" -Direction Inbound -LocalPort 2121 -Protocol TCP -Action Allow -ErrorAction SilentlyContinue

# Mostrar resumen final
Write-Host "`n========================================" -ForegroundColor Green
Write-Host "Configuración completada exitosamente!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "`nResumen de configuración:" -ForegroundColor Cyan
Write-Host "  • Dirección FTP: ftp://$(hostname):2121" -ForegroundColor White
Write-Host "  • Puerto: 2121" -ForegroundColor White
Write-Host "  • Usuario: diego" -ForegroundColor White
Write-Host "  • Contraseña: Milaneza12345" -ForegroundColor White
Write-Host "  • Carpeta raíz: C:\FTP" -ForegroundColor White
Write-Host "  • Carpeta general: C:\FTP\general" -ForegroundColor White

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "Configuración para FileZilla:" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "Host: $(hostname)" -ForegroundColor White
Write-Host "Puerto: 2121" -ForegroundColor White
Write-Host "Protocolo: FTP - Protocolo de transferencia de archivos" -ForegroundColor White
Write-Host "Cifrado: Usar FTP plano (no seguro)" -ForegroundColor White
Write-Host "Usuario: diego" -ForegroundColor White
Write-Host "Contraseña: Milaneza12345" -ForegroundColor White
Write-Host "`n¡Importante! Después de conectar, verás la carpeta 'general' donde podrás:" -ForegroundColor Yellow
Write-Host "✓ Ver archivos" -ForegroundColor Green
Write-Host "✓ Subir archivos" -ForegroundColor Green
Write-Host "✓ Modificar archivos" -ForegroundColor Green
Write-Host "✓ Eliminar archivos" -ForegroundColor Green
Write-Host "✓ Descargar archivos" -ForegroundColor Green

# Probar conectividad
Write-Host "`nProbando conectividad local..." -ForegroundColor Yellow
try {
    $ftpResponse = Test-NetConnection -ComputerName "localhost" -Port 2121 -WarningAction SilentlyContinue
    if ($ftpResponse.TcpTestSucceeded) {
        Write-Host "✓ Puerto 2121 está abierto y escuchando" -ForegroundColor Green
    } else {
        Write-Host "✗ Error: Puerto 2121 no está accesible" -ForegroundColor Red
    }
} catch {
    Write-Host "  No se pudo probar la conectividad" -ForegroundColor Yellow
}
