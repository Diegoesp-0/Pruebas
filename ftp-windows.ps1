param(
    [switch]$verify,
    [switch]$install,
    [switch]$users,
    [switch]$restart,
    [switch]$status,
    [switch]$list,
    [switch]$help
)

$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[ERROR] Este script debe ejecutarse como Administrador" -ForegroundColor Red
    exit 1
}

function Print-Info   { param($msg) Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Print-Ok     { param($msg) Write-Host "[OK]    $msg" -ForegroundColor Green }
function Print-Error  { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Print-Warn   { param($msg) Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Print-Titulo { param($msg) Write-Host "`n=== $msg ===`n" -ForegroundColor Magenta }

$FTP_ROOT           = "C:\ftp"
$GRUPO_REPROBADOS   = "reprobados"
$GRUPO_RECURSADORES = "recursadores"
$FTP_SITE_NAME      = "ServidorFTP"
$FTP_PORT           = 21

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

function New-ACLRule {
    param([object]$Identity, [string]$Rights = "FullControl", [string]$Type = "Allow")
    return New-Object System.Security.AccessControl.FileSystemAccessRule(
        $Identity, $Rights, "ContainerInherit,ObjectInherit", "None", $Type)
}

function Set-FolderACL {
    param([string]$Path, [System.Security.AccessControl.FileSystemAccessRule[]]$Rules)
    $acl = Get-Acl $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in $Rules) { $acl.AddAccessRule($rule) }
    Set-Acl -Path $Path -AclObject $acl
}

function Protect-FolderFromDeletion {
    param([string]$Path)
    $acl = Get-Acl $Path
    $denyRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $ID_EVERYONE, "Delete", "None", "None", "Deny")
    $acl.AddAccessRule($denyRule)
    Set-Acl -Path $Path -AclObject $acl
}

# FIX 1: Usar SeNetworkLogonRight en lugar de SeInteractiveLogonRight.
# FTP autentica via logon de red, no logon interactivo. Usar el derecho
# incorrecto no bloquea el login directamente pero puede causar 530 en
# configuraciones con politicas estrictas de "Deny logon locally".
function Write-SeceditInf {
    param([string]$Path, [string]$PrivilegeLine)
    $lines = @(
        "[Unicode]",
        "Unicode=yes",
        "[Version]",
        'signature="$CHICAGO$"',
        "Revision=1",
        "[Privilege Rights]",
        $PrivilegeLine
    )
    $lines | Out-File -FilePath $Path -Encoding Unicode
}

function Grant-FTPLogonRight {
    param([string]$Username)
    $exportInf = "$env:TEMP\secedit_export.inf"
    $applyInf  = "$env:TEMP\secedit_apply.inf"
    $applyDb   = "$env:TEMP\secedit_apply.sdb"

    & secedit /export /cfg $exportInf /quiet 2>$null
    $cfg = Get-Content $exportInf -ErrorAction SilentlyContinue

    # Otorgar SeNetworkLogonRight (logon de red — el correcto para FTP)
    $lineaNet = $cfg | Where-Object { $_ -match "^SeNetworkLogonRight" }
    if ($lineaNet -and $lineaNet -match [regex]::Escape($Username)) {
        Print-Info "  '$Username' ya tiene SeNetworkLogonRight."
    } else {
        $nuevaLineaNet = if ($lineaNet) { "$lineaNet,*$Username" } else { "SeNetworkLogonRight = *$Username" }
        Write-SeceditInf -Path $applyInf -PrivilegeLine $nuevaLineaNet
        & secedit /configure /db $applyDb /cfg $applyInf /quiet 2>$null
        Remove-Item $applyInf, $applyDb -ErrorAction SilentlyContinue
        Print-Ok "  SeNetworkLogonRight otorgado a '$Username'."
    }

    # Asegurarse de que el usuario NO este en la lista de denegacion de logon de red
    $lineaDeny = $cfg | Where-Object { $_ -match "^SeDenyNetworkLogonRight" }
    if ($lineaDeny -and $lineaDeny -match [regex]::Escape($Username)) {
        Print-Warn "  '$Username' esta en SeDenyNetworkLogonRight — removiendo..."
        $nuevaLineaDeny = ($lineaDeny -replace ",?\*?$Username", "").TrimEnd(",")
        $applyDb2 = "$env:TEMP\secedit_apply2.sdb"
        Write-SeceditInf -Path $applyInf -PrivilegeLine $nuevaLineaDeny
        & secedit /configure /db $applyDb2 /cfg $applyInf /quiet 2>$null
        Remove-Item $applyInf, $applyDb2 -ErrorAction SilentlyContinue
        Print-Ok "  '$Username' removido de SeDenyNetworkLogonRight."
    }

    Remove-Item $exportInf -ErrorAction SilentlyContinue
}

function Verificar-Instalacion {
    Print-Info "Verificando instalacion de IIS y FTP..."
    $features = @("Web-Server","Web-Ftp-Server","Web-Ftp-Service","Web-Ftp-Ext")
    $allOk = $true
    foreach ($f in $features) {
        $feat = Get-WindowsFeature -Name $f -ErrorAction SilentlyContinue
        if ($feat -and $feat.Installed) { Print-Ok "$f instalado." }
        else { Print-Error "$f NO instalado."; $allOk = $false }
    }
    return $allOk
}

function Crear-Grupos {
    Print-Info "Verificando grupos del sistema..."
    foreach ($grupo in @($GRUPO_REPROBADOS, $GRUPO_RECURSADORES)) {
        if (-not (Get-LocalGroup -Name $grupo -ErrorAction SilentlyContinue)) {
            New-LocalGroup -Name $grupo -Description "Grupo FTP $grupo" | Out-Null
            Print-Ok "Grupo '$grupo' creado."
        } else { Print-Info "Grupo '$grupo' ya existe." }
    }
}

function Crear-Estructura-Base {
    Print-Info "Creando estructura de directorios..."

    $dirs = @(
        $FTP_ROOT,
        "$FTP_ROOT\LocalUser",
        "$FTP_ROOT\LocalUser\Public",
        "$FTP_ROOT\LocalUser\Public\general",
        "$FTP_ROOT\LocalUser\$GRUPO_REPROBADOS",
        "$FTP_ROOT\LocalUser\$GRUPO_RECURSADORES"
    )
    foreach ($dir in $dirs) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Print-Ok "Creado: $dir"
        } else { Print-Info "Ya existe: $dir" }
    }

    # Raiz: solo admins/system
    Set-FolderACL -Path $FTP_ROOT -Rules @(
        (New-ACLRule $ID_ADMINS "FullControl"),
        (New-ACLRule $ID_SYSTEM "FullControl")
    )

    # LocalUser: AUTH e IUSR necesitan ReadAndExecute para que IIS resuelva el home
    Set-FolderACL -Path "$FTP_ROOT\LocalUser" -Rules @(
        (New-ACLRule $ID_ADMINS "FullControl"),
        (New-ACLRule $ID_SYSTEM "FullControl"),
        (New-ACLRule $ID_AUTH   "ReadAndExecute"),
        (New-ACLRule $ID_IUSR   "ReadAndExecute")
    )
    Print-Ok "Permisos LocalUser configurados."

    # Public: home del anonimo
    Set-FolderACL -Path "$FTP_ROOT\LocalUser\Public" -Rules @(
        (New-ACLRule $ID_ADMINS "FullControl"),
        (New-ACLRule $ID_SYSTEM "FullControl"),
        (New-ACLRule $ID_IUSR   "ReadAndExecute")
    )

    # general: AUTH escribe, IUSR solo lee. Protegida contra borrado.
    Set-FolderACL -Path "$FTP_ROOT\LocalUser\Public\general" -Rules @(
        (New-ACLRule $ID_ADMINS "FullControl"),
        (New-ACLRule $ID_SYSTEM "FullControl"),
        (New-ACLRule $ID_AUTH   "Modify"),
        (New-ACLRule $ID_IUSR   "ReadAndExecute")
    )
    Protect-FolderFromDeletion "$FTP_ROOT\LocalUser\Public\general"
    Print-Ok "Permisos 'general' configurados."

    # reprobados: solo su grupo. Protegida contra borrado.
    Set-FolderACL -Path "$FTP_ROOT\LocalUser\$GRUPO_REPROBADOS" -Rules @(
        (New-ACLRule $ID_ADMINS        "FullControl"),
        (New-ACLRule $ID_SYSTEM        "FullControl"),
        (New-ACLRule $GRUPO_REPROBADOS "Modify")
    )
    Protect-FolderFromDeletion "$FTP_ROOT\LocalUser\$GRUPO_REPROBADOS"
    Print-Ok "Permisos '$GRUPO_REPROBADOS' configurados."

    # recursadores: solo su grupo. Protegida contra borrado.
    Set-FolderACL -Path "$FTP_ROOT\LocalUser\$GRUPO_RECURSADORES" -Rules @(
        (New-ACLRule $ID_ADMINS          "FullControl"),
        (New-ACLRule $ID_SYSTEM          "FullControl"),
        (New-ACLRule $GRUPO_RECURSADORES "Modify")
    )
    Protect-FolderFromDeletion "$FTP_ROOT\LocalUser\$GRUPO_RECURSADORES"
    Print-Ok "Permisos '$GRUPO_RECURSADORES' configurados."

    Print-Ok "Estructura base lista."
}

