param(
    [switch]$i,
    [switch]$u,
    [switch]$c,
    [switch]$l
)

# ---------- Cargar librerias ----------
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$SCRIPT_DIR\utils.ps1"
. "$SCRIPT_DIR\validaciones.ps1"

# ---------- Variables globales ----------
$SITE_NAME          = "FTP-Servidor"
$FTP_ROOT           = "C:\FTP"
$PORT               = 21
$GRUPO_REPROBADOS   = "reprobados"
$GRUPO_RECURSADORES = "recursadores"

# ============================================================
# FUNCION AUXILIAR: Verificar que el modulo WebAdministration este cargado
# ============================================================
function Cargar-WebAdmin {
    if (-not (Get-Module -Name WebAdministration -ErrorAction SilentlyContinue)) {
        Import-Module WebAdministration -Force -ErrorAction Stop
    }
}

# ============================================================
# FUNCION AUXILIAR: Crear raiz de aislamiento del usuario
#
# IIS FTP modo 3 (IsolateUsers) busca:
#   C:\FTP\LocalUser\<usuario>\   <- esto es la raiz / que ve el usuario
#
# Dentro creamos junctions a las carpetas reales:
#   general   -> C:\FTP\_general
#   <grupo>   -> C:\FTP\_<grupo>
#   <usuario> -> C:\FTP\_usuarios\<usuario>
#
# Permisos NTFS:
#   - El usuario necesita RX en su raiz de aislamiento para que IIS no rechace el login
#   - Las carpetas reales tienen los permisos de lectura/escritura correspondientes
# ============================================================
function Crear-RaizUsuario {
    param(
        [string]$usuario,
        [string]$grupo
    )

    $raiz = "$FTP_ROOT\LocalUser\$usuario"

    # Crear raiz de aislamiento
    if (-not (Test-Path $raiz)) {
        New-Item -Path $raiz -ItemType Directory -Force | Out-Null
    }

    # ---- Junction: general ----
    $linkGeneral = "$raiz\general"
    if (-not (Test-Path $linkGeneral)) {
        cmd /c "mklink /J `"$linkGeneral`" `"$FTP_ROOT\_general`"" | Out-Null
    }

    # ---- Junction: carpeta de grupo ----
    $linkGrupo = "$raiz\$grupo"
    if (-not (Test-Path $linkGrupo)) {
        cmd /c "mklink /J `"$linkGrupo`" `"$FTP_ROOT\_$grupo`"" | Out-Null
    }

    # ---- Junction: carpeta personal ----
    $dirPersonal = "$FTP_ROOT\_usuarios\$usuario"
    if (-not (Test-Path $dirPersonal)) {
        New-Item -Path $dirPersonal -ItemType Directory -Force | Out-Null
    }
    $linkPersonal = "$raiz\$usuario"
    if (-not (Test-Path $linkPersonal)) {
        cmd /c "mklink /J `"$linkPersonal`" `"$dirPersonal`"" | Out-Null
    }

    # ---- Permisos NTFS en la raiz de aislamiento ----
    # RX en la raiz para que IIS FTP acepte el login y el usuario pueda listar
    icacls $raiz /grant "${usuario}:(OI)(CI)RX" /T 2>&1 | Out-Null

    # ---- Permisos NTFS en las carpetas reales ----
    # general:        escritura (M = leer + escribir + borrar)
    icacls "$FTP_ROOT\_general"  /grant "${usuario}:(OI)(CI)M" 2>&1 | Out-Null
    # grupo propio:   escritura
    icacls "$FTP_ROOT\_$grupo"   /grant "${usuario}:(OI)(CI)M" 2>&1 | Out-Null
    # carpeta propia: control total
    icacls "$dirPersonal"        /grant "${usuario}:(OI)(CI)F" 2>&1 | Out-Null

    Print-Completado "Raiz de aislamiento lista para '$usuario' (grupo: $grupo)"
    Print-Info "  Ve: /general, /$grupo, /$usuario"
}

