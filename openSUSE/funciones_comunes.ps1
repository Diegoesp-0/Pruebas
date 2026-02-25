$NOMBRE_IFACE = "Ethernet"

function Pausa {
    Read-Host "`nPresione Enter para continuar" | Out-Null
}

function Validar-IP {
    param([string]$ip)

    if ($ip -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { return $false }

    $partes = $ip.Split('.')
    foreach ($o in $partes) {
        if ([int]$o -gt 255) { return $false }
    }

    if ($ip -eq "0.0.0.0")         { return $false }
    if ($ip -eq "255.255.255.255") { return $false }
    if ($partes[0] -eq "127")      { return $false }

    return $true
}

function IP-Num {
    param([string]$ip)
    $p = $ip.Split('.')
    return ([int]$p[0] * 16777216) +
           ([int]$p[1] * 65536)    +
           ([int]$p[2] * 256)      +
           [int]$p[3]
}

function Siguiente-IP {
    param([string]$ip)
    $p    = $ip.Split('.')
    $p[3] = [string]([int]$p[3] + 1)
    if ([int]$p[3] -gt 255) { $p[3] = "0"; $p[2] = [string]([int]$p[2] + 1) }
    if ([int]$p[2] -gt 255) { $p[2] = "0"; $p[1] = [string]([int]$p[1] + 1) }
    return $p -join '.'
}

function Red-Base {
    param(
        [string]$ip,
        [string]$mask = ""
    )

    if ($mask -ne "" -and $mask -ne "X") {
        $ipBytes   = ([System.Net.IPAddress]::Parse($ip)).GetAddressBytes()
        $maskBytes = ([System.Net.IPAddress]::Parse($mask)).GetAddressBytes()
        $net = for ($i = 0; $i -lt 4; $i++) { $ipBytes[$i] -band $maskBytes[$i] }
        return $net -join '.'
    }

    # Sin mascara: calculo rapido para redes /24
    $p = $ip.Split('.')
    return "$($p[0]).$($p[1]).$($p[2]).0"
}

function Calcular-CIDR {
    param([string]$mask)
    $cidr = 0
    foreach ($b in ([System.Net.IPAddress]::Parse($mask)).GetAddressBytes()) {
        $cidr += ([Convert]::ToString($b, 2).ToCharArray() |
                  Where-Object { $_ -eq '1' }).Count
    }
    return $cidr
}

function Rol-Instalado {
    param([string]$nombreRol)
    $rol = Get-WindowsFeature -Name $nombreRol -ErrorAction SilentlyContinue
    return ($rol -and $rol.Installed)
}

function Instalar-Rol {
    param([string]$nombreRol)
    Write-Host "Instalando rol '$nombreRol', espere..."
    Install-WindowsFeature -Name $nombreRol -IncludeManagementTools | Out-Null
    Write-Host "Instalacion de '$nombreRol' completada."
}

function Iniciar-Servicio {
    param([string]$nombreSvc)
    $svc = Get-Service -Name $nombreSvc -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Host "ERROR: El servicio '$nombreSvc' no existe."
        return $false
    }
    Set-Service  -Name $nombreSvc -StartupType Automatic
    Start-Service -Name $nombreSvc -ErrorAction Stop
    $svc = Get-Service -Name $nombreSvc
    if ($svc.Status -eq "Running") {
        Write-Host "Servicio '$nombreSvc' iniciado correctamente."
        return $true
    } else {
        Write-Host "ERROR: No se pudo iniciar '$nombreSvc'."
        return $false
    }
}

function Detener-Servicio {
    param([string]$nombreSvc)
    Stop-Service -Name $nombreSvc -Force -ErrorAction Stop
    Write-Host "Servicio '$nombreSvc' detenido correctamente."
}

function Obtener-Interfaz {
    # Buscar por nombre fijo primero
    $iface = Get-NetAdapter -Name $NOMBRE_IFACE -ErrorAction SilentlyContinue
    if ($iface -and $iface.Status -eq 'Up') { return $iface }

    # Fallback: primera interfaz activa que no sea loopback
    Write-Host "AVISO: No se encontro '$NOMBRE_IFACE', usando primera interfaz activa."
    $iface = Get-NetAdapter |
             Where-Object { $_.Status -eq 'Up' -and
                            $_.InterfaceDescription -notmatch 'Loopback' } |
             Select-Object -First 1
    return $iface
}

function Asignar-IPEstatica {
    param(
        [string]$ipFija,
        [int]   $prefijo,
        [string]$gateway = "X"
    )

    $iface = Obtener-Interfaz
    if (-not $iface) {
        Write-Host "ERROR: No se encontro ninguna interfaz de red activa."
        return $false
    }

    Write-Host "Configurando IP estatica $ipFija /$prefijo en '$($iface.Name)'..."

    # Limpiar configuracion IP anterior
    Remove-NetIPAddress -InterfaceAlias $iface.Name -AddressFamily IPv4 `
                        -Confirm:$false -ErrorAction SilentlyContinue
    Remove-NetRoute     -InterfaceAlias $iface.Name -AddressFamily IPv4 `
                        -Confirm:$false -ErrorAction SilentlyContinue

    try {
        if ($gateway -ne "X" -and $gateway -ne "" -and (Validar-IP $gateway)) {
            New-NetIPAddress -InterfaceAlias $iface.Name `
                             -IPAddress      $ipFija     `
                             -PrefixLength   $prefijo    `
                             -DefaultGateway $gateway    `
                             -ErrorAction    Stop | Out-Null
        } else {
            New-NetIPAddress -InterfaceAlias $iface.Name `
                             -IPAddress      $ipFija     `
                             -PrefixLength   $prefijo    `
                             -ErrorAction    Stop | Out-Null
        }
        Write-Host "IP estatica configurada correctamente: $ipFija /$prefijo"
        return $true
    } catch {
        Write-Host "ERROR al asignar IP estatica: $_"
        return $false
    }
}

function Detectar-EstadoIP {
    $iface   = Obtener-Interfaz
    $ifIndex = $iface.ifIndex

    $dhcp = (Get-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv4).Dhcp

    $ipActual = (Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 |
                 Where-Object { $_.IPAddress -notmatch '^127\.' } |
                 Select-Object -First 1).IPAddress

    return [PSCustomObject]@{
        IP     = $ipActual
        EsDHCP = ($dhcp -eq "Enabled")
        Index  = $ifIndex
        Nombre = $iface.Name
    }
}
function Mostrar-Cabecera {
    param([string]$titulo)
    Clear-Host
    Write-Host "============================================"
    Write-Host "   $titulo"
    Write-Host "============================================"
}
