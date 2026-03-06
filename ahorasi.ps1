# ============================================================================
# ftp_server.ps1 - Servidor FTP Windows Server 2025
# IIS + FTP Service - Administracion de Sistemas
#
# Uso:
#   .\ftp_server.ps1 -install    Instalar y configurar servidor FTP
#   .\ftp_server.ps1 -users      Gestionar usuarios FTP
#   .\ftp_server.ps1 -status     Ver estado del servidor
#   .\ftp_server.ps1 -restart    Reiniciar servicio FTP
#   .\ftp_server.ps1 -list       Listar usuarios
#   .\ftp_server.ps1 -verify     Verificar instalacion
#   .\ftp_server.ps1 -help       Mostrar ayuda
#
# Estructura FTP por usuario (modo sin aislamiento, control por NTFS):
#   C:\ftp\
#     general\          <- todos leen y escriben, nadie borra la carpeta
#     reprobados\       <- solo miembros del grupo reprobados
#     recursadores\     <- solo miembros del grupo recursadores
#     <usuario>\        <- carpeta personal de cada usuario
# ============================================================================

param(
    [switch]$verify,
    [switch]$install,
    [switch]$users,
    [switch]$restart,
    [switch]$status,
    [switch]$list,
    [switch]$help
)

# ============================================================================
# VERIFICAR ADMINISTRADOR
# ============================================================================
$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[ERROR] Este script debe ejecutarse como Administrador" -ForegroundColor Red
    exit 1
}