# ============================================================
# FUNCION AUXILIAR: Detectar grupo actual de un usuario (por permisos ACL)
# Busca en cual carpeta de grupo tiene permiso M (modificar = su grupo)
# ============================================================
function Obtener-GrupoActual {
    param([string]$usuario)

    $aclR = (icacls "$FTP_ROOT\_reprobados"   2>&1) -join " "
    $aclE = (icacls "$FTP_ROOT\_recursadores" 2>&1) -join " "

    if ($aclR -match "${usuario}.*M\)") {
        return "reprobados"
    } elseif ($aclE -match "${usuario}.*M\)") {
        return "recursadores"
    }
    return ""
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

    # ---------- 1. Instalar caracteristicas de Windows ----------
    Print-Info "Instalando caracteristicas de Windows (IIS + FTP)..."

    $features = @(
        "Web-Server",
        "Web-Ftp-Server",
        "Web-Ftp-Service",
        "Web-Ftp-Extensibility",
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

    # ---------- 2. Importar modulo WebAdministration ----------
    Print-Info "Cargando modulo WebAdministration..."
    Import-Module WebAdministration -Force -ErrorAction Stop

    # ---------- 3. Firewall ----------
    Print-Info "Configurando Firewall de Windows para FTP..."

    Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
    Print-Completado "Firewall deshabilitado."

    if (-not (Get-NetFirewallRule -Name "FTP-Control-21" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name "FTP-Control-21" `
            -DisplayName "FTP Control Port 21" `
            -Protocol TCP -LocalPort 21 `
            -Direction Inbound -Action Allow | Out-Null
        Print-Completado "Regla puerto 21 creada."
    }

    if (-not (Get-NetFirewallRule -Name "FTP-Pasivo" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name "FTP-Pasivo" `
            -DisplayName "FTP Modo Pasivo 49152-65535" `
            -Protocol TCP -LocalPort 49152-65535 `
            -Direction Inbound -Action Allow | Out-Null
        Print-Completado "Regla modo pasivo creada."
    }

    # ---------- 4. Crear estructura de directorios ----------
    Print-Info "Creando estructura de directorios en $FTP_ROOT..."

    $dirsReales = @(
        $FTP_ROOT,
        "$FTP_ROOT\_general",
        "$FTP_ROOT\_reprobados",
        "$FTP_ROOT\_recursadores",
        "$FTP_ROOT\_usuarios",
        "$FTP_ROOT\LocalUser"
    )

    foreach ($d in $dirsReales) {
        if (-not (Test-Path $d)) {
            New-Item -Path $d -ItemType Directory -Force | Out-Null
            Print-Completado "Directorio creado: $d"
        } else {
            Print-Info "Directorio ya existe: $d"
        }
    }

    # ---------- 5. Permisos NTFS base ----------
    Print-Info "Configurando permisos NTFS base..."

    # Administrators con control total en todo el arbol
    icacls $FTP_ROOT /grant "Administrators:(OI)(CI)F" /T 2>&1 | Out-Null

    # _reprobados y _recursadores: deshabilitar herencia y bloquear anonymous
    # Los usuarios autenticados reciben permisos al crearse con -u
    foreach ($carpeta in @("_reprobados", "_recursadores", "_usuarios")) {
        icacls "$FTP_ROOT\$carpeta" /inheritance:d                    2>&1 | Out-Null
        icacls "$FTP_ROOT\$carpeta" /remove "IUSR"                    2>&1 | Out-Null
        icacls "$FTP_ROOT\$carpeta" /remove "IIS_IUSRS"               2>&1 | Out-Null
        icacls "$FTP_ROOT\$carpeta" /grant "Administrators:(OI)(CI)F" 2>&1 | Out-Null
        Print-Completado "$carpeta : anonymous sin acceso."
    }

    # _general: anonymous puede leer (IUSR con RX)
    icacls "$FTP_ROOT\_general" /grant "IUSR:(OI)(CI)RX"      2>&1 | Out-Null
    icacls "$FTP_ROOT\_general" /grant "IIS_IUSRS:(OI)(CI)RX" 2>&1 | Out-Null
    Print-Completado "_general: anonymous con lectura (RX)."

    # ---------- 6. Raiz de aislamiento para anonymous ----------
    # IIS FTP modo 3 busca C:\FTP\LocalUser\Public\ para el usuario anonymous
    # Solo ponemos junction a _general, que es lo unico que debe ver
    Print-Info "Creando raiz de aislamiento para anonymous..."

    $publicRoot = "$FTP_ROOT\LocalUser\Public"
    if (-not (Test-Path $publicRoot)) {
        New-Item -Path $publicRoot -ItemType Directory -Force | Out-Null
    }

    $publicGeneral = "$publicRoot\general"
    if (-not (Test-Path $publicGeneral)) {
        cmd /c "mklink /J `"$publicGeneral`" `"$FTP_ROOT\_general`"" | Out-Null
    }

    # IUSR necesita RX en la raiz Public para que IIS acepte el login anonimo
    icacls $publicRoot /grant "IUSR:(OI)(CI)RX"      /T 2>&1 | Out-Null
    icacls $publicRoot /grant "IIS_IUSRS:(OI)(CI)RX" /T 2>&1 | Out-Null
    Print-Completado "Raiz anonima lista: anonymous ve solo /general en lectura."

    # ---------- 7. Detener sitio Default Web Site ----------
    $defaultSite = Get-WebSite -Name "Default Web Site" -ErrorAction SilentlyContinue
    if ($defaultSite) {
        Stop-WebSite -Name "Default Web Site" -ErrorAction SilentlyContinue
        Set-ItemProperty "IIS:\Sites\Default Web Site" -Name serverAutoStart -Value $false
        Print-Info "Sitio 'Default Web Site' detenido."
    }

    # ---------- 8. Crear o actualizar sitio FTP ----------
    $sitioExiste = Get-WebSite -Name $SITE_NAME -ErrorAction SilentlyContinue

    if ($sitioExiste) {
        Print-Info "Eliminando sitio FTP anterior para recrearlo limpio..."
        Remove-WebSite -Name $SITE_NAME -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    Print-Info "Creando sitio FTP: $SITE_NAME en puerto $PORT..."
    New-WebFtpSite `
        -Name $SITE_NAME `
        -Port $PORT `
        -PhysicalPath $FTP_ROOT `
        -Force | Out-Null
    Print-Completado "Sitio FTP creado."

    # ---------- 9. Modo de aislamiento ----------
    # Modo 3 = IsolateUsers
    # Cada usuario ve SOLO su carpeta en C:\FTP\LocalUser\<usuario>\
    # Anonymous ve SOLO C:\FTP\LocalUser\Public\
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.userIsolation.mode `
        -Value 3
    Print-Completado "Modo de aislamiento: IsolateUsers (modo 3)."

    # ---------- 10. Autenticacion ----------
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.authentication.anonymousAuthentication.enabled `
        -Value $true

    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.authentication.basicAuthentication.enabled `
        -Value $true

    Print-Completado "Autenticacion anonima y basica habilitadas."

    # ---------- 11. Reglas de autorizacion FTP ----------
    Print-Info "Configurando reglas de autorizacion FTP..."

    Clear-WebConfiguration `
        -PSPath "IIS:\" `
        -Filter "system.ftpServer/security/authorization" `
        -Location $SITE_NAME `
        -ErrorAction SilentlyContinue

    # Anonymous: solo lectura a nivel FTP (el aislamiento ya limita que carpetas ve)
    Add-WebConfiguration `
        -PSPath "IIS:\" `
        -Filter "system.ftpServer/security/authorization" `
        -Location $SITE_NAME `
        -Value @{
            accessType  = "Allow"
            users       = "anonymous"
            roles       = ""
            permissions = "Read"
        }

    # Usuarios autenticados: lectura y escritura (NTFS controla donde exactamente)
    Add-WebConfiguration `
        -PSPath "IIS:\" `
        -Filter "system.ftpServer/security/authorization" `
        -Location $SITE_NAME `
        -Value @{
            accessType  = "Allow"
            users       = "*"
            roles       = ""
            permissions = "Read,Write"
        }

    Print-Completado "Reglas de autorizacion configuradas."

    # ---------- 12. SSL ----------
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.ssl.controlChannelPolicy `
        -Value 0
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.ssl.dataChannelPolicy `
        -Value 0
    Print-Completado "SSL configurado como opcional (sin forzar)."

    # ---------- 13. Arrancar servicio ----------
    Print-Info "Arrancando servicio FTPSVC..."
    Set-Service -Name FTPSVC -StartupType Automatic
    Restart-Service FTPSVC -Force
    Start-Sleep -Seconds 3
    Start-WebSite -Name $SITE_NAME -ErrorAction SilentlyContinue

    # ---------- 14. Verificacion ----------
    $estado = (Get-WebSite -Name $SITE_NAME).state
    if ($estado -eq "Started") {
        Print-Completado "Sitio FTP arrancado correctamente."
    } else {
        Print-Error "El sitio FTP no arranco. Estado: $estado"
        Print-Info "Revisa: Get-EventLog -LogName Application -Source *ftp* -Newest 10"
    }

    $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne "127.0.0.1" } | Select-Object -First 1).IPAddress

    Print-Titulo "SERVIDOR FTP LISTO"
    Print-Info "  IP del servidor  : $ip"
    Print-Info "  Puerto FTP       : $PORT"
    Print-Info "  Acceso anonimo   : ftp://$ip  (usuario: anonymous, pass: cualquier cosa)"
    Print-Info "  Raiz FTP en disco: $FTP_ROOT"
    Print-Info ""
    Print-Info "Lo que ve cada usuario al conectarse:"
    Print-Info "  anonymous        => /general (solo lectura)"
    Print-Info "  usuario autent.  => /general (escritura) + /<grupo> (escritura) + /<usuario> (total)"
    Print-Info ""
    Print-Info "Ahora puede crear usuarios con: .\ftp-windows.ps1 -u"
}

# ============================================================
# CREAR USUARIOS
# ============================================================
if ($u) {

    Cargar-WebAdmin

    Print-Titulo "CREACION DE USUARIOS FTP"

    if (-not (Test-Path "$FTP_ROOT\LocalUser")) {
        Print-Error "El servidor FTP no esta instalado. Ejecuta primero: .\ftp-windows.ps1 -i"
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

        try {
            New-LocalUser `
                -Name $usuario `
                -Password $passSecure `
                -PasswordNeverExpires `
                -UserMayNotChangePassword `
                -Description "Usuario FTP - Grupo: $grupo" | Out-Null
            Print-Completado "Usuario '$usuario' creado."
        } catch {
            Print-Error "Error al crear usuario '$usuario': $_"
            continue
        }

        # --- Crear raiz de aislamiento + junctions + permisos NTFS ---
        Crear-RaizUsuario -usuario $usuario -grupo $grupo

        Print-Completado "Usuario '$usuario' listo."
        Print-Info "  Raiz FTP        : $FTP_ROOT\LocalUser\$usuario\"
        Print-Info "  Carpetas visibles: /general, /$grupo, /$usuario"
    }

    Print-Info "Reiniciando servicio FTPSVC..."
    Restart-Service FTPSVC -Force
    Start-Sleep -Seconds 2
    Start-WebSite -Name $SITE_NAME -ErrorAction SilentlyContinue
    Print-Completado "Servicio reiniciado."

    Print-Titulo "CREACION DE USUARIOS COMPLETADA"
}

# ============================================================
# CAMBIAR GRUPO DE USUARIO
# ============================================================
if ($c) {

    Cargar-WebAdmin

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

    # --- Detectar grupo actual ---
    $grupoActual = Obtener-GrupoActual -usuario $usuario
    if ($grupoActual -ne "") {
        Print-Info "Grupo actual de '$usuario': $grupoActual"
    } else {
        Print-Info "No se pudo detectar el grupo actual de '$usuario'."
    }

    # --- Nuevo grupo ---
    $nuevoGrupo = ""
    do {
        $nuevoGrupo = Read-Host "Nuevo grupo (reprobados/recursadores)"
        if (-not (Validar-Grupo $nuevoGrupo)) {
            $nuevoGrupo = ""
        }
    } while ($nuevoGrupo -eq "")

    if ($grupoActual -eq $nuevoGrupo) {
        Print-Info "El usuario '$usuario' ya pertenece al grupo '$nuevoGrupo'. No hay cambios."
        exit 0
    }

    # --- Quitar permisos del grupo anterior ---
    if ($grupoActual -ne "") {
        Print-Info "Quitando acceso a '$grupoActual'..."
        icacls "$FTP_ROOT\_$grupoActual" /remove $usuario 2>&1 | Out-Null
        Print-Completado "Permisos removidos de '_$grupoActual'."
    }

    # --- Dar permisos en el nuevo grupo ---
    Print-Info "Asignando acceso a '$nuevoGrupo'..."
    icacls "$FTP_ROOT\_$nuevoGrupo" /grant "${usuario}:(OI)(CI)M" 2>&1 | Out-Null
    Print-Completado "Permisos asignados en '_$nuevoGrupo'."

    # --- Actualizar junctions en la raiz de aislamiento ---
    $raiz = "$FTP_ROOT\LocalUser\$usuario"

    # Eliminar junction del grupo anterior
    if ($grupoActual -ne "") {
        $junctionAntigua = "$raiz\$grupoActual"
        if (Test-Path $junctionAntigua) {
            cmd /c "rmdir `"$junctionAntigua`"" 2>&1 | Out-Null
            Print-Completado "Junction '$grupoActual' eliminado."
        }
    }

    # Crear junction del nuevo grupo
    $junctionNueva = "$raiz\$nuevoGrupo"
    if (-not (Test-Path $junctionNueva)) {
        cmd /c "mklink /J `"$junctionNueva`" `"$FTP_ROOT\_$nuevoGrupo`"" | Out-Null
        Print-Completado "Junction '$nuevoGrupo' creado."
    }

    Print-Info "Reiniciando servicio FTPSVC..."
    Restart-Service FTPSVC -Force
    Start-Sleep -Seconds 2
    Start-WebSite -Name $SITE_NAME -ErrorAction SilentlyContinue

    Print-Completado "Grupo actualizado correctamente."
    Print-Info "Usuario '$usuario' ahora pertenece a: $nuevoGrupo"
    Print-Info "Carpetas visibles: /general, /$nuevoGrupo, /$usuario"
}

# ============================================================
# LISTAR USUARIOS FTP
# ============================================================
if ($l) {

    Print-Titulo "USUARIOS FTP CONFIGURADOS"

    if (-not (Test-Path "$FTP_ROOT\LocalUser")) {
        Print-Error "El servidor FTP no esta instalado."
        exit 1
    }

    $dirs = Get-ChildItem "$FTP_ROOT\LocalUser" -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne "Public" }

    if (-not $dirs) {
        Print-Info "No hay usuarios FTP creados aun."
    } else {
        Write-Host ""
        Write-Host ("{0,-20} {1,-15} {2}" -f "USUARIO", "GRUPO", "RAIZ FTP") -ForegroundColor Cyan
        Write-Host ("-" * 65) -ForegroundColor Cyan

        foreach ($d in $dirs) {
            $usr = $d.Name
            $grp = Obtener-GrupoActual -usuario $usr
            if ($grp -eq "") { $grp = "(desconocido)" }
            Write-Host ("{0,-20} {1,-15} {2}" -f $usr, $grp, $d.FullName)
        }
        Write-Host ""
    }
}

# ---------- Sin parametros ----------
if (-not $i -and -not $u -and -not $c -and -not $l) {
    Print-Titulo "SCRIPT DE ADMINISTRACION FTP - Windows Server IIS"
    Print-Info "Uso:"
    Print-Info "  .\ftp-windows.ps1 -i   => Instalar y configurar servidor FTP (puerto $PORT)"
    Print-Info "  .\ftp-windows.ps1 -u   => Crear usuarios FTP"
    Print-Info "  .\ftp-windows.ps1 -c   => Cambiar grupo de un usuario"
    Print-Info "  .\ftp-windows.ps1 -l   => Listar usuarios FTP"
    Print-Info ""
    Print-Info "Puedes combinar opciones:"
    Print-Info "  .\ftp-windows.ps1 -i -u   => Instalar y luego crear usuarios"
}
