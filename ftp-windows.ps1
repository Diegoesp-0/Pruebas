# ============================================================
# FTP WINDOWS SERVER IIS - VERSION CORREGIDA Y ESTABLE
# Puerto 2121
# ============================================================

param(
    [switch]$i,
    [switch]$u,
    [switch]$c
)

$SITE_NAME = "FTP-SERVER"
$FTP_ROOT  = "C:\FTP"
$PORT      = 2121

# ============================================================
# VALIDAR ADMIN
# ============================================================
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host "Ejecutar PowerShell como Administrador"
    exit
}

# ============================================================
# INSTALACION
# ============================================================
if ($i) {

    Write-Host "==== INSTALACION SERVIDOR FTP IIS ===="

    # 1. INSTALAR IIS + FTP
    $features = @(
        "Web-Server",
        "Web-Ftp-Server",
        "Web-Ftp-Service",
        "Web-Ftp-Extensibility"
    )

    foreach ($f in $features) {
        $feat = Get-WindowsFeature -Name $f
        if (-not $feat.Installed) {
            Install-WindowsFeature -Name $f -IncludeManagementTools | Out-Null
        }
    }

    Import-Module WebAdministration

    # 2. CREAR GRUPOS
    foreach ($g in @("reprobados","recursadores")) {
        if (-not (Get-LocalGroup -Name $g -ErrorAction SilentlyContinue)) {
            New-LocalGroup -Name $g | Out-Null
        }
    }

    # 3. CREAR ESTRUCTURA
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

    # 4. PERMISOS SEGUROS (NO ROMPE HERENCIA)
    icacls $FTP_ROOT /grant "Administrators:(OI)(CI)F" /T | Out-Null
    icacls $FTP_ROOT /grant "SYSTEM:(OI)(CI)F" /T | Out-Null
    icacls $FTP_ROOT /grant "IIS_IUSRS:(OI)(CI)M" /T | Out-Null
    icacls "$FTP_ROOT\general" /grant "IUSR:(OI)(CI)RX" | Out-Null

    # 5. ELIMINAR SITIO SI EXISTE
    if (Get-WebSite -Name $SITE_NAME -ErrorAction SilentlyContinue) {
        Stop-WebSite -Name $SITE_NAME
        Remove-WebSite -Name $SITE_NAME
    }

    # 6. CREAR SITIO LIMPIO
    New-WebFtpSite -Name $SITE_NAME -Port $PORT -PhysicalPath $FTP_ROOT -Force | Out-Null

    # 7. CONFIGURAR AUTENTICACION
    Set-WebConfigurationProperty `
        -Filter "system.ftpServer/security/authentication/anonymousAuthentication" `
        -PSPath IIS:\ `
        -Location $SITE_NAME `
        -Name enabled -Value True

    Set-WebConfigurationProperty `
        -Filter "system.ftpServer/security/authentication/basicAuthentication" `
        -PSPath IIS:\ `
        -Location $SITE_NAME `
        -Name enabled -Value True

    # 8. LIMPIAR AUTORIZACION
    Clear-WebConfiguration `
        -Filter "system.ftpServer/security/authorization" `
        -PSPath IIS:\ `
        -Location $SITE_NAME `
        -ErrorAction SilentlyContinue

    # ANONIMO SOLO LECTURA
    Add-WebConfiguration `
        -Filter "system.ftpServer/security/authorization" `
        -PSPath IIS:\ `
        -Location $SITE_NAME `
        -Value @{accessType="Allow";users="anonymous";permissions="Read"}

    # AUTENTICADOS LECTURA Y ESCRITURA
    Add-WebConfiguration `
        -Filter "system.ftpServer/security/authorization" `
        -PSPath IIS:\ `
        -Location $SITE_NAME `
        -Value @{accessType="Allow";users="*";permissions="Read,Write"}

    # 9. FIREWALL
    if (-not (Get-NetFirewallRule -DisplayName "FTP 2121" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule `
            -DisplayName "FTP 2121" `
            -Direction Inbound `
            -Protocol TCP `
            -LocalPort $PORT `
            -Action Allow | Out-Null
    }

    # 10. INICIAR SERVICIO
    Set-Service FTPSVC -StartupType Automatic
    Restart-Service FTPSVC
    Start-WebSite -Name $SITE_NAME

    Write-Host "FTP listo en puerto $PORT"
}

# ============================================================
# CREACION MASIVA DE USUARIOS
# ============================================================
if ($u) {

    $cantidad = [int](Read-Host "Cantidad de usuarios")

    for ($iUser=1; $iUser -le $cantidad; $iUser++) {

        Write-Host "Usuario $iUser"

        do {
            $usuario = Read-Host "Nombre usuario"
        } until (-not (Get-LocalUser $usuario -ErrorAction SilentlyContinue))

        $password = Read-Host "Password"

        do {
            $grupo = Read-Host "Grupo (reprobados/recursadores)"
        } until ($grupo -in @("reprobados","recursadores"))

        $securePass = ConvertTo-SecureString $password -AsPlainText -Force

        New-LocalUser -Name $usuario -Password $securePass -PasswordNeverExpires | Out-Null
        Add-LocalGroupMember -Group $grupo -Member $usuario

        $userDir = "$FTP_ROOT\$usuario"
        if (-not (Test-Path $userDir)) {
            New-Item -Path $userDir -ItemType Directory | Out-Null
        }

        # Permisos
        icacls $userDir /grant "${usuario}:(OI)(CI)F" | Out-Null
        icacls "$FTP_ROOT\general" /grant "${usuario}:(OI)(CI)M" | Out-Null
        icacls "$FTP_ROOT\$grupo" /grant "${usuario}:(OI)(CI)M" | Out-Null

        Write-Host "Usuario $usuario creado"
    }
}

# ============================================================
# CAMBIO DE GRUPO
# ============================================================
if ($c) {

    $usuario = Read-Host "Usuario"

    if (-not (Get-LocalUser $usuario -ErrorAction SilentlyContinue)) {
        Write-Host "Usuario no existe"
        exit
    }

    do {
        $nuevoGrupo = Read-Host "Nuevo grupo (reprobados/recursadores)"
    } until ($nuevoGrupo -in @("reprobados","recursadores"))

    foreach ($g in @("reprobados","recursadores")) {
        Remove-LocalGroupMember -Group $g -Member $usuario -ErrorAction SilentlyContinue
    }

    Add-LocalGroupMember -Group $nuevoGrupo -Member $usuario

    icacls "$FTP_ROOT\reprobados" /remove $usuario | Out-Null
    icacls "$FTP_ROOT\recursadores" /remove $usuario | Out-Null
    icacls "$FTP_ROOT\$nuevoGrupo" /grant "${usuario}:(OI)(CI)M" | Out-Null

    Write-Host "Grupo actualizado"
}
