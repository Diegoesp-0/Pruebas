# ============================================================
# ftp-windows.ps1 - Instalacion y gestion de servidor FTP
# Windows Server Core - IIS + FTP Service (FTP Plano, sin SSL)
# Puerto: 22
# Uso:
#   .\ftp-windows.ps1 -i   => Instalar y configurar FTP
#   .\ftp-windows.ps1 -u   => Crear usuarios
#   .\ftp-windows.ps1 -c   => Cambiar grupo de usuario
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
$PASSIVE_PORT_RANGE = "49152-65535"

# ============================================================
# FUNCION: Crear grupos locales si no existen
# ============================================================
function Crear-Grupos {
    $grupos = @("reprobados", "recursadores")
    foreach ($g in $grupos) {
        if (-not (Get-LocalGroup -Name $g -ErrorAction SilentlyContinue)) {
            New-LocalGroup -Name $g -Description "Grupo FTP para $g" | Out-Null
            Print-Completado "Grupo local '$g' creado."
        } else {
            Print-Info "Grupo local '$g' ya existe."
        }
    }
}

# ============================================================
# FUNCION: Configurar permisos NTFS base
# ============================================================
function Configurar-PermisosBase {
    Print-Info "Configurando permisos NTFS base..."

    # IUSR = cuenta anonima de IIS
    $iusr = "IUSR"
    $authUsers = "Authenticated Users"

    # Permisos en la raiz: lectura para anonimo y autenticados (para poder listar)
    icacls $FTP_ROOT /grant "${iusr}:(OI)(CI)RX" 2>&1 | Out-Null
    icacls $FTP_ROOT /grant "${authUsers}:(OI)(CI)RX" 2>&1 | Out-Null

    # General: anonimo solo lectura, autenticados modificacion
    icacls "$FTP_ROOT\general" /grant "${iusr}:(OI)(CI)RX" 2>&1 | Out-Null
    icacls "$FTP_ROOT\general" /grant "${authUsers}:(OI)(CI)M" 2>&1 | Out-Null

    # Grupos: solo el grupo correspondiente tiene modificacion (se asigna al grupo, no a usuarios individuales)
    icacls "$FTP_ROOT\reprobados" /grant "reprobados:(OI)(CI)M" 2>&1 | Out-Null
    icacls "$FTP_ROOT\recursadores" /grant "recursadores:(OI)(CI)M" 2>&1 | Out-Null

    Print-Completado "Permisos base configurados."
}

