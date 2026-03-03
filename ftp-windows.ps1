# Script simple para FTP en Windows Server Core
# Ejecutar como ADMINISTRADOR

Write-Host "=== CONFIGURANDO FTP SERVER ===" -ForegroundColor Green

# 1. Verificar administrador
$admin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
if (-not $admin) {
    Write-Host "ERROR: Ejecuta como Administrador" -ForegroundColor Red
    exit
}

# 2. Instalar características
Write-Host "Instalando IIS y FTP..." -ForegroundColor Yellow
Install-WindowsFeature -Name Web-Server -IncludeManagementTools
Install-WindowsFeature -Name Web-Ftp-Server
Install-WindowsFeature -Name Web-Ftp-Service

# 3. Crear carpetas
Write-Host "Creando carpetas..." -ForegroundColor Yellow
New-Item -ItemType Directory -Path "C:\FTP" -Force
New-Item -ItemType Directory -Path "C:\FTP\general" -Force

# 4. Crear usuario
Write-Host "Creando usuario diego..." -ForegroundColor Yellow
$pass = ConvertTo-SecureString "Milaneza12345" -AsPlainText -Force
$user = Get-LocalUser -Name "diego" -ErrorAction SilentlyContinue
if (-not $user) {
    New-LocalUser -Name "diego" -Password $pass -FullName "Usuario FTP"
    Write-Host "Usuario creado" -ForegroundColor Green
}

# 5. Permisos simples
Write-Host "Configurando permisos..." -ForegroundColor Yellow
icacls "C:\FTP\general" /grant "diego:(OI)(CI)F" /grant "IUSR:(OI)(CI)R" /grant "Users:(OI)(CI)R"

# 6. Configurar sitio FTP
Write-Host "Configurando sitio FTP..." -ForegroundColor Yellow
Import-Module WebAdministration

# Eliminar sitio si existe
$site = Get-Website -Name "FTP_Site" -ErrorAction SilentlyContinue
if ($site) {
    Remove-Website -Name "FTP_Site"
}

# Crear sitio nuevo
New-WebFtpSite -Name "FTP_Site" -Port 2121 -PhysicalPath "C:\FTP"

# Configurar autenticación
Set-WebConfigurationProperty -Filter "system.ftpServer/security/authentication/anonymousAuthentication" -Name "enabled" -Value $true -PSPath "IIS:\Sites\FTP_Site"
Set-WebConfigurationProperty -Filter "system.ftpServer/security/authentication/basicAuthentication" -Name "enabled" -Value $true -PSPath "IIS:\Sites\FTP_Site"

# Reglas de autorización
Clear-WebConfiguration -Filter "system.ftpServer/security/authorization" -PSPath "IIS:\Sites\FTP_Site"
Add-WebConfiguration -Filter "system.ftpServer/security/authorization" -Value @{accessType="Allow"; users="?"; permissions="Read"} -PSPath "IIS:\Sites\FTP_Site"
Add-WebConfiguration -Filter "system.ftpServer/security/authorization" -Value @{accessType="Allow"; users="diego"; permissions="Read, Write"} -PSPath "IIS:\Sites\FTP_Site"

# Iniciar sitio
Start-WebSite -Name "FTP_Site"

# 7. Firewall
Write-Host "Configurando firewall..." -ForegroundColor Yellow
New-NetFirewallRule -DisplayName "FTP 2121" -Direction Inbound -LocalPort 2121 -Protocol TCP -Action Allow -ErrorAction SilentlyContinue

# 8. Mostrar resultado
Write-Host "`n=== CONFIGURACION COMPLETADA ===" -ForegroundColor Green
Write-Host "Servidor: $(hostname)" -ForegroundColor Cyan
Write-Host "Puerto: 2121" -ForegroundColor Cyan
Write-Host "Usuario: diego" -ForegroundColor Cyan
Write-Host "Password: Milaneza12345" -ForegroundColor Cyan
Write-Host "Carpeta: C:\FTP\general" -ForegroundColor Cyan

Write-Host "`n=== DATOS PARA FILEZILLA ===" -ForegroundColor Yellow
Write-Host "Host: $(hostname)" 
Write-Host "Puerto: 2121"
Write-Host "Usuario: diego"
Write-Host "Password: Milaneza12345"
Write-Host "Protocolo: FTP"
Write-Host "Cifrado: Usar FTP plano"

pause
