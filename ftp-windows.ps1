# ==============================
# INSTALAR IIS + FTP
# ==============================

Write-Host "Instalando IIS y servicio FTP..."

Install-WindowsFeature -Name Web-Server -IncludeManagementTools
Install-WindowsFeature -Name Web-Ftp-Server

# ==============================
# CREAR ESTRUCTURA DE CARPETAS
# ==============================

Write-Host "Creando carpetas..."

New-Item -Path "C:\FTP" -ItemType Directory -Force
New-Item -Path "C:\FTP\general" -ItemType Directory -Force

# ==============================
# CREAR USUARIO LOCAL
# ==============================

Write-Host "Creando usuario local..."

$password = ConvertTo-SecureString "Milaneza12345" -AsPlainText -Force
New-LocalUser -Name "diego" -Password $password -FullName "Usuario FTP Diego" -Description "Usuario FTP"
Add-LocalGroupMember -Group "Users" -Member "diego"

# ==============================
# ASIGNAR PERMISOS A LA CARPETA
# ==============================

Write-Host "Asignando permisos..."

$acl = Get-Acl "C:\FTP\general"
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "diego",
    "FullControl",
    "ContainerInherit,ObjectInherit",
    "None",
    "Allow"
)
$acl.AddAccessRule($rule)
Set-Acl "C:\FTP\general" $acl

# ==============================
# CONFIGURAR SITIO FTP
# ==============================

Import-Module WebAdministration

Write-Host "Creando sitio FTP..."

New-WebFtpSite -Name "FTP-Site" -Port 21 -PhysicalPath "C:\FTP\general" -Force

# Configurar autenticación básica
Set-ItemProperty "IIS:\Sites\FTP-Site" -Name ftpServer.security.authentication.basicAuthentication.enabled -Value $true
Set-ItemProperty "IIS:\Sites\FTP-Site" -Name ftpServer.security.authentication.anonymousAuthentication.enabled -Value $false

# Configurar autorización (control total para diego)
Add-WebConfiguration `
  -Filter "/system.ftpServer/security/authorization" `
  -PSPath "IIS:\" `
  -Value @{accessType="Allow"; users="diego"; permissions="Read, Write"}

# ==============================
# ABRIR PUERTO EN FIREWALL
# ==============================

Write-Host "Configurando Firewall..."

New-NetFirewallRule -DisplayName "FTP Port 21" -Direction Inbound -Protocol TCP -LocalPort 21 -Action Allow

Write-Host "==================================="
Write-Host "Servidor FTP configurado correctamente."
Write-Host "Usuario: diego"
Write-Host "Password: Milaneza12345"
Write-Host "Carpeta: C:\FTP\general"
Write-Host "==================================="
