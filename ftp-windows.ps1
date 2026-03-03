# ============================================================
# ftp-windows.ps1 - Instalacion y gestion de servidor FTP
# Windows Server Core - IIS + FTP Service
# Puerto: 21
# Uso:
#   .\ftp-windows.ps1 -i   => Instalar y configurar FTP
#   .\ftp-windows.ps1 -u   => Crear usuarios
#   .\ftp-windows.ps1 -c   => Cambiar grupo de usuario
#   .\ftp-windows.ps1 -l   => Listar usuarios FTP
#
# ESTRUCTURA EN EL CLIENTE FTP (lo que ve cada usuario al conectarse):
#   /general          (todos pueden leer; autenticados pueden escribir)
#   /reprobados       (solo su grupo)   <-- solo aparece si el usuario es de ese grupo
#   /recursadores     (solo su grupo)   <-- solo aparece si el usuario es de ese grupo
#   /<nombre_usuario> (carpeta personal)
#
# AISLAMIENTO IIS FTP:
#   IIS FTP con modo IsolateUsers usa esta estructura en disco:
#   C:\FTP\LocalUser\<usuario>\     <-- raiz que ve el usuario (chroot)
#   Dentro de esa raiz se crean junction points (enlaces) a:
#     general, <grupo>, <usuario>
# ============================================================

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
$SITE_NAME        = "FTP-Servidor"
$FTP_ROOT         = "C:\FTP"
$PORT             = 21
$GRUPO_REPROBADOS = "reprobados"
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
# FUNCION AUXILIAR: Crear la raiz de aislamiento de un usuario
# Estructura que IIS FTP espera cuando usa IsolateUsers:
#   C:\FTP\LocalUser\<usuario>\  (esta es la raiz / que ve el usuario)
#   Dentro se crean directorios reales o junction points:
#     general     -> C:\FTP\_general
#     <grupo>     -> C:\FTP\_reprobados  o  C:\FTP\_recursadores
#     <usuario>   -> C:\FTP\_usuarios\<usuario>
# ============================================================
function Crear-RaizUsuario {
    param(
        [string]$usuario,
        [string]$grupo
    )

    $raiz = "$FTP_ROOT\LocalUser\$usuario"

    # Crear raiz de aislamiento si no existe
    if (-not (Test-Path $raiz)) {
        New-Item -Path $raiz -ItemType Directory -Force | Out-Null
    }

    # ---- general ----
    $linkGeneral = "$raiz\general"
    if (-not (Test-Path $linkGeneral)) {
        # Usar mklink /J para junction (no requiere elevacion especial en NTFS local)
        cmd /c "mklink /J `"$linkGeneral`" `"$FTP_ROOT\_general`"" | Out-Null
    }

    # ---- carpeta de grupo ----
    $linkGrupo = "$raiz\$grupo"
    if (-not (Test-Path $linkGrupo)) {
        cmd /c "mklink /J `"$linkGrupo`" `"$FTP_ROOT\_$grupo`"" | Out-Null
    }

    # ---- carpeta personal ----
    $dirPersonal = "$FTP_ROOT\_usuarios\$usuario"
    if (-not (Test-Path $dirPersonal)) {
        New-Item -Path $dirPersonal -ItemType Directory -Force | Out-Null
    }
    $linkPersonal = "$raiz\$usuario"
    if (-not (Test-Path $linkPersonal)) {
        cmd /c "mklink /J `"$linkPersonal`" `"$dirPersonal`"" | Out-Null
    }

    # ---- Permisos NTFS en la raiz de aislamiento ----
    # El usuario necesita al menos Read+Execute en su raiz para que IIS FTP no rechace el login
    icacls $raiz /grant "${usuario}:(OI)(CI)RX" /T 2>&1 | Out-Null

    # Permisos de escritura en las carpetas reales (no en los junctions)
    icacls "$FTP_ROOT\_general"          /grant "${usuario}:(OI)(CI)M" 2>&1 | Out-Null
    icacls "$FTP_ROOT\_$grupo"           /grant "${usuario}:(OI)(CI)M" 2>&1 | Out-Null
    icacls "$dirPersonal"                /grant "${usuario}:(OI)(CI)F" 2>&1 | Out-Null

    Print-Completado "Raiz de aislamiento lista para '$usuario' (grupo: $grupo)"
}

