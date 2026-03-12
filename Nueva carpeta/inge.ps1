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

function Resolve-SID {
    param([string]$Sid)
    $sidObj = New-Object System.Security.Principal.SecurityIdentifier($Sid)
    return $sidObj.Translate([System.Security.Principal.NTAccount])
}

$ID_ADMINS = Resolve-SID "S-1-5-32-544"
$ID_SYSTEM = Resolve-SID "S-1-5-18"
$ID_AUTH   = Resolve-SID "S-1-5-11"
$ID_IUSR   = Resolve-SID "S-1-5-17"

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

function New-DenyDeleteSelfOnly {
    param([object]$Identity)
    return New-Object System.Security.AccessControl.FileSystemAccessRule(
        $Identity,
        "Delete",
        "None",
        "None",
        "Deny"
    )
}

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

function Grant-FTPLogonRight {
    param([string]$Username)

    $exportInf = "$env:TEMP\secedit_export.inf"
    $applyInf  = "$env:TEMP\secedit_apply.inf"
    $applyDb   = "$env:TEMP\secedit_apply.sdb"

    & secedit /export /cfg $exportInf /quiet 2>$null

    $cfg   = Get-Content $exportInf -ErrorAction SilentlyContinue
    $linea = $cfg | Where-Object { $_ -match "^SeInteractiveLogonRight" }

    if ($linea -and $linea -match [regex]::Escape($Username)) { return }

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
}

function Verificar-Instalacion {
    $iis = Get-WindowsFeature -Name "Web-Server"     -ErrorAction SilentlyContinue
    $ftp = Get-WindowsFeature -Name "Web-Ftp-Server" -ErrorAction SilentlyContinue
    if ($iis.Installed -and $ftp.Installed) { return $true }
    return $false
}

function Configurar-Firewall {
    if (-not (Get-NetFirewallRule -DisplayName "FTP Puerto 21" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "FTP Puerto 21" `
            -Direction Inbound -Protocol TCP -LocalPort 21 -Action Allow | Out-Null
    }
    if (-not (Get-NetFirewallRule -DisplayName "FTP Pasivo 40000-40100" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "FTP Pasivo 40000-40100" `
            -Direction Inbound -Protocol TCP -LocalPort 40000-40100 -Action Allow | Out-Null
    }
}

function Crear-Grupos {
    foreach ($grupo in @($GRUPO_REPROBADOS, $GRUPO_RECURSADORES)) {
        if (-not (Get-LocalGroup -Name $grupo -ErrorAction SilentlyContinue)) {
            New-LocalGroup -Name $grupo -Description "Grupo FTP $grupo" | Out-Null
        }
    }
}

function Crear-Estructura-Base {
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
        }
    }

    # Raiz FTP: solo admins y system
    Set-FolderACL -Path $FTP_ROOT -Rules @(
        (New-ACLRule $ID_ADMINS "FullControl"),
        (New-ACLRule $ID_SYSTEM "FullControl")
    )

    # LocalUser\Public: IUSR puede navegar (jaula del anonimo)
    Set-FolderACL -Path "$FTP_ROOT\LocalUser\Public" -Rules @(
        (New-ACLRule $ID_ADMINS "FullControl"),
        (New-ACLRule $ID_SYSTEM "FullControl"),
        (New-ACLRule $ID_IUSR   "ReadAndExecute")
    )

    # general: autenticados Modify, IUSR solo ReadAndExecute + Deny escritura/borrado
    $aclG = New-Object System.Security.AccessControl.DirectorySecurity
    $aclG.SetAccessRuleProtection($true, $false)
    $aclG.AddAccessRule((New-ACLRule $ID_ADMINS "FullControl"))
    $aclG.AddAccessRule((New-ACLRule $ID_SYSTEM "FullControl"))
    $aclG.AddAccessRule((New-ACLRule $ID_AUTH   "Modify"))
    $aclG.AddAccessRule((New-DenyDeleteSelfOnly $ID_AUTH))
    $aclG.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        $ID_IUSR,
        "ReadAndExecute",
        "ContainerInherit,ObjectInherit", "None", "Allow"
    )))
    $aclG.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        $ID_IUSR,
        "Write,Delete,DeleteSubdirectoriesAndFiles",
        "ContainerInherit,ObjectInherit", "None", "Deny"
    )))
    Set-Acl -Path "$FTP_ROOT\LocalUser\Public\general" -AclObject $aclG

    # reprobados y recursadores: IUSR sin acceso
    foreach ($grupo in @($GRUPO_REPROBADOS, $GRUPO_RECURSADORES)) {
        Set-FolderACL -Path "$FTP_ROOT\LocalUser\$grupo" -Rules @(
            (New-ACLRule $ID_ADMINS "FullControl"),
            (New-ACLRule $ID_SYSTEM "FullControl"),
            (New-ACLRule $grupo     "Modify"),
            (New-DenyDeleteSelfOnly $grupo)
        )
    }
}

