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
function Print-Titulo { param($msg) Write-Host "`n=== $msg ===`n" -ForegroundColor Yellow }

$FTP_ROOT           = "C:\ftp"
$GRUPO_REPROBADOS   = "reprobados"
$GRUPO_RECURSADORES = "recursadores"
$FTP_SITE_NAME      = "ServidorFTP"
$FTP_PORT           = 21

# ---------------------------------------------------------------------------
# Resolucion de SIDs estandar
# ---------------------------------------------------------------------------
function Resolve-SID {
    param([string]$Sid)
    $sidObj = New-Object System.Security.Principal.SecurityIdentifier($Sid)
    return $sidObj.Translate([System.Security.Principal.NTAccount])
}

$ID_ADMINS = Resolve-SID "S-1-5-32-544"   # BUILTIN\Administrators
$ID_SYSTEM = Resolve-SID "S-1-5-18"        # NT AUTHORITY\SYSTEM
$ID_IUSR   = Resolve-SID "S-1-5-17"        # NT AUTHORITY\IUSR  (anonimo IIS)

# ---------------------------------------------------------------------------
# Helpers de ACL
# ---------------------------------------------------------------------------
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

function New-DenyDelete {
    param([object]$Identity)
    return New-Object System.Security.AccessControl.FileSystemAccessRule(
        $Identity,
        "Delete,DeleteSubdirectoriesAndFiles",
        "ContainerInherit,ObjectInherit",
        "None",
        "Deny"
    )
}

function Set-FolderACL {
    param(
        [string]$Path,
        [System.Security.AccessControl.FileSystemAccessRule[]]$Rules
    )
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)   # herencia desactivada, limpia
    foreach ($rule in $Rules) {
        $acl.AddAccessRule($rule)
    }
    Set-Acl -Path $Path -AclObject $acl
}

