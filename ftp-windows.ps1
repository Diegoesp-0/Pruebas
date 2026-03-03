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
# FUNCION AUXILIAR: Aplicar bloque completo de permisos IIS en una carpeta
#
# IMPORTANTE: Todas las llamadas a icacls que contengan "NETWORK SERVICE"
# deben ir via cmd /c porque PowerShell interpreta "SERVICE:" como unidad
# de disco y lanza InvalidVariableReferenceWithDrive.
# La solucion es construir la ruta en una variable de PowerShell y luego
# pasar todo el comando como string a cmd /c.
# ============================================================
function Dar-Permisos-IIS {
    param([string]$ruta)

    cmd /c "icacls `"$ruta`" /grant `"SYSTEM:(OI)(CI)F`"" | Out-Null
    cmd /c "icacls `"$ruta`" /grant `"Administrators:(OI)(CI)F`"" | Out-Null
    cmd /c "icacls `"$ruta`" /grant `"NETWORK SERVICE:(OI)(CI)RX`"" | Out-Null
    cmd /c "icacls `"$ruta`" /grant `"IIS_IUSRS:(OI)(CI)RX`"" | Out-Null
}

function Dar-Permisos-IIS-Recursivo {
    param([string]$ruta)

    cmd /c "icacls `"$ruta`" /grant `"SYSTEM:(OI)(CI)F`" /T" | Out-Null
    cmd /c "icacls `"$ruta`" /grant `"Administrators:(OI)(CI)F`" /T" | Out-Null
    cmd /c "icacls `"$ruta`" /grant `"NETWORK SERVICE:(OI)(CI)RX`" /T" | Out-Null
    cmd /c "icacls `"$ruta`" /grant `"IIS_IUSRS:(OI)(CI)RX`" /T" | Out-Null
}

function Dar-Permiso-Usuario {
    param([string]$ruta, [string]$usuario, [string]$permiso)
    # Esta funcion NO usa cmd /c porque los usuarios locales no tienen espacios
    # ni dos puntos en su nombre que confundan al parser de PowerShell
    icacls $ruta /grant "${usuario}:(OI)(CI)$permiso" 2>&1 | Out-Null
}

function Dar-Permiso-IUSR {
    param([string]$ruta)
    cmd /c "icacls `"$ruta`" /grant `"IUSR:(OI)(CI)RX`"" | Out-Null
}