# ============================================================================
# FUNCIONES DE SALIDA
# ============================================================================
function Print-Info   { param($msg) Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Print-Ok     { param($msg) Write-Host "[OK]    $msg" -ForegroundColor Green }
function Print-Error  { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Print-Warn   { param($msg) Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Print-Titulo { param($msg) Write-Host "`n=== $msg ===`n" -ForegroundColor Magenta }

# ============================================================================
# VARIABLES GLOBALES
# ============================================================================
$FTP_ROOT           = "C:\ftp"
$GRUPO_REPROBADOS   = "reprobados"
$GRUPO_RECURSADORES = "recursadores"
$FTP_SITE_NAME      = "ServidorFTP"
$FTP_PORT           = 21

# ============================================================================
# IDENTIDADES POR SID (independiente del idioma del SO)
#   S-1-5-32-544 = Administrators / Administradores
#   S-1-5-18     = SYSTEM / SISTEMA
#   S-1-5-11     = Authenticated Users / Usuarios autenticados
#   S-1-5-17     = IUSR (cuenta anonima IIS)
#   S-1-1-0      = Everyone / Todos
# ============================================================================
function Resolve-SID {
    param([string]$Sid)
    $sidObj = New-Object System.Security.Principal.SecurityIdentifier($Sid)
    return $sidObj.Translate([System.Security.Principal.NTAccount])
}

$ID_ADMINS   = Resolve-SID "S-1-5-32-544"
$ID_SYSTEM   = Resolve-SID "S-1-5-18"
$ID_AUTH     = Resolve-SID "S-1-5-11"
$ID_IUSR     = Resolve-SID "S-1-5-17"
$ID_EVERYONE = Resolve-SID "S-1-1-0"

# ============================================================================
# FUNCION: Crear regla ACL
# ============================================================================
function New-ACLRule {
    param(
        [object]$Identity,
        [string]$Rights = "FullControl",
        [string]$Type   = "Allow"
    )
    return New-Object System.Security.AccessControl.FileSystemAccessRule(
        $Identity, $Rights,
        "ContainerInherit,ObjectInherit", "None", $Type
    )
}

# ============================================================================
# FUNCION: Aplicar ACL limpia (rompe herencia y aplica solo las reglas dadas)
# ============================================================================
function Set-FolderACL {
    param(
        [string]$Path,
        [System.Security.AccessControl.FileSystemAccessRule[]]$Rules
    )
    $acl = Get-Acl $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in $Rules) { $acl.AddAccessRule($rule) }
    Set-Acl -Path $Path -AclObject $acl
}

# ============================================================================
# FUNCION: Agregar regla DENY de borrado (proteger carpeta base)
# Impide que cualquier usuario borre la carpeta en si misma.
# Los archivos dentro se pueden borrar normalmente.
# ============================================================================
function Protect-FolderFromDeletion {
    param([string]$Path)
    $acl = Get-Acl $Path
    # Deny "Delete" solo sobre el objeto contenedor, sin propagar a hijos
    $denyRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $ID_EVERYONE,
        "Delete",
        "None", "None",
        "Deny"
    )
    $acl.AddAccessRule($denyRule)
    Set-Acl -Path $Path -AclObject $acl
    Print-Ok "Protegida contra borrado: $Path"
}

# ============================================================================
# FUNCION: Otorgar "Log on locally" (SeInteractiveLogonRight) a un usuario.
# IIS FTP Basic Auth lo requiere para autenticar.
# ============================================================================
function Grant-FTPLogonRight {
    param([string]$Username)

    $exportInf = "$env:TEMP\secedit_export.inf"
    $applyInf  = "$env:TEMP\secedit_apply.inf"
    $applyDb   = "$env:TEMP\secedit_apply.sdb"

    & secedit /export /cfg $exportInf /quiet 2>$null

    $cfg   = Get-Content $exportInf -ErrorAction SilentlyContinue
    $linea = $cfg | Where-Object { $_ -match "^SeInteractiveLogonRight" }

    if ($linea -and $linea -match [regex]::Escape($Username)) {
        Print-Info "  '$Username' ya tiene derecho de logon local."
        Remove-Item $exportInf -ErrorAction SilentlyContinue
        return
    }

    $nuevaLinea = if ($linea) { "$linea,*$Username" } `
                  else        { "SeInteractiveLogonRight = *$Username" }

    $infContent = @"
[Unicode]
Unicode=yes
[Version]
signature="`$CHICAGO`$"
Revision=1
[Privilege Rights]
$nuevaLinea
"@
    $infContent | Out-File -FilePath $applyInf -Encoding Unicode
    & secedit /configure /db $applyDb /cfg $applyInf /quiet 2>$null
    Remove-Item $exportInf, $applyInf, $applyDb -ErrorAction SilentlyContinue
    Print-Ok "  Derecho 'Log on locally' otorgado a '$Username'."
}

# ============================================================================
# FUNCION: Verificar instalacion de IIS y FTP
# ============================================================================
function Verificar-Instalacion {
    Print-Info "Verificando instalacion de IIS y FTP..."

    $features = @("Web-Server","Web-Ftp-Server","Web-Ftp-Service","Web-Ftp-Ext")
    $allOk = $true

    foreach ($f in $features) {
        $feat = Get-WindowsFeature -Name $f -ErrorAction SilentlyContinue
        if ($feat -and $feat.Installed) {
            Print-Ok "$f instalado."
        } else {
            Print-Error "$f NO instalado."
            $allOk = $false
        }
    }
    return $allOk
}

# ============================================================================
# FUNCION: Crear grupos locales del sistema
# ============================================================================
function Crear-Grupos {
    Print-Info "Verificando grupos del sistema..."
    foreach ($grupo in @($GRUPO_REPROBADOS, $GRUPO_RECURSADORES)) {
        if (-not (Get-LocalGroup -Name $grupo -ErrorAction SilentlyContinue)) {
            New-LocalGroup -Name $grupo -Description "Grupo FTP $grupo" | Out-Null
            Print-Ok "Grupo '$grupo' creado."
        } else {
            Print-Info "Grupo '$grupo' ya existe."
        }
    }
}

# ============================================================================
# FUNCION: Crear estructura de directorios y permisos NTFS
#
# Estructura:
#   C:\ftp\                    <- raiz del sitio FTP
#     general\                 <- carpeta publica compartida
#     reprobados\              <- solo grupo reprobados
#     recursadores\            <- solo grupo recursadores
#     <usuario>\               <- carpeta personal de cada usuario
#
# PERMISOS:
#   C:\ftp\           -> Admins + SYSTEM + AUTH(ReadExecute) + IUSR(ReadExecute)
#   general\          -> Admins + SYSTEM + AUTH(Modify) + IUSR(ReadExecute)
#   reprobados\       -> Admins + SYSTEM + grupo reprobados(Modify)
#   recursadores\     -> Admins + SYSTEM + grupo recursadores(Modify)
#
# Las carpetas base tienen ademas DENY Delete para Everyone (no se pueden borrar).
# ============================================================================
function Crear-Estructura-Base {
    Print-Info "Creando estructura de directorios..."

    $dirs = @(
        $FTP_ROOT,
        "$FTP_ROOT\general",
        "$FTP_ROOT\reprobados",
        "$FTP_ROOT\recursadores"
    )

    foreach ($dir in $dirs) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Print-Ok "Creado: $dir"
        } else {
            Print-Info "Ya existe: $dir"
        }
    }

    # Raiz FTP: usuarios autenticados e IUSR pueden navegar (necesario para entrar al sitio)
    Set-FolderACL -Path $FTP_ROOT -Rules @(
        (New-ACLRule $ID_ADMINS "FullControl"),
        (New-ACLRule $ID_SYSTEM "FullControl"),
        (New-ACLRule $ID_AUTH   "ReadAndExecute"),
        (New-ACLRule $ID_IUSR   "ReadAndExecute")
    )
    Print-Ok "Permisos raiz configurados."

    # general: todos leen y escriben; IUSR solo lee
    Set-FolderACL -Path "$FTP_ROOT\general" -Rules @(
        (New-ACLRule $ID_ADMINS "FullControl"),
        (New-ACLRule $ID_SYSTEM "FullControl"),
        (New-ACLRule $ID_AUTH   "Modify"),
        (New-ACLRule $ID_IUSR   "ReadAndExecute")
    )
    Protect-FolderFromDeletion "$FTP_ROOT\general"
    Print-Ok "Permisos 'general' configurados."

    # reprobados: solo su grupo; anonimo sin acceso
    Set-FolderACL -Path "$FTP_ROOT\reprobados" -Rules @(
        (New-ACLRule $ID_ADMINS        "FullControl"),
        (New-ACLRule $ID_SYSTEM        "FullControl"),
        (New-ACLRule $GRUPO_REPROBADOS "Modify")
    )
    Protect-FolderFromDeletion "$FTP_ROOT\reprobados"
    Print-Ok "Permisos 'reprobados' configurados."

    # recursadores: solo su grupo; anonimo sin acceso
    Set-FolderACL -Path "$FTP_ROOT\recursadores" -Rules @(
        (New-ACLRule $ID_ADMINS          "FullControl"),
        (New-ACLRule $ID_SYSTEM          "FullControl"),
        (New-ACLRule $GRUPO_RECURSADORES "Modify")
    )
    Protect-FolderFromDeletion "$FTP_ROOT\recursadores"
    Print-Ok "Permisos 'recursadores' configurados."

    Print-Ok "Estructura base lista."
}

# ============================================================================
# FUNCION: Configurar sitio FTP en IIS
#
# IMPORTANTE: Se usa modo de aislamiento 0 (sin aislamiento por directorio).
# El control de acceso lo hacen los permisos NTFS.
# Esto evita el error 530 "home directory inaccessible" del modo 3,
# que requiere C:\ftp\LocalUser\<usuario> y falla en Windows Server 2025
# cuando Web-Ftp-Ext no esta correctamente inicializado.
# ============================================================================
function Configurar-FTP {
    Print-Info "Configurando sitio FTP en IIS..."

    Import-Module WebAdministration -ErrorAction Stop

    # Eliminar sitio anterior si existe
    if (Get-WebSite -Name $FTP_SITE_NAME -ErrorAction SilentlyContinue) {
        & "$env:SystemRoot\System32\inetsrv\appcmd.exe" stop site $FTP_SITE_NAME 2>$null
        Start-Sleep -Seconds 1
        Remove-WebSite -Name $FTP_SITE_NAME -ErrorAction SilentlyContinue
        Print-Info "Sitio anterior eliminado."
    }

    # Detener Default Web Site para evitar conflictos
    if (Get-WebSite -Name "Default Web Site" -ErrorAction SilentlyContinue) {
        Stop-WebSite -Name "Default Web Site" -ErrorAction SilentlyContinue
        Print-Info "Default Web Site detenido."
    }

    # Reiniciar ftpsvc antes de crear el sitio (asegura modulos cargados)
    Stop-Service ftpsvc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Service ftpsvc
    Start-Sleep -Seconds 2

    # Crear sitio FTP
    New-WebFtpSite -Name $FTP_SITE_NAME -Port $FTP_PORT -PhysicalPath $FTP_ROOT -Force | Out-Null
    Print-Ok "Sitio '$FTP_SITE_NAME' creado."

    # Modo 0 = sin aislamiento de directorios.
    # Los permisos NTFS en cada carpeta controlan quien accede a que.
    Set-ItemProperty "IIS:\Sites\$FTP_SITE_NAME" `
        -Name "ftpServer.userIsolation.mode" -Value 0
    Print-Ok "User Isolation: modo 0 (control por NTFS)."

    # Autenticacion basica y anonima
    Set-ItemProperty "IIS:\Sites\$FTP_SITE_NAME" `
        -Name "ftpServer.security.authentication.basicAuthentication.enabled" `
        -Value $true
    Set-ItemProperty "IIS:\Sites\$FTP_SITE_NAME" `
        -Name "ftpServer.security.authentication.anonymousAuthentication.enabled" `
        -Value $true
    Print-Ok "Autenticacion basica y anonima habilitadas."

    # SSL: SslAllow permite conexion sin certificado (entorno de laboratorio)
    Set-ItemProperty "IIS:\Sites\$FTP_SITE_NAME" `
        -Name "ftpServer.security.ssl.controlChannelPolicy" -Value "SslAllow"
    Set-ItemProperty "IIS:\Sites\$FTP_SITE_NAME" `
        -Name "ftpServer.security.ssl.dataChannelPolicy" -Value "SslAllow"
    Print-Ok "SSL configurado (SslAllow - texto plano permitido)."

    # Puertos pasivos
    Set-WebConfigurationProperty -PSPath "IIS:\" `
        -Filter "system.ftpServer/firewallSupport" `
        -Name "lowDataChannelPort"  -Value 40000
    Set-WebConfigurationProperty -PSPath "IIS:\" `
        -Filter "system.ftpServer/firewallSupport" `
        -Name "highDataChannelPort" -Value 40100
    Print-Ok "Puertos pasivos 40000-40100 configurados."

    # Reglas de autorizacion FTP
    Clear-WebConfiguration "/system.ftpServer/security/authorization" `
        -PSPath "IIS:\" -Location $FTP_SITE_NAME -ErrorAction SilentlyContinue

    # Anonimo: solo lectura (vera unicamente 'general' por permisos NTFS)
    Add-WebConfiguration "/system.ftpServer/security/authorization" `
        -PSPath "IIS:\" -Location $FTP_SITE_NAME `
        -Value @{ accessType="Allow"; users="?"; roles=""; permissions=1 } `
        -ErrorAction SilentlyContinue

    # Usuarios autenticados: lectura y escritura
    Add-WebConfiguration "/system.ftpServer/security/authorization" `
        -PSPath "IIS:\" -Location $FTP_SITE_NAME `
        -Value @{ accessType="Allow"; users="*"; roles=""; permissions=3 } `
        -ErrorAction SilentlyContinue

    Print-Ok "Reglas de autorizacion FTP configuradas."

    # Reiniciar e iniciar sitio
    Stop-Service ftpsvc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Service ftpsvc
    Start-Sleep -Seconds 3

    & "$env:SystemRoot\System32\inetsrv\appcmd.exe" start site $FTP_SITE_NAME 2>$null
    Start-Sleep -Seconds 1

    $estado = (& "$env:SystemRoot\System32\inetsrv\appcmd.exe" list site $FTP_SITE_NAME)
    Print-Ok "Estado del sitio: $estado"

    # Verificar que el puerto este escuchando
    $escuchando = netstat -ano | Select-String ":$FTP_PORT "
    if ($escuchando) {
        Print-Ok "Puerto $FTP_PORT escuchando correctamente."
    } else {
        Print-Warn "El puerto $FTP_PORT no aparece en netstat. Verifique manualmente."
    }
}

# ============================================================================
# FUNCION: Configurar firewall
# ============================================================================
function Configurar-Firewall {
    Print-Info "Configurando firewall..."

    if (-not (Get-NetFirewallRule -DisplayName "FTP Puerto $FTP_PORT" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "FTP Puerto $FTP_PORT" `
            -Direction Inbound -Protocol TCP -LocalPort $FTP_PORT -Action Allow | Out-Null
        Print-Ok "Puerto $FTP_PORT abierto."
    } else {
        Print-Info "Regla puerto $FTP_PORT ya existe."
    }

    if (-not (Get-NetFirewallRule -DisplayName "FTP Pasivo 40000-40100" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "FTP Pasivo 40000-40100" `
            -Direction Inbound -Protocol TCP -LocalPort 40000-40100 -Action Allow | Out-Null
        Print-Ok "Puertos pasivos 40000-40100 abiertos."
    } else {
        Print-Info "Regla puertos pasivos ya existe."
    }
}

# ============================================================================
# FUNCION: Validar nombre de usuario
# ============================================================================
function Validar-Usuario {
    param([string]$usuario)

    if ([string]::IsNullOrEmpty($usuario)) {
        Print-Error "El nombre no puede estar vacio."; return $false
    }
    if ($usuario.Length -lt 3 -or $usuario.Length -gt 20) {
        Print-Error "El nombre debe tener entre 3 y 20 caracteres."; return $false
    }
    if ($usuario -notmatch '^[a-zA-Z][a-zA-Z0-9_-]*$') {
        Print-Error "Solo letras, numeros, guion y guion bajo. Debe iniciar con letra."; return $false
    }
    if (Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue) {
        Print-Error "El usuario '$usuario' ya existe."; return $false
    }
    return $true
}

# ============================================================================
# FUNCION: Crear usuario FTP
#
# Por cada usuario se crea:
#   C:\ftp\<usuario>\   con permisos exclusivos para ese usuario
#
# El usuario vera al conectarse por FTP (gracias a NTFS):
#   /general/           (publica - puede leer y escribir, no borrar la carpeta)
#   /reprobados/ O      (solo si pertenece al grupo)
#   /recursadores/
#   /<usuario>/         (personal - control total)
# ============================================================================
function Crear-Usuario-FTP {
    param(
        [string]$usuario,
        [string]$password,
        [string]$grupo
    )

    Print-Info "Creando usuario '$usuario' en grupo '$grupo'..."

    # Crear usuario local del sistema
    $securePass = ConvertTo-SecureString $password -AsPlainText -Force
    try {
        New-LocalUser -Name $usuario -Password $securePass `
            -PasswordNeverExpires `
            -UserMayNotChangePassword `
            -Description "Usuario FTP - $grupo" | Out-Null
        Print-Ok "Usuario del sistema creado."
    } catch {
        Print-Error "Error al crear usuario '$usuario': $_"
        return $false
    }

    Start-Sleep -Seconds 1

    # Otorgar derecho de logon local (requerido por IIS FTP Basic Auth)
    Grant-FTPLogonRight -Username $usuario

    # Asignar al grupo correcto (quitar del otro si estuviera)
    $otroGrupo = if ($grupo -eq $GRUPO_REPROBADOS) { $GRUPO_RECURSADORES } else { $GRUPO_REPROBADOS }
    Remove-LocalGroupMember -Group $otroGrupo -Member $usuario -ErrorAction SilentlyContinue
    Add-LocalGroupMember    -Group $grupo      -Member $usuario -ErrorAction SilentlyContinue
    Print-Ok "Usuario agregado al grupo '$grupo'."

    # Crear carpeta personal
    $carpetaPersonal = "$FTP_ROOT\$usuario"
    if (-not (Test-Path $carpetaPersonal)) {
        New-Item -ItemType Directory -Path $carpetaPersonal -Force | Out-Null
    }

    # Obtener cuenta del usuario por SID (evita problemas de idioma/dominio)
    $userSID     = (Get-LocalUser -Name $usuario).SID
    $userAccount = $userSID.Translate([System.Security.Principal.NTAccount])

    # Permisos carpeta personal: solo el usuario y admins
    Set-FolderACL -Path $carpetaPersonal -Rules @(
        (New-ACLRule $ID_ADMINS   "FullControl"),
        (New-ACLRule $ID_SYSTEM   "FullControl"),
        (New-ACLRule $userAccount "Modify")
    )
    # Proteger la carpeta personal contra borrado tambien
    Protect-FolderFromDeletion $carpetaPersonal
    Print-Ok "  Carpeta personal: $carpetaPersonal"

    Write-Host ""
    Print-Ok "═══════════════════════════════════════════════"
    Print-Ok "  Usuario '$usuario' creado correctamente"
    Print-Ok "═══════════════════════════════════════════════"
    Print-Info "  Carpetas visibles al conectar por FTP:"
    Print-Info "    /general/          (publica: leer y escribir)"
    Print-Info "    /$grupo/           (solo tu grupo)"
    Print-Info "    /$usuario/         (personal)"
    Print-Info "  Ninguna carpeta puede ser borrada por el usuario."
    Print-Ok "═══════════════════════════════════════════════"

    return $true
}

# ============================================================================
# FUNCION: Eliminar usuario FTP
# ============================================================================
function Eliminar-Usuario-FTP {
    param([string]$usuario)

    Print-Info "Eliminando usuario '$usuario'..."

    # Eliminar carpeta personal
    $carpeta = "$FTP_ROOT\$usuario"
    if (Test-Path $carpeta) {
        # Quitar primero el DENY para poder borrar
        $acl = Get-Acl $carpeta
        $acl.SetAccessRuleProtection($false, $true)
        Set-Acl -Path $carpeta -AclObject $acl
        Remove-Item -Path $carpeta -Recurse -Force -ErrorAction SilentlyContinue
        Print-Ok "  Carpeta personal eliminada."
    }

    # Eliminar usuario del sistema
    Remove-LocalUser -Name $usuario -ErrorAction SilentlyContinue
    Print-Ok "  Usuario '$usuario' eliminado del sistema."
}

# ============================================================================
# FUNCION: Cambiar usuario de grupo
# ============================================================================
function Cambiar-Grupo-Usuario {
    param([string]$usuario)

    if (-not (Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue)) {
        Print-Error "El usuario '$usuario' no existe."
        return
    }

    # Detectar grupo actual
    $grupoActual = $null
    foreach ($g in @($GRUPO_REPROBADOS, $GRUPO_RECURSADORES)) {
        $miembros = Get-LocalGroupMember -Group $g -ErrorAction SilentlyContinue
        if ($miembros | Where-Object { ($_.Name -replace "^.*\\","") -eq $usuario }) {
            $grupoActual = $g
            break
        }
    }

    Print-Info "Grupo actual de '$usuario': $(if ($grupoActual) { $grupoActual } else { '(ninguno)' })"

    Write-Host ""
    Write-Host "  Nuevo grupo:"
    Write-Host "  1) $GRUPO_REPROBADOS"
    Write-Host "  2) $GRUPO_RECURSADORES"
    $opcion = Read-Host "Seleccione [1-2]"

    $nuevoGrupo = switch ($opcion) {
        "1" { $GRUPO_REPROBADOS }
        "2" { $GRUPO_RECURSADORES }
        default { Print-Error "Opcion invalida."; return }
    }

    if ($grupoActual -eq $nuevoGrupo) {
        Print-Info "El usuario ya pertenece a '$nuevoGrupo'."
        return
    }

    # Cambiar membresia de grupo
    if ($grupoActual) {
        Remove-LocalGroupMember -Group $grupoActual -Member $usuario -ErrorAction SilentlyContinue
        Print-Ok "Removido de '$grupoActual'."
    }
    Add-LocalGroupMember -Group $nuevoGrupo -Member $usuario -ErrorAction SilentlyContinue
    Print-Ok "Agregado a '$nuevoGrupo'."

    # Los permisos NTFS en las carpetas de grupo son por membresia,
    # no hace falta modificar ACLs individuales.
    Print-Ok "Usuario '$usuario' movido a '$nuevoGrupo'."
    Print-Info "El usuario ahora tendra acceso a /$nuevoGrupo/ en su proxima sesion FTP."
}

# ============================================================================
# FUNCION: Instalar y configurar servidor FTP completo
# ============================================================================
function Instalar-FTP {
    Print-Titulo "Instalacion y Configuracion de Servidor FTP"

    if (Verificar-Instalacion) {
        $reconf = Read-Host "IIS y FTP ya instalados. Reconfigurar? [s/N]"
        if ($reconf -notmatch '^[Ss]$') { Print-Info "Cancelado."; return }
    } else {
        Print-Info "Instalando IIS y FTP Service..."
        $result = Install-WindowsFeature `
            -Name Web-Server, Web-Ftp-Server, Web-Ftp-Service, Web-Ftp-Ext, Web-Mgmt-Console `
            -IncludeManagementTools
        if ($result.Success) {
            Print-Ok "IIS y FTP instalados."
        } else {
            Print-Error "Error en la instalacion. Verifique el log de Windows."
            return
        }
    }

    Import-Module WebAdministration -ErrorAction Stop

    Crear-Grupos
    Crear-Estructura-Base
    Configurar-FTP
    Configurar-Firewall

    $ip = (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -ne "127.0.0.1" } |
        Select-Object -First 1).IPAddress

    Write-Host ""
    Print-Ok "══════════════════════════════════════════════════"
    Print-Ok "  Servidor FTP listo"
    Print-Ok "══════════════════════════════════════════════════"
    Print-Info "  IP       : $ip"
    Print-Info "  Puerto   : $FTP_PORT"
    Print-Info "  Anonimo  : ftp://$ip  (solo lectura en /general)"
    Print-Ok "══════════════════════════════════════════════════"
    Print-Info "Cree usuarios con: .\ftp_server.ps1 -users"
    Write-Host ""
}