# ---------------------------------------------------------------------------
# Verificar instalacion de IIS + FTP
# ---------------------------------------------------------------------------
function Verificar-Instalacion {
    $iis = Get-WindowsFeature -Name "Web-Server"     -ErrorAction SilentlyContinue
    $ftp = Get-WindowsFeature -Name "Web-Ftp-Server" -ErrorAction SilentlyContinue
    if ($iis.Installed -and $ftp.Installed) { return $true }
    return $false
}

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------
function Configurar-Firewall {
    if (-not (Get-NetFirewallRule -DisplayName "FTP Puerto 21" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "FTP Puerto 21" `
            -Direction Inbound -Protocol TCP -LocalPort 21 -Action Allow | Out-Null
        Print-Ok "Regla firewall: puerto 21"
    }
    if (-not (Get-NetFirewallRule -DisplayName "FTP Pasivo 40000-40100" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "FTP Pasivo 40000-40100" `
            -Direction Inbound -Protocol TCP -LocalPort 40000-40100 -Action Allow | Out-Null
        Print-Ok "Regla firewall: puertos pasivos 40000-40100"
    }
}

# ---------------------------------------------------------------------------
# Crear grupos locales
# ---------------------------------------------------------------------------
function Crear-Grupos {
    foreach ($grupo in @($GRUPO_REPROBADOS, $GRUPO_RECURSADORES)) {
        if (-not (Get-LocalGroup -Name $grupo -ErrorAction SilentlyContinue)) {
            New-LocalGroup -Name $grupo -Description "Grupo FTP $grupo" | Out-Null
            Print-Ok "Grupo creado: $grupo"
        } else {
            Print-Info "Grupo ya existe: $grupo"
        }
    }
}

# ---------------------------------------------------------------------------
# Estructura de directorios base
#
# C:\ftp\                          <- raiz del sitio IIS
#   LocalUser\
#     Public\
#       general\                   <- carpeta publica (anonimo lee aqui)
#     reprobados\                  <- carpeta compartida del grupo
#     recursadores\
# ---------------------------------------------------------------------------
function Crear-Estructura-Base {
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
            Print-Ok "Directorio creado: $dir"
        }
    }

    # --- Raiz FTP: IIS_IUSRS necesita leer para que el servicio arranque bien ---
    $iisUsrs = "IIS_IUSRS"
    Set-FolderACL -Path $FTP_ROOT -Rules @(
        (New-ACLRule $ID_ADMINS  "FullControl"),
        (New-ACLRule $ID_SYSTEM  "FullControl"),
        (New-ACLRule $iisUsrs    "ReadAndExecute")
    )

    # --- LocalUser: igual que raiz ---
    Set-FolderACL -Path "$FTP_ROOT\LocalUser" -Rules @(
        (New-ACLRule $ID_ADMINS  "FullControl"),
        (New-ACLRule $ID_SYSTEM  "FullControl"),
        (New-ACLRule $iisUsrs    "ReadAndExecute")
    )

    # --- Public: IUSR puede navegar (jaula del anonimo) ---
    Set-FolderACL -Path "$FTP_ROOT\LocalUser\Public" -Rules @(
        (New-ACLRule $ID_ADMINS "FullControl"),
        (New-ACLRule $ID_SYSTEM "FullControl"),
        (New-ACLRule $ID_IUSR   "ReadAndExecute")
    )

    # --- general: IUSR solo lectura; autenticados pueden escribir pero NO borrar la carpeta ---
    # Nota: los usuarios autenticados se identifican por pertenecer a sus grupos,
    # pero como general es compartida usamos "Users" (todos los usuarios locales)
    $aclG = New-Object System.Security.AccessControl.DirectorySecurity
    $aclG.SetAccessRuleProtection($true, $false)
    $aclG.AddAccessRule((New-ACLRule $ID_ADMINS "FullControl"))
    $aclG.AddAccessRule((New-ACLRule $ID_SYSTEM "FullControl"))
    # Usuarios locales: pueden crear/modificar archivos en general
    $aclG.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        "Users",
        "Modify",
        "ContainerInherit,ObjectInherit", "None", "Allow"
    )))
    # Pero no pueden borrar la carpeta general en si misma
    $aclG.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        "Users",
        "Delete",
        "None", "None", "Deny"
    )))
    # Anonimo: solo lectura
    $aclG.AddAccessRule((New-ACLRule $ID_IUSR "ReadAndExecute"))
    $aclG.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        $ID_IUSR,
        "Write,Delete,DeleteSubdirectoriesAndFiles",
        "ContainerInherit,ObjectInherit", "None", "Deny"
    )))
    Set-Acl -Path "$FTP_ROOT\LocalUser\Public\general" -AclObject $aclG

    # --- Carpetas de grupo: solo miembros del grupo ---
    foreach ($grupo in @($GRUPO_REPROBADOS, $GRUPO_RECURSADORES)) {
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        $acl.AddAccessRule((New-ACLRule $ID_ADMINS "FullControl"))
        $acl.AddAccessRule((New-ACLRule $ID_SYSTEM "FullControl"))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $grupo,
            "Modify",
            "ContainerInherit,ObjectInherit", "None", "Allow"
        )))
        # No pueden borrar la carpeta raiz del grupo
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $grupo,
            "Delete",
            "None", "None", "Deny"
        )))
        Set-Acl -Path "$FTP_ROOT\LocalUser\$grupo" -AclObject $acl
    }

    Print-Ok "Estructura base configurada"
}

