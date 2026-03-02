# ============================================================
# script-ftp.ps1 - Instalacion y gestion de servidor FTP
# Windows Server Core - IIS + FTP Service
# Puerto: 21
# Uso:
#   .\script-ftp.ps1 -i   => Instalar y configurar FTP
#   .\script-ftp.ps1 -u   => Crear usuarios
#   .\script-ftp.ps1 -c   => Cambiar grupo de usuario
# ============================================================

param(
    [switch]$i,
    [switch]$u,
    [switch]$c
)

# ---------- Cargar librerias ----------
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$SCRIPT_DIR\utils.ps1"
. "$SCRIPT_DIR\validaciones.ps1"

# ---------- Variables globales ----------
$SITE_NAME = "FTP-Servidor"
$FTP_ROOT  = "C:\FTP"
$PORT      = 21

# ============================================================
# INSTALACION Y CONFIGURACION IIS + FTP
# ============================================================
if ($i) {

    Print-Titulo "INSTALACION DEL SERVIDOR FTP"

    # Verificar que se ejecuta como Administrador
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal   = New-Object Security.Principal.WindowsPrincipal($currentUser)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Print-Error "Este script debe ejecutarse como Administrador."
        exit 1
    }

    # ---------- Instalar caracteristicas ----------
    Print-Info "Instalando caracteristicas de Windows (IIS + FTP)..."

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
            Print-Info "Instalando: $f"
            Install-WindowsFeature -Name $f -IncludeManagementTools | Out-Null
            Print-Completado "Instalado: $f"
        } elseif ($feat -and $feat.Installed) {
            Print-Info "Ya instalado: $f"
        }
    }

    # ---------- Importar modulo WebAdministration ----------
    Print-Info "Cargando modulo WebAdministration..."
    Import-Module WebAdministration -Force -ErrorAction Stop

    # ---------- Deshabilitar Firewall ----------
    Print-Info "Deshabilitando Firewall de Windows..."
    Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
    Print-Completado "Firewall deshabilitado."

    # Reglas por si se reactiva el firewall
    if (-not (Get-NetFirewallRule -Name "FTP-$PORT" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name "FTP-$PORT" `
            -DisplayName "FTP Puerto $PORT" `
            -Protocol TCP -LocalPort $PORT `
            -Direction Inbound -Action Allow | Out-Null
        Print-Completado "Regla de firewall creada para puerto $PORT."
    }

    if (-not (Get-NetFirewallRule -Name "FTP-Pasivo" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name "FTP-Pasivo" `
            -DisplayName "FTP Modo Pasivo 49152-65535" `
            -Protocol TCP -LocalPort 49152-65535 `
            -Direction Inbound -Action Allow | Out-Null
        Print-Completado "Regla de firewall para modo pasivo creada."
    }

    # ---------- Crear estructura de directorios ----------
    Print-Info "Creando estructura de directorios en $FTP_ROOT..."

    $dirs = @(
        $FTP_ROOT,
        "$FTP_ROOT\general",
        "$FTP_ROOT\reprobados",
        "$FTP_ROOT\recursadores",
        "$FTP_ROOT\LocalUser",
        "$FTP_ROOT\LocalUser\Public"
    )

    foreach ($d in $dirs) {
        if (-not (Test-Path $d)) {
            New-Item -Path $d -ItemType Directory | Out-Null
            Print-Completado "Directorio creado: $d"
        } else {
            Print-Info "Directorio ya existe: $d"
        }
    }

    # Junction en Public para que el anonimo vea solo /general (solo lectura)
    $jPublicGeneral = "$FTP_ROOT\LocalUser\Public\general"
    if (-not (Test-Path $jPublicGeneral)) {
        cmd /c "mklink /J `"$jPublicGeneral`" `"$FTP_ROOT\general`"" | Out-Null
        Print-Completado "Enlace anonimo creado: $jPublicGeneral -> $FTP_ROOT\general"
    }

    # ---------- Permisos NTFS base ----------
    Print-Info "Configurando permisos NTFS base..."
    # IUSR accede a la raiz y a LocalUser\Public (solo lectura)
    icacls $FTP_ROOT /grant "IUSR:(OI)(CI)RX" /T | Out-Null
    Print-Completado "Permisos de usuario anonimo configurados."

    # ---------- Detener sitio Default ----------
    $defaultSite = Get-WebSite -Name "Default Web Site" -ErrorAction SilentlyContinue
    if ($defaultSite) {
        Stop-WebSite -Name "Default Web Site" -ErrorAction SilentlyContinue
        Print-Info "Sitio 'Default Web Site' detenido."
    }

    # ---------- Crear o actualizar sitio FTP ----------
    $sitioExiste = Get-WebSite -Name $SITE_NAME -ErrorAction SilentlyContinue

    if (-not $sitioExiste) {
        Print-Info "Creando sitio FTP: $SITE_NAME en puerto $PORT..."
        New-WebFtpSite `
            -Name $SITE_NAME `
            -Port $PORT `
            -PhysicalPath $FTP_ROOT `
            -Force | Out-Null
        Print-Completado "Sitio FTP creado."
    } else {
        Print-Info "Sitio FTP ya existe, actualizando configuracion..."
        Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
            -Name bindings `
            -Value @{protocol="ftp"; bindingInformation="*:${PORT}:"}
        Print-Completado "Puerto actualizado a $PORT."
    }

    # ---------- Aislamiento de usuarios (modo 3 = carpeta local por usuario) ----------
    # IIS busca la raiz de cada usuario en: $FTP_ROOT\LocalUser\<usuario>
    # El anonimo usa: $FTP_ROOT\LocalUser\Public
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.userIsolation.mode `
        -Value 3
    Print-Completado "Aislamiento de usuarios activado."

    # ---------- SSL deshabilitado (FTP plano sin cifrado) ----------
    Print-Info "Deshabilitando SSL..."
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.ssl.controlChannelPolicy `
        -Value 0
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.ssl.dataChannelPolicy `
        -Value 0
    Print-Completado "SSL deshabilitado, FTP plano habilitado."

    # ---------- Autenticacion ----------
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.authentication.anonymousAuthentication.enabled `
        -Value $true
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.authentication.basicAuthentication.enabled `
        -Value $true
    Print-Completado "Autenticacion anonima y basica habilitadas."

    # ---------- Reglas de autorizacion FTP ----------
    Print-Info "Configurando reglas de autorizacion FTP..."

    Clear-WebConfiguration -PSPath "IIS:\" `
        -Filter "system.ftpServer/security/authorization" `
        -Location $SITE_NAME -ErrorAction SilentlyContinue

    # Anonimo: solo lectura
    Add-WebConfiguration -PSPath "IIS:\" `
        -Filter "system.ftpServer/security/authorization" `
        -Location $SITE_NAME `
        -Value @{
            accessType  = "Allow"
            users       = "anonymous"
            permissions = "Read"
        }

    # Usuarios autenticados: lectura y escritura
    Add-WebConfiguration -PSPath "IIS:\" `
        -Filter "system.ftpServer/security/authorization" `
        -Location $SITE_NAME `
        -Value @{
            accessType  = "Allow"
            users       = "*"
            permissions = "Read,Write"
        }

    Print-Completado "Reglas de autorizacion configuradas."

    # ---------- Arrancar servicio FTP ----------
    Print-Info "Arrancando servicio FTPSVC..."
    Set-Service -Name FTPSVC -StartupType Automatic
    Restart-Service FTPSVC -Force
    Start-WebSite -Name $SITE_NAME -ErrorAction SilentlyContinue

    Print-Completado "Servidor FTP listo en puerto $PORT"
    Print-Info ""
    Print-Info "Al conectarse por FTP cada usuario vera:"
    Print-Info "  /general          => lectura y escritura"
    Print-Info "  /<grupo>          => lectura y escritura (solo su grupo)"
    Print-Info "  /<usuario>        => lectura y escritura (carpeta personal)"
    Print-Info ""
    Print-Info "El anonimo vera unicamente:"
    Print-Info "  /general          => solo lectura"
}

# ============================================================
# CREAR USUARIOS
# ============================================================
if ($u) {

    Import-Module WebAdministration -Force -ErrorAction Stop

    Print-Titulo "CREACION DE USUARIOS FTP"

    if (-not (Test-Path $FTP_ROOT)) {
        Print-Error "El directorio $FTP_ROOT no existe. Ejecuta primero: .\script-ftp.ps1 -i"
        exit 1
    }

    $cantidadStr = ""
    do {
        $cantidadStr = Read-Host "Cuantos usuarios desea crear"
        if ($cantidadStr -notmatch '^\d+$' -or [int]$cantidadStr -lt 1) {
            Print-Error "Ingrese un numero entero positivo."
        }
    } while ($cantidadStr -notmatch '^\d+$' -or [int]$cantidadStr -lt 1)

    $cantidad = [int]$cantidadStr

    for ($idx = 1; $idx -le $cantidad; $idx++) {

        Print-Titulo "Usuario $idx de $cantidad"

        # --- Nombre de usuario ---
        $usuario = ""
        do {
            $usuario = Read-Host "Nombre de usuario"
            if (-not (Validar-Usuario $usuario)) {
                $usuario = ""
            }
        } while ($usuario -eq "")

        if (Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue) {
            Print-Error "El usuario '$usuario' ya existe. Saltando..."
            continue
        }

        # --- Contrasena ---
        $password = ""
        do {
            $password = Read-Host "Contrasena"
            if ($password.Length -lt 4) {
                Print-Error "La contrasena debe tener al menos 4 caracteres."
                $password = ""
            }
        } while ($password -eq "")

        # --- Grupo ---
        $grupo = ""
        do {
            $grupo = Read-Host "Grupo (reprobados/recursadores)"
            if (-not (Validar-Grupo $grupo)) {
                $grupo = ""
            }
        } while ($grupo -eq "")

        # --- Crear usuario Windows local ---
        Print-Info "Creando usuario Windows: $usuario..."
        $passSecure = ConvertTo-SecureString $password -AsPlainText -Force
        New-LocalUser `
            -Name $usuario `
            -Password $passSecure `
            -PasswordNeverExpires `
            -UserMayNotChangePassword `
            -Description "Usuario FTP - Grupo: $grupo" | Out-Null
        Print-Completado "Usuario '$usuario' creado."

        # --- Crear carpeta personal real ---
        $userPersonal = "$FTP_ROOT\$usuario"
        if (-not (Test-Path $userPersonal)) {
            New-Item -Path $userPersonal -ItemType Directory | Out-Null
        }

        # --- Crear raiz de aislamiento ---
        # IIS (modo 3) busca: C:\FTP\LocalUser\<usuario>
        # Dentro se ponen junctions para que el usuario vea general, grupo y personal
        $userRoot = "$FTP_ROOT\LocalUser\$usuario"
        if (-not (Test-Path $userRoot)) {
            New-Item -Path $userRoot -ItemType Directory | Out-Null
            Print-Completado "Raiz de aislamiento creada: $userRoot"
        }

        # Junction a general
        $jGeneral = "$userRoot\general"
        if (-not (Test-Path $jGeneral)) {
            cmd /c "mklink /J `"$jGeneral`" `"$FTP_ROOT\general`"" | Out-Null
            Print-Completado "Enlace: $jGeneral -> $FTP_ROOT\general"
        }

        # Junction al grupo
        $jGrupo = "$userRoot\$grupo"
        if (-not (Test-Path $jGrupo)) {
            cmd /c "mklink /J `"$jGrupo`" `"$FTP_ROOT\$grupo`"" | Out-Null
            Print-Completado "Enlace: $jGrupo -> $FTP_ROOT\$grupo"
        }

        # Junction a carpeta personal
        $jPersonal = "$userRoot\$usuario"
        if (-not (Test-Path $jPersonal)) {
            cmd /c "mklink /J `"$jPersonal`" `"$userPersonal`"" | Out-Null
            Print-Completado "Enlace: $jPersonal -> $userPersonal"
        }

        # --- Permisos NTFS ---
        Print-Info "Asignando permisos NTFS..."
        icacls $userPersonal /grant "${usuario}:(OI)(CI)F"  | Out-Null
        icacls "$FTP_ROOT\general" /grant "${usuario}:(OI)(CI)M" | Out-Null
        icacls "$FTP_ROOT\$grupo"  /grant "${usuario}:(OI)(CI)M" | Out-Null
        icacls $userRoot /grant "${usuario}:(OI)(CI)RX" | Out-Null

        Print-Completado "Usuario '$usuario' listo. Al conectarse vera:"
        Print-Info "  /general    => lectura y escritura"
        Print-Info "  /$grupo     => lectura y escritura"
        Print-Info "  /$usuario   => lectura y escritura (carpeta personal)"
    }

    Print-Titulo "CREACION DE USUARIOS COMPLETADA"
}