function Configurar-FTP {
    Import-Module WebAdministration -ErrorAction Stop

    if (Get-WebSite -Name $FTP_SITE_NAME -ErrorAction SilentlyContinue) {
        & "$env:SystemRoot\System32\inetsrv\appcmd.exe" stop site $FTP_SITE_NAME 2>$null
        Remove-WebSite -Name $FTP_SITE_NAME
    }

    New-WebFtpSite -Name $FTP_SITE_NAME -Port $FTP_PORT -PhysicalPath $FTP_ROOT -Force | Out-Null

    Set-ItemProperty "IIS:\Sites\$FTP_SITE_NAME" -Name ftpServer.security.ssl.controlChannelPolicy -Value 0
    Set-ItemProperty "IIS:\Sites\$FTP_SITE_NAME" -Name ftpServer.security.ssl.dataChannelPolicy    -Value 0

    # Aislamiento por usuario
    Set-ItemProperty "IIS:\Sites\$FTP_SITE_NAME" `
        -Name "ftpServer.userIsolation.mode" -Value 3

    # Autenticacion basica y anonima habilitadas
    Set-ItemProperty "IIS:\Sites\$FTP_SITE_NAME" `
        -Name "ftpServer.security.authentication.basicAuthentication.enabled" -Value $true

    Set-ItemProperty "IIS:\Sites\$FTP_SITE_NAME" `
        -Name "ftpServer.security.authentication.anonymousAuthentication.enabled" -Value $true

    # Limpiar reglas anteriores
    Clear-WebConfiguration "/system.ftpServer/security/authorization" `
        -PSPath "IIS:\" -Location $FTP_SITE_NAME -ErrorAction SilentlyContinue

    # Anonimo: solo lectura (permissions=1)
    Add-WebConfiguration "/system.ftpServer/security/authorization" `
        -PSPath "IIS:\" -Location $FTP_SITE_NAME `
        -Value @{ accessType="Allow"; users="?"; roles=""; permissions=1 }

    # Autenticados: lectura y escritura (permissions=3)
    Add-WebConfiguration "/system.ftpServer/security/authorization" `
        -PSPath "IIS:\" -Location $FTP_SITE_NAME `
        -Value @{ accessType="Allow"; users="*"; roles=""; permissions=3 }

    Stop-Service ftpsvc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Service ftpsvc
    Start-Sleep -Seconds 2

    try {
        & "$env:SystemRoot\System32\inetsrv\appcmd.exe" start site $FTP_SITE_NAME
    } catch {}
}

function Construir-Jaula-Usuario {
    param(
        [string]$usuario,
        [string]$grupo
    )

    $jaula    = "$FTP_ROOT\LocalUser\$usuario"
    $personal = "$jaula\$usuario"

    if (-not (Test-Path $jaula))    { New-Item -ItemType Directory -Path $jaula    -Force | Out-Null }
    if (-not (Test-Path $personal)) { New-Item -ItemType Directory -Path $personal -Force | Out-Null }

    $userSID     = (Get-LocalUser -Name $usuario).SID
    $userAccount = $userSID.Translate([System.Security.Principal.NTAccount])

    # Jaula raiz: navegar, NO borrar
    $acl = Get-Acl $jaula
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule((New-ACLRule $ID_ADMINS "FullControl"))
    $acl.AddAccessRule((New-ACLRule $ID_SYSTEM "FullControl"))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        $userAccount,
        "ReadAndExecute,ListDirectory",
        "ContainerInherit,ObjectInherit", "None", "Allow"
    )))
    $acl.AddAccessRule((New-DenyDeleteSelfOnly $userAccount))
    Set-Acl -Path $jaula -AclObject $acl

    # Carpeta personal: Modify, NO borrar la carpeta
    $aclP = Get-Acl $personal
    $aclP.SetAccessRuleProtection($true, $false)
    $aclP.AddAccessRule((New-ACLRule $ID_ADMINS   "FullControl"))
    $aclP.AddAccessRule((New-ACLRule $ID_SYSTEM   "FullControl"))
    $aclP.AddAccessRule((New-ACLRule $userAccount "Modify"))
    $aclP.AddAccessRule((New-DenyDeleteSelfOnly   $userAccount))
    Set-Acl -Path $personal -AclObject $aclP

    # Junction general
    $jGeneral = "$jaula\general"
    if (-not (Test-Path $jGeneral)) {
        cmd /c "mklink /J `"$jGeneral`" `"$FTP_ROOT\LocalUser\Public\general`"" | Out-Null
    }

    # Junction grupo actual
    $jGrupo = "$jaula\$grupo"
    if (-not (Test-Path $jGrupo)) {
        cmd /c "mklink /J `"$jGrupo`" `"$FTP_ROOT\LocalUser\$grupo`"" | Out-Null
    }
}

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
}