# ---------------------------------------------------------------------------
# Configurar el sitio FTP en IIS
#
# Modo de aislamiento 3 = IsolateAllDirectories
# Con este modo IIS busca la carpeta del usuario en:
#   <FtpRoot>\LocalUser\<username>   <- esta es la raiz que ve el usuario
# ---------------------------------------------------------------------------
function Configurar-FTP {
    Import-Module WebAdministration -ErrorAction Stop

    # Detener y eliminar sitio previo si existe
    if (Get-WebSite -Name $FTP_SITE_NAME -ErrorAction SilentlyContinue) {
        & "$env:SystemRoot\System32\inetsrv\appcmd.exe" stop site /site.name:$FTP_SITE_NAME 2>$null
        Start-Sleep -Seconds 1
        Remove-WebSite -Name $FTP_SITE_NAME -ErrorAction SilentlyContinue
    }

    # Crear sitio FTP nuevo
    New-WebFtpSite -Name $FTP_SITE_NAME -Port $FTP_PORT -PhysicalPath $FTP_ROOT -Force | Out-Null
    Print-Ok "Sitio FTP creado: $FTP_SITE_NAME en puerto $FTP_PORT"

    # SSL: desactivado (sin certificado)
    Set-ItemProperty "IIS:\Sites\$FTP_SITE_NAME" `
        -Name ftpServer.security.ssl.controlChannelPolicy -Value 0
    Set-ItemProperty "IIS:\Sites\$FTP_SITE_NAME" `
        -Name ftpServer.security.ssl.dataChannelPolicy    -Value 0

    # Aislamiento por usuario (modo 3 = IsolateAllDirectories)
    Set-ItemProperty "IIS:\Sites\$FTP_SITE_NAME" `
        -Name "ftpServer.userIsolation.mode" -Value 3

    # Autenticacion basica habilitada
    Set-ItemProperty "IIS:\Sites\$FTP_SITE_NAME" `
        -Name "ftpServer.security.authentication.basicAuthentication.enabled" -Value $true

    # Autenticacion anonima habilitada
    Set-ItemProperty "IIS:\Sites\$FTP_SITE_NAME" `
        -Name "ftpServer.security.authentication.anonymousAuthentication.enabled" -Value $true

    # Modo pasivo
    Set-WebConfigurationProperty -PSPath "IIS:\" -Location $FTP_SITE_NAME `
        -Filter "system.ftpServer/firewallSupport" `
        -Name "pasvPortRange" -Value "40000-40100" -ErrorAction SilentlyContinue

    # Limpiar reglas de autorizacion anteriores
    Clear-WebConfiguration "/system.ftpServer/security/authorization" `
        -PSPath "IIS:\" -Location $FTP_SITE_NAME -ErrorAction SilentlyContinue

    # Anonimo: solo lectura (permissions=1 = Read)
    Add-WebConfiguration "/system.ftpServer/security/authorization" `
        -PSPath "IIS:\" -Location $FTP_SITE_NAME `
        -Value @{ accessType = "Allow"; users = "?"; roles = ""; permissions = 1 }

    # Usuarios autenticados: lectura + escritura (permissions=3 = Read|Write)
    Add-WebConfiguration "/system.ftpServer/security/authorization" `
        -PSPath "IIS:\" -Location $FTP_SITE_NAME `
        -Value @{ accessType = "Allow"; users = "*"; roles = ""; permissions = 3 }

    Print-Ok "Reglas de autorizacion FTP configuradas"

    # Reiniciar servicio FTP
    Stop-Service ftpsvc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Service ftpsvc
    Start-Sleep -Seconds 2

    & "$env:SystemRoot\System32\inetsrv\appcmd.exe" start site /site.name:$FTP_SITE_NAME 2>$null
    Print-Ok "Servicio FTP iniciado"
}

