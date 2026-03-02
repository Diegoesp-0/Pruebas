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
# FUNCION AUXILIAR: Crear estructura de carpetas del usuario
# Crea C:\FTP\LocalUser\<usuario>\ con junction points hacia:
#   - general        => C:\FTP\general
#   - reprobados/recursadores => C:\FTP\<grupo>
#   - <usuario>      => C:\FTP\users\<usuario>
# Asi IIS FTP con aislamiento muestra solo esa subcarpeta como raiz.
# ============================================================
function Crear-EstructuraUsuario {
    param(
        [string]$usuario,
        [string]$grupo
    )

    # Raiz virtual del usuario que IIS FTP usa con aislamiento
    $userVirtualRoot = "$FTP_ROOT\LocalUser\$usuario"

    if (-not (Test-Path $userVirtualRoot)) {
        New-Item -Path $userVirtualRoot -ItemType Directory | Out-Null
        Print-Completado "Directorio virtual creado: $userVirtualRoot"
    }

    # Carpeta personal real del usuario (fuera de LocalUser para no exponer otras rutas)
    $userPersonalDir = "$FTP_ROOT\users\$usuario"
    if (-not (Test-Path $userPersonalDir)) {
        New-Item -Path $userPersonalDir -ItemType Directory | Out-Null
        Print-Completado "Carpeta personal creada: $userPersonalDir"
    }

    # Junction: general => C:\FTP\general
    $junctionGeneral = "$userVirtualRoot\general"
    if (-not (Test-Path $junctionGeneral)) {
        cmd /c "mklink /J `"$junctionGeneral`" `"$FTP_ROOT\general`"" | Out-Null
        Print-Completado "Junction creado: $junctionGeneral => $FTP_ROOT\general"
    }

    # Junction: grupo => C:\FTP\<grupo>
    $junctionGrupo = "$userVirtualRoot\$grupo"
    if (-not (Test-Path $junctionGrupo)) {
        cmd /c "mklink /J `"$junctionGrupo`" `"$FTP_ROOT\$grupo`"" | Out-Null
        Print-Completado "Junction creado: $junctionGrupo => $FTP_ROOT\$grupo"
    }

    # Junction: <usuario> => C:\FTP\users\<usuario>
    $junctionPersonal = "$userVirtualRoot\$usuario"
    if (-not (Test-Path $junctionPersonal)) {
        cmd /c "mklink /J `"$junctionPersonal`" `"$userPersonalDir`"" | Out-Null
        Print-Completado "Junction creado: $junctionPersonal => $userPersonalDir"
    }

    # Permisos NTFS sobre las carpetas reales
    # Carpeta personal: control total
    icacls $userPersonalDir /grant "${usuario}:(OI)(CI)F" | Out-Null

    # Carpeta general: modificar (lectura + escritura)
    icacls "$FTP_ROOT\general" /grant "${usuario}:(OI)(CI)M" | Out-Null

    # Carpeta de su grupo: modificar
    icacls "$FTP_ROOT\$grupo" /grant "${usuario}:(OI)(CI)M" | Out-Null

    # La raiz virtual del usuario: el usuario necesita al menos listar (RX)
    icacls $userVirtualRoot /grant "${usuario}:(OI)(CI)RX" | Out-Null

    Print-Completado "Permisos NTFS asignados para '$usuario'."
}