function Configurar-FTP {
    Print-Info "Configurando sitio FTP en IIS..."
    Import-Module WebAdministration -ErrorAction Stop

    if (Get-WebSite -Name $FTP_SITE_NAME -ErrorAction SilentlyContinue) {
        & "$env:SystemRoot\System32\inetsrv\appcmd.exe" stop site $FTP_SITE_NAME 2>$null
        Start-Sleep -Seconds 1
        Remove-WebSite -Name $FTP_SITE_NAME -ErrorAction SilentlyContinue
        Print-Info "Sitio anterior eliminado."
    }

    if (Get-WebSite -Name "Default Web Site" -ErrorAction SilentlyContinue) {
        Stop-WebSite -Name "Default Web Site" -ErrorAction SilentlyContinue
        Print-Info "Default Web Site detenido."
    }

    Stop-Service ftpsvc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Service ftpsvc
    Start-Sleep -Seconds 2

    New-WebFtpSite -Name $FTP_SITE_NAME -Port $FTP_PORT -PhysicalPath $FTP_ROOT -Force | Out-Null
    Print-Ok "Sitio '$FTP_SITE_NAME' creado."

    # Modo 3: cada usuario enjaulado en LocalUser\<usuario>
    Set-ItemProperty "IIS:\Sites\$FTP_SITE_NAME" -Name "ftpServer.userIsolation.mode" -Value 3
    Print-Ok "User Isolation: modo 3 (IsolateAllDirectories)."

    Set-ItemProperty "IIS:\Sites\$FTP_SITE_NAME" `
        -Name "ftpServer.security.authentication.basicAuthentication.enabled" -Value $true
    Set-ItemProperty "IIS:\Sites\$FTP_SITE_NAME" `
        -Name "ftpServer.security.authentication.anonymousAuthentication.enabled" -Value $true
    Print-Ok "Autenticacion basica y anonima habilitadas."

    Set-ItemProperty "IIS:\Sites\$FTP_SITE_NAME" `
        -Name "ftpServer.security.ssl.controlChannelPolicy" -Value "SslAllow"
    Set-ItemProperty "IIS:\Sites\$FTP_SITE_NAME" `
        -Name "ftpServer.security.ssl.dataChannelPolicy" -Value "SslAllow"
    Print-Ok "SSL configurado (SslAllow)."

    Set-WebConfigurationProperty -PSPath "IIS:\" `
        -Filter "system.ftpServer/firewallSupport" -Name "lowDataChannelPort"  -Value 40000
    Set-WebConfigurationProperty -PSPath "IIS:\" `
        -Filter "system.ftpServer/firewallSupport" -Name "highDataChannelPort" -Value 40100
    Print-Ok "Puertos pasivos 40000-40100 configurados."

    Clear-WebConfiguration "/system.ftpServer/security/authorization" `
        -PSPath "IIS:\" -Location $FTP_SITE_NAME -ErrorAction SilentlyContinue

    # Anonimo: solo lectura (permissions=1)
    Add-WebConfiguration "/system.ftpServer/security/authorization" `
        -PSPath "IIS:\" -Location $FTP_SITE_NAME `
        -Value @{ accessType="Allow"; users="?"; roles=""; permissions=1 } `
        -ErrorAction SilentlyContinue

    # Usuarios autenticados: lectura y escritura (permissions=3)
    Add-WebConfiguration "/system.ftpServer/security/authorization" `
        -PSPath "IIS:\" -Location $FTP_SITE_NAME `
        -Value @{ accessType="Allow"; users="*"; roles=""; permissions=3 } `
        -ErrorAction SilentlyContinue

    Print-Ok "Reglas de autorizacion FTP configuradas."

    # FIX 2: Habilitar explicitamente Windows Authentication provider en el sitio FTP.
    # Sin esto IIS puede rechazar credenciales validas con 530 aunque basicAuthentication
    # este en true, porque el provider subyacente no esta registrado en el sitio.
    $authProviders = Get-WebConfiguration "system.ftpServer/security/authentication/basicAuthentication" `
        -PSPath "IIS:\Sites\$FTP_SITE_NAME" -ErrorAction SilentlyContinue
    if ($null -eq $authProviders) {
        Print-Warn "No se pudo verificar el provider de autenticacion basica."
    }

    # Asegurarse de que el proveedor "IIS Manager" no este bloqueando
    Set-WebConfigurationProperty -PSPath "IIS:\Sites\$FTP_SITE_NAME" `
        -Filter "system.ftpServer/security/authentication/basicAuthentication" `
        -Name "enabled" -Value $true -ErrorAction SilentlyContinue

    Stop-Service ftpsvc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Service ftpsvc
    Start-Sleep -Seconds 3

    & "$env:SystemRoot\System32\inetsrv\appcmd.exe" start site $FTP_SITE_NAME 2>$null | Out-Null
    Start-Sleep -Seconds 2

    $escuchando = netstat -ano | Select-String ":$FTP_PORT "
    if ($escuchando) { Print-Ok "Puerto $FTP_PORT escuchando correctamente." }
    else { Print-Warn "Puerto $FTP_PORT no detectado aun. Verifique con -status." }
}

