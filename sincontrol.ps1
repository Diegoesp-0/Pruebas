# ============================================================
# script-ftp.ps1 - Instalacion y gestion de servidor FTP
# Windows Server Core - IIS + FTP Service
# Puerto: 22
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
$PORT      = 22

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

    # ---------- Instalar características ----------
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

    # ---------- Deshabilitar Firewall (para garantizar conectividad) ----------
    Print-Info "Deshabilitando Firewall de Windows para garantizar conectividad..."
    Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
    Print-Completado "Firewall deshabilitado."

    # Tambien crear regla por si acaso se reactiva el firewall
    if (-not (Get-NetFirewallRule -Name "FTP-$PORT" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name "FTP-$PORT" `
            -DisplayName "FTP Puerto $PORT" `
            -Protocol TCP -LocalPort $PORT `
            -Direction Inbound -Action Allow | Out-Null
        Print-Completado "Regla de firewall creada para puerto $PORT."
    }

    # Regla para modo pasivo (rango de puertos tipico)
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
        "$FTP_ROOT\recursadores"
    )

    foreach ($d in $dirs) {
        if (-not (Test-Path $d)) {
            New-Item -Path $d -ItemType Directory | Out-Null
            Print-Completado "Directorio creado: $d"
        } else {
            Print-Info "Directorio ya existe: $d"
        }
    }

    # ---------- Permisos NTFS base ----------
    Print-Info "Configurando permisos NTFS base..."

    # IUSR = usuario anonimo de IIS
    icacls $FTP_ROOT /grant "IUSR:(OI)(CI)RX" /T | Out-Null
    icacls "$FTP_ROOT\general" /grant "IUSR:(OI)(CI)RX" | Out-Null
    Print-Completado "Permisos de usuario anonimo configurados."

    # ---------- Detener sitio Default si existe para liberar puerto ----------
    $defaultSite = Get-WebSite -Name "Default Web Site" -ErrorAction SilentlyContinue
    if ($defaultSite) {
        Stop-WebSite -Name "Default Web Site" -ErrorAction SilentlyContinue
        Print-Info "Sitio 'Default Web Site' detenido para liberar recursos."
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
        Print-Info "Sitio FTP ya existe, actualizando puerto a $PORT..."
        Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
            -Name bindings `
            -Value @{protocol="ftp"; bindingInformation="*:${PORT}:"}
        Print-Completado "Puerto actualizado a $PORT."
    }

    # ---------- Aislamiento de usuarios ----------
    # Modo 0 = sin aislamiento (todos ven la raiz, pero permisos NTFS controlan acceso)
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.userIsolation.mode `
        -Value 0
    Print-Info "Modo de aislamiento configurado (sin aislamiento, control por NTFS)."

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

    # Limpiar reglas anteriores
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

    # ---------- Habilitar y arrancar servicio FTP ----------
    Print-Info "Arrancando servicio FTPSVC..."
    Set-Service -Name FTPSVC -StartupType Automatic
    Restart-Service FTPSVC -Force
    Start-WebSite -Name $SITE_NAME -ErrorAction SilentlyContinue

    Print-Completado "Servidor FTP listo y escuchando en el puerto $PORT"
    Print-Info "Estructura de directorios:"
    Print-Info "  $FTP_ROOT\general        (todos: lectura; autenticados: escritura)"
    Print-Info "  $FTP_ROOT\reprobados     (solo miembros del grupo)"
    Print-Info "  $FTP_ROOT\recursadores   (solo miembros del grupo)"
    Print-Info "  $FTP_ROOT\<usuario>      (carpeta personal de cada usuario)"
}

# ============================================================
# CREAR USUARIOS
# ============================================================
if ($u) {

    Import-Module WebAdministration -Force -ErrorAction Stop

    Print-Titulo "CREACION DE USUARIOS FTP"

    # Verificar que el servidor este instalado
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

        # Verificar si ya existe
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

        # --- Crear carpeta personal ---
        $userDir = "$FTP_ROOT\$usuario"
        if (-not (Test-Path $userDir)) {
            New-Item -Path $userDir -ItemType Directory | Out-Null
            Print-Completado "Carpeta personal creada: $userDir"
        }

        # --- Asignar permisos NTFS ---
        Print-Info "Asignando permisos NTFS..."

        # Carpeta personal: control total
        icacls $userDir /grant "${usuario}:(OI)(CI)F" | Out-Null

        # Carpeta general: modificar (lectura + escritura)
        icacls "$FTP_ROOT\general" /grant "${usuario}:(OI)(CI)M" | Out-Null

        # Carpeta de su grupo: modificar
        icacls "$FTP_ROOT\$grupo" /grant "${usuario}:(OI)(CI)M" | Out-Null

        Print-Completado "Permisos asignados para '$usuario':"
        Print-Info "  $userDir           => Control total"
        Print-Info "  $FTP_ROOT\general  => Modificar (lectura + escritura)"
        Print-Info "  $FTP_ROOT\$grupo   => Modificar (lectura + escritura)"
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

    # Detectar grupo actual revisando permisos
    $grupoActual = ""
    $aclReprobados   = (icacls "$FTP_ROOT\reprobados" 2>&1) -join " "
    $aclRecursadores = (icacls "$FTP_ROOT\recursadores" 2>&1) -join " "

    if ($aclReprobados -match $usuario) {
        $grupoActual = "reprobados"
    } elseif ($aclRecursadores -match $usuario) {
        $grupoActual = "recursadores"
    }

    if ($grupoActual -eq $nuevoGrupo) {
        Print-Info "El usuario '$usuario' ya pertenece al grupo '$nuevoGrupo'. No hay cambios."
        exit 0
    }

    # Quitar acceso al grupo anterior
    if ($grupoActual -ne "") {
        Print-Info "Quitando acceso a '$grupoActual'..."
        icacls "$FTP_ROOT\$grupoActual" /remove $usuario 2>&1 | Out-Null
        Print-Completado "Acceso removido de '$grupoActual'."
    }

    # Dar acceso al nuevo grupo
    Print-Info "Asignando acceso a '$nuevoGrupo'..."
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
