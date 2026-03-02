# ============================================================
# script-ftp.ps1 - FTP Server Automation
# Windows Server Core - IIS FTP
# ============================================================

param(
    [switch]$i,
    [switch]$u,
    [switch]$c
)

# ---------- Librerias ----------
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$SCRIPT_DIR\utils.ps1"
. "$SCRIPT_DIR\validaciones.ps1"

# ---------- Variables ----------
$SITE_NAME = "FTP-Servidor"
$FTP_ROOT  = "C:\FTP\LocalUser"
$PORT      = 21

# ============================================================
# INSTALACION
# ============================================================
if ($i) {

    Print-Titulo "INSTALACION SERVIDOR FTP"

    # Administrador
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal   = New-Object Security.Principal.WindowsPrincipal($currentUser)

    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Print-Error "Ejecutar como Administrador"
        exit 1
    }

    # Features IIS FTP
    $features = @(
        "Web-Server",
        "Web-Ftp-Server",
        "Web-Ftp-Service",
        "Web-Ftp-Extensibility",
        "Web-Mgmt-Service",
        "Web-Scripting-Tools"
    )

    foreach ($f in $features) {
        $feat = Get-WindowsFeature -Name $f -ErrorAction SilentlyContinue
        if ($feat -and -not $feat.Installed) {
            Install-WindowsFeature -Name $f -IncludeManagementTools | Out-Null
        }
    }

    Import-Module WebAdministration -Force

    # Firewall
    Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False

    New-NetFirewallRule -Name "FTP-$PORT" `
        -DisplayName "FTP Puerto $PORT" `
        -Protocol TCP -LocalPort $PORT `
        -Direction Inbound -Action Allow -ErrorAction SilentlyContinue | Out-Null

    New-NetFirewallRule -Name "FTP-PASIVO" `
        -DisplayName "FTP Pasivo" `
        -Protocol TCP -LocalPort 49152-65535 `
        -Direction Inbound -Action Allow -ErrorAction SilentlyContinue | Out-Null

    # Directorios base
    $dirs = @(
        $FTP_ROOT,
        "$FTP_ROOT\general",
        "$FTP_ROOT\reprobados",
        "$FTP_ROOT\recursadores"
    )

    foreach ($d in $dirs) {
        New-Item -Path $d -ItemType Directory -Force | Out-Null
    }

    # Permisos anonimo
    icacls "$FTP_ROOT\general" /grant "IUSR:(OI)(CI)RX" /T | Out-Null

    # Sitio FTP
    if (-not (Get-WebSite -Name $SITE_NAME -ErrorAction SilentlyContinue)) {

        New-WebFtpSite `
            -Name $SITE_NAME `
            -Port $PORT `
            -PhysicalPath $FTP_ROOT `
            -Force | Out-Null
    }

    # AISLAMIENTO USUARIO POR CARPETA
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.userIsolation.mode `
        -Value 3

    # Auth
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.authentication.anonymousAuthentication.enabled `
        -Value $true

    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.authentication.basicAuthentication.enabled `
        -Value $true

    Set-Service FTPSVC -StartupType Automatic
    Restart-Service FTPSVC -Force -ErrorAction SilentlyContinue

    Print-Completado "Servidor FTP instalado"
}

# ============================================================
# CREAR USUARIOS
# ============================================================
if ($u) {

    Import-Module WebAdministration -Force

    Print-Titulo "CREACION USUARIOS FTP"

    # Cantidad usuarios
    # Cantidad usuarios
$cantidad = 0

do {

    $cantidadStr = Read-Host "Cuantos usuarios desea crear"
    $cantidadStr = $cantidadStr.Trim()

    $ok = [int]::TryParse($cantidadStr, [ref]$cantidad)

    if (-not $ok -or $cantidad -lt 1) {
        Print-Error "Numero invalido"
        $cantidad = 0
    }

} while ($cantidad -lt 1)

    } while ($cantidad -lt 1)

    # Creación masiva
    for ($i = 1; $i -le $cantidad; $i++) {

        Print-Titulo "Usuario $i de $cantidad"

        do { $usuario = Read-Host "Usuario" }
        while (-not (Validar-Usuario $usuario))

        if (Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue) {
            Print-Error "Usuario existe"
            continue
        }

        do { $password = Read-Host "Password" }
        while ($password.Length -lt 4)

        do { $grupo = Read-Host "Grupo (reprobados/recursadores)" }
        while (-not (Validar-Grupo $grupo))

        # Crear usuario Windows
        $passSecure = ConvertTo-SecureString $password -AsPlainText -Force

        New-LocalUser `
            -Name $usuario `
            -Password $passSecure `
            -PasswordNeverExpires `
            -UserMayNotChangePassword | Out-Null

        # Estructura FTP
        $userRoot = "$FTP_ROOT\$usuario"

        $paths = @(
            $userRoot,
            "$userRoot\general",
            "$userRoot\$grupo",
            "$userRoot\$usuario"
        )

        foreach ($p in $paths) {
            New-Item -Path $p -ItemType Directory -Force | Out-Null
        }

        # Permisos NTFS
        icacls $userRoot /inheritance:r /T | Out-Null

        icacls $userRoot /grant "SYSTEM:(OI)(CI)F" /T | Out-Null
        icacls $userRoot /grant "Administrators:(OI)(CI)F" /T | Out-Null
        icacls $userRoot /grant "${usuario}:(OI)(CI)F" /T | Out-Null

        icacls "$userRoot\general" /grant "IUSR:(OI)(CI)RX" /T | Out-Null
        icacls "$userRoot\general" /grant "${usuario}:(OI)(CI)M" /T | Out-Null

        icacls "$userRoot\$grupo" /grant "${usuario}:(OI)(CI)M" /T | Out-Null

        Print-Completado "Usuario creado"
    }
}

# ============================================================
# CAMBIO DE GRUPO
# ============================================================
if ($c) {

    Print-Titulo "CAMBIO DE GRUPO"

    do {
        $usuario = Read-Host "Usuario"
    } while (-not (Get-LocalUser $usuario -ErrorAction SilentlyContinue))

    do {
        $nuevoGrupo = Read-Host "Nuevo grupo (reprobados/recursadores)"
    } while (-not (Validar-Grupo $nuevoGrupo))

    icacls "$FTP_ROOT\reprobados" /remove $usuario 2>$null
    icacls "$FTP_ROOT\recursadores" /remove $usuario 2>$null

    icacls "$FTP_ROOT\$nuevoGrupo" /grant "${usuario}:(OI)(CI)M" | Out-Null

    Print-Completado "Grupo actualizado"
}

# ============================================================
if (-not $i -and -not $u -and -not $c) {
    Print-Info "Uso:"
    Print-Info ".\script-ftp.ps1 -i"
    Print-Info ".\script-ftp.ps1 -u"
    Print-Info ".\script-ftp.ps1 -c"
}