# ---------------------------------------------------------------------------
# Construir la jaula de un usuario
#
# Estructura resultante dentro de C:\ftp\LocalUser\<usuario>\ :
#   general\         -> junction a C:\ftp\LocalUser\Public\general
#   <grupo>\         -> junction a C:\ftp\LocalUser\<grupo>
#   <usuario>\       -> carpeta personal del usuario
#
# IIS con modo 3 pone al usuario directamente en:
#   C:\ftp\LocalUser\<usuario>\
# Por eso el usuario ve las tres carpetas al conectar.
# ---------------------------------------------------------------------------
function Construir-Jaula-Usuario {
    param(
        [string]$usuario,
        [string]$grupo
    )

    $jaula    = "$FTP_ROOT\LocalUser\$usuario"
    $personal = "$jaula\$usuario"

    if (-not (Test-Path $jaula))    { New-Item -ItemType Directory -Path $jaula    -Force | Out-Null }
    if (-not (Test-Path $personal)) { New-Item -ItemType Directory -Path $personal -Force | Out-Null }

    # Resolver cuenta del usuario
    $userAccount = New-Object System.Security.Principal.NTAccount($env:COMPUTERNAME, $usuario)

    # --- ACL de la raiz de la jaula ---
    # El usuario puede listar y navegar, pero NO borrar la raiz
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule((New-ACLRule $ID_ADMINS "FullControl"))
    $acl.AddAccessRule((New-ACLRule $ID_SYSTEM "FullControl"))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        $userAccount,
        "ReadAndExecute,ListDirectory",
        "ContainerInherit,ObjectInherit", "None", "Allow"
    )))
    # IIS_IUSRS necesita leer la jaula para el proceso del servicio
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        "IIS_IUSRS",
        "ReadAndExecute,ListDirectory",
        "ContainerInherit,ObjectInherit", "None", "Allow"
    )))
    Set-Acl -Path $jaula -AclObject $acl

    # --- ACL de la carpeta personal ---
    $aclP = New-Object System.Security.AccessControl.DirectorySecurity
    $aclP.SetAccessRuleProtection($true, $false)
    $aclP.AddAccessRule((New-ACLRule $ID_ADMINS   "FullControl"))
    $aclP.AddAccessRule((New-ACLRule $ID_SYSTEM   "FullControl"))
    $aclP.AddAccessRule((New-ACLRule $userAccount "Modify"))
    # No puede borrar su propia carpeta personal
    $aclP.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        $userAccount,
        "Delete",
        "None", "None", "Deny"
    )))
    Set-Acl -Path $personal -AclObject $aclP

    # --- Junction: general ---
    $jGeneral = "$jaula\general"
    if (-not (Test-Path $jGeneral)) {
        cmd /c "mklink /J `"$jGeneral`" `"$FTP_ROOT\LocalUser\Public\general`"" | Out-Null
        Print-Ok "Junction creado: $jGeneral"
    }

    # --- Junction: grupo ---
    $jGrupo = "$jaula\$grupo"
    if (-not (Test-Path $jGrupo)) {
        cmd /c "mklink /J `"$jGrupo`" `"$FTP_ROOT\LocalUser\$grupo`"" | Out-Null
        Print-Ok "Junction creado: $jGrupo"
    }

    Print-Ok "Jaula lista para '$usuario'"
}