# ============================================================================
# FUNCION: Gestionar usuarios FTP
# ============================================================================
function Gestionar-Usuarios {
    Print-Titulo "Gestion de Usuarios FTP"

    if (-not (Verificar-Instalacion)) {
        Print-Error "IIS/FTP no instalado. Ejecute primero: .\ftp_server.ps1 -install"
        return
    }

    Import-Module WebAdministration -ErrorAction SilentlyContinue

    Write-Host "  1) Crear nuevos usuarios"
    Write-Host "  2) Cambiar grupo de un usuario"
    Write-Host "  3) Eliminar usuario"
    Write-Host "  4) Cambiar contrasena de usuario"
    Write-Host "  5) Volver"
    Write-Host ""
    $opcion = Read-Host "Seleccione [1-5]"

    switch ($opcion) {

        "1" {
            $num = Read-Host "Cuantos usuarios desea crear?"
            if (-not ($num -match '^\d+$') -or [int]$num -lt 1) {
                Print-Error "Numero invalido."; return
            }

            for ($i = 1; $i -le [int]$num; $i++) {
                Write-Host ""
                Print-Titulo "Usuario $i de $num"

                do { $usuario = (Read-Host "Nombre de usuario").Trim() } `
                    while (-not (Validar-Usuario -usuario $usuario))

                do { $password = (Read-Host "Contrasena").Trim() } `
                    while ([string]::IsNullOrWhiteSpace($password))

                Write-Host "  1) $GRUPO_REPROBADOS"
                Write-Host "  2) $GRUPO_RECURSADORES"
                $gOp = Read-Host "Grupo [1-2]"
                $grupo = switch ($gOp) {
                    "1" { $GRUPO_REPROBADOS }
                    "2" { $GRUPO_RECURSADORES }
                    default {
                        Print-Warn "Opcion invalida, asignando a $GRUPO_REPROBADOS."
                        $GRUPO_REPROBADOS
                    }
                }

                Crear-Usuario-FTP -usuario $usuario -password $password -grupo $grupo
            }
        }

        "2" {
            Listar-Usuarios-FTP
            $usuario = (Read-Host "Usuario a cambiar de grupo").Trim()
            Cambiar-Grupo-Usuario -usuario $usuario
        }

        "3" {
            Listar-Usuarios-FTP
            $usuario = (Read-Host "Usuario a eliminar").Trim()
            if (-not (Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue)) {
                Print-Error "Usuario '$usuario' no existe."; return
            }
            $confirmar = Read-Host "Confirma eliminar '$usuario' y su carpeta? [s/N]"
            if ($confirmar -match '^[Ss]$') {
                Eliminar-Usuario-FTP -usuario $usuario
            } else {
                Print-Info "Cancelado."
            }
        }

        "4" {
            Listar-Usuarios-FTP
            $usuario = (Read-Host "Nombre del usuario").Trim()
            if (-not (Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue)) {
                Print-Error "Usuario '$usuario' no existe."; return
            }
            $newPass = (Read-Host "Nueva contrasena").Trim()
            if ([string]::IsNullOrWhiteSpace($newPass)) {
                Print-Error "La contrasena no puede estar vacia."; return
            }
            $secPass = ConvertTo-SecureString $newPass -AsPlainText -Force
            Set-LocalUser -Name $usuario -Password $secPass
            Print-Ok "Contrasena de '$usuario' actualizada."
        }

        "5" { return }
        default { Print-Error "Opcion invalida." }
    }
}