# ============================================================
# FUNCION AUXILIAR: Eliminar junction points del grupo anterior
# ============================================================
function Eliminar-JunctionGrupo {
    param(
        [string]$usuario,
        [string]$grupoViejo
    )

    $junctionViejo = "$FTP_ROOT\LocalUser\$usuario\$grupoViejo"
    if (Test-Path $junctionViejo) {
        # Eliminar junction sin borrar el contenido real
        cmd /c "rmdir `"$junctionViejo`"" | Out-Null
        Print-Completado "Junction eliminado: $junctionViejo"
    }
}

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

    # ---------- Deshabilitar Firewall ----------
    Print-Info "Deshabilitando Firewall de Windows para garantizar conectividad..."
    Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
    Print-Completado "Firewall deshabilitado."

    # Regla por si se reactiva el firewall
    if (-not (Get-NetFirewallRule -Name "FTP-$PORT" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name "FTP-$PORT" `
            -DisplayName "FTP Puerto $PORT" `
            -Protocol TCP -LocalPort $PORT `
            -Direction Inbound -Action Allow | Out-Null
        Print-Completado "Regla de firewall creada para puerto $PORT."
    }

    # Regla para modo pasivo
    if (-not (Get-NetFirewallRule -Name "FTP-Pasivo" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name "FTP-Pasivo" `
            -DisplayName "FTP Modo Pasivo 49152-65535" `
            -Protocol TCP -LocalPort 49152-65535 `
            -Direction Inbound -Action Allow | Out-Null
        Print-Completado "Regla de firewall para modo pasivo creada."
    }

    # ---------- Crear estructura de directorios base ----------
    Print-Info "Creando estructura de directorios en $FTP_ROOT..."

    $dirs = @(
        $FTP_ROOT,
        "$FTP_ROOT\general",
        "$FTP_ROOT\reprobados",
        "$FTP_ROOT\recursadores",
        "$FTP_ROOT\users",        # Carpetas personales reales
        "$FTP_ROOT\LocalUser"     # Raices virtuales por usuario (requerido por IIS FTP)
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

    # IUSR = usuario anonimo de IIS (solo lectura en general)
    icacls "$FTP_ROOT\general" /grant "IUSR:(OI)(CI)RX" | Out-Null
    Print-Completado "Permisos de usuario anonimo configurados en \general."

    # Acceso anonimo a su raiz virtual
    $anonymousRoot = "$FTP_ROOT\LocalUser\Public"
    if (-not (Test-Path $anonymousRoot)) {
        New-Item -Path $anonymousRoot -ItemType Directory | Out-Null
    }
    # Junction hacia general para el acceso anonimo
    $junctionAnonGeneral = "$anonymousRoot\general"
    if (-not (Test-Path $junctionAnonGeneral)) {
        cmd /c "mklink /J `"$junctionAnonGeneral`" `"$FTP_ROOT\general`"" | Out-Null
    }
    icacls $anonymousRoot /grant "IUSR:(OI)(CI)RX" | Out-Null
    Print-Completado "Raiz virtual anonima configurada en $anonymousRoot."

    # ---------- Detener sitio Default si existe ----------
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
        Print-Info "Sitio FTP ya existe, actualizando puerto a $PORT..."
        Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
            -Name bindings `
            -Value @{protocol="ftp"; bindingInformation="*:${PORT}:"}
        Print-Completado "Puerto actualizado a $PORT."
    }

    # ---------- Aislamiento de usuarios ----------
    # Modo 3 = IsolateAllDirectories:
    #   IIS FTP usa C:\FTP\LocalUser\<usuario>\ como raiz del usuario autenticado.
    #   Cada usuario SOLO ve lo que hay dentro de su carpeta virtual.
    #   El anonimo usa C:\FTP\LocalUser\Public\
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.userIsolation.mode `
        -Value 3
    Print-Completado "Modo de aislamiento configurado: IsolateAllDirectories (modo 3)."
    Print-Info "  => Cada usuario vera SOLO su carpeta virtual en $FTP_ROOT\LocalUser\<usuario>"

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

    # ---------- Habilitar y arrancar servicio FTP ----------
    Print-Info "Arrancando servicio FTPSVC..."
    Set-Service -Name FTPSVC -StartupType Automatic
    Restart-Service FTPSVC -Force
    Start-WebSite -Name $SITE_NAME -ErrorAction SilentlyContinue

    Print-Completado "Servidor FTP listo y escuchando en el puerto $PORT"
    Print-Info ""
    Print-Info "Estructura al conectarse como usuario autenticado:"
    Print-Info "  /                        (raiz virtual del usuario)"
    Print-Info "  /general                 (lectura + escritura)"
    Print-Info "  /reprobados o recursadores (lectura + escritura segun grupo)"
    Print-Info "  /<nombre_usuario>        (lectura + escritura, carpeta personal)"
    Print-Info ""
    Print-Info "Estructura al conectarse como anonimo:"
    Print-Info "  /                        (raiz publica)"
    Print-Info "  /general                 (solo lectura)"
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

        # --- Crear estructura de carpetas con junctions ---
        Print-Info "Creando estructura de directorios y junctions para '$usuario'..."
        Crear-EstructuraUsuario -usuario $usuario -grupo $grupo

        Print-Completado "Estructura lista para '$usuario':"
        Print-Info "  Al conectarse por FTP vera:"
        Print-Info "  /general          => $FTP_ROOT\general"
        Print-Info "  /$grupo           => $FTP_ROOT\$grupo"
        Print-Info "  /$usuario         => $FTP_ROOT\users\$usuario"
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

    # Detectar grupo actual revisando junctions en la carpeta virtual del usuario
    $userVirtualRoot = "$FTP_ROOT\LocalUser\$usuario"
    $grupoActual = ""

    if (Test-Path "$userVirtualRoot\reprobados") {
        $grupoActual = "reprobados"
    } elseif (Test-Path "$userVirtualRoot\recursadores") {
        $grupoActual = "recursadores"
    }

    if ($grupoActual -eq $nuevoGrupo) {
        Print-Info "El usuario '$usuario' ya pertenece al grupo '$nuevoGrupo'. No hay cambios."
        exit 0
    }

    # --- Quitar junction y permisos del grupo anterior ---
    if ($grupoActual -ne "") {
        Print-Info "Removiendo acceso al grupo anterior '$grupoActual'..."

        # Eliminar junction
        Eliminar-JunctionGrupo -usuario $usuario -grupoViejo $grupoActual

        # Quitar permisos NTFS sobre la carpeta real del grupo viejo
        icacls "$FTP_ROOT\$grupoActual" /remove $usuario 2>&1 | Out-Null
        Print-Completado "Acceso removido de '$grupoActual'."
    }

    # --- Crear junction al nuevo grupo ---
    Print-Info "Asignando acceso al nuevo grupo '$nuevoGrupo'..."

    $junctionNuevo = "$userVirtualRoot\$nuevoGrupo"
    if (-not (Test-Path $junctionNuevo)) {
        cmd /c "mklink /J `"$junctionNuevo`" `"$FTP_ROOT\$nuevoGrupo`"" | Out-Null
        Print-Completado "Junction creado: $junctionNuevo => $FTP_ROOT\$nuevoGrupo"
    }

    # Asignar permisos NTFS sobre la carpeta real del nuevo grupo
    icacls "$FTP_ROOT\$nuevoGrupo" /grant "${usuario}:(OI)(CI)M" | Out-Null

    # Actualizar descripcion del usuario
    Set-LocalUser -Name $usuario -Description "Usuario FTP - Grupo: $nuevoGrupo" -ErrorAction SilentlyContinue

    Print-Completado "Grupo actualizado correctamente."
    Print-Info "Usuario '$usuario' ahora pertenece a: $nuevoGrupo"
    Print-Info "Al conectarse por FTP vera:"
    Print-Info "  /general      => $FTP_ROOT\general"
    Print-Info "  /$nuevoGrupo  => $FTP_ROOT\$nuevoGrupo"
    Print-Info "  /$usuario     => $FTP_ROOT\users\$usuario"
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
