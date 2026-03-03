param(
    [switch]$i
)

$SITE_NAME = "FTP-SERVER"
$FTP_ROOT  = "C:\FTP"
$PORT      = 2121

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host "Ejecuta PowerShell como Administrador"
    exit
}

if ($i) {

    Write-Host "===== INSTALANDO IIS + FTP ====="

    # Instalar IIS base
    Install-WindowsFeature Web-Server -IncludeManagementTools

    # Buscar nombre correcto del FTP
    $ftpFeature = Get-WindowsFeature | Where-Object {
        $_.Name -like "Web-Ftp*"
    }

    if (-not $ftpFeature) {
        Write-Host "Tu servidor no tiene disponibles los features FTP."
        exit
    }

    foreach ($f in $ftpFeature) {
        if (-not $f.Installed) {
            Install-WindowsFeature $f.Name -IncludeManagementTools
        }
    }

    Import-Module WebAdministration

    # Crear carpeta si no existe
    if (-not (Test-Path $FTP_ROOT)) {
        New-Item -Path $FTP_ROOT -ItemType Directory
    }

    # Permisos básicos seguros
    icacls $FTP_ROOT /grant "Administrators:(OI)(CI)F" /T
    icacls $FTP_ROOT /grant "SYSTEM:(OI)(CI)F" /T
    icacls $FTP_ROOT /grant "IIS_IUSRS:(OI)(CI)M" /T

    # Eliminar sitio previo si existe
    if (Get-WebSite -Name $SITE_NAME -ErrorAction SilentlyContinue) {
        Stop-WebSite -Name $SITE_NAME -ErrorAction SilentlyContinue
        Remove-WebSite -Name $SITE_NAME
    }

    # Crear sitio FTP
    New-WebFtpSite -Name $SITE_NAME `
                   -Port $PORT `
                   -PhysicalPath $FTP_ROOT `
                   -Force

    Start-Sleep 2

    # Verificar que exista antes de configurar
    if (-not (Get-WebSite -Name $SITE_NAME -ErrorAction SilentlyContinue)) {
        Write-Host "El sitio no se creó correctamente."
        exit
    }

    # Configurar autenticación
    Set-WebConfigurationProperty `
        -Filter "/system.ftpServer/security/authentication/anonymousAuthentication" `
        -PSPath IIS:\ `
        -Location $SITE_NAME `
        -Name enabled `
        -Value true

    Set-WebConfigurationProperty `
        -Filter "/system.ftpServer/security/authentication/basicAuthentication" `
        -PSPath IIS:\ `
        -Location $SITE_NAME `
        -Name enabled `
        -Value true

    # Regla autorización
    Clear-WebConfiguration `
        -Filter "/system.ftpServer/security/authorization" `
        -PSPath IIS:\ `
        -Location $SITE_NAME `
        -ErrorAction SilentlyContinue

    Add-WebConfiguration `
        -Filter "/system.ftpServer/security/authorization" `
        -PSPath IIS:\ `
        -Location $SITE_NAME `
        -Value @{accessType="Allow";users="*";permissions="Read,Write"}

    # Firewall
    if (-not (Get-NetFirewallRule -DisplayName "FTP 2121" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule `
            -DisplayName "FTP 2121" `
            -Direction Inbound `
            -Protocol TCP `
            -LocalPort $PORT `
            -Action Allow
    }

    # Servicio
    Set-Service FTPSVC -StartupType Automatic
    Restart-Service FTPSVC

    Start-WebSite -Name $SITE_NAME

    Write-Host ""
    Write-Host "================================="
    Write-Host "FTP FUNCIONANDO EN PUERTO $PORT"
    Write-Host "================================="
}
