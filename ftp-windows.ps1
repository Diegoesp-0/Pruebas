param(
    [Alias("i")][switch]$install,
    [Alias("u")][switch]$users,
    [Alias("r")][switch]$restart,
    [Alias("s")][switch]$status,
    [Alias("l")][switch]$list,
    [Alias("v")][switch]$verify,
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
# Utilidades de color
# ============================================================================
function Print-Info   { param($msg) Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Print-Ok     { param($msg) Write-Host "[OK]    $msg" -ForegroundColor Green }
function Print-Error  { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Print-Warn   { param($msg) Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Print-Titulo { param($msg) Write-Host "`n=== $msg ===`n" -ForegroundColor Yellow }

# ============================================================================
# Variables Globales
# ============================================================================
$FTP_ROOT           = "C:\ftp"
$GRUPO_REPROBADOS   = "reprobados"
$GRUPO_RECURSADORES = "recursadores"
$FTP_SITE_NAME      = "ServidorFTP"
$FTP_PORT           = 21
$APPCMD             = "$env:SystemRoot\System32\inetsrv\appcmd.exe"

# ============================================================================
# Resolver identidades por SID (independiente del idioma del SO)
# ============================================================================
function Resolve-SID {
    param([string]$Sid)
    return (New-Object System.Security.Principal.SecurityIdentifier($Sid)).Translate(
        [System.Security.Principal.NTAccount])
}

$ID_ADMINS = Resolve-SID "S-1-5-32-544"   # Administrators
$ID_SYSTEM = Resolve-SID "S-1-5-18"       # SYSTEM
$ID_AUTH   = Resolve-SID "S-1-5-11"       # Authenticated Users
$ID_IUSR   = Resolve-SID "S-1-5-17"       # IUSR

# ============================================================================
# Crear regla ACL
# ============================================================================
function New-ACLRule {
    param(
        [object]$Identity,
        [string]$Rights = "FullControl",
        [string]$Type   = "Allow"
    )
    return New-Object System.Security.AccessControl.FileSystemAccessRule(
        $Identity, $Rights, "ContainerInherit,ObjectInherit", "None", $Type
    )
}

# ============================================================================
# Aplicar ACL limpia (sin herencia, solo las reglas indicadas)
# ============================================================================
function Set-FolderACL {
    param(
        [string]$Path,
        [System.Security.AccessControl.FileSystemAccessRule[]]$Rules
    )
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in $Rules) { $acl.AddAccessRule($rule) }
    Set-Acl -Path $Path -AclObject $acl
}

# ============================================================================
# Otorgar "Log on locally" (SeInteractiveLogonRight) via secedit
# ============================================================================
function Grant-LogonRight {
    param([string]$Username)

    $exportInf = "$env:TEMP\sec_export.inf"
    $applyInf  = "$env:TEMP\sec_apply.inf"
    $applyDb   = "$env:TEMP\sec_apply.sdb"

    & secedit /export /cfg $exportInf /quiet 2>$null
    $cfg   = Get-Content $exportInf -ErrorAction SilentlyContinue
    $linea = $cfg | Where-Object { $_ -match "^SeInteractiveLogonRight" }

    if ($linea -and $linea -match [regex]::Escape($Username)) {
        Print-Info "  '$Username' ya tiene SeInteractiveLogonRight."
        Remove-Item $exportInf -ErrorAction SilentlyContinue
        return
    }

    $nuevaLinea = if ($linea) { "$linea,$Username" } else { "SeInteractiveLogonRight = $Username" }

    @"
[Unicode]
Unicode=yes
[Version]
signature="`$CHICAGO`$"
Revision=1
[Privilege Rights]
$nuevaLinea
"@ | Out-File -FilePath $applyInf -Encoding Unicode

    & secedit /configure /db $applyDb /cfg $applyInf /quiet 2>$null
    Remove-Item $exportInf, $applyInf, $applyDb -ErrorAction SilentlyContinue
    Print-Ok "  SeInteractiveLogonRight otorgado a '$Username'."
}

# ============================================================================
# Verificar instalacion IIS + FTP
# ============================================================================
function Verificar-Instalacion {
    Print-Info "Verificando instalacion de IIS y FTP..."
    $iis = Get-WindowsFeature -Name "Web-Server"     -ErrorAction SilentlyContinue
    $ftp = Get-WindowsFeature -Name "Web-Ftp-Server" -ErrorAction SilentlyContinue
    if ($iis.Installed -and $ftp.Installed) {
        Print-Ok "IIS y FTP Service instalados."
        return $true
    }
    if (-not $iis.Installed) { Print-Error "IIS (Web-Server) no instalado." }
    if (-not $ftp.Installed) { Print-Error "FTP (Web-Ftp-Server) no instalado." }
    return $false
}

# ============================================================================
# Firewall
# ============================================================================
function Configurar-Firewall {
    Print-Info "Configurando firewall..."
    if (-not (Get-NetFirewallRule -DisplayName "FTP Puerto 21" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "FTP Puerto 21" -Direction Inbound -Protocol TCP -LocalPort 21 -Action Allow | Out-Null
        Print-Ok "Puerto 21 abierto."
    } else { Print-Info "Regla puerto 21 ya existe." }

    if (-not (Get-NetFirewallRule -DisplayName "FTP Pasivo 40000-40100" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "FTP Pasivo 40000-40100" -Direction Inbound -Protocol TCP -LocalPort 40000-40100 -Action Allow | Out-Null
        Print-Ok "Puertos pasivos abiertos."
    } else { Print-Info "Regla puertos pasivos ya existe." }
}

# ============================================================================
# Crear grupos locales
# ============================================================================
function Crear-Grupos {
    Print-Info "Verificando grupos..."
    foreach ($g in @($GRUPO_REPROBADOS, $GRUPO_RECURSADORES)) {
        if (-not (Get-LocalGroup -Name $g -ErrorAction SilentlyContinue)) {
            New-LocalGroup -Name $g -Description "Grupo FTP $g" | Out-Null
            Print-Ok "Grupo '$g' creado."
        } else { Print-Info "Grupo '$g' ya existe." }
    }
}

# ============================================================================
# Estructura de directorios y permisos base
#
# C:\ftp\
#   LocalUser\
#     Public\          <- home anonimo (IUSR)
#       general\       <- carpeta publica compartida
#     reprobados\      <- carpeta del grupo reprobados
#     recursadores\    <- carpeta del grupo recursadores
#     <usuario>\       <- home del usuario (creado al crear usuario)
# ============================================================================
function Crear-Estructura-Base {
    Print-Info "Creando estructura de directorios..."

    foreach ($dir in @(
        $FTP_ROOT,
        "$FTP_ROOT\LocalUser",
        "$FTP_ROOT\LocalUser\Public",
        "$FTP_ROOT\LocalUser\Public\general",
        "$FTP_ROOT\LocalUser\reprobados",
        "$FTP_ROOT\LocalUser\recursadores"
    )) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Print-Ok "Creado: $dir"
        } else { Print-Info "Ya existe: $dir" }
    }

    # Raiz FTP: IUSR necesita leer para que IIS pueda resolver paths
    Set-FolderACL -Path $FTP_ROOT -Rules @(
        (New-ACLRule $ID_ADMINS "FullControl"),
        (New-ACLRule $ID_SYSTEM "FullControl"),
        (New-ACLRule $ID_IUSR   "ReadAndExecute"),
        (New-ACLRule $ID_AUTH   "ReadAndExecute")
    )

    # LocalUser: IIS recorre esta carpeta para encontrar homes
    Set-FolderACL -Path "$FTP_ROOT\LocalUser" -Rules @(
        (New-ACLRule $ID_ADMINS "FullControl"),
        (New-ACLRule $ID_SYSTEM "FullControl"),
        (New-ACLRule $ID_IUSR   "ReadAndExecute"),
        (New-ACLRule $ID_AUTH   "ReadAndExecute")
    )

    # Public: home del usuario anonimo
    Set-FolderACL -Path "$FTP_ROOT\LocalUser\Public" -Rules @(
        (New-ACLRule $ID_ADMINS "FullControl"),
        (New-ACLRule $ID_SYSTEM "FullControl"),
        (New-ACLRule $ID_IUSR   "ReadAndExecute"),
        (New-ACLRule $ID_AUTH   "ReadAndExecute")
    )

    # general: todos leen y escriben, anonimo solo lee
    Set-FolderACL -Path "$FTP_ROOT\LocalUser\Public\general" -Rules @(
        (New-ACLRule $ID_ADMINS "FullControl"),
        (New-ACLRule $ID_SYSTEM "FullControl"),
        (New-ACLRule $ID_AUTH   "Modify"),
        (New-ACLRule $ID_IUSR   "ReadAndExecute")
    )
    Print-Ok "Permisos 'general' configurados."

    # Carpetas de grupo: solo el grupo respectivo, anonimo sin acceso
    foreach ($g in @($GRUPO_REPROBADOS, $GRUPO_RECURSADORES)) {
        Set-FolderACL -Path "$FTP_ROOT\LocalUser\$g" -Rules @(
            (New-ACLRule $ID_ADMINS "FullControl"),
            (New-ACLRule $ID_SYSTEM "FullControl"),
            (New-ACLRule $g         "Modify")
        )
        Print-Ok "Permisos '$g' configurados."
    }

    Print-Ok "Estructura base lista."
}

# ============================================================================
# FIX SSL: editar applicationHost.config con XPath directo
# Evita el error 800710D8 que ocurre cuando no hay certificado instalado
# ============================================================================
function Fix-SSL-Config {
    param([string]$SiteName)

    $configFile = "$env:SystemRoot\System32\inetsrv\config\applicationHost.config"

    try {
        [xml]$xml = Get-Content $configFile -Encoding UTF8 -Raw

        $site = $xml.configuration.'system.applicationHost'.sites.site |
            Where-Object { $_.name -eq $SiteName }

        if (-not $site) { Print-Warn "  Sitio no encontrado en config."; return $false }

        $ftpServer = $site.ftpServer
        if (-not $ftpServer) { Print-Warn "  Nodo ftpServer no encontrado."; return $false }

        $security = $ftpServer.security
        if (-not $security) {
            $security = $xml.CreateElement("security")
            $ftpServer.AppendChild($security) | Out-Null
        }

        $ssl = $security.ssl
        if (-not $ssl) {
            $ssl = $xml.CreateElement("ssl")
            $security.AppendChild($ssl) | Out-Null
        }

        # 0 = SslAllow: permite conexiones sin cifrar (sin certificado)
        $ssl.SetAttribute("controlChannelPolicy", "0")
        $ssl.SetAttribute("dataChannelPolicy",    "0")
        $ssl.SetAttribute("serverCertHash",       "")
        $ssl.SetAttribute("serverCertStoreName",  "MY")

        $xml.Save($configFile)
        Print-Ok "  SSL = SslAllow (texto plano permitido)."
        return $true
    } catch {
        Print-Warn "  Error editando config SSL: $_"
        return $false
    }
}

# ============================================================================
# Configurar sitio FTP en IIS
# ============================================================================
function Configurar-FTP {
    Print-Info "Configurando sitio FTP..."

    Import-Module WebAdministration -ErrorAction Stop

    # 1. Parar el servicio FTP completamente antes de modificar config
    Print-Info "Deteniendo servicio FTP..."
    Stop-Service ftpsvc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3

    # 2. Eliminar sitio anterior via appcmd (evita errores de PS con 800710D8)
    $existe = & $APPCMD list site /site.name:"$FTP_SITE_NAME" 2>$null
    if ($existe) {
        & $APPCMD delete site /site.name:"$FTP_SITE_NAME" 2>$null
        Print-Info "Sitio anterior eliminado."
        Start-Sleep -Seconds 1
    }

    # 3. Crear sitio FTP con appcmd
    & $APPCMD add site /name:"$FTP_SITE_NAME" /id:2 /bindings:"ftp/*:21:" /physicalPath:"$FTP_ROOT" 2>$null
    Print-Ok "Sitio '$FTP_SITE_NAME' creado."
    Start-Sleep -Seconds 1

    # 4. FIX SSL: editar applicationHost.config ANTES de arrancar el servicio
    Print-Info "Configurando SSL en applicationHost.config..."
    Fix-SSL-Config -SiteName $FTP_SITE_NAME

    # 5. Arrancar servicio para cargar la nueva config
    Start-Service ftpsvc -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 4

    # 6. User Isolation modo 3 = IsolateAllDirectories
    #    Cada usuario enjaulado en C:\ftp\LocalUser\<usuario>\
    try {
        Set-ItemProperty "IIS:\Sites\$FTP_SITE_NAME" -Name "ftpServer.userIsolation.mode" -Value 3
        Print-Ok "User Isolation modo 3 activado."
    } catch {
        & $APPCMD set site "$FTP_SITE_NAME" /ftpServer.userIsolation.mode:3 2>$null
        Print-Ok "User Isolation modo 3 activado (via appcmd)."
    }

    # 7. Autenticacion basica y anonima
    try {
        Set-ItemProperty "IIS:\Sites\$FTP_SITE_NAME" `
            -Name "ftpServer.security.authentication.basicAuthentication.enabled"   -Value $true
        Set-ItemProperty "IIS:\Sites\$FTP_SITE_NAME" `
            -Name "ftpServer.security.authentication.anonymousAuthentication.enabled" -Value $true
        Print-Ok "Autenticacion basica y anonima habilitadas."
    } catch {
        & $APPCMD set site "$FTP_SITE_NAME" `
            /ftpServer.security.authentication.basicAuthentication.enabled:true `
            /ftpServer.security.authentication.anonymousAuthentication.enabled:true 2>$null
        Print-Ok "Autenticacion configurada (via appcmd)."
    }

    # 8. Puertos pasivos
    Set-WebConfigurationProperty -PSPath "IIS:\" `
        -Filter "system.ftpServer/firewallSupport" `
        -Name "lowDataChannelPort"  -Value 40000
    Set-WebConfigurationProperty -PSPath "IIS:\" `
        -Filter "system.ftpServer/firewallSupport" `
        -Name "highDataChannelPort" -Value 40100
    Print-Ok "Puertos pasivos 40000-40100 configurados."

    # 9. Reglas de autorizacion FTP
    Clear-WebConfiguration "/system.ftpServer/security/authorization" `
        -PSPath "IIS:\" -Location $FTP_SITE_NAME -ErrorAction SilentlyContinue

    # Anonimo: solo lectura
    Add-WebConfiguration "/system.ftpServer/security/authorization" `
        -PSPath "IIS:\" -Location $FTP_SITE_NAME `
        -Value @{ accessType="Allow"; users="?"; roles=""; permissions=1 } `
        -ErrorAction SilentlyContinue

    # Autenticados: lectura + escritura
    Add-WebConfiguration "/system.ftpServer/security/authorization" `
        -PSPath "IIS:\" -Location $FTP_SITE_NAME `
        -Value @{ accessType="Allow"; users="*"; roles=""; permissions=3 } `
        -ErrorAction SilentlyContinue

    Print-Ok "Reglas de autorizacion configuradas."

    # 10. Reinicio final
    Stop-Service ftpsvc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Service ftpsvc
    Start-Sleep -Seconds 4

    & $APPCMD start site /site.name:"$FTP_SITE_NAME" 2>$null
    Start-Sleep -Seconds 1

    $estadoFinal = & $APPCMD list site /site.name:"$FTP_SITE_NAME" 2>$null
    $svcStatus   = (Get-Service ftpsvc -ErrorAction SilentlyContinue).Status

    if ($svcStatus -eq "Running") { Print-Ok "Servicio ftpsvc: Running" }
    else { Print-Error "Servicio ftpsvc no esta corriendo: $svcStatus" }

    Print-Ok "Sitio: $estadoFinal"
}

# ============================================================================
# Construir jaula del usuario con junctions
#
# Resultado visible al conectarse por FTP:
#   /                    C:\ftp\LocalUser\<usuario>\
#   ├── general\         junction -> C:\ftp\LocalUser\Public\general
#   ├── reprobados\      junction -> C:\ftp\LocalUser\reprobados
#   └── <usuario>\       carpeta personal fisica
#
# FIX 530: La carpeta home C:\ftp\LocalUser\<usuario>\ DEBE tener
# IUSR con ReadAndExecute. IIS verifica el home bajo IUSR antes
# de autenticar al usuario. Sin esto => "530 home directory inaccessible"
# ============================================================================
function Construir-Jaula-Usuario {
    param([string]$usuario, [string]$grupo)

    Print-Info "Construyendo jaula FTP para '$usuario'..."

    $jaula    = "$FTP_ROOT\LocalUser\$usuario"
    $personal = "$jaula\$usuario"

    New-Item -ItemType Directory -Path $jaula    -Force -ErrorAction SilentlyContinue | Out-Null
    New-Item -ItemType Directory -Path $personal -Force -ErrorAction SilentlyContinue | Out-Null

    # Obtener cuenta del usuario via SID
    $userSID     = (Get-LocalUser -Name $usuario -ErrorAction Stop).SID
    $userAccount = $userSID.Translate([System.Security.Principal.NTAccount])

    # ===== FIX CRITICO PARA ERROR 530 =====
    # IIS FTP verifica el home del usuario bajo la cuenta IUSR ANTES de validar
    # credenciales. Si IUSR no tiene ReadAndExecute en la jaula => 530.
    Set-FolderACL -Path $jaula -Rules @(
        (New-ACLRule $ID_ADMINS   "FullControl"),
        (New-ACLRule $ID_SYSTEM   "FullControl"),
        (New-ACLRule $ID_IUSR     "ReadAndExecute"),
        (New-ACLRule $userAccount "Modify")
    )
    # ======================================

    # Carpeta personal: solo el usuario
    Set-FolderACL -Path $personal -Rules @(
        (New-ACLRule $ID_ADMINS   "FullControl"),
        (New-ACLRule $ID_SYSTEM   "FullControl"),
        (New-ACLRule $userAccount "Modify")
    )
    Print-Ok "  Carpeta personal: $personal"

    # Junctions: IIS FTP muestra junctions en el listing (no Virtual Directories)
    foreach ($juncInfo in @(
        @{ Name = "general"; Target = "$FTP_ROOT\LocalUser\Public\general" },
        @{ Name = $grupo;    Target = "$FTP_ROOT\LocalUser\$grupo" }
    )) {
        $jPath = "$jaula\$($juncInfo.Name)"
        if (Test-Path $jPath) { cmd /c "rmdir `"$jPath`"" 2>$null }
        cmd /c "mklink /J `"$jPath`" `"$($juncInfo.Target)`"" 2>$null
        if (Test-Path $jPath) { Print-Ok "  Junction '$($juncInfo.Name)' creado." }
        else { Print-Error "  Fallo junction '$($juncInfo.Name)'." }
    }

    Print-Ok "Jaula lista para '$usuario'."
}

# ============================================================================
# Destruir jaula del usuario
# ============================================================================
function Destruir-Jaula-Usuario {
    param([string]$usuario)

    Print-Info "Eliminando jaula de '$usuario'..."
    $jaula = "$FTP_ROOT\LocalUser\$usuario"

    foreach ($junc in @("general", $GRUPO_REPROBADOS, $GRUPO_RECURSADORES)) {
        $jPath = "$jaula\$junc"
        if (Test-Path $jPath) { cmd /c "rmdir `"$jPath`"" 2>$null; Print-Ok "  Junction '$junc' eliminado." }
    }

    if (Test-Path $jaula) {
        Remove-Item -Path $jaula -Recurse -Force -ErrorAction SilentlyContinue
        Print-Ok "  Home del usuario eliminado."
    }
}

# ============================================================================
# Validar nombre de usuario
# ============================================================================
function Validar-Usuario {
    param([string]$usuario)
    if ([string]::IsNullOrEmpty($usuario))                           { Print-Error "Nombre vacio.";                                   return $false }
    if ($usuario.Length -lt 3 -or $usuario.Length -gt 20)          { Print-Error "Entre 3 y 20 caracteres.";                        return $false }
    if ($usuario -notmatch '^[a-zA-Z][a-zA-Z0-9_-]*$')             { Print-Error "Solo letras/numeros/_/-. Debe iniciar con letra."; return $false }
    if (Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue) { Print-Error "El usuario '$usuario' ya existe.";                return $false }
    return $true
}

# ============================================================================
# Crear usuario FTP
# ============================================================================
function Crear-Usuario-FTP {
    param([string]$usuario, [string]$password, [string]$grupo)

    Print-Info "Creando usuario '$usuario' en grupo '$grupo'..."

    $secPass = ConvertTo-SecureString $password -AsPlainText -Force
    try {
        New-LocalUser -Name $usuario -Password $secPass `
            -PasswordNeverExpires -UserMayNotChangePassword `
            -Description "Usuario FTP - $grupo" | Out-Null
        Print-Ok "Usuario del sistema creado."
    } catch {
        Print-Error "Error al crear '$usuario': $_"
        return $false
    }

    Start-Sleep -Seconds 1
    Grant-LogonRight -Username $usuario

    $otroGrupo = if ($grupo -eq $GRUPO_REPROBADOS) { $GRUPO_RECURSADORES } else { $GRUPO_REPROBADOS }
    Remove-LocalGroupMember -Group $otroGrupo -Member $usuario -ErrorAction SilentlyContinue
    Add-LocalGroupMember    -Group $grupo      -Member $usuario -ErrorAction SilentlyContinue
    Print-Ok "Agregado al grupo '$grupo'."

    Construir-Jaula-Usuario -usuario $usuario -grupo $grupo

    Write-Host ""
    Print-Ok "══════════════════════════════════════════"
    Print-Ok "  Usuario '$usuario' creado correctamente"
    Print-Ok "══════════════════════════════════════════"
    Print-Info "  /general/    (publica - todos leen y escriben)"
    Print-Info "  /$grupo/     (solo tu grupo)"
    Print-Info "  /$usuario/   (carpeta personal)"
    Print-Ok "══════════════════════════════════════════"

    return $true
}

# ============================================================================
# Cambiar usuario de grupo
# ============================================================================
function Cambiar-Grupo-Usuario {
    param([string]$usuario)

    if (-not (Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue)) {
        Print-Error "El usuario '$usuario' no existe."; return
    }

    $grupoActual = $null
    foreach ($g in @($GRUPO_REPROBADOS, $GRUPO_RECURSADORES)) {
        $miembros = Get-LocalGroupMember -Group $g -ErrorAction SilentlyContinue
        if ($miembros | Where-Object { ($_.Name -replace "^.*\\","") -eq $usuario }) {
            $grupoActual = $g; break
        }
    }

    Print-Info "Grupo actual de '$usuario': $(if ($grupoActual) { $grupoActual } else { '(ninguno)' })"
    Write-Host "  1) $GRUPO_REPROBADOS"
    Write-Host "  2) $GRUPO_RECURSADORES"
    $op = Read-Host "Nuevo grupo [1-2]"
    $nuevoGrupo = switch ($op) {
        "1" { $GRUPO_REPROBADOS } "2" { $GRUPO_RECURSADORES }
        default { Print-Error "Invalido."; return }
    }

    if ($grupoActual -eq $nuevoGrupo) { Print-Info "Ya pertenece a '$nuevoGrupo'."; return }

    if ($grupoActual) { Remove-LocalGroupMember -Group $grupoActual -Member $usuario -ErrorAction SilentlyContinue }
    Add-LocalGroupMember -Group $nuevoGrupo -Member $usuario -ErrorAction SilentlyContinue
    Print-Ok "Grupo cambiado a '$nuevoGrupo'."

    $jaula = "$FTP_ROOT\LocalUser\$usuario"
    if ($grupoActual) {
        $jViejo = "$jaula\$grupoActual"
        if (Test-Path $jViejo) { cmd /c "rmdir `"$jViejo`"" 2>$null; Print-Ok "Junction '$grupoActual' eliminado." }
    }
    $jNuevo = "$jaula\$nuevoGrupo"
    if (Test-Path $jNuevo) { cmd /c "rmdir `"$jNuevo`"" 2>$null }
    cmd /c "mklink /J `"$jNuevo`" `"$FTP_ROOT\LocalUser\$nuevoGrupo`"" 2>$null
    Print-Ok "Junction '$nuevoGrupo' creado."

    # Actualizar permisos de la jaula (IUSR sigue presente)
    $userSID     = (Get-LocalUser -Name $usuario).SID
    $userAccount = $userSID.Translate([System.Security.Principal.NTAccount])
    Set-FolderACL -Path $jaula -Rules @(
        (New-ACLRule $ID_ADMINS   "FullControl"),
        (New-ACLRule $ID_SYSTEM   "FullControl"),
        (New-ACLRule $ID_IUSR     "ReadAndExecute"),
        (New-ACLRule $userAccount "Modify")
    )
    Print-Ok "Usuario '$usuario' movido a '$nuevoGrupo'."
}

# ============================================================================
# Instalar y configurar servidor FTP
# ============================================================================
function Instalar-FTP {
    Print-Titulo "Instalacion y Configuracion de Servidor FTP"

    if (Verificar-Instalacion) {
        $r = Read-Host "IIS y FTP ya instalados. Reconfigurar? [s/N]"
        if ($r -notmatch '^[Ss]$') { Print-Info "Cancelado."; return }
    } else {
        Print-Info "Instalando IIS y FTP Service..."
        $res = Install-WindowsFeature -Name Web-Server,Web-Ftp-Server,Web-Ftp-Service,Web-Mgmt-Console -IncludeManagementTools
        if ($res.Success) { Print-Ok "Instalacion completada." } else { Print-Error "Error en la instalacion."; return }
    }

    Import-Module WebAdministration -ErrorAction Stop

    Crear-Grupos
    Crear-Estructura-Base
    Configurar-FTP
    Configurar-Firewall

    # Re-aplicar permisos de jaulas existentes (usuarios creados antes del fix)
    Print-Info "Actualizando permisos de usuarios existentes..."
    foreach ($g in @($GRUPO_REPROBADOS, $GRUPO_RECURSADORES)) {
        $miembros = Get-LocalGroupMember -Group $g -ErrorAction SilentlyContinue
        foreach ($m in $miembros) {
            $nombre = $m.Name -replace ".*\\", ""
            $jaula  = "$FTP_ROOT\LocalUser\$nombre"
            if (Test-Path $jaula) {
                $u = Get-LocalUser -Name $nombre -ErrorAction SilentlyContinue
                if ($u) {
                    $ua = $u.SID.Translate([System.Security.Principal.NTAccount])
                    Set-FolderACL -Path $jaula -Rules @(
                        (New-ACLRule $ID_ADMINS "FullControl"),
                        (New-ACLRule $ID_SYSTEM "FullControl"),
                        (New-ACLRule $ID_IUSR   "ReadAndExecute"),
                        (New-ACLRule $ua        "Modify")
                    )
                    Print-Ok "  Permisos actualizados: '$nombre'"
                }
            }
        }
    }

    $ip = (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.InterfaceAlias -notmatch "Loopback" } |
        Select-Object -First 1).IPAddress

    Write-Host ""
    Print-Ok "══════════════════════════════════════════════════"
    Print-Ok "  Servidor FTP listo"
    Print-Ok "══════════════════════════════════════════════════"
    Print-Info "  IP      : $ip"
    Print-Info "  Puerto  : 21"
    Print-Info "  Anonimo : ftp://$ip  (solo lectura en /general)"
    Print-Ok "══════════════════════════════════════════════════"
    Print-Info "Siguiente paso: .\ftp-windows.ps1 -users"
}

# ============================================================================
# Listar usuarios FTP
# ============================================================================
function Listar-Usuarios-FTP {
    Print-Titulo "Usuarios FTP"
    $lista = @()
    foreach ($g in @($GRUPO_REPROBADOS, $GRUPO_RECURSADORES)) {
        $miembros = Get-LocalGroupMember -Group $g -ErrorAction SilentlyContinue
        foreach ($m in $miembros) {
            $nombre = $m.Name -replace ".*\\", ""
            $lista += [PSCustomObject]@{
                Usuario = $nombre
                Grupo   = $g
                Jaula   = if (Test-Path "$FTP_ROOT\LocalUser\$nombre") { "OK" } else { "FALTA" }
            }
        }
    }
    if ($lista.Count -eq 0) { Print-Info "Sin usuarios FTP."; return }
    $lista | Format-Table -AutoSize
}

# ============================================================================
# Gestionar usuarios
# ============================================================================
function Gestionar-Usuarios {
    Print-Titulo "Gestion de Usuarios FTP"

    if (-not (Verificar-Instalacion)) {
        Print-Error "IIS/FTP no instalado. Ejecute: .\ftp-windows.ps1 -install"
        return
    }
    Import-Module WebAdministration -ErrorAction SilentlyContinue

    Write-Host "  1) Crear nuevos usuarios"
    Write-Host "  2) Cambiar grupo de un usuario"
    Write-Host "  3) Eliminar usuario"
    Write-Host "  4) Cambiar contrasena de usuario"
    Write-Host "  5) Volver"
    Write-Host ""
    $op = Read-Host "Seleccione [1-5]"

    switch ($op) {
        "1" {
            $num = Read-Host "Cuantos usuarios?"
            if (-not ($num -match '^\d+$') -or [int]$num -lt 1) { Print-Error "Numero invalido."; return }

            for ($i = 1; $i -le [int]$num; $i++) {
                Write-Host ""; Print-Titulo "Usuario $i de $num"

                do   { $usuario  = (Read-Host "Nombre de usuario").Trim() } while (-not (Validar-Usuario $usuario))
                do   { $password = (Read-Host "Contrasena").Trim()        } while ([string]::IsNullOrWhiteSpace($password))

                Write-Host "  1) $GRUPO_REPROBADOS"
                Write-Host "  2) $GRUPO_RECURSADORES"
                $gOp   = Read-Host "Grupo [1-2]"
                $grupo = switch ($gOp) {
                    "1"     { $GRUPO_REPROBADOS }
                    "2"     { $GRUPO_RECURSADORES }
                    default { Print-Warn "Invalido, asignando reprobados."; $GRUPO_REPROBADOS }
                }
                Crear-Usuario-FTP -usuario $usuario -password $password -grupo $grupo
            }
        }
        "2" { Listar-Usuarios-FTP; $u = (Read-Host "Usuario").Trim(); Cambiar-Grupo-Usuario $u }
        "3" {
            Listar-Usuarios-FTP
            $u = (Read-Host "Usuario a eliminar").Trim()
            if (-not (Get-LocalUser -Name $u -ErrorAction SilentlyContinue)) { Print-Error "No existe."; return }
            $c = Read-Host "Confirma eliminar '$u'? [s/N]"
            if ($c -match '^[Ss]$') {
                Destruir-Jaula-Usuario $u
                Remove-LocalUser -Name $u -ErrorAction SilentlyContinue
                Print-Ok "Usuario '$u' eliminado."
            } else { Print-Info "Cancelado." }
        }
        "4" {
            Listar-Usuarios-FTP
            $u = (Read-Host "Nombre del usuario").Trim()
            if (-not (Get-LocalUser -Name $u -ErrorAction SilentlyContinue)) { Print-Error "No existe."; return }
            $np = (Read-Host "Nueva contrasena").Trim()
            Set-LocalUser -Name $u -Password (ConvertTo-SecureString $np -AsPlainText -Force)
            Print-Ok "Contrasena actualizada."
        }
        "5" { return }
        default { Print-Error "Opcion invalida." }
    }
}

# ============================================================================
# Estado del servidor
# ============================================================================
function Ver-Estado {
    Print-Titulo "ESTADO DEL SERVIDOR FTP"
    Import-Module WebAdministration -ErrorAction SilentlyContinue

    $svc = Get-Service -Name "ftpsvc" -ErrorAction SilentlyContinue
    if ($svc) {
        $color = if ($svc.Status -eq "Running") { "Green" } else { "Red" }
        Write-Host "  Servicio ftpsvc : " -NoNewline; Write-Host $svc.Status -ForegroundColor $color
    }

    $sitio = & $APPCMD list site /site.name:"$FTP_SITE_NAME" 2>$null
    Write-Host "  Sitio IIS       : $sitio"

    try {
        $iso = (Get-ItemProperty "IIS:\Sites\$FTP_SITE_NAME" -Name "ftpServer.userIsolation.mode" -ErrorAction Stop).Value
        $isoTxt = switch ($iso) { 3 { "IsolateAllDirectories (correcto)" } 0 { "Sin aislamiento (INCORRECTO)" } default { "Modo $iso" } }
        Write-Host "  User Isolation  : $isoTxt"
    } catch { Write-Host "  User Isolation  : (no se pudo leer)" -ForegroundColor Yellow }

    Write-Host ""
    Print-Info "Conexiones en puerto 21:"
    netstat -an | Select-String ":21 "
    Write-Host ""
    Listar-Usuarios-FTP
}

# ============================================================================
# Reiniciar FTP
# ============================================================================
function Reiniciar-FTP {
    Print-Info "Reiniciando FTP..."
    Stop-Service ftpsvc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Service ftpsvc
    Start-Sleep -Seconds 3
    & $APPCMD start site /site.name:"$FTP_SITE_NAME" 2>$null
    Print-Ok "FTP reiniciado."
    Ver-Estado
}

# ============================================================================
# Ayuda
# ============================================================================
function Mostrar-Ayuda {
    Write-Host ""
    Write-Host "Uso: .\ftp-windows.ps1 [opcion]" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  -install  (-i)   Instalar y configurar servidor FTP"
    Write-Host "  -users    (-u)   Gestionar usuarios"
    Write-Host "  -status   (-s)   Ver estado del servidor"
    Write-Host "  -restart  (-r)   Reiniciar servicio FTP"
    Write-Host "  -verify   (-v)   Verificar si IIS y FTP estan instalados"
    Write-Host "  -list     (-l)   Listar usuarios"
    Write-Host "  -help            Esta ayuda"
    Write-Host ""
    Write-Host "Primera vez:" -ForegroundColor Yellow
    Write-Host "  1. .\ftp-windows.ps1 -install"
    Write-Host "  2. .\ftp-windows.ps1 -users"
    Write-Host ""
    Write-Host "Si persiste el error 530 en usuarios ya creados:" -ForegroundColor Yellow
    Write-Host "  .\ftp-windows.ps1 -install  (responder 's' a reconfigurar)"
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