function Bloquear-Anonymous {
    param([string]$ruta)
    cmd /c "icacls `"$ruta`" /inheritance:d" | Out-Null
    cmd /c "icacls `"$ruta`" /remove IUSR" | Out-Null
    cmd /c "icacls `"$ruta`" /remove IIS_IUSRS" | Out-Null
}

# ============================================================
# FUNCION AUXILIAR: Crear raiz de aislamiento del usuario
#
# IIS FTP modo 3 (IsolateUsers) busca:
#   C:\FTP\LocalUser\<usuario>\   <- raiz / que ve el usuario al conectarse
#
# Dentro creamos junctions a las carpetas reales:
#   general   -> C:\FTP\_general
#   <grupo>   -> C:\FTP\_<grupo>
#   <usuario> -> C:\FTP\_usuarios\<usuario>
# ============================================================
function Crear-RaizUsuario {
    param(
        [string]$usuario,
        [string]$grupo
    )

    $raiz        = "$FTP_ROOT\LocalUser\$usuario"
    $dirPersonal = "$FTP_ROOT\_usuarios\$usuario"
    $rutaGeneral = "$FTP_ROOT\_general"
    $rutaGrupo   = "$FTP_ROOT\_$grupo"

    # ---- Crear raiz de aislamiento ----
    if (-not (Test-Path $raiz)) {
        New-Item -Path $raiz -ItemType Directory -Force | Out-Null
    }

    # ---- Junction: general ----
    if (-not (Test-Path "$raiz\general")) {
        cmd /c "mklink /J `"$raiz\general`" `"$rutaGeneral`"" | Out-Null
    }

    # ---- Junction: carpeta de grupo ----
    if (-not (Test-Path "$raiz\$grupo")) {
        cmd /c "mklink /J `"$raiz\$grupo`" `"$rutaGrupo`"" | Out-Null
    }

    # ---- Junction: carpeta personal ----
    if (-not (Test-Path $dirPersonal)) {
        New-Item -Path $dirPersonal -ItemType Directory -Force | Out-Null
    }
    if (-not (Test-Path "$raiz\$usuario")) {
        cmd /c "mklink /J `"$raiz\$usuario`" `"$dirPersonal`"" | Out-Null
    }

    # ---- Permisos en la raiz de aislamiento ----
    Dar-Permisos-IIS   -ruta $raiz
    Dar-Permiso-Usuario -ruta $raiz -usuario $usuario -permiso "RX"

    # ---- Permisos en _general ----
    Dar-Permisos-IIS    -ruta $rutaGeneral
    Dar-Permiso-IUSR    -ruta $rutaGeneral
    Dar-Permiso-Usuario -ruta $rutaGeneral -usuario $usuario -permiso "M"

    # ---- Permisos en carpeta de grupo propio ----
    Dar-Permisos-IIS    -ruta $rutaGrupo
    Dar-Permiso-Usuario -ruta $rutaGrupo -usuario $usuario -permiso "M"

    # ---- Permisos en carpeta personal ----
    Dar-Permisos-IIS    -ruta $dirPersonal
    Dar-Permiso-Usuario -ruta $dirPersonal -usuario $usuario -permiso "F"

    Print-Completado "Raiz de aislamiento lista para '$usuario' (grupo: $grupo)"
    Print-Info "  Ve: /general, /$grupo, /$usuario"
}

