# ============================================================================
# Script de Automatizacion de Servidor FTP - Windows Server 2025
# Administracion de Sistemas - IIS con FTP Service
# ============================================================================

# ============================================================================
# DEBE ESTAR AL INICIO DEL SCRIPT
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
# Colores y utilidades
# ============================================================================
function Print-Info   { param($msg) Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Print-Ok     { param($msg) Write-Host "[OK]    $msg" -ForegroundColor Green }
function Print-Error  { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Print-Warn   { param($msg) Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Print-Titulo { param($msg) Write-Host "`n=== $msg ===`n" -ForegroundColor Magenta }

# ============================================================================
# Variables Globales
# ============================================================================
$FTP_ROOT           = "C:\ftp"
$GRUPO_REPROBADOS   = "reprobados"
$GRUPO_RECURSADORES = "recursadores"
$FTP_SITE_NAME      = "ServidorFTP"
$FTP_PORT           = 21

# ============================================================================
# IDENTIDADES POR SID - Independiente del idioma del SO
# S-1-5-32-544 = Administrators / Administradores
# S-1-5-18     = SYSTEM / SISTEMA
# S-1-5-11     = Authenticated Users / Usuarios autenticados
# S-1-5-17     = IUSR (cuenta anonima IIS)
# ============================================================================
function Resolve-SID {
    param([string]$Sid)
    $sidObj = New-Object System.Security.Principal.SecurityIdentifier($Sid)
    return $sidObj.Translate([System.Security.Principal.NTAccount])
}

$ID_ADMINS = Resolve-SID "S-1-5-32-544"
$ID_SYSTEM = Resolve-SID "S-1-5-18"
$ID_AUTH   = Resolve-SID "S-1-5-11"
$ID_IUSR   = Resolve-SID "S-1-5-17"

# ============================================================================
# FUNCION: Crear regla ACL reutilizable
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
# FUNCION: Aplicar ACL limpia a una carpeta
# ============================================================================
function Set-FolderACL {
    param(
        [string]$Path,
        [System.Security.AccessControl.FileSystemAccessRule[]]$Rules
    )
    $acl = Get-Acl $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in $Rules) {
        $acl.AddAccessRule($rule)
    }
    Set-Acl -Path $Path -AclObject $acl
}

# ============================================================================
# FUNCION: Otorgar derecho "Log on locally" requerido por IIS FTP
# ============================================================================
function Grant-FTPLogonRight {
    param([string]$Username)

    $exportInf = "$env:TEMP\secedit_export.inf"
    $applyInf  = "$env:TEMP\secedit_apply.inf"
    $applyDb   = "$env:TEMP\secedit_apply.sdb"

    # Exportar politica actual
    & secedit /export /cfg $exportInf /quiet 2>$null

    $cfg = Get-Content $exportInf -ErrorAction SilentlyContinue
    $linea = $cfg | Where-Object { $_ -match "^SeInteractiveLogonRight" }

    # Si ya tiene el usuario, no hacer nada
    if ($linea -and $linea -match [regex]::Escape($Username)) {
        Print-Info "  '$Username' ya tiene derecho de logon local."
        return
    }

    # Construir nueva linea agregando el usuario
    if ($linea) {
        $nuevaLinea = "$linea,*$Username"
    } else {
        $nuevaLinea = "SeInteractiveLogonRight = *$Username"
    }

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
    $iis = Get-WindowsFeature -Name "Web-Server"      -ErrorAction SilentlyContinue
    $ftp = Get-WindowsFeature -Name "Web-Ftp-Server"  -ErrorAction SilentlyContinue

    if ($iis.Installed -and $ftp.Installed) {
        Print-Ok "IIS y FTP Service instalados."
        return $true
    }
    if (-not $iis.Installed) { Print-Error "IIS (Web-Server) no instalado." }
    if (-not $ftp.Installed) { Print-Error "FTP Service (Web-Ftp-Server) no instalado." }
    return $false
}

# ============================================================================
# FUNCION: Configurar firewall
# ============================================================================
function Configurar-Firewall {
    Print-Info "Configurando firewall..."

    if (-not (Get-NetFirewallRule -DisplayName "FTP Puerto 21" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "FTP Puerto 21" `
            -Direction Inbound -Protocol TCP -LocalPort 21 -Action Allow | Out-Null
        Print-Ok "Puerto 21 abierto."
    } else { Print-Info "Regla puerto 21 ya existe." }

    if (-not (Get-NetFirewallRule -DisplayName "FTP Pasivo 40000-40100" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "FTP Pasivo 40000-40100" `
            -Direction Inbound -Protocol TCP -LocalPort 40000-40100 -Action Allow | Out-Null
        Print-Ok "Puertos pasivos 40000-40100 abiertos."
    } else { Print-Info "Regla puertos pasivos ya existe." }
}

# ============================================================================
# FUNCION: Crear grupos locales
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

function Crear-Estructura-Base {
    Print-Info "Creando estructura de directorios..."

    $dirs = @(
        $FTP_ROOT,
        "$FTP_ROOT\LocalUser",
        "$FTP_ROOT\LocalUser\Public",
        "$FTP_ROOT\LocalUser\Public\general",
        "$FTP_ROOT\LocalUser\reprobados",
        "$FTP_ROOT\LocalUser\recursadores"
    )

    foreach ($dir in $dirs) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Print-Ok "Creado: $dir"
        } else {
            Print-Info "Ya existe: $dir"
        }
    }

    # --- Permisos raiz FTP: solo admins
    Set-FolderACL -Path $FTP_ROOT -Rules @(
        (New-ACLRule $ID_ADMINS "FullControl"),
        (New-ACLRule $ID_SYSTEM "FullControl")
    )

    # --- Permisos LocalUser\Public (home anonimo)
    # IUSR solo puede listar esta carpeta, pero NO su contenido directamente
    # Solo llegara a ver 'general' porque es la unica subcarpeta
    Set-FolderACL -Path "$FTP_ROOT\LocalUser\Public" -Rules @(
        (New-ACLRule $ID_ADMINS "FullControl"),
        (New-ACLRule $ID_SYSTEM "FullControl"),
        (New-ACLRule $ID_IUSR   "ReadAndExecute")
    )

    # --- Permisos general: autenticados escriben, IUSR solo lee
    Set-FolderACL -Path "$FTP_ROOT\LocalUser\Public\general" -Rules @(
        (New-ACLRule $ID_ADMINS "FullControl"),
        (New-ACLRule $ID_SYSTEM "FullControl"),
        (New-ACLRule $ID_AUTH   "Modify"),
        (New-ACLRule $ID_IUSR   "ReadAndExecute")
    )
    Print-Ok "Permisos 'general' configurados."

    # --- Permisos carpetas de grupo: IUSR sin acceso, solo el grupo respectivo
    foreach ($grupo in @($GRUPO_REPROBADOS, $GRUPO_RECURSADORES)) {
        Set-FolderACL -Path "$FTP_ROOT\LocalUser\$grupo" -Rules @(
            (New-ACLRule $ID_ADMINS "FullControl"),
            (New-ACLRule $ID_SYSTEM "FullControl"),
            (New-ACLRule $grupo     "Modify")
            # IUSR no tiene regla aqui: sin acceso a carpetas de grupo
        )
        Print-Ok "Permisos '$grupo' configurados (anonimo sin acceso)."
    }

    Print-Ok "Estructura base lista."
    Proteger-CarpetasBase
}

# ============================================================================
# FUNCION: Configurar sitio FTP en IIS
# ============================================================================
function Configurar-FTP {
    Print-Info "Configurando sitio FTP en IIS..."

    Import-Module WebAdministration -ErrorAction Stop

    # Eliminar sitio anterior si existe
    if (Get-WebSite -Name $FTP_SITE_NAME -ErrorAction SilentlyContinue) {
        & "$env:SystemRoot\System32\inetsrv\appcmd.exe" stop site $FTP_SITE_NAME 2>$null
        Remove-WebSite -Name $FTP_SITE_NAME
        Print-Info "Sitio anterior eliminado."
    }

    # Crear sitio FTP apuntando a la raiz
    New-WebFtpSite -Name $FTP_SITE_NAME -Port $FTP_PORT -PhysicalPath $FTP_ROOT -Force | Out-Null
    Print-Ok "Sitio '$FTP_SITE_NAME' creado."

    # User Isolation modo 3: enjaula cada usuario en LocalUser\<username>
    Set-ItemProperty "IIS:\Sites\$FTP_SITE_NAME" `
        -Name "ftpServer.userIsolation.mode" -Value 3
    Print-Ok "User Isolation activado."

    # Autenticacion basica y anonima
    Set-ItemProperty "IIS:\Sites\$FTP_SITE_NAME" `
        -Name "ftpServer.security.authentication.basicAuthentication.enabled" -Value $true
    Set-ItemProperty "IIS:\Sites\$FTP_SITE_NAME" `
        -Name "ftpServer.security.authentication.anonymousAuthentication.enabled" -Value $true
    Print-Ok "Autenticacion configurada."

    # SSL deshabilitado (entorno de laboratorio)
    # Usar valor numerico 0 directamente en el XML para evitar error 0x800710D8
    $configFile = "$env:SystemRoot\System32\inetsrv\config\applicationHost.config"
    [xml]$xml = Get-Content $configFile

    $siteNode = $xml.configuration.'system.applicationHost'.sites.site |
        Where-Object { $_.name -eq $FTP_SITE_NAME }

    if ($siteNode) {
        $sslNode = $siteNode.ftpServer.security.ssl
        if ($sslNode) {
            $sslNode.SetAttribute("controlChannelPolicy", "SslAllow")
            $sslNode.SetAttribute("dataChannelPolicy",    "SslAllow")
            $sslNode.SetAttribute("serverCertHash",       "")
            $sslNode.SetAttribute("serverCertStoreName",  "")
            $xml.Save($configFile)
            Print-Ok "SSL configurado correctamente en applicationHost.config."
        }
    }

    # SSL deshabilitado (entorno de laboratorio) - Permitir texto plano
    Set-ItemProperty -Path "IIS:\Sites\$FTP_SITE_NAME" -Name "ftpServer.security.ssl.controlChannelPolicy" -Value "SslAllow"
    Set-ItemProperty -Path "IIS:\Sites\$FTP_SITE_NAME" -Name "ftpServer.security.ssl.dataChannelPolicy" -Value "SslAllow"
    Print-Ok "SSL configurado para permitir texto plano."

    # Puertos pasivos
    Set-WebConfigurationProperty -PSPath "IIS:\" `
        -Filter "system.ftpServer/firewallSupport" `
        -Name "lowDataChannelPort"  -Value 40000
    Set-WebConfigurationProperty -PSPath "IIS:\" `
        -Filter "system.ftpServer/firewallSupport" `
        -Name "highDataChannelPort" -Value 40100
    Print-Ok "Puertos pasivos 40000-40100 configurados."

    # Limpiar reglas anteriores
    Clear-WebConfiguration "/system.ftpServer/security/authorization" `
        -PSPath "IIS:\" -Location $FTP_SITE_NAME -ErrorAction SilentlyContinue

    # Anonimo: solo lectura (vera unicamente general por permisos NTFS)
    Add-WebConfiguration "/system.ftpServer/security/authorization" `
        -PSPath "IIS:\" -Location $FTP_SITE_NAME `
        -Value @{ accessType="Allow"; users="?"; roles=""; permissions=1 } `
        -ErrorAction SilentlyContinue

    # Usuarios autenticados: lectura y escritura
    Add-WebConfiguration "/system.ftpServer/security/authorization" `
        -PSPath "IIS:\" -Location $FTP_SITE_NAME `
        -Value @{ accessType="Allow"; users="*"; roles=""; permissions=3 } `
        -ErrorAction SilentlyContinue

    # Reiniciar servicio FTP para aplicar cambios del XML
    Stop-Service ftpsvc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Service ftpsvc
    Start-Sleep -Seconds 2

    # Arrancar sitio
    & "$env:SystemRoot\System32\inetsrv\appcmd.exe" start site $FTP_SITE_NAME
    $estado = (& "$env:SystemRoot\System32\inetsrv\appcmd.exe" list site $FTP_SITE_NAME)
    Print-Ok "Estado del sitio: $estado"
}

function Construir-Jaula-Usuario {
    param(
        [string]$usuario,
        [string]$grupo
    )

    Print-Info "Construyendo jaula FTP para '$usuario'..."

    $jaula    = "$FTP_ROOT\LocalUser\$usuario"
    $personal = "$jaula\$usuario"

    # Crear carpeta home del usuario
    if (-not (Test-Path $jaula)) {
        New-Item -ItemType Directory -Path $jaula -Force | Out-Null
    }

    # Crear carpeta personal fisica dentro del home
    if (-not (Test-Path $personal)) {
        New-Item -ItemType Directory -Path $personal -Force | Out-Null
    }

    # Obtener SID del usuario para permisos (evita problemas de idioma)
    $userSID     = (Get-LocalUser -Name $usuario).SID
    $userAccount = $userSID.Translate([System.Security.Principal.NTAccount])

    # Permisos home del usuario
    Set-FolderACL -Path $jaula -Rules @(
        (New-ACLRule $ID_ADMINS   "FullControl"),
        (New-ACLRule $ID_SYSTEM   "FullControl"),
        (New-ACLRule $userAccount "Modify")
    )

    # Permisos carpeta personal
    Set-FolderACL -Path $personal -Rules @(
        (New-ACLRule $ID_ADMINS   "FullControl"),
        (New-ACLRule $ID_SYSTEM   "FullControl"),
        (New-ACLRule $userAccount "Modify")
    )
    Print-Ok "  Carpeta personal: $personal"

    # Junction: general -> C:\ftp\LocalUser\Public\general (compartida todos)
    $jGeneral = "$jaula\general"
    if (-not (Test-Path $jGeneral)) {
        cmd /c "mklink /J `"$jGeneral`" `"$FTP_ROOT\LocalUser\Public\general`"" | Out-Null
        Print-Ok "  Junction 'general' creado."
    } else {
        Print-Info "  Junction 'general' ya existe."
    }

    # Junction: <grupo> -> C:\ftp\LocalUser\<grupo> (solo su grupo)
    $jGrupo = "$jaula\$grupo"
    if (-not (Test-Path $jGrupo)) {
        cmd /c "mklink /J `"$jGrupo`" `"$FTP_ROOT\LocalUser\$grupo`"" | Out-Null
        Print-Ok "  Junction '$grupo' creado."
    } else {
        Print-Info "  Junction '$grupo' ya existe."
    }

    Print-Ok "Jaula lista para '$usuario'."
}