# ---------------------------------------------------------------------------
# Destruir la jaula de un usuario
# ---------------------------------------------------------------------------
function Destruir-Jaula-Usuario {
    param([string]$usuario)

    $jaula = "$FTP_ROOT\LocalUser\$usuario"

    foreach ($junc in @("general", $GRUPO_REPROBADOS, $GRUPO_RECURSADORES)) {
        $juncPath = "$jaula\$junc"
        if (Test-Path $juncPath) {
            cmd /c "rmdir `"$juncPath`"" | Out-Null
        }
    }

    if (Test-Path $jaula) {
        Remove-Item -Path $jaula -Recurse -Force
    }

    Print-Ok "Jaula eliminada: $jaula"
}

# ---------------------------------------------------------------------------
# Validar nombre de usuario
# ---------------------------------------------------------------------------
function Validar-Usuario {
    param([string]$usuario)
    if ([string]::IsNullOrEmpty($usuario))                 { return $false }
    if ($usuario.Length -lt 3 -or $usuario.Length -gt 20) { return $false }
    if ($usuario -notmatch '^[a-zA-Z][a-zA-Z0-9_-]*$')    { return $false }
    if (Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue) { return $false }
    return $true
}

# ---------------------------------------------------------------------------
# Crear usuario FTP
# ---------------------------------------------------------------------------
function Crear-Usuario-FTP {
    param(
        [string]$usuario,
        [string]$password,
        [string]$grupo
    )

    $securePass = ConvertTo-SecureString $password -AsPlainText -Force

    try {
        New-LocalUser -Name $usuario -Password $securePass `
            -PasswordNeverExpires `
            -UserMayNotChangePassword `
            -Description "Usuario FTP - $grupo" | Out-Null
        Print-Ok "Usuario del sistema creado: $usuario"
    } catch {
        Print-Error "Error al crear usuario: $_"
        return $false
    }

    Start-Sleep -Seconds 1

    # Asignar grupo correcto, quitar del otro si aplica
    $otroGrupo = if ($grupo -eq $GRUPO_REPROBADOS) { $GRUPO_RECURSADORES } else { $GRUPO_REPROBADOS }
    Remove-LocalGroupMember -Group $otroGrupo -Member $usuario -ErrorAction SilentlyContinue
    Add-LocalGroupMember    -Group $grupo     -Member $usuario -ErrorAction SilentlyContinue
    Print-Ok "Usuario '$usuario' agregado al grupo '$grupo'"

    # Tambien agregar al grupo "Users" para que tenga acceso a /general
    Add-LocalGroupMember -Group "Users" -Member $usuario -ErrorAction SilentlyContinue

    Construir-Jaula-Usuario -usuario $usuario -grupo $grupo

    return $true
}

# ---------------------------------------------------------------------------
# Cambiar grupo de un usuario
# ---------------------------------------------------------------------------
function Cambiar-Grupo-Usuario {
    param([string]$usuario)

    if (-not (Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue)) {
        Print-Error "Usuario '$usuario' no existe"
        return
    }

    $grupoActual = $null
    foreach ($g in @($GRUPO_REPROBADOS, $GRUPO_RECURSADORES)) {
        $miembros = Get-LocalGroupMember -Group $g -ErrorAction SilentlyContinue
        if ($miembros | Where-Object { ($_.Name -replace "^.*\\", "") -eq $usuario }) {
            $grupoActual = $g
            break
        }
    }

    Write-Host ""
    Write-Host "Usuario     : $usuario"
    Write-Host "Grupo actual: $(if ($grupoActual) { $grupoActual } else { 'ninguno' })"
    Write-Host ""
    Write-Host "1) $GRUPO_REPROBADOS"
    Write-Host "2) $GRUPO_RECURSADORES"

    $opcion = Read-Host "Seleccione nuevo grupo"

    $nuevoGrupo = switch ($opcion) {
        "1" { $GRUPO_REPROBADOS }
        "2" { $GRUPO_RECURSADORES }
        default {
            Print-Warn "Opcion invalida"
            return
        }
    }

    if ($grupoActual -eq $nuevoGrupo) {
        Print-Warn "El usuario ya pertenece a '$nuevoGrupo'"
        return
    }

    # Actualizar membresías de grupo
    if ($grupoActual) {
        Remove-LocalGroupMember -Group $grupoActual -Member $usuario -ErrorAction SilentlyContinue
    }
    Add-LocalGroupMember -Group $nuevoGrupo -Member $usuario -ErrorAction SilentlyContinue

    # Reconstruir jaula: eliminar junction viejo y crear el nuevo
    $jaula = "$FTP_ROOT\LocalUser\$usuario"
    if ($grupoActual) {
        $juncViejo = "$jaula\$grupoActual"
        if (Test-Path $juncViejo) {
            cmd /c "rmdir `"$juncViejo`"" | Out-Null
        }
    }

    # Construir junction del nuevo grupo
    $jNuevo = "$jaula\$nuevoGrupo"
    if (-not (Test-Path $jNuevo)) {
        cmd /c "mklink /J `"$jNuevo`" `"$FTP_ROOT\LocalUser\$nuevoGrupo`"" | Out-Null
        Print-Ok "Junction actualizado: $jNuevo"
    }

    Print-Info "Reiniciando servicio FTP..."
    Stop-Service ftpsvc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Service ftpsvc
    Start-Sleep -Seconds 2
    & "$env:SystemRoot\System32\inetsrv\appcmd.exe" start site /site.name:$FTP_SITE_NAME 2>$null

    Print-Ok "Usuario '$usuario' movido a '$nuevoGrupo' - reconecta FileZilla para ver los cambios"
}

# ---------------------------------------------------------------------------
# Listar usuarios FTP
# ---------------------------------------------------------------------------
function Listar-Usuarios-FTP {
    $usuarios = @()

    foreach ($grupo in @($GRUPO_REPROBADOS, $GRUPO_RECURSADORES)) {
        $miembros = Get-LocalGroupMember -Group $grupo -ErrorAction SilentlyContinue
        foreach ($m in $miembros) {
            $nombre  = $m.Name -replace ".*\\", ""
            $jaulaOk = Test-Path "$FTP_ROOT\LocalUser\$nombre"
            $usuarios += [PSCustomObject]@{
                Usuario = $nombre
                Grupo   = $grupo
                Jaula   = if ($jaulaOk) { "OK" } else { "FALTA" }
            }
        }
    }

    if ($usuarios.Count -eq 0) {
        Print-Info "No hay usuarios FTP configurados"
        return
    }
    $usuarios | Format-Table -AutoSize
}

# ---------------------------------------------------------------------------
# Ver estado general
# ---------------------------------------------------------------------------
function Ver-Estado {
    Import-Module WebAdministration -ErrorAction SilentlyContinue

    $svc = Get-Service -Name "ftpsvc" -ErrorAction SilentlyContinue
    if ($svc) { Write-Host "Servicio ftpsvc: $($svc.Status)" -ForegroundColor Cyan }

    $estado = & "$env:SystemRoot\System32\inetsrv\appcmd.exe" list site /site.name:$FTP_SITE_NAME 2>$null
    Write-Host "Sitio IIS: $estado"

    Write-Host "`nConexiones en :21" -ForegroundColor Cyan
    netstat -an | Select-String ":21 "

    Write-Host ""
    Listar-Usuarios-FTP
}

# ---------------------------------------------------------------------------
# Reiniciar FTP
# ---------------------------------------------------------------------------
function Reiniciar-FTP {
    Print-Info "Reiniciando servicio FTP..."
    Stop-Service ftpsvc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Service ftpsvc
    Start-Sleep -Seconds 2
    & "$env:SystemRoot\System32\inetsrv\appcmd.exe" start site /site.name:$FTP_SITE_NAME 2>$null
    Print-Ok "Servicio FTP reiniciado"
}

# ---------------------------------------------------------------------------
# Instalar y configurar FTP completo
# ---------------------------------------------------------------------------
function Instalar-FTP {
    Print-Titulo "Instalacion y Configuracion del Servidor FTP"
    Import-Module ServerManager

    if (Verificar-Instalacion) {
        Write-Host ""
        $resp = Read-Host "FTP ya esta instalado. Sobrescribir instalacion? (s/n)"
        if ($resp -ne "s") {
            Print-Info "Instalacion cancelada"
            return
        }

        Import-Module WebAdministration
        if (Get-WebSite -Name $FTP_SITE_NAME -ErrorAction SilentlyContinue) {
            & "$env:SystemRoot\System32\inetsrv\appcmd.exe" stop site /site.name:$FTP_SITE_NAME 2>$null
            Start-Sleep -Seconds 1
            Remove-WebSite -Name $FTP_SITE_NAME -ErrorAction SilentlyContinue
        }
    } else {
        Print-Info "Instalando roles IIS + FTP..."
        Install-WindowsFeature `
            -Name Web-Server, Web-Ftp-Server, Web-Ftp-Service `
            -IncludeManagementTools
        Print-Ok "Roles instalados"
    }

    Import-Module WebAdministration

    Crear-Grupos
    Crear-Estructura-Base
    Configurar-FTP
    Configurar-Firewall

    $ip = (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -ne "127.0.0.1" } |
        Select-Object -First 1).IPAddress

    Write-Host ""
    Print-Ok "====================================================="
    Print-Ok "  Servidor FTP listo"
    Print-Ok "====================================================="
    Print-Info "  IP           : ftp://$ip"
    Print-Info "  Puerto       : 21"
    Print-Info "  Anonimo      : ftp://$ip  (solo lectura en /general)"
    Print-Info "  Autenticado  : ve /general, /<grupo>, /<usuario>"
    Print-Ok "====================================================="
    Write-Host ""
    Print-Info "Cree usuarios con: .\FTPNICE.ps1 -users"
}

# ---------------------------------------------------------------------------
# Gestionar usuarios
# ---------------------------------------------------------------------------
function Gestionar-Usuarios {
    Print-Titulo "Gestion de Usuarios FTP"
    Write-Host ""
    Write-Host "1 Crear usuario(s)"
    Write-Host "2 Cambiar grupo de usuario"
    Write-Host "3 Eliminar usuario"
    Write-Host ""

    $op = Read-Host "Seleccione opcion"

    switch ($op) {
        "1" {
            $n = Read-Host "Cuantos usuarios desea crear"
            if (-not ($n -match '^\d+$') -or [int]$n -lt 1) {
                Print-Error "Numero invalido"
                return
            }

            for ($i = 1; $i -le [int]$n; $i++) {
                Print-Titulo "Usuario $i de $n"

                do {
                    $usuario = Read-Host "Nombre de usuario"
                    $valido  = Validar-Usuario $usuario
                    if (-not $valido) { Print-Warn "Nombre invalido o ya existe. Intente de nuevo." }
                } while (-not $valido)

                $password = Read-Host "Password"

                Write-Host "1 $GRUPO_REPROBADOS"
                Write-Host "2 $GRUPO_RECURSADORES"
                $g = Read-Host "Grupo [1/2]"

                $grupo = if ($g -eq "1") { $GRUPO_REPROBADOS } else { $GRUPO_RECURSADORES }

                $ok = Crear-Usuario-FTP $usuario $password $grupo
                if ($ok) {
                    Print-Ok "Usuario '$usuario' creado. Al conectarse vera:"
                    Print-Info "  /general     (publica)"
                    Print-Info "  /$grupo      (su grupo)"
                    Print-Info "  /$usuario    (personal)"
                }
            }

            Print-Info "Reiniciando FTP para aplicar cambios..."
            Stop-Service ftpsvc -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            Start-Service ftpsvc
            Start-Sleep -Seconds 2
            & "$env:SystemRoot\System32\inetsrv\appcmd.exe" start site /site.name:$FTP_SITE_NAME 2>$null
        }
        "2" {
            $usuario = Read-Host "Usuario a cambiar de grupo"
            Cambiar-Grupo-Usuario $usuario
        }
        "3" {
            Listar-Usuarios-FTP
            $usuario = Read-Host "Usuario a eliminar"

            $confirmar = Read-Host "Confirmar eliminacion de '$usuario'? (s/n)"
            if ($confirmar -eq "s") {
                Destruir-Jaula-Usuario $usuario
                Remove-LocalUser $usuario -ErrorAction SilentlyContinue
                Print-Ok "Usuario '$usuario' eliminado"

                Stop-Service ftpsvc -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
                Start-Service ftpsvc
                & "$env:SystemRoot\System32\inetsrv\appcmd.exe" start site /site.name:$FTP_SITE_NAME 2>$null
            } else {
                Print-Info "Operacion cancelada"
            }
        }
        default { Print-Warn "Opcion invalida" }
    }
}

# ---------------------------------------------------------------------------
# Mostrar ayuda
# ---------------------------------------------------------------------------
function Mostrar-Ayuda {
    Write-Host ""
    Write-Host "Uso: .\FTPNICE.ps1 [opcion]" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  -install   Instala y configura el servidor FTP"
    Write-Host "  -users     Gestiona usuarios (crear/cambiar grupo/eliminar)"
    Write-Host "  -status    Muestra estado del servidor y lista de usuarios"
    Write-Host "  -restart   Reinicia el servicio FTP"
    Write-Host "  -list      Lista usuarios y estructura FTP"
    Write-Host "  -verify    Verifica si IIS+FTP estan instalados"
    Write-Host "  -help      Muestra esta ayuda"
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Despacho de argumentos
# ---------------------------------------------------------------------------
if     ($verify)  { Verificar-Instalacion }
elseif ($install) { Instalar-FTP }
elseif ($users)   { Gestionar-Usuarios }
elseif ($restart) { Reiniciar-FTP }
elseif ($status)  { Ver-Estado }
elseif ($list)    { Listar-Usuarios-FTP }
elseif ($help)    { Mostrar-Ayuda }
else              { Mostrar-Ayuda }
