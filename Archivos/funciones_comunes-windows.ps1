# ==================== FUNCIONES COMUNES - WINDOWS ====================
# Cargado por main-windows.ps1 con dot-sourcing.
# NO ejecutar directamente.

# ==================== GENERALES ====================

function Validar-IP([string]$ip) {
    if ($ip -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { return $false }
    $p = $ip.Split('.')
    foreach ($o in $p) { if ([int]$o -gt 255) { return $false } }
    if ($ip -eq "0.0.0.0" -or $ip -eq "255.255.255.255" -or $p[0] -eq "127") { return $false }
    return $true
}

function IP-Num([string]$ip) {
    $p = $ip.Split('.')
    return ([int]$p[0]*16777216)+([int]$p[1]*65536)+([int]$p[2]*256)+[int]$p[3]
}

function Siguiente-IP([string]$ip) {
    $p = $ip.Split('.'); $p[3] = [string]([int]$p[3]+1)
    if ([int]$p[3] -gt 255) { $p[3]="0"; $p[2]=[string]([int]$p[2]+1) }
    if ([int]$p[2] -gt 255) { $p[2]="0"; $p[1]=[string]([int]$p[1]+1) }
    return $p -join '.'
}

function Red-Base([string]$ip, [string]$mask = "") {
    if ($mask -ne "" -and $mask -ne "X") {
        $ipBytes   = ([System.Net.IPAddress]::Parse($ip)).GetAddressBytes()
        $maskBytes = ([System.Net.IPAddress]::Parse($mask)).GetAddressBytes()
        $net = for ($i = 0; $i -lt 4; $i++) { $ipBytes[$i] -band $maskBytes[$i] }
        return $net -join '.'
    }
    $p = $ip.Split('.'); return "$($p[0]).$($p[1]).$($p[2]).0"
}

function Calcular-CIDR([string]$mask) {
    $cidr = 0
    foreach ($b in ([System.Net.IPAddress]::Parse($mask)).GetAddressBytes()) {
        $cidr += ([Convert]::ToString($b,2).ToCharArray() | Where-Object {$_ -eq '1'}).Count
    }
    return $cidr
}

function Pausa { Read-Host "`nPresione Enter para continuar" | Out-Null }

function Rol-Instalado([string]$nombre) {
    $f = Get-WindowsFeature -Name $nombre -ErrorAction SilentlyContinue
    return ($f -and $f.Installed)
}

function Instalar-Rol([string]$nombre) {
    Clear-Host
    if (Rol-Instalado $nombre) {
        Write-Host ""
        Write-Host "El rol '$nombre' ya esta instalado :D"
        Write-Host ""
        Start-Sleep 2
    } else {
        Write-Host ""
        Write-Host "El rol '$nombre' no esta instalado"
        Write-Host ""
        $r = Read-Host "Desea instalarlo ahora? (S/s)"
        if ($r -eq 'S' -or $r -eq 's') {
            Install-WindowsFeature -Name $nombre -IncludeManagementTools
            Write-Host "Instalacion completada."
        }
    }
    Pausa
}

function Verificar-Servicio([string]$nombre) {
    $svc = Get-Service -Name $nombre -ErrorAction SilentlyContinue
    return ($svc -and $svc.Status -eq 'Running')
}

function Iniciar-Servicio-Windows([string]$nombre) {
    $svc = Get-Service -Name $nombre -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") {
        Clear-Host
        Write-Host ""
        Write-Host "El servicio '$nombre' ya esta corriendo"
        Write-Host ""
        Start-Sleep 2
    } else {
        Clear-Host
        Set-Service -Name $nombre -StartupType Automatic
        Start-Service -Name $nombre
        Write-Host ""
        Write-Host "Iniciando servicio..."
        Write-Host ""
        $svc = Get-Service -Name $nombre
        if ($svc.Status -eq "Running") {
            Write-Host "Servicio '$nombre' iniciado correctamente"
        } else {
            Write-Host "Error al iniciar el servicio '$nombre'"
        }
    }
}

function Detener-Servicio-Windows([string]$nombre) {
    Clear-Host
    Write-Host "=== DETENER SERVICIO $nombre ==="
    try {
        Stop-Service $nombre -Force -ErrorAction Stop
        Write-Host ""
        Write-Host "Servicio '$nombre' detenido correctamente."
        Write-Host ""
    } catch {
        Write-Host "Error: $_"
    }
    Pausa
}

function Reiniciar-Servicio-Windows([string]$nombre) {
    try {
        Restart-Service $nombre -ErrorAction Stop
        Start-Sleep 2
        if (Verificar-Servicio $nombre) {
            Write-Host "Servicio '$nombre' reiniciado correctamente."
        } else {
            Write-Host "ERROR: El servicio '$nombre' no pudo reiniciarse."
        }
    } catch {
        Write-Host "Error al reiniciar '$nombre': $_"
    }
}