# ============================================================================
# FUNCION: Listar usuarios FTP
# ============================================================================
function Listar-Usuarios-FTP {
    Print-Titulo "Usuarios FTP Configurados"

    $usuarios = @()
    foreach ($grupo in @($GRUPO_REPROBADOS, $GRUPO_RECURSADORES)) {
        $miembros = Get-LocalGroupMember -Group $grupo -ErrorAction SilentlyContinue
        foreach ($m in $miembros) {
            $nombre     = $m.Name -replace ".*\\", ""
            $carpetaOk  = Test-Path "$FTP_ROOT\$nombre"
            $usuarios  += [PSCustomObject]@{
                Usuario  = $nombre
                Grupo    = $grupo
                Carpeta  = if ($carpetaOk) { "OK" } else { "FALTA" }
            }
        }
    }

    if ($usuarios.Count -eq 0) {
        Print-Info "No hay usuarios FTP configurados."
        return
    }
    $usuarios | Format-Table -AutoSize
}

# ============================================================================
# FUNCION: Ver estado del servidor
# ============================================================================
function Ver-Estado {
    Print-Titulo "ESTADO DEL SERVIDOR FTP"

    Import-Module WebAdministration -ErrorAction SilentlyContinue

    # Servicio
    $svc = Get-Service -Name "ftpsvc" -ErrorAction SilentlyContinue
    if ($svc) {
        $color = if ($svc.Status -eq "Running") { "Green" } else { "Red" }
        Write-Host "  Servicio ftpsvc : " -NoNewline
        Write-Host $svc.Status -ForegroundColor $color
    }

    # Sitio IIS
    $estadoSitio = & "$env:SystemRoot\System32\inetsrv\appcmd.exe" list site $FTP_SITE_NAME 2>$null
    Write-Host "  Sitio IIS       : $estadoSitio"

    # Puerto
    $puerto = netstat -ano | Select-String ":$FTP_PORT "
    if ($puerto) {
        Write-Host "  Puerto $FTP_PORT      : " -NoNewline
        Write-Host "ESCUCHANDO" -ForegroundColor Green
    } else {
        Write-Host "  Puerto $FTP_PORT      : " -NoNewline
        Write-Host "NO ESCUCHA" -ForegroundColor Red
    }

    # Isolation mode
    $isolation = (Get-ItemProperty "IIS:\Sites\$FTP_SITE_NAME" `
        -Name "ftpServer.userIsolation.mode" -ErrorAction SilentlyContinue).Value
    $isoText = switch ($isolation) {
        0 { "Sin aislamiento / control por NTFS (correcto)" }
        3 { "IsolateAllDirectories" }
        default { "Modo $isolation" }
    }
    Write-Host "  User Isolation  : $isoText"

    Write-Host ""
    Listar-Usuarios-FTP
}

# ============================================================================
# FUNCION: Reiniciar FTP
# ============================================================================
function Reiniciar-FTP {
    Print-Info "Reiniciando servidor FTP..."
    Stop-Service ftpsvc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Service ftpsvc
    Start-Sleep -Seconds 2
    & "$env:SystemRoot\System32\inetsrv\appcmd.exe" start site $FTP_SITE_NAME 2>$null
    Print-Ok "Servidor FTP reiniciado."

    $puerto = netstat -ano | Select-String ":$FTP_PORT "
    if ($puerto) {
        Print-Ok "Puerto $FTP_PORT escuchando."
    } else {
        Print-Warn "Puerto $FTP_PORT no detectado. Verifique con: netstat -ano | findstr :$FTP_PORT"
    }
}

# ============================================================================
# FUNCION: Mostrar ayuda
# ============================================================================
function Mostrar-Ayuda {
    Clear-Host
    Write-Host ""
    Write-Host "  Servidor FTP - Windows Server 2025" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "  Uso: .\ftp_server.ps1 [opcion]"
    Write-Host ""
    Write-Host "  -install   Instala y configura el servidor FTP"
    Write-Host "  -users     Gestionar usuarios (crear, cambiar grupo, eliminar)"
    Write-Host "  -status    Ver estado del servidor y usuarios"
    Write-Host "  -restart   Reiniciar el servicio FTP"
    Write-Host "  -verify    Verificar si IIS y FTP estan instalados"
    Write-Host "  -list      Listar usuarios configurados"
    Write-Host "  -help      Mostrar esta ayuda"
    Write-Host ""
    Write-Host "  Estructura de acceso por usuario:" -ForegroundColor Cyan
    Write-Host "    /general/       Publica (todos leen y escriben)"
    Write-Host "    /reprobados/    Solo grupo reprobados"
    Write-Host "    /recursadores/  Solo grupo recursadores"
    Write-Host "    /<usuario>/     Carpeta personal exclusiva"
    Write-Host ""
}

# ============================================================================
# ENTRY POINT
# ============================================================================
if     ($verify)  { Verificar-Instalacion }
elseif ($install) { Instalar-FTP }
elseif ($users)   { Gestionar-Usuarios }
elseif ($restart) { Reiniciar-FTP }
elseif ($status)  { Ver-Estado }
elseif ($list)    { Listar-Usuarios-FTP }
elseif ($help)    { Mostrar-Ayuda }
else              { Mostrar-Ayuda }
