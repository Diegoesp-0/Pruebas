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
# FUNCION AUXILIAR: Asignar permisos NTFS al usuario en todas las carpetas
#
# Modo actual: SIN aislamiento. Todos los usuarios autenticados ven todo.
# Anonymous solo puede ver _general en lectura.
#
# TODO: AISLAMIENTO - Cuando quieras activar el aislamiento por usuario:
#   1. Cambiar ftpServer.userIsolation.mode a 3 (en seccion -i)
#   2. Crear C:\FTP\LocalUser\<usuario>\ para cada usuario
#   3. Crear junctions dentro de esa raiz apuntando a las carpetas reales:
#        mklink /J "C:\FTP\LocalUser\<usuario>\general"      "C:\FTP\_general"
#        mklink /J "C:\FTP\LocalUser\<usuario>\<grupo>"      "C:\FTP\_<grupo>"
#        mklink /J "C:\FTP\LocalUser\<usuario>\<usuario>"    "C:\FTP\_usuarios\<usuario>"
#   4. Crear C:\FTP\LocalUser\Public\ para anonymous con junction a _general
#   5. Asignar RX al usuario en su raiz de aislamiento
# ============================================================
function Configurar-PermisosUsuario {
    param(
        [string]$usuario,
        [string]$grupo
    )

    # Carpeta personal del usuario
    $dirPersonal = "$FTP_ROOT\_usuarios\$usuario"
    if (-not (Test-Path $dirPersonal)) {
        New-Item -Path $dirPersonal -ItemType Directory -Force | Out-Null
    }

    # ---- general: todos los autenticados pueden leer y escribir ----
    icacls "$FTP_ROOT\_general" /grant "${usuario}:(OI)(CI)M" 2>&1 | Out-Null

    # ---- carpeta de grupo propio: escritura ----
    icacls "$FTP_ROOT\_$grupo" /grant "${usuario}:(OI)(CI)M" 2>&1 | Out-Null

    # ---- otras carpetas de grupo: solo lectura (todos ven todo) ----
    # TODO: AISLAMIENTO - Quitar estos dos bloques cuando actives el aislamiento,
    #       ya que con junctions el usuario no vera las carpetas de otros grupos.
    if ($grupo -ne "reprobados") {
        icacls "$FTP_ROOT\_reprobados" /grant "${usuario}:(OI)(CI)RX" 2>&1 | Out-Null
    }
    if ($grupo -ne "recursadores") {
        icacls "$FTP_ROOT\_recursadores" /grant "${usuario}:(OI)(CI)RX" 2>&1 | Out-Null
    }

    # ---- carpeta _usuarios: lectura general, pero su carpeta personal tiene control total ----
    # TODO: AISLAMIENTO - Con junctions esto no es necesario porque el usuario
    #       no vera _usuarios\ directamente, solo su propia carpeta personal.
    icacls "$FTP_ROOT\_usuarios" /grant "${usuario}:(OI)(CI)RX" 2>&1 | Out-Null
    icacls "$dirPersonal"        /grant "${usuario}:(OI)(CI)F"  2>&1 | Out-Null

    Print-Completado "Permisos configurados para '$usuario' (grupo: $grupo)"
}