# ============================================================
# FUNCION AUXILIAR: Detectar grupo actual de un usuario (por permisos ACL)
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

    # Raiz completa: permisos IIS de forma recursiva
    Dar-Permisos-IIS-Recursivo -ruta $FTP_ROOT
    Print-Completado "Raiz $FTP_ROOT: permisos IIS base aplicados."

    # ---------- 6. Permisos por carpeta ----------

    # _reprobados: bloquear anonymous, dejar IIS y Administrators
    $rutaReprobados = "$FTP_ROOT\_reprobados"
    Bloquear-Anonymous  -ruta $rutaReprobados
    Dar-Permisos-IIS    -ruta $rutaReprobados
    Print-Completado "_reprobados: anonymous sin acceso."

    # _recursadores: igual
    $rutaRecursadores = "$FTP_ROOT\_recursadores"
    Bloquear-Anonymous  -ruta $rutaRecursadores
    Dar-Permisos-IIS    -ruta $rutaRecursadores
    Print-Completado "_recursadores: anonymous sin acceso."

    # _usuarios: igual
    $rutaUsuarios = "$FTP_ROOT\_usuarios"
    Bloquear-Anonymous  -ruta $rutaUsuarios
    Dar-Permisos-IIS    -ruta $rutaUsuarios
    Print-Completado "_usuarios: anonymous sin acceso."

    # _general: anonymous puede leer
    $rutaGeneral = "$FTP_ROOT\_general"
    Dar-Permisos-IIS -ruta $rutaGeneral
    Dar-Permiso-IUSR -ruta $rutaGeneral
    Print-Completado "_general: anonymous con lectura (RX)."

    # ---------- 7. Raiz de aislamiento para anonymous ----------
    Print-Info "Creando raiz de aislamiento para anonymous..."

    $publicRoot = "$FTP_ROOT\LocalUser\Public"
    if (-not (Test-Path $publicRoot)) {
        New-Item -Path $publicRoot -ItemType Directory -Force | Out-Null
    }

    if (-not (Test-Path "$publicRoot\general")) {
        cmd /c "mklink /J `"$publicRoot\general`" `"$rutaGeneral`"" | Out-Null
    }

    Dar-Permisos-IIS -ruta $publicRoot
    Dar-Permiso-IUSR -ruta $publicRoot
    Print-Completado "Raiz anonima lista: anonymous ve solo /general en lectura."

    # ---------- 8. Detener sitio Default Web Site ----------
    $defaultSite = Get-WebSite -Name "Default Web Site" -ErrorAction SilentlyContinue
    if ($defaultSite) {
        Stop-WebSite -Name "Default Web Site" -ErrorAction SilentlyContinue
        Set-ItemProperty "IIS:\Sites\Default Web Site" -Name serverAutoStart -Value $false
        Print-Info "Sitio 'Default Web Site' detenido."
    }

    # ---------- 9. Crear o actualizar sitio FTP ----------
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

    # ---------- 10. Modo de aislamiento ----------
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.userIsolation.mode `
        -Value 3
    Print-Completado "Modo de aislamiento: IsolateUsers (modo 3)."

    # ---------- 11. Autenticacion ----------
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.authentication.anonymousAuthentication.enabled `
        -Value $true

    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.authentication.basicAuthentication.enabled `
        -Value $true

    Print-Completado "Autenticacion anonima y basica habilitadas."

    # ---------- 12. Reglas de autorizacion FTP ----------
    Print-Info "Configurando reglas de autorizacion FTP..."

    Clear-WebConfiguration `
        -PSPath "IIS:\" `
        -Filter "system.ftpServer/security/authorization" `
        -Location $SITE_NAME `
        -ErrorAction SilentlyContinue

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

    # ---------- 13. SSL ----------
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.ssl.controlChannelPolicy `
        -Value 0
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.ssl.dataChannelPolicy `
        -Value 0
    Print-Completado "SSL configurado como opcional (sin forzar)."

    # ---------- 14. Arrancar servicio ----------
    Print-Info "Arrancando servicio FTPSVC..."
    Set-Service -Name FTPSVC -StartupType Automatic
    Restart-Service FTPSVC -Force
    Start-Sleep -Seconds 3
    Start-WebSite -Name $SITE_NAME -ErrorAction SilentlyContinue

    # ---------- 15. Verificacion ----------
    $estado = (Get-WebSite -Name $SITE_NAME).state
    if ($estado -eq "Started") {
        Print-Completado "Sitio FTP arrancado correctamente."
    } else {
        Print-Error "El sitio FTP no arranco. Estado: $estado"
        Print-Info "Revisa: Get-EventLog -LogName Application -Source *ftp* -Newest 10"
    }

    $ip = (Get-NetIPAddress -AddressFamily IPv4 |
           Where-Object { $_.IPAddress -ne "127.0.0.1" } |
           Select-Object -First 1).IPAddress

    Print-Titulo "SERVIDOR FTP LISTO"
    Print-Info "  IP del servidor  : $ip"
    Print-Info "  Puerto FTP       : $PORT"
    Print-Info "  Acceso anonimo   : ftp://$ip  (usuario: anonymous, pass: cualquier cosa)"
    Print-Info "  Raiz FTP en disco: $FTP_ROOT"
    Print-Info ""
    Print-Info "Lo que ve cada usuario al conectarse:"
    Print-Info "  anonymous       => /general (solo lectura)"
    Print-Info "  autenticado     => /general (escritura) + /<grupo> (escritura) + /<usuario> (total)"
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

        $usuario = ""
        do {
            $usuario = Read-Host "Nombre de usuario"
            if (-not (Validar-Usuario $usuario)) { $usuario = "" }
        } while ($usuario -eq "")

        if (Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue) {
            Print-Error "El usuario '$usuario' ya existe. Saltando..."
            continue
        }

        $password = ""
        do {
            $password = Read-Host "Contrasena"
            if ($password.Length -lt 4) {
                Print-Error "La contrasena debe tener al menos 4 caracteres."
                $password = ""
            }
        } while ($password -eq "")

        $grupo = ""
        do {
            $grupo = Read-Host "Grupo (reprobados/recursadores)"
            if (-not (Validar-Grupo $grupo)) { $grupo = "" }
        } while ($grupo -eq "")

        Print-Info "Creando usuario Windows: $usuario..."
        $passSecure = ConvertTo-SecureString $password -AsPlainText -Force

        try {
            New-LocalUser `
                -Name $usuario `
                -Password $passSecure `
                -PasswordNeverExpires `
                -UserMayNotChangePassword `
                -Description "Usuario FTP - Grupo: $grupo" | Out-Null
            Print-Completado "Usuario Windows '$usuario' creado."
        } catch {
            Print-Error "Error al crear usuario '$usuario': $_"
            continue
        }

        Crear-RaizUsuario -usuario $usuario -grupo $grupo

        Print-Completado "Usuario '$usuario' listo."
        Print-Info "  Raiz FTP         : $FTP_ROOT\LocalUser\$usuario\"
        Print-Info "  Carpetas visibles: /general, /$grupo, /$usuario"
    }

    Print-Info "Reiniciando servicio FTPSVC..."
    Restart-Service FTPSVC -Force
    Start-Sleep -Seconds 3
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

    $usuario = ""
    do {
        $usuario = Read-Host "Nombre del usuario a cambiar de grupo"
        if (-not (Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue)) {
            Print-Error "El usuario '$usuario' no existe en el sistema."
            $usuario = ""
        }
    } while ($usuario -eq "")

    $grupoActual = Obtener-GrupoActual -usuario $usuario
    if ($grupoActual -ne "") {
        Print-Info "Grupo actual de '$usuario': $grupoActual"
    } else {
        Print-Info "No se pudo detectar el grupo actual de '$usuario'."
    }

    $nuevoGrupo = ""
    do {
        $nuevoGrupo = Read-Host "Nuevo grupo (reprobados/recursadores)"
        if (-not (Validar-Grupo $nuevoGrupo)) { $nuevoGrupo = "" }
    } while ($nuevoGrupo -eq "")

    if ($grupoActual -eq $nuevoGrupo) {
        Print-Info "El usuario '$usuario' ya pertenece al grupo '$nuevoGrupo'. No hay cambios."
        exit 0
    }

    # Quitar permisos del grupo anterior
    if ($grupoActual -ne "") {
        Print-Info "Quitando acceso a '_$grupoActual'..."
        $rutaGrupoAnterior = "$FTP_ROOT\_$grupoActual"
        icacls $rutaGrupoAnterior /remove $usuario 2>&1 | Out-Null
        Print-Completado "Permisos removidos de '_$grupoActual'."
    }

    # Dar permisos en el nuevo grupo
    Print-Info "Asignando acceso a '_$nuevoGrupo'..."
    $rutaNuevoGrupo = "$FTP_ROOT\_$nuevoGrupo"
    Dar-Permisos-IIS    -ruta $rutaNuevoGrupo
    Dar-Permiso-Usuario -ruta $rutaNuevoGrupo -usuario $usuario -permiso "M"
    Print-Completado "Permisos asignados en '_$nuevoGrupo'."

    # Actualizar junctions
    $raiz = "$FTP_ROOT\LocalUser\$usuario"

    if ($grupoActual -ne "") {
        $junctionAntigua = "$raiz\$grupoActual"
        if (Test-Path $junctionAntigua) {
            cmd /c "rmdir `"$junctionAntigua`"" | Out-Null
            Print-Completado "Junction '$grupoActual' eliminado."
        }
    }

    $junctionNueva = "$raiz\$nuevoGrupo"
    if (-not (Test-Path $junctionNueva)) {
        cmd /c "mklink /J `"$junctionNueva`" `"$rutaNuevoGrupo`"" | Out-Null
        Print-Completado "Junction '$nuevoGrupo' creado."
    }

    Print-Info "Reiniciando servicio FTPSVC..."
    Restart-Service FTPSVC -Force
    Start-Sleep -Seconds 3
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