# ============================================================================
# FUNCION: Destruir jaula del usuario
# ============================================================================
function Destruir-Jaula-Usuario {
    param([string]$usuario)

    Print-Info "Eliminando jaula de '$usuario'..."

    $jaula = "$FTP_ROOT\LocalUser\$usuario"

    # Eliminar junctions con rmdir (NO usar Remove-Item, borraria el contenido real)
    foreach ($junc in @("general", $GRUPO_REPROBADOS, $GRUPO_RECURSADORES)) {
        $juncPath = "$jaula\$junc"
        if (Test-Path $juncPath) {
            cmd /c "rmdir `"$juncPath`"" | Out-Null
            Print-Ok "  Junction '$junc' eliminado."
        }
    }

    # Eliminar carpeta home
    $jaula = "$FTP_ROOT\LocalUser\$usuario"
    if (Test-Path $jaula) {
        Remove-Item -Path $jaula -Recurse -Force
        Print-Ok "  Carpeta home eliminada."
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
        Print-Error "Solo letras, numeros, - y _. Debe iniciar con letra."; return $false
    }
    if (Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue) {
        Print-Error "El usuario '$usuario' ya existe."; return $false
    }
    return $true
}

# ============================================================================
# FUNCION: Crear usuario FTP
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

    # Otorgar derecho de logon local (requerido por IIS FTP)
    Grant-FTPLogonRight -Username $usuario

    # Agregar al grupo
    $otroGrupo = if ($grupo -eq $GRUPO_REPROBADOS) { $GRUPO_RECURSADORES } else { $GRUPO_REPROBADOS }
    Remove-LocalGroupMember -Group $otroGrupo -Member $usuario -ErrorAction SilentlyContinue
    Add-LocalGroupMember    -Group $grupo      -Member $usuario -ErrorAction SilentlyContinue
    Print-Ok "Usuario agregado al grupo '$grupo'."

    # Construir jaula con Virtual Directories
    Construir-Jaula-Usuario -usuario $usuario -grupo $grupo

    Write-Host ""
    Print-Ok "═══════════════════════════════════════════"
    Print-Ok "  Usuario '$usuario' creado correctamente"
    Print-Ok "═══════════════════════════════════════════"
    Print-Info "  Estructura al conectar por FTP:"
    Print-Info "    /general/      (publica, todos leen y escriben)"
    Print-Info "    /$grupo/       (solo tu grupo)"
    Print-Info "    /$usuario/     (personal)"
    Print-Ok "═══════════════════════════════════════════"

    return $true
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

    Print-Info "Cambiando '$usuario': '$grupoActual' -> '$nuevoGrupo'..."

    # Cambiar grupo local
    if ($grupoActual) {
        Remove-LocalGroupMember -Group $grupoActual -Member $usuario -ErrorAction SilentlyContinue
        Print-Ok "Removido de '$grupoActual'."
    }
    Add-LocalGroupMember -Group $nuevoGrupo -Member $usuario -ErrorAction SilentlyContinue
    Print-Ok "Agregado a '$nuevoGrupo'."

    # Actualizar junctions: eliminar la del grupo viejo y crear la nueva
    $jaula = "$FTP_ROOT\LocalUser\$usuario"

    if ($grupoActual) {
        $juncViejo = "$jaula\$grupoActual"
        if (Test-Path $juncViejo) {
            cmd /c "rmdir `"$juncViejo`"" | Out-Null
            Print-Ok "Junction '$grupoActual' eliminado."
        }
    }

    $juncNuevo = "$jaula\$nuevoGrupo"
    if (-not (Test-Path $juncNuevo)) {
        cmd /c "mklink /J `"$juncNuevo`" `"$FTP_ROOT\LocalUser\$nuevoGrupo`"" | Out-Null
        Print-Ok "Junction '$nuevoGrupo' creado."
    }

    Print-Ok "Usuario '$usuario' movido a '$nuevoGrupo'."
    Print-Info "Nueva estructura FTP:"
    Print-Info "  /general/       (publica)"
    Print-Info "  /$nuevoGrupo/   (nuevo grupo)"
    Print-Info "  /$usuario/      (personal)"
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
        $result = Install-WindowsFeature -Name Web-Server, Web-Ftp-Server, Web-Ftp-Service, Web-Mgmt-Console `
            -IncludeManagementTools
        if ($result.Success) { Print-Ok "IIS y FTP instalados." }
        else { Print-Error "Error en la instalacion."; return }
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
    Print-Ok "══════════════════════════════════════════════"
    Print-Ok "  Servidor FTP listo"
    Print-Ok "══════════════════════════════════════════════"
    Print-Info "  IP     : $ip"
    Print-Info "  Puerto : 21"
    Print-Info "  Anon   : ftp://$ip  (solo lectura en /general)"
    Print-Ok "══════════════════════════════════════════════"
    Print-Info "Cree usuarios con: .\ftp_server.ps1 -users"
}

# ============================================================================
# FUNCION: Gestionar usuarios FTP
# ============================================================================
function Gestionar-Usuarios {
    Print-Titulo "Gestion de Usuarios FTP"

    if (-not (Verificar-Instalacion)) {
        Print-Error "IIS/FTP no instalado. Ejecute: .\ftp_server.ps1 -install"
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
                    default { Print-Warn "Opcion invalida, asignando a reprobados."; $GRUPO_REPROBADOS }
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
            $confirmar = Read-Host "Confirma eliminar '$usuario'? [s/N]"
            if ($confirmar -match '^[Ss]$') {
                Destruir-Jaula-Usuario -usuario $usuario
                Remove-LocalUser -Name $usuario -ErrorAction SilentlyContinue
                Print-Ok "Usuario '$usuario' eliminado."
            } else { Print-Info "Cancelado." }
        }

        "4" {
            Listar-Usuarios-FTP
            $usuario = (Read-Host "Nombre del usuario").Trim()
            if (-not (Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue)) {
                Print-Error "Usuario '$usuario' no existe."; return
            }
            $newPass = (Read-Host "Nueva contrasena").Trim()
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
            $nombre = $m.Name -replace ".*\\", ""
            $jaulaOk = Test-Path "$FTP_ROOT\LocalUser\$nombre"
            $usuarios += [PSCustomObject]@{
                Usuario  = $nombre
                Grupo    = $grupo
                Jaula    = if ($jaulaOk) { "OK" } else { "FALTA" }
            }
        }
    }

    if ($usuarios.Count -eq 0) { Print-Info "No hay usuarios FTP configurados."; return }
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

    # Sitio
    $estado = & "$env:SystemRoot\System32\inetsrv\appcmd.exe" list site $FTP_SITE_NAME 2>$null
    Write-Host "  Sitio IIS       : $estado"

    # Isolation mode
    $isolation = (Get-ItemProperty "IIS:\Sites\$FTP_SITE_NAME" `
        -Name "ftpServer.userIsolation.mode" -ErrorAction SilentlyContinue).Value
    $isoText = switch ($isolation) {
        3 { "IsolateAllDirectories (correcto)" }
        0 { "Sin aislamiento (incorrecto)" }
        default { "Modo $isolation" }
    }
    Write-Host "  User Isolation  : $isoText"

    Write-Host ""
    Print-Info "Conexiones activas en puerto 21:"
    netstat -an | Select-String ":21 "

    Write-Host ""
    Listar-Usuarios-FTP
}