function Validar-Usuario {
    param([string]$usuario)
    if ([string]::IsNullOrEmpty($usuario))                 { return $false }
    if ($usuario.Length -lt 3 -or $usuario.Length -gt 20) { return $false }
    if ($usuario -notmatch '^[a-zA-Z][a-zA-Z0-9_-]*$')    { return $false }
    if (Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue) { return $false }
    return $true
}

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
    } catch {
        return $false
    }

    Start-Sleep -Seconds 1
    Grant-FTPLogonRight -Username $usuario

    $otroGrupo = if ($grupo -eq $GRUPO_REPROBADOS) { $GRUPO_RECURSADORES } else { $GRUPO_REPROBADOS }

    Remove-LocalGroupMember -Group $otroGrupo -Member $usuario -ErrorAction SilentlyContinue
    Add-LocalGroupMember    -Group $grupo     -Member $usuario -ErrorAction SilentlyContinue

    Construir-Jaula-Usuario -usuario $usuario -grupo $grupo

    return $true
}

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

    if ($grupoActual) {
        Remove-LocalGroupMember -Group $grupoActual -Member $usuario -ErrorAction SilentlyContinue
    }
    Add-LocalGroupMember -Group $nuevoGrupo -Member $usuario -ErrorAction SilentlyContinue

    $jaula = "$FTP_ROOT\LocalUser\$usuario"
    if ($grupoActual) {
        $juncViejo = "$jaula\$grupoActual"
        if (Test-Path $juncViejo) {
            cmd /c "rmdir `"$juncViejo`"" | Out-Null
        }
    }

    Construir-Jaula-Usuario -usuario $usuario -grupo $nuevoGrupo

    Print-Info "Aplicando cambios de permisos..."
    Stop-Service ftpsvc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Service ftpsvc
    Start-Sleep -Seconds 2
    try {
        & "$env:SystemRoot\System32\inetsrv\appcmd.exe" start site $FTP_SITE_NAME 2>$null
    } catch {}

    Print-Ok "Usuario '$usuario' movido a '$nuevoGrupo' - reconecta FileZilla para aplicar cambios"
}

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

    if ($usuarios.Count -eq 0) { return }
    $usuarios | Format-Table -AutoSize
}

function Ver-Estado {
    Import-Module WebAdministration -ErrorAction SilentlyContinue

    $svc = Get-Service -Name "ftpsvc" -ErrorAction SilentlyContinue
    if ($svc) { Write-Host "Servicio ftpsvc:" $svc.Status }

    $estado = & "$env:SystemRoot\System32\inetsrv\appcmd.exe" list site $FTP_SITE_NAME 2>$null
    Write-Host "Sitio IIS:" $estado

    netstat -an | Select-String ":21 "

    Listar-Usuarios-FTP
}

function Reiniciar-FTP {
    Stop-Service ftpsvc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Service ftpsvc
    Start-Sleep -Seconds 2
    & "$env:SystemRoot\System32\inetsrv\appcmd.exe" start site $FTP_SITE_NAME
}

function Instalar-FTP {
    Import-Module ServerManager

    if (Verificar-Instalacion) {
        Write-Host ""
        $resp = Read-Host "FTP ya instalado. Sobrescribir instalacion? (s/n)"

        if ($resp -ne "s") {
            Write-Host "Instalacion cancelada"
            return
        }

        Import-Module WebAdministration

        if (Get-WebSite -Name $FTP_SITE_NAME -ErrorAction SilentlyContinue) {
            try {
                & "$env:SystemRoot\System32\inetsrv\appcmd.exe" stop site $FTP_SITE_NAME
            } catch {}
            Remove-WebSite -Name $FTP_SITE_NAME
        }
    } else {
        Install-WindowsFeature `
            -Name Web-Server,Web-Ftp-Server,Web-Ftp-Service `
            -IncludeManagementTools
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
    Write-Host "FTP listo en: ftp://$ip"
    Write-Host ""
    Write-Host "Anonimo  -> solo ve y descarga desde /general"
    Write-Host "Usuarios -> acceso completo segun su grupo"
}

function Gestionar-Usuarios {
    Write-Host ""
    Write-Host "1 Crear usuario"
    Write-Host "2 Cambiar grupo"
    Write-Host "3 Eliminar usuario"
    Write-Host ""

    $op = Read-Host "Seleccione opcion"

    switch ($op) {
        "1" {
            $usuario  = Read-Host "usuario"
            $password = Read-Host "password"

            Write-Host "1 reprobados"
            Write-Host "2 recursadores"

            $g = Read-Host "grupo"

            if ($g -eq "1") { $grupo = $GRUPO_REPROBADOS }
            else             { $grupo = $GRUPO_RECURSADORES }

            Crear-Usuario-FTP $usuario $password $grupo
        }
        "2" {
            $usuario = Read-Host "usuario"
            Cambiar-Grupo-Usuario $usuario
        }
        "3" {
            $usuario = Read-Host "usuario"
            Destruir-Jaula-Usuario $usuario
            Remove-LocalUser $usuario -ErrorAction SilentlyContinue
        }
    }
}

function Mostrar-Ayuda {
    Write-Host ""
    Write-Host "./FTPNICE.ps1 -install"
    Write-Host "./FTPNICE.ps1 -users"
    Write-Host "./FTPNICE.ps1 -status"
    Write-Host "./FTPNICE.ps1 -restart"
    Write-Host "./FTPNICE.ps1 -verify"
    Write-Host "./FTPNICE.ps1 -list"
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