# ============================================================
# FUNCION AUXILIAR: Detectar grupo actual de un usuario (por permisos ACL)
# ============================================================
function Obtener-GrupoActual {
    param([string]$usuario)

    $aclR = (icacls "$FTP_ROOT\_reprobados"   2>&1) -join " "
    $aclE = (icacls "$FTP_ROOT\_recursadores" 2>&1) -join " "

    # Detectamos por cual carpeta tiene permiso de Modificar (M), no solo lectura
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
        "$FTP_ROOT\_usuarios"
        # TODO: AISLAMIENTO - Agregar "$FTP_ROOT\LocalUser" cuando actives junctions
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
    # Estrategia:
    #   - C:\FTP raiz       : Administrators con control total
    #   - _general          : IUSR + IIS_IUSRS con RX  => anonymous puede leer
    #   - _reprobados       : herencia deshabilitada, IUSR removido => anonymous NO entra
    #   - _recursadores     : igual que _reprobados
    #   - _usuarios         : igual, anonymous NO entra
    #   Los usuarios autenticados reciben sus permisos al momento de crearse (-u)
    Print-Info "Configurando permisos NTFS base..."

    # Administrators con control total en todo el arbol (punto de partida)
    icacls $FTP_ROOT /grant "Administrators:(OI)(CI)F" /T 2>&1 | Out-Null

    # -- _general: anonymous puede leer --
    icacls "$FTP_ROOT\_general" /grant "IUSR:(OI)(CI)RX"      2>&1 | Out-Null
    icacls "$FTP_ROOT\_general" /grant "IIS_IUSRS:(OI)(CI)RX" 2>&1 | Out-Null
    Print-Completado "_general: anonymous con lectura (RX)."

    # -- _reprobados: deshabilitar herencia y bloquear anonymous --
    # /inheritance:d  => desconectar herencia del padre, conservar ACEs actuales como explicitos
    # /remove         => quitar las entradas de IUSR e IIS_IUSRS
    icacls "$FTP_ROOT\_reprobados" /inheritance:d                    2>&1 | Out-Null
    icacls "$FTP_ROOT\_reprobados" /remove "IUSR"                    2>&1 | Out-Null
    icacls "$FTP_ROOT\_reprobados" /remove "IIS_IUSRS"               2>&1 | Out-Null
    icacls "$FTP_ROOT\_reprobados" /grant "Administrators:(OI)(CI)F" 2>&1 | Out-Null
    Print-Completado "_reprobados: anonymous sin acceso."

    # -- _recursadores: igual --
    icacls "$FTP_ROOT\_recursadores" /inheritance:d                    2>&1 | Out-Null
    icacls "$FTP_ROOT\_recursadores" /remove "IUSR"                    2>&1 | Out-Null
    icacls "$FTP_ROOT\_recursadores" /remove "IIS_IUSRS"               2>&1 | Out-Null
    icacls "$FTP_ROOT\_recursadores" /grant "Administrators:(OI)(CI)F" 2>&1 | Out-Null
    Print-Completado "_recursadores: anonymous sin acceso."

    # -- _usuarios: igual --
    icacls "$FTP_ROOT\_usuarios" /inheritance:d                    2>&1 | Out-Null
    icacls "$FTP_ROOT\_usuarios" /remove "IUSR"                    2>&1 | Out-Null
    icacls "$FTP_ROOT\_usuarios" /remove "IIS_IUSRS"               2>&1 | Out-Null
    icacls "$FTP_ROOT\_usuarios" /grant "Administrators:(OI)(CI)F" 2>&1 | Out-Null
    Print-Completado "_usuarios: anonymous sin acceso."

    Print-Completado "Permisos NTFS base configurados."

    # ---------- 6. Detener sitio Default Web Site ----------
    $defaultSite = Get-WebSite -Name "Default Web Site" -ErrorAction SilentlyContinue
    if ($defaultSite) {
        Stop-WebSite -Name "Default Web Site" -ErrorAction SilentlyContinue
        Set-ItemProperty "IIS:\Sites\Default Web Site" -Name serverAutoStart -Value $false
        Print-Info "Sitio 'Default Web Site' detenido."
    }

    # ---------- 7. Crear o actualizar sitio FTP ----------
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

    # ---------- 8. Modo de aislamiento ----------
    # Modo 0 = sin aislamiento, todos los usuarios ven C:\FTP completo
    # TODO: AISLAMIENTO - Cambiar a modo 3 (IsolateUsers) cuando actives junctions
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.userIsolation.mode `
        -Value 0
    Print-Completado "Modo de aislamiento: Sin aislamiento (modo 0)."

    # ---------- 9. Autenticacion ----------
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.authentication.anonymousAuthentication.enabled `
        -Value $true

    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.authentication.basicAuthentication.enabled `
        -Value $true

    Print-Completado "Autenticacion anonima y basica habilitadas."

    # ---------- 10. Reglas de autorizacion FTP ----------
    Print-Info "Configurando reglas de autorizacion FTP..."

    Clear-WebConfiguration `
        -PSPath "IIS:\" `
        -Filter "system.ftpServer/security/authorization" `
        -Location $SITE_NAME `
        -ErrorAction SilentlyContinue

    # Anonymous: solo lectura a nivel FTP (NTFS restringe a que carpetas puede entrar)
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

    # ---------- 11. SSL ----------
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.ssl.controlChannelPolicy `
        -Value 0
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.ssl.dataChannelPolicy `
        -Value 0
    Print-Completado "SSL configurado como opcional (sin forzar)."

    # ---------- 12. Arrancar servicio ----------
    Print-Info "Arrancando servicio FTPSVC..."
    Set-Service -Name FTPSVC -StartupType Automatic
    Restart-Service FTPSVC -Force
    Start-Sleep -Seconds 3
    Start-WebSite -Name $SITE_NAME -ErrorAction SilentlyContinue

    # ---------- 13. Verificacion ----------
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
    Print-Info "  _general      => anonymous: LECTURA  / autenticados: escritura"
    Print-Info "  _reprobados   => anonymous: SIN ACCESO / autenticados: segun grupo"
    Print-Info "  _recursadores => anonymous: SIN ACCESO / autenticados: segun grupo"
    Print-Info "  _usuarios\<x> => anonymous: SIN ACCESO / autenticados: lectura / dueno: total"
    Print-Info ""
    Print-Info "Ahora puede crear usuarios con: .\ftp-windows.ps1 -u"
}