# ============================================================
# FUNCION: Crear reglas de firewall
# ============================================================
function Configurar-Firewall {
    Print-Info "Configurando reglas de firewall..."

    # Puerto de control FTP
    if (-not (Get-NetFirewallRule -Name "FTP-$PORT" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name "FTP-$PORT" `
            -DisplayName "FTP Puerto $PORT" `
            -Protocol TCP -LocalPort $PORT `
            -Direction Inbound -Action Allow | Out-Null
        Print-Completado "Regla para puerto $PORT creada."
    } else {
        Print-Info "Regla para puerto $PORT ya existe."
    }

    # Rango de puertos pasivos
    if (-not (Get-NetFirewallRule -Name "FTP-Pasivo" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name "FTP-Pasivo" `
            -DisplayName "FTP Modo Pasivo $PASSIVE_PORT_RANGE" `
            -Protocol TCP -LocalPort $PASSIVE_PORT_RANGE `
            -Direction Inbound -Action Allow | Out-Null
        Print-Completado "Regla para modo pasivo creada."
    } else {
        Print-Info "Regla para modo pasivo ya existe."
    }
}

# ============================================================
# FUNCION: Habilitar ABE (Access Based Enumeration) en el sitio FTP
# ============================================================
function Habilitar-ABE {
    try {
        Set-WebConfigurationProperty -Filter "system.ftpServer/userIsolation" `
            -Name accessBasedEnumeration -Value $true -PSPath "IIS:\" -Location $SITE_NAME -ErrorAction Stop
        Print-Completado "Access Based Enumeration (ABE) habilitado."
    } catch {
        Print-Error "No se pudo habilitar ABE. Asegurese que el sitio existe."
    }
}

# ============================================================
# FUNCION: Deshabilitar SSL completamente (solo FTP plano)
# ============================================================
function Deshabilitar-SSL-Completamente {
    Print-Info "Deshabilitando SSL completamente (modo FTP plano)..."

    try {
        # Deshabilitar SSL en el canal de control
        Set-ItemProperty "IIS:\Sites\$SITE_NAME" -Name ftpServer.security.ssl.controlChannelPolicy -Value "SslDisable" -ErrorAction Stop
        
        # Deshabilitar SSL en el canal de datos
        Set-ItemProperty "IIS:\Sites\$SITE_NAME" -Name ftpServer.security.ssl.dataChannelPolicy -Value "SslDisable" -ErrorAction Stop
        
        Print-Completado "SSL deshabilitado completamente. El servidor ahora acepta solo FTP plano."
    } catch {
        Print-Error "No se pudo deshabilitar SSL con PowerShell. Intentando metodo alternativo..."
        
        # Metodo alternativo usando appcmd
        & "$env:SystemRoot\System32\inetsrv\appcmd.exe" set config -section:system.ftpServer/security/ssl /controlChannelPolicy:"SslDisable" /commit:apphost | Out-Null
        & "$env:SystemRoot\System32\inetsrv\appcmd.exe" set config -section:system.ftpServer/security/ssl /dataChannelPolicy:"SslDisable" /commit:apphost | Out-Null
        
        Print-Completado "SSL deshabilitado usando appcmd."
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

    # ---------- Crear grupos locales ----------
    Crear-Grupos

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

    # ---------- Configurar permisos NTFS ----------
    Configurar-PermisosBase

    # ---------- Configurar firewall ----------
    Configurar-Firewall

    # ---------- Detener sitio Default si existe para liberar puerto ----------
    $defaultSite = Get-WebSite -Name "Default Web Site" -ErrorAction SilentlyContinue
    if ($defaultSite -and $defaultSite.State -eq "Started") {
        Stop-WebSite -Name "Default Web Site"
        Print-Info "Sitio 'Default Web Site' detenido para liberar recursos."
    }

    # ---------- Crear o actualizar sitio FTP ----------
    $sitioExiste = Get-WebSite -Name $SITE_NAME -ErrorAction SilentlyContinue

    if (-not $sitioExiste) {
        Print-Info "Creando sitio FTP: $SITE_NAME en puerto $PORT..."
        New-WebFtpSite -Name $SITE_NAME -Port $PORT -PhysicalPath $FTP_ROOT | Out-Null
        Print-Completado "Sitio FTP creado."
    } else {
        Print-Info "Sitio FTP ya existe, actualizando puerto a $PORT..."
        Set-ItemProperty "IIS:\Sites\$SITE_NAME" -Name bindings -Value @{protocol="ftp"; bindingInformation="*:${PORT}:"}
        Print-Completado "Puerto actualizado."
    }

    # ---------- Configurar aislamiento (modo 0 = sin aislamiento, usamos ABE) ----------
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" -Name ftpServer.userIsolation.mode -Value 0
    Print-Info "Modo de aislamiento: sin aislamiento (se usara ABE y permisos NTFS)."

    # ---------- Habilitar ABE ----------
    Habilitar-ABE

    # ---------- Autenticacion ----------
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" -Name ftpServer.security.authentication.anonymousAuthentication.enabled -Value $true
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" -Name ftpServer.security.authentication.basicAuthentication.enabled -Value $true
    Print-Completado "Autenticacion anonima y basica habilitadas."

    # ---------- Reglas de autorizacion FTP ----------
    Print-Info "Configurando reglas de autorizacion FTP..."

    # Limpiar reglas anteriores
    Clear-WebConfiguration -PSPath "IIS:\" -Filter "system.ftpServer/security/authorization" -Location $SITE_NAME -ErrorAction SilentlyContinue

    # Anonimo: solo lectura
    Add-WebConfiguration -PSPath "IIS:\" -Filter "system.ftpServer/security/authorization" -Location $SITE_NAME -Value @{
        accessType  = "Allow"
        users       = "anonymous"
        permissions = "Read"
    }

    # Usuarios autenticados: lectura y escritura
    Add-WebConfiguration -PSPath "IIS:\" -Filter "system.ftpServer/security/authorization" -Location $SITE_NAME -Value @{
        accessType  = "Allow"
        users       = "*"
        permissions = "Read, Write"
    }

    Print-Completado "Reglas de autorizacion configuradas."

    # ---------- Deshabilitar SSL completamente (FTP plano) ----------
    Deshabilitar-SSL-Completamente

    # ---------- Habilitar y arrancar servicio FTP ----------
    Print-Info "Arrancando servicio FTPSVC..."
    Set-Service -Name FTPSVC -StartupType Automatic
    Start-Service -Name FTPSVC -ErrorAction SilentlyContinue
    Start-WebSite -Name $SITE_NAME -ErrorAction SilentlyContinue

    Print-Completado "Servidor FTP listo y escuchando en el puerto $PORT (FTP plano, sin SSL)"
    Print-Info "Estructura de directorios en ${FTP_ROOT}:"
    Print-Info "  general        (anonimo: lectura, autenticados: escritura)"
    Print-Info "  reprobados     (solo miembros del grupo reprobados: escritura)"
    Print-Info "  recursadores   (solo miembros del grupo recursadores: escritura)"
    Print-Info "  <usuario>      (carpeta personal, solo el usuario: control total)"
    Print-Info "Nota: Con Access Based Enumeration, cada usuario vera solo las carpetas a las que tiene permiso."
}

# ============================================================
# CREAR USUARIOS
# ============================================================
if ($u) {

    Import-Module WebAdministration -Force -ErrorAction Stop

    Print-Titulo "CREACION DE USUARIOS FTP"

    # Verificar que el servidor este instalado
    if (-not (Test-Path $FTP_ROOT)) {
        Print-Error "El directorio $FTP_ROOT no existe. Ejecute primero: .\ftp-windows.ps1 -i"
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
        New-LocalUser -Name $usuario -Password $passSecure -PasswordNeverExpires -UserMayNotChangePassword -Description "Usuario FTP - Grupo: $grupo" | Out-Null
        Print-Completado "Usuario '$usuario' creado."

        # --- Agregar al grupo correspondiente ---
        Add-LocalGroupMember -Group $grupo -Member $usuario
        Print-Completado "Usuario agregado al grupo '$grupo'."

        # --- Crear carpeta personal ---
        $userDir = "$FTP_ROOT\$usuario"
        if (-not (Test-Path $userDir)) {
            New-Item -Path $userDir -ItemType Directory | Out-Null
            Print-Completado "Carpeta personal creada: $userDir"
        }

        # --- Asignar permisos NTFS ---
        Print-Info "Asignando permisos NTFS..."

        # Carpeta personal: control total para el usuario
        icacls $userDir /grant "${usuario}:(OI)(CI)F" | Out-Null

        Print-Completado "Permisos asignados para '$usuario'."
    }

    Print-Titulo "CREACION DE USUARIOS COMPLETADA"
    Print-Info "Puede probar el acceso con un cliente FTP (puerto $PORT, FTP plano)."
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

    # Determinar grupo actual (si pertenece a alguno de los dos)
    $grupoActual = $null
    if ((Get-LocalGroupMember -Group "reprobados" -ErrorAction SilentlyContinue) -match $usuario) {
        $grupoActual = "reprobados"
    } elseif ((Get-LocalGroupMember -Group "recursadores" -ErrorAction SilentlyContinue) -match $usuario) {
        $grupoActual = "recursadores"
    }

    if ($grupoActual -eq $nuevoGrupo) {
        Print-Info "El usuario '$usuario' ya pertenece al grupo '$nuevoGrupo'. No hay cambios."
        exit 0
    }

    # Quitar del grupo anterior (si aplica)
    if ($grupoActual) {
        Remove-LocalGroupMember -Group $grupoActual -Member $usuario -ErrorAction SilentlyContinue
        Print-Completado "Usuario removido del grupo '$grupoActual'."
    }

    # Agregar al nuevo grupo
    Add-LocalGroupMember -Group $nuevoGrupo -Member $usuario
    Print-Completado "Usuario agregado al grupo '$nuevoGrupo'."

    Print-Completado "Grupo actualizado correctamente."
    Print-Info "Usuario '$usuario' ahora pertenece a: $nuevoGrupo"
}

# ---------- Sin parametros ----------
if (-not $i -and -not $u -and -not $c) {
    Print-Titulo "SCRIPT DE ADMINISTRACION FTP"
    Print-Info "Uso:"
    Print-Info "  .\ftp-windows.ps1 -i   => Instalar y configurar servidor FTP (puerto $PORT)"
    Print-Info "  .\ftp-windows.ps1 -u   => Crear usuarios FTP"
    Print-Info "  .\ftp-windows.ps1 -c   => Cambiar grupo de un usuario"
    Print-Info ""
    Print-Info "Ejemplos:"
    Print-Info "  .\ftp-windows.ps1 -i"
    Print-Info "  .\ftp-windows.ps1 -u"
    Print-Info "  .\ftp-windows.ps1 -c"
}