# ==================== RED ====================

function Configurar-IP-Estatica([string]$ipFija, [string]$mascara = "255.255.255.0") {
    $iface = Get-NetAdapter | Where-Object {
        $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Loopback'
    } | Select-Object -First 1

    if (-not $iface) {
        Write-Host "ERROR: No se encontro interfaz activa."
        return $false
    }

    Write-Host "Asignando IP estatica $ipFija en '$($iface.Name)'..."

    # Eliminar todas las IPs IPv4 previas para no acumularlas
    Get-NetIPAddress -InterfaceAlias $iface.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    Remove-NetRoute -InterfaceAlias $iface.Name -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue

    try {
        $params = @{
            InterfaceAlias = $iface.Name
            IPAddress      = $ipFija
            PrefixLength   = (Calcular-CIDR $mascara)
        }
        # Solo agregar gateway si pertenece a la misma red que la IP nueva
        $gateway = (Get-NetRoute -AddressFamily IPv4 |
                    Where-Object { $_.DestinationPrefix -eq "0.0.0.0/0" } |
                    Select-Object -First 1).NextHop
        if ($gateway -and (Red-Base $gateway $mascara) -eq (Red-Base $ipFija $mascara)) {
            $params['DefaultGateway'] = $gateway
        }
        New-NetIPAddress @params -ErrorAction Stop | Out-Null
        Write-Host "IP estatica configurada correctamente."
        return $iface
    } catch {
        Write-Host "ERROR al asignar IP: $_"
        return $false
    }
}

function Configurar-IPFija-Interactivo {
    $adaptadores = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.Name -notmatch "Loopback" }
    $adaptador   = $adaptadores | Select-Object -First 1

    if (-not $adaptador) {
        Clear-Host; Write-Host ""; Write-Host "ERROR: No se encontro interfaz activa."; Write-Host ""
        Pausa; return
    }

    $ifIndex = $adaptador.ifIndex
    $dhcp    = Get-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv4 | Select-Object -ExpandProperty Dhcp

    if ($dhcp -eq "Enabled") {
        Clear-Host
        Write-Host ""
        Write-Host "La interfaz es dinamica"
        Write-Host ""

        do {
            $ipFija = Read-Host "Ingrese la IP fija"
            if (-not (Validar-IP $ipFija)) {
                Clear-Host
                Write-Host ""
                Write-Host "IP invalida"
                Write-Host ""
                Start-Sleep 2
            }
        } while (-not (Validar-IP $ipFija))

        $gateway = (Get-NetRoute -AddressFamily IPv4 |
                    Where-Object { $_.DestinationPrefix -eq "0.0.0.0/0" } |
                    Select-Object -First 1).NextHop
        $dns = (Get-DnsClientServerAddress -InterfaceIndex $ifIndex -AddressFamily IPv4).ServerAddresses |
                Select-Object -First 1

        Remove-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
        Remove-NetRoute     -InterfaceIndex $ifIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue

        $params = @{ InterfaceIndex=$ifIndex; IPAddress=$ipFija; PrefixLength=24 }
        if ($gateway -and (Red-Base $gateway "255.255.255.0") -eq (Red-Base $ipFija "255.255.255.0")) {
            $params['DefaultGateway'] = $gateway
        }
        New-NetIPAddress @params | Out-Null

        if ($dns) { Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses $dns }

        Write-Host ""
        Write-Host "IP fija configurada: $ipFija"
        Write-Host ""
    } else {
        Clear-Host
        Write-Host ""
        Write-Host "La interfaz ya tiene IP fija"
        Write-Host ""
        Start-Sleep 2
    }
}

# ==================== PERSISTENCIA ====================

function Guardar-Variable-EnArchivo([string]$archivo, [string]$nombre, [string]$valor) {
    $c = Get-Content $archivo -Raw
    $c = $c -replace "(?m)^\`$$nombre\s*=\s*`"[^`"]*`"", "`$$nombre = `"$valor`""
    Set-Content $archivo $c -Encoding UTF8
}

function Guardar-Array-EnArchivo([string]$archivo, [string]$nombre, [string[]]$valores) {
    $linea = "`$$nombre = @(" + (($valores | ForEach-Object { "`"$_`"" }) -join ', ') + ")"
    $c     = Get-Content $archivo -Raw
    $c     = $c -replace "(?m)^\`$$nombre\s*=\s*@\([^)]*\)", $linea
    Set-Content $archivo $c -Encoding UTF8
}