# ============================================================
# CREAR USUARIOS
# ============================================================
if ($u) {

    Cargar-WebAdmin

    Print-Titulo "CREACION DE USUARIOS FTP"

    if (-not (Test-Path "$FTP_ROOT\_general")) {
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

        # --- Asignar permisos NTFS ---
        Configurar-PermisosUsuario -usuario $usuario -grupo $grupo

        Print-Completado "Usuario '$usuario' listo."
        Print-Info "  Carpeta personal: $FTP_ROOT\_usuarios\$usuario"
        Print-Info "  Grupo asignado  : $grupo"
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

    # --- Bajar permiso de escritura en grupo anterior (dejar solo lectura) ---
    if ($grupoActual -ne "") {
        Print-Info "Quitando escritura en '$grupoActual'..."
        icacls "$FTP_ROOT\_$grupoActual" /remove $usuario 2>&1 | Out-Null
        icacls "$FTP_ROOT\_$grupoActual" /grant "${usuario}:(OI)(CI)RX" 2>&1 | Out-Null
        Print-Completado "Acceso reducido a lectura en '$grupoActual'."
    }

    # --- Dar escritura en nuevo grupo ---
    Print-Info "Asignando escritura en '$nuevoGrupo'..."
    icacls "$FTP_ROOT\_$nuevoGrupo" /remove $usuario 2>&1 | Out-Null
    icacls "$FTP_ROOT\_$nuevoGrupo" /grant "${usuario}:(OI)(CI)M" 2>&1 | Out-Null
    Print-Completado "Permisos de escritura asignados en '_$nuevoGrupo'."

    # TODO: AISLAMIENTO - Cuando actives junctions tambien hay que:
    #   1. Eliminar junction del grupo anterior:
    #      cmd /c "rmdir `"$FTP_ROOT\LocalUser\$usuario\$grupoActual`""
    #   2. Crear junction del nuevo grupo:
    #      cmd /c "mklink /J `"$FTP_ROOT\LocalUser\$usuario\$nuevoGrupo`" `"$FTP_ROOT\_$nuevoGrupo`""

    Print-Info "Reiniciando servicio FTPSVC..."
    Restart-Service FTPSVC -Force
    Start-Sleep -Seconds 2
    Start-WebSite -Name $SITE_NAME -ErrorAction SilentlyContinue

    Print-Completado "Grupo actualizado correctamente."
    Print-Info "Usuario '$usuario' ahora pertenece a: $nuevoGrupo"
}

# ============================================================
# LISTAR USUARIOS FTP
# ============================================================
if ($l) {

    Print-Titulo "USUARIOS FTP CONFIGURADOS"

    if (-not (Test-Path "$FTP_ROOT\_usuarios")) {
        Print-Error "El servidor FTP no esta instalado."
        exit 1
    }

    $dirs = Get-ChildItem "$FTP_ROOT\_usuarios" -Directory -ErrorAction SilentlyContinue

    if (-not $dirs) {
        Print-Info "No hay usuarios FTP creados aun."
    } else {
        Write-Host ""
        Write-Host ("{0,-20} {1,-15} {2}" -f "USUARIO", "GRUPO", "CARPETA PERSONAL") -ForegroundColor Cyan
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