# ============================================================================
# FUNCION: Proteger carpetas base contra eliminacion accidental
# ============================================================================
function Proteger-CarpetasBase {
    $carpetas = @(
        "$FTP_ROOT\LocalUser\Public\general",
        "$FTP_ROOT\LocalUser\reprobados",
        "$FTP_ROOT\LocalUser\recursadores"
    )

    foreach ($carpeta in $carpetas) {
        if (Test-Path $carpeta) {
            # Denegar explicitamente "Delete" y "DeleteSubdirectoriesAndFiles" a todos
            $acl = Get-Acl $carpeta
            $denyAll = New-Object System.Security.Principal.SecurityIdentifier("S-1-1-0") # Everyone
            $denyRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $denyAll, "Delete,DeleteSubdirectoriesAndFiles",
                "None", "None", "Deny"
            )
            $acl.AddAccessRule($denyRule)
            Set-Acl -Path $carpeta -AclObject $acl
            Print-Ok "Carpeta protegida contra eliminacion: $carpeta"
        }
    }
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
    & "$env:SystemRoot\System32\inetsrv\appcmd.exe" start site $FTP_SITE_NAME
    Print-Ok "Servidor FTP reiniciado."
}

# ============================================================================
# FUNCION: Mostrar ayuda
# ============================================================================
function Mostrar-Ayuda {
    Clear-Host
    Write-Host ""
    Write-Host "Selecciona una opcion" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "  -install   Instala y configura el servidor FTP (primera vez)"
    Write-Host "  -users     Gestionar usuarios (crear, cambiar grupo, eliminar)"
    Write-Host "  -status    Ver estado del servidor y usuarios"
    Write-Host "  -restart   Reiniciar el servicio FTP"
    Write-Host "  -verify    Verificar si IIS y FTP estan instalados"
    Write-Host "  -list      Listar usuarios y estructura"
    Write-Host "  -help      Mostrar esta ayuda"
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