# ============================================================
# CAMBIAR GRUPO DE USUARIO
# ============================================================
if ($c) {

    Import-Module WebAdministration -Force -ErrorAction Stop

    Print-Titulo "CAMBIO DE GRUPO DE USUARIO"

    # --- Nombre de usuario ---
    $usuario = ""
    do {
        $usuario = Read-Host "Nombre del usuario a cambiar de grupo"
        if (-not (Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue)) {
            Print-Error "El usuario '$usuario' no existe en el sistema."
            $usuario = ""
        }
    } while ($usuario -eq "")

    # --- Nuevo grupo ---
    $nuevoGrupo = ""
    do {
        $nuevoGrupo = Read-Host "Nuevo grupo (reprobados/recursadores)"
        if (-not (Validar-Grupo $nuevoGrupo)) {
            $nuevoGrupo = ""
        }
    } while ($nuevoGrupo -eq "")

    $userRoot = "$FTP_ROOT\LocalUser\$usuario"

    # Detectar grupo actual buscando el junction existente
    $grupoActual = ""
    foreach ($g in @("reprobados", "recursadores")) {
        if (Test-Path "$userRoot\$g") {
            $grupoActual = $g
            break
        }
    }

    if ($grupoActual -eq $nuevoGrupo) {
        Print-Info "El usuario '$usuario' ya pertenece al grupo '$nuevoGrupo'. No hay cambios."
        exit 0
    }

    # Quitar junction del grupo anterior
    if ($grupoActual -ne "") {
        Print-Info "Quitando acceso a '$grupoActual'..."
        cmd /c "rmdir `"$userRoot\$grupoActual`"" | Out-Null
        icacls "$FTP_ROOT\$grupoActual" /remove $usuario 2>&1 | Out-Null
        Print-Completado "Acceso removido de '$grupoActual'."
    }

    # Crear junction del nuevo grupo
    Print-Info "Asignando acceso a '$nuevoGrupo'..."
    if (-not (Test-Path "$userRoot\$nuevoGrupo")) {
        cmd /c "mklink /J `"$userRoot\$nuevoGrupo`" `"$FTP_ROOT\$nuevoGrupo`"" | Out-Null
    }
    icacls "$FTP_ROOT\$nuevoGrupo" /grant "${usuario}:(OI)(CI)M" | Out-Null

    Print-Completado "Grupo actualizado correctamente."
    Print-Info "Usuario '$usuario' ahora pertenece a: $nuevoGrupo"
}

# ---------- Sin parametros ----------
if (-not $i -and -not $u -and -not $c) {
    Print-Titulo "SCRIPT DE ADMINISTRACION FTP"
    Print-Info "Uso:"
    Print-Info "  .\script-ftp.ps1 -i   => Instalar y configurar servidor FTP (puerto $PORT)"
    Print-Info "  .\script-ftp.ps1 -u   => Crear usuarios FTP"
    Print-Info "  .\script-ftp.ps1 -c   => Cambiar grupo de un usuario"
    Print-Info ""
    Print-Info "Ejemplos:"
    Print-Info "  .\script-ftp.ps1 -i"
    Print-Info "  .\script-ftp.ps1 -i -u"
    Print-Info "  .\script-ftp.ps1 -u"
    Print-Info "  .\script-ftp.ps1 -c"
}
