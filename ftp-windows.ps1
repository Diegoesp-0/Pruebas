# ============================================================
# ftp-windows.ps1
# Servidor FTP IIS + FTP Service
# Puerto 2121
# Estructura:
#   C:\FTP
#       general
#       reprobados
#       recursadores
#       usuario
# ============================================================

param(
    [switch]$i,
    [switch]$u,
    [switch]$c
)

# -------- Cargar librerias --------
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$SCRIPT_DIR\utils.ps1"
. "$SCRIPT_DIR\validaciones.ps1"

# -------- Variables globales --------
$SITE_NAME = "FTP-SERVER"
$FTP_ROOT  = "C:\FTP"
$PORT      = 2121
$PASSIVE_START = 50000
$PASSIVE_END   = 50100

# ============================================================
# FUNCION: Verificar administrador
# ============================================================
function Test-Admin {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ============================================================
# INSTALACION
# ============================================================
if ($i) {

    if (-not (Test-Admin)) {
        Print-Error "Ejecutar como Administrador"
        exit 1
    }

    Print-Titulo "INSTALACION SERVIDOR FTP IIS"

    # ---- Instalar IIS + FTP ----
    $features = @(
        "Web-Server",
        "Web-Ftp-Server",
        "Web-Ftp-Service",
        "Web-Ftp-Extensibility",
        "Web-Mgmt-Tools"
    )

    foreach ($f in $features) {
        $feat = Get-WindowsFeature -Name $f -ErrorAction SilentlyContinue
        if ($feat -and -not $feat.Installed) {
            Install-WindowsFeature -Name $f -IncludeManagementTools | Out-Null
            Print-Completado "Instalado: $f"
        }
    }

    Import-Module WebAdministration -Force

    # ---- Crear grupos locales ----
    foreach ($g in @("reprobados","recursadores")) {
        if (-not (Get-LocalGroup -Name $g -ErrorAction SilentlyContinue)) {
            New-LocalGroup -Name $g | Out-Null
            Print-Completado "Grupo creado: $g"
        }
    }

    # ---- Crear estructura de carpetas ----
    $dirs = @(
        $FTP_ROOT,
        "$FTP_ROOT\general",
        "$FTP_ROOT\reprobados",
        "$FTP_ROOT\recursadores"
    )

    foreach ($d in $dirs) {
        if (-not (Test-Path $d)) {
            New-Item -Path $d -ItemType Directory | Out-Null
        }
    }

    # ---- Permisos base ----
    icacls $FTP_ROOT /inheritance:r | Out-Null
    icacls $FTP_ROOT /grant "Administrators:(OI)(CI)F" | Out-Null
    icacls "$FTP_ROOT\general" /grant "IUSR:(OI)(CI)RX" | Out-Null

    # grupos solo lectura base
    icacls "$FTP_ROOT\reprobados" /grant "reprobados:(OI)(CI)RX" | Out-Null
    icacls "$FTP_ROOT\recursadores" /grant "recursadores:(OI)(CI)RX" | Out-Null

    # ---- Firewall ----
    if (-not (Get-NetFirewallRule -Name "FTP-$PORT" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name "FTP-$PORT" `
            -DisplayName "FTP $PORT" `
            -Protocol TCP -LocalPort $PORT `
            -Direction Inbound -Action Allow | Out-Null
    }

    if (-not (Get-NetFirewallRule -Name "FTP-PASSIVE" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name "FTP-PASSIVE" `
            -DisplayName "FTP Passive" `
            -Protocol TCP -LocalPort $PASSIVE_START-$PASSIVE_END `
            -Direction Inbound -Action Allow | Out-Null
    }

    # ---- Crear sitio FTP ----
    if (-not (Get-WebSite -Name $SITE_NAME -ErrorAction SilentlyContinue)) {
        New-WebFtpSite -Name $SITE_NAME -Port $PORT -PhysicalPath $FTP_ROOT -Force | Out-Null
    }

    # Configurar rango pasivo
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.firewallSupport.passivePortRange `
        -Value "$PASSIVE_START-$PASSIVE_END"

    # Sin aislamiento visual, control total por NTFS
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.userIsolation.mode `
        -Value 0

    # Autenticacion
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.authentication.anonymousAuthentication.enabled `
        -Value $true

    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.authentication.basicAuthentication.enabled `
        -Value $true

    # Limpiar reglas
    Clear-WebConfiguration -PSPath "IIS:\" `
        -Filter "system.ftpServer/security/authorization" `
        -Location $SITE_NAME -ErrorAction SilentlyContinue

    # Anonymous solo lectura
    Add-WebConfiguration -PSPath "IIS:\" `
        -Filter "system.ftpServer/security/authorization" `
        -Location $SITE_NAME `
        -Value @{accessType="Allow";users="anonymous";permissions="Read"}

    # Autenticados lectura y escritura
    Add-WebConfiguration -PSPath "IIS:\" `
        -Filter "system.ftpServer/security/authorization" `
        -Location $SITE_NAME `
        -Value @{accessType="Allow";users="*";permissions="Read,Write"}

    Set-Service FTPSVC -StartupType Automatic
    Restart-Service FTPSVC
    Start-WebSite -Name $SITE_NAME

    Print-Completado "Servidor FTP listo en puerto $PORT"
}

# ============================================================
# CREAR USUARIOS
# ============================================================
if ($u) {

    Import-Module WebAdministration -Force

    $cantidad = [int](Read-Host "Cantidad de usuarios")

    for ($iUser=1; $iUser -le $cantidad; $iUser++) {

        Print-Titulo "Usuario $iUser"

        do {
            $usuario = Read-Host "Nombre usuario"
        } until (Validar-Usuario $usuario -and -not (Get-LocalUser $usuario -ErrorAction SilentlyContinue))

        do {
            $password = Read-Host "Password"
        } until ($password.Length -ge 4)

        do {
            $grupo = Read-Host "Grupo (reprobados/recursadores)"
        } until (Validar-Grupo $grupo)

        $passSecure = ConvertTo-SecureString $password -AsPlainText -Force

        New-LocalUser -Name $usuario -Password $passSecure -PasswordNeverExpires | Out-Null
        Add-LocalGroupMember -Group $grupo -Member $usuario

        $userDir = "$FTP_ROOT\$usuario"
        New-Item -Path $userDir -ItemType Directory | Out-Null

        # Permisos NTFS
        icacls $userDir /grant "${usuario}:(OI)(CI)F" | Out-Null
        icacls "$FTP_ROOT\general" /grant "${usuario}:(OI)(CI)M" | Out-Null
        icacls "$FTP_ROOT\$grupo" /grant "${usuario}:(OI)(CI)M" | Out-Null

        Print-Completado "Usuario $usuario creado correctamente"
    }
}

# ============================================================
# CAMBIAR GRUPO
# ============================================================
if ($c) {

    $usuario = Read-Host "Usuario a modificar"

    if (-not (Get-LocalUser $usuario -ErrorAction SilentlyContinue)) {
        Print-Error "Usuario no existe"
        exit
    }

    do {
        $nuevoGrupo = Read-Host "Nuevo grupo (reprobados/recursadores)"
    } until (Validar-Grupo $nuevoGrupo)

    foreach ($g in @("reprobados","recursadores")) {
        Remove-LocalGroupMember -Group $g -Member $usuario -ErrorAction SilentlyContinue
    }

    Add-LocalGroupMember -Group $nuevoGrupo -Member $usuario

    icacls "$FTP_ROOT\reprobados" /remove $usuario | Out-Null
    icacls "$FTP_ROOT\recursadores" /remove $usuario | Out-Null
    icacls "$FTP_ROOT\$nuevoGrupo" /grant "${usuario}:(OI)(CI)M" | Out-Null

    Print-Completado "Grupo actualizado"
}

# ============================================================
# AYUDA
# ============================================================
if (-not $i -and -not $u -and -not $c) {

    Print-Titulo "ADMINISTRADOR FTP WINDOWS"
    Print-Info ".\ftp-windows.ps1 -i  -> instalar servidor"
    Print-Info ".\ftp-windows.ps1 -u  -> crear usuarios"
    Print-Info ".\ftp-windows.ps1 -c  -> cambiar grupo"
    Print-Info ""
    Print-Info "Conexion desde FileZilla:"
    Print-Info "  Protocolo: FTP"
    Print-Info "  Puerto: $PORT"
    Print-Info "  Modo: Pasivo"
}