function Configurar-Firewall {
    Print-Info "Configurando firewall..."
    if (-not (Get-NetFirewallRule -DisplayName "FTP Puerto $FTP_PORT" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "FTP Puerto $FTP_PORT" `
            -Direction Inbound -Protocol TCP -LocalPort $FTP_PORT -Action Allow | Out-Null
        Print-Ok "Puerto $FTP_PORT abierto."
    } else { Print-Info "Regla puerto $FTP_PORT ya existe." }

    if (-not (Get-NetFirewallRule -DisplayName "FTP Pasivo 40000-40100" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "FTP Pasivo 40000-40100" `
            -Direction Inbound -Protocol TCP -LocalPort 40000-40100 -Action Allow | Out-Null
        Print-Ok "Puertos pasivos 40000-40100 abiertos."
    } else { Print-Info "Regla puertos pasivos ya existe." }
}

function Validar-Usuario {
    param([string]$usuario)
    if ([string]::IsNullOrEmpty($usuario))                           { Print-Error "El nombre no puede estar vacio.";               return $false }
    if ($usuario.Length -lt 3 -or $usuario.Length -gt 20)           { Print-Error "Debe tener entre 3 y 20 caracteres.";           return $false }
    if ($usuario -notmatch '^[a-zA-Z][a-zA-Z0-9_-]*$')              { Print-Error "Solo letras, numeros, guion y guion bajo.";     return $false }
    if (Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue) { Print-Error "El usuario '$usuario' ya existe.";             return $false }
    return $true
}

function Construir-Jaula-Usuario {
    param([string]$usuario, [string]$grupo)

    Print-Info "Construyendo jaula FTP para '$usuario'..."

    $jaula    = "$FTP_ROOT\LocalUser\$usuario"
    $personal = "$jaula\$usuario"

    if (-not (Test-Path $jaula))    { New-Item -ItemType Directory -Path $jaula    -Force | Out-Null }
    if (-not (Test-Path $personal)) { New-Item -ItemType Directory -Path $personal -Force | Out-Null }

    $userSID     = (Get-LocalUser -Name $usuario).SID
    $userAccount = $userSID.Translate([System.Security.Principal.NTAccount])

    # FIX 3: La jaula raiz (LocalUser\<usuario>) debe tener ReadAndExecute para el usuario,
    # NO Modify. IIS FTP con User Isolation modo 3 usa esta carpeta solo como punto de
    # montaje para resolver el home directory. Si el usuario tiene Modify aqui, IIS lo
    # interpreta como un perfil ambiguo y puede retornar 530 "home directory inaccessible".
    # El usuario accede a su contenido a traves de las subcarpetas (personal, junctions),
    # no directamente desde la raiz de la jaula.
    Set-FolderACL -Path $jaula -Rules @(
        (New-ACLRule $ID_ADMINS   "FullControl"),
        (New-ACLRule $ID_SYSTEM   "FullControl"),
        (New-ACLRule $userAccount "ReadAndExecute")
    )
    # FIX 4: No aplicar Protect-FolderFromDeletion en la jaula raiz.
    # El DENY Delete sobre la carpeta raiz de la jaula interfiere con el proceso
    # de IIS al intentar acceder al home directory del usuario, causando 530.
    # La proteccion se aplica solo a subcarpetas donde el usuario tiene Modify.

    # Carpeta personal: Modify + protegida contra borrado
    Set-FolderACL -Path $personal -Rules @(
        (New-ACLRule $ID_ADMINS   "FullControl"),
        (New-ACLRule $ID_SYSTEM   "FullControl"),
        (New-ACLRule $userAccount "Modify")
    )
    Protect-FolderFromDeletion $personal
    Print-Ok "  Carpeta personal: $personal"

    # Junction general -> C:\ftp\LocalUser\Public\general
    $jGeneral = "$jaula\general"
    if (-not (Test-Path $jGeneral)) {
        cmd /c "mklink /J `"$jGeneral`" `"$FTP_ROOT\LocalUser\Public\general`"" | Out-Null
        Print-Ok "  Junction 'general' creado."
    } else { Print-Info "  Junction 'general' ya existe." }

    # Junction grupo -> C:\ftp\LocalUser\<grupo>
    $jGrupo = "$jaula\$grupo"
    if (-not (Test-Path $jGrupo)) {
        cmd /c "mklink /J `"$jGrupo`" `"$FTP_ROOT\LocalUser\$grupo`"" | Out-Null
        Print-Ok "  Junction '$grupo' creado."
    } else { Print-Info "  Junction '$grupo' ya existe." }

    Print-Ok "Jaula lista para '$usuario'."
}

function Destruir-Jaula-Usuario {
    param([string]$usuario)
    Print-Info "Eliminando jaula de '$usuario'..."
    $jaula = "$FTP_ROOT\LocalUser\$usuario"

    foreach ($junc in @("general", $GRUPO_REPROBADOS, $GRUPO_RECURSADORES)) {
        $juncPath = "$jaula\$junc"
        if (Test-Path $juncPath) {
            cmd /c "rmdir `"$juncPath`"" | Out-Null
            Print-Ok "  Junction '$junc' eliminado."
        }
    }

    if (Test-Path $jaula) {
        foreach ($sub in @($jaula, "$jaula\$usuario")) {
            if (Test-Path $sub) {
                $acl = Get-Acl $sub -ErrorAction SilentlyContinue
                if ($acl) {
                    $acl.SetAccessRuleProtection($false, $true)
                    Set-Acl -Path $sub -AclObject $acl -ErrorAction SilentlyContinue
                }
            }
        }
        Remove-Item -Path $jaula -Recurse -Force -ErrorAction SilentlyContinue
        Print-Ok "  Carpeta home eliminada."
    }
}

function Crear-Usuario-FTP {
    param([string]$usuario, [string]$password, [string]$grupo)

    Print-Info "Creando usuario '$usuario' en grupo '$grupo'..."

    $securePass = ConvertTo-SecureString $password -AsPlainText -Force
    try {
        New-LocalUser -Name $usuario -Password $securePass `
            -PasswordNeverExpires -UserMayNotChangePassword `
            -Description "Usuario FTP - $grupo" | Out-Null
        Print-Ok "Usuario del sistema creado."
    } catch {
        Print-Error "Error al crear usuario '$usuario': $_"; return $false
    }

    Start-Sleep -Seconds 1
    Grant-FTPLogonRight -Username $usuario

    $otroGrupo = if ($grupo -eq $GRUPO_REPROBADOS) { $GRUPO_RECURSADORES } else { $GRUPO_REPROBADOS }
    Remove-LocalGroupMember -Group $otroGrupo -Member $usuario -ErrorAction SilentlyContinue
    Add-LocalGroupMember    -Group $grupo      -Member $usuario -ErrorAction SilentlyContinue
    Print-Ok "Usuario agregado al grupo '$grupo'."

    Construir-Jaula-Usuario -usuario $usuario -grupo $grupo

    Write-Host ""
    Print-Ok "═══════════════════════════════════════════════"
    Print-Ok "  Usuario '$usuario' creado correctamente"
    Print-Ok "═══════════════════════════════════════════════"
    Print-Info "  Al conectar por FTP vera unicamente:"
    Print-Info "    /general/      (publica: todos leen y escriben)"
    Print-Info "    /$grupo/       (solo tu grupo)"
    Print-Info "    /$usuario/     (personal)"
    Print-Ok "═══════════════════════════════════════════════"
    return $true
}

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

    Write-Host ""
    Write-Host "  1) $GRUPO_REPROBADOS"
    Write-Host "  2) $GRUPO_RECURSADORES"
    $opcion = Read-Host "Seleccione nuevo grupo [1-2]"

    $nuevoGrupo = switch ($opcion) {
        "1" { $GRUPO_REPROBADOS }
        "2" { $GRUPO_RECURSADORES }
        default { Print-Error "Opcion invalida."; return }
    }

    if ($grupoActual -eq $nuevoGrupo) { Print-Info "El usuario ya pertenece a '$nuevoGrupo'."; return }

    if ($grupoActual) {
        Remove-LocalGroupMember -Group $grupoActual -Member $usuario -ErrorAction SilentlyContinue
        Print-Ok "Removido de '$grupoActual'."
    }
    Add-LocalGroupMember -Group $nuevoGrupo -Member $usuario -ErrorAction SilentlyContinue
    Print-Ok "Agregado a '$nuevoGrupo'."

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
    Print-Info "  Nueva estructura: /general/  /$nuevoGrupo/  /$usuario/"
}

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
        if ($result.Success) { Print-Ok "IIS y FTP instalados." }
        else { Print-Error "Error en la instalacion."; return }
    }

    Import-Module WebAdministration -ErrorAction Stop
    Crear-Grupos
    Crear-Estructura-Base
    Configurar-FTP
    Configurar-Firewall

    $ip = (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -ne "127.0.0.1" } | Select-Object -First 1).IPAddress

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

function Gestionar-Usuarios {
    Print-Titulo "Gestion de Usuarios FTP"

    if (-not (Verificar-Instalacion)) {
        Print-Error "IIS/FTP no instalado. Ejecute primero: .\ftp_server.ps1 -install"; return
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
            if (-not ($num -match '^\d+$') -or [int]$num -lt 1) { Print-Error "Numero invalido."; return }
            for ($i = 1; $i -le [int]$num; $i++) {
                Write-Host ""
                Print-Titulo "Usuario $i de $num"
                do { $usuario  = (Read-Host "Nombre de usuario").Trim() } while (-not (Validar-Usuario -usuario $usuario))
                do { $password = (Read-Host "Contrasena").Trim() }        while ([string]::IsNullOrWhiteSpace($password))
                Write-Host "  1) $GRUPO_REPROBADOS"
                Write-Host "  2) $GRUPO_RECURSADORES"
                $gOp = Read-Host "Grupo [1-2]"
                $grupo = switch ($gOp) {
                    "1" { $GRUPO_REPROBADOS }
                    "2" { $GRUPO_RECURSADORES }
                    default { Print-Warn "Opcion invalida, asignando a $GRUPO_REPROBADOS."; $GRUPO_REPROBADOS }
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
            if (-not (Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue)) { Print-Error "Usuario no existe."; return }
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
            if (-not (Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue)) { Print-Error "Usuario no existe."; return }
            $newPass = (Read-Host "Nueva contrasena").Trim()
            if ([string]::IsNullOrWhiteSpace($newPass)) { Print-Error "La contrasena no puede estar vacia."; return }
            Set-LocalUser -Name $usuario -Password (ConvertTo-SecureString $newPass -AsPlainText -Force)
            Print-Ok "Contrasena de '$usuario' actualizada."
        }
        "5" { return }
        default { Print-Error "Opcion invalida." }
    }
}

function Listar-Usuarios-FTP {
    Print-Titulo "Usuarios FTP Configurados"
    $usuarios = @()
    foreach ($grupo in @($GRUPO_REPROBADOS, $GRUPO_RECURSADORES)) {
        $miembros = Get-LocalGroupMember -Group $grupo -ErrorAction SilentlyContinue
        foreach ($m in $miembros) {
            $nombre = $m.Name -replace ".*\\", ""
            $usuarios += [PSCustomObject]@{
                Usuario = $nombre
                Grupo   = $grupo
                Jaula   = if (Test-Path "$FTP_ROOT\LocalUser\$nombre") { "OK" } else { "FALTA" }
            }
        }
    }
    if ($usuarios.Count -eq 0) { Print-Info "No hay usuarios FTP configurados."; return }
    $usuarios | Format-Table -AutoSize
}

function Ver-Estado {
    Print-Titulo "ESTADO DEL SERVIDOR FTP"
    Import-Module WebAdministration -ErrorAction SilentlyContinue

    $svc = Get-Service -Name "ftpsvc" -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Host "  Servicio ftpsvc : " -NoNewline
        Write-Host $svc.Status -ForegroundColor $(if ($svc.Status -eq "Running") { "Green" } else { "Red" })
    }

    $estadoSitio = & "$env:SystemRoot\System32\inetsrv\appcmd.exe" list site $FTP_SITE_NAME 2>$null
    Write-Host "  Sitio IIS       : $estadoSitio"

    $puerto = netstat -ano | Select-String ":$FTP_PORT "
    Write-Host "  Puerto $FTP_PORT      : " -NoNewline
    if ($puerto) { Write-Host "ESCUCHANDO" -ForegroundColor Green }
    else         { Write-Host "NO ESCUCHA"  -ForegroundColor Red }

    $isolation = (Get-ItemProperty "IIS:\Sites\$FTP_SITE_NAME" `
        -Name "ftpServer.userIsolation.mode" -ErrorAction SilentlyContinue).Value
    Write-Host "  User Isolation  : $(switch ($isolation) { 3 { 'IsolateAllDirectories (correcto)' } 0 { 'Sin aislamiento' } default { "Modo $isolation" } })"

    Write-Host ""
    Listar-Usuarios-FTP
}

function Reiniciar-FTP {
    Print-Info "Reiniciando servidor FTP..."
    Stop-Service ftpsvc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Service ftpsvc
    Start-Sleep -Seconds 2
    & "$env:SystemRoot\System32\inetsrv\appcmd.exe" start site $FTP_SITE_NAME 2>$null | Out-Null
    $puerto = netstat -ano | Select-String ":$FTP_PORT "
    if ($puerto) { Print-Ok "Servidor FTP reiniciado. Puerto $FTP_PORT escuchando." }
    else         { Print-Warn "Reiniciado pero puerto $FTP_PORT no detectado aun." }
}

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

if     ($verify)  { Verificar-Instalacion }
elseif ($install) { Instalar-FTP }
elseif ($users)   { Gestionar-Usuarios }
elseif ($restart) { Reiniciar-FTP }
elseif ($status)  { Ver-Estado }
elseif ($list)    { Listar-Usuarios-FTP }
elseif ($help)    { Mostrar-Ayuda }
else              { Mostrar-Ayuda }