# ============================================================
# FUNCION AUXILIAR: Detectar grupo actual de un usuario (por permisos ACL)
# ============================================================
function Obtener-GrupoActual {
    param([string]$usuario)

    $aclR = (icacls "$FTP_ROOT\_reprobados"   2>&1) -join " "
    $aclE = (icacls "$FTP_ROOT\_recursadores" 2>&1) -join " "

    if ($aclR -match [regex]::Escape($usuario)) {
        return "reprobados"
    } elseif ($aclE -match [regex]::Escape($usuario)) {
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

    # Deshabilitar firewall para garantizar conectividad en entorno de laboratorio
    Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
    Print-Completado "Firewall deshabilitado."

    # Regla puerto 21 (por si se reactiva el firewall)
    if (-not (Get-NetFirewallRule -Name "FTP-Control-21" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name "FTP-Control-21" `
            -DisplayName "FTP Control Port 21" `
            -Protocol TCP -LocalPort 21 `
            -Direction Inbound -Action Allow | Out-Null
        Print-Completado "Regla puerto 21 creada."
    }

    # Regla modo pasivo
    if (-not (Get-NetFirewallRule -Name "FTP-Pasivo" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name "FTP-Pasivo" `
            -DisplayName "FTP Modo Pasivo 49152-65535" `
            -Protocol TCP -LocalPort 49152-65535 `
            -Direction Inbound -Action Allow | Out-Null
        Print-Completado "Regla modo pasivo creada."
    }

    # ---------- 4. Crear estructura de directorios ----------
    # Carpetas REALES (con prefijo _ para distinguirlas de los junctions)
    Print-Info "Creando estructura de directorios en $FTP_ROOT..."

    $dirsReales = @(
        $FTP_ROOT,
        "$FTP_ROOT\_general",
        "$FTP_ROOT\_reprobados",
        "$FTP_ROOT\_recursadores",
        "$FTP_ROOT\_usuarios",
        "$FTP_ROOT\LocalUser"        # requerido por IIS FTP IsolateUsers
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

    # IUSR = cuenta anonima de IIS
    # Solo lectura en _general para anonimos
    icacls "$FTP_ROOT\_general" /grant "IUSR:(OI)(CI)RX" 2>&1 | Out-Null
    icacls "$FTP_ROOT\_general" /grant "IIS_IUSRS:(OI)(CI)RX" 2>&1 | Out-Null
    Print-Completado "Permisos anonimos en _general configurados."

    # Administradores con control total en todo el arbol
    icacls $FTP_ROOT /grant "Administrators:(OI)(CI)F" /T 2>&1 | Out-Null

    # ---------- 6. Raiz de aislamiento para usuario anonimo ----------
    # IIS FTP anonimo busca: C:\FTP\LocalUser\Public\
    $publicRoot = "$FTP_ROOT\LocalUser\Public"
    if (-not (Test-Path $publicRoot)) {
        New-Item -Path $publicRoot -ItemType Directory -Force | Out-Null
    }

    # Junction: /general apuntando a _general (solo lectura para anonimos)
    $publicGeneral = "$publicRoot\general"
    if (-not (Test-Path $publicGeneral)) {
        cmd /c "mklink /J `"$publicGeneral`" `"$FTP_ROOT\_general`"" | Out-Null
    }

    # Permisos en la raiz Public para IUSR
    icacls $publicRoot /grant "IUSR:(OI)(CI)RX" /T 2>&1 | Out-Null
    icacls $publicRoot /grant "IIS_IUSRS:(OI)(CI)RX" /T 2>&1 | Out-Null
    Print-Completado "Raiz anonima (LocalUser\Public) configurada."

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

    # ---------- 9. Configurar aislamiento de usuarios ----------
    # Modo 3 = IsolateUsers (cada usuario ve solo su carpeta en LocalUser\<usuario>)
    # Esto es lo que evita el error 530 por permisos cruzados
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.userIsolation.mode `
        -Value 3
    Print-Completado "Modo de aislamiento: IsolateUsers (modo 3)."

    # ---------- 10. Autenticacion ----------
    # Habilitar autenticacion anonima
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.authentication.anonymousAuthentication.enabled `
        -Value $true

    # Habilitar autenticacion basica (usuario/contrasena Windows local)
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.authentication.basicAuthentication.enabled `
        -Value $true

    Print-Completado "Autenticacion anonima y basica habilitadas."

    # ---------- 11. Reglas de autorizacion FTP ----------
    Print-Info "Configurando reglas de autorizacion FTP..."

    # Limpiar reglas anteriores del sitio
    Clear-WebConfiguration `
        -PSPath "IIS:\" `
        -Filter "system.ftpServer/security/authorization" `
        -Location $SITE_NAME `
        -ErrorAction SilentlyContinue

    # Anonimos: solo lectura
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

    # Usuarios autenticados: lectura y escritura
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

    # ---------- 12. Configurar SSL (sin SSL para laboratorio) ----------
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.ssl.controlChannelPolicy `
        -Value 0   # 0 = SslAllow (no forzar SSL)

    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.ssl.dataChannelPolicy `
        -Value 0
    Print-Completado "SSL configurado como opcional (sin forzar)."

    # ---------- 13. Habilitar y arrancar servicio FTP ----------
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

    # Obtener IP del servidor
    $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne "127.0.0.1" } | Select-Object -First 1).IPAddress

    Print-Titulo "SERVIDOR FTP LISTO"
    Print-Info "  IP del servidor  : $ip"
    Print-Info "  Puerto FTP       : $PORT"
    Print-Info "  Acceso anonimo   : ftp://$ip  (usuario: anonymous, pass: cualquier cosa)"
    Print-Info "  Raiz FTP en disco: $FTP_ROOT"
    Print-Info ""
    Print-Info "Lo que ve cada usuario al conectarse:"
    Print-Info "  /general          => lectura (anonimos) / escritura (autenticados)"
    Print-Info "  /<grupo>          => escritura (solo miembros del grupo)"
    Print-Info "  /<nombre_usuario> => escritura (solo ese usuario)"
    Print-Info ""
    Print-Info "Ahora puede crear usuarios con: .\ftp-windows.ps1 -u"
}

# ============================================================
# CREAR USUARIOS
# ============================================================
if ($u) {

    Cargar-WebAdmin

    Print-Titulo "CREACION DE USUARIOS FTP"

    # Verificar que la estructura base exista
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

        # --- Crear estructura de aislamiento (junction points) ---
        Crear-RaizUsuario -usuario $usuario -grupo $grupo

        Print-Completado "Usuario '$usuario' listo."
        Print-Info "  Raiz visible por FTP    : $FTP_ROOT\LocalUser\$usuario\"
        Print-Info "  Carpetas accesibles     : general, $grupo, $usuario"
    }

    # Reiniciar servicio para aplicar cambios
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

    # --- Quitar acceso al grupo anterior ---
    if ($grupoActual -ne "") {
        Print-Info "Quitando acceso a '$grupoActual'..."
        icacls "$FTP_ROOT\_$grupoActual" /remove $usuario 2>&1 | Out-Null
        Print-Completado "Acceso removido de '$grupoActual'."
    }

    # --- Dar acceso al nuevo grupo ---
    Print-Info "Asignando acceso a '$nuevoGrupo'..."
    icacls "$FTP_ROOT\_$nuevoGrupo" /grant "${usuario}:(OI)(CI)M" 2>&1 | Out-Null
    Print-Completado "Permisos asignados en '_$nuevoGrupo'."

    # --- Actualizar la raiz de aislamiento (cambiar junction de grupo) ---
    $raiz = "$FTP_ROOT\LocalUser\$usuario"

    # Eliminar junction del grupo anterior
    if ($grupoActual -ne "") {
        $junctionAntigua = "$raiz\$grupoActual"
        if (Test-Path $junctionAntigua) {
            # Eliminar junction (rmdir sin /S para no borrar el contenido real)
            cmd /c "rmdir `"$junctionAntigua`"" 2>&1 | Out-Null
            Print-Completado "Junction '$grupoActual' eliminado de la raiz del usuario."
        }
    }

    # Crear junction del nuevo grupo
    $junctionNueva = "$raiz\$nuevoGrupo"
    if (-not (Test-Path $junctionNueva)) {
        cmd /c "mklink /J `"$junctionNueva`" `"$FTP_ROOT\_$nuevoGrupo`"" | Out-Null
        Print-Completado "Junction '$nuevoGrupo' creado en la raiz del usuario."
    }

    # Reiniciar servicio
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

    if (-not (Test-Path "$FTP_ROOT\LocalUser")) {
        Print-Error "El servidor FTP no esta instalado."
        exit 1
    }

    $dirs = Get-ChildItem "$FTP_ROOT\LocalUser" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "Public" }

    if (-not $dirs) {
        Print-Info "No hay usuarios FTP creados aun."
    } else {
        Write-Host ""
        Write-Host ("{0,-20} {1,-15} {2}" -f "USUARIO", "GRUPO", "RAIZ FTP") -ForegroundColor Cyan
        Write-Host ("-" * 60) -ForegroundColor Cyan

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
