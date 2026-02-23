function Validar-IP([string]$ip) {
    if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $false }
    foreach ($p in ($ip -split '\.')) { if ([int]$p -gt 255) { return $false } }
    if ($ip -eq "0.0.0.0" -or $ip -eq "255.255.255.255" -or $ip -match '^127\.') { return $false }
    return $true
}

function Pausa { Read-Host "`nPresione Enter para continuar" | Out-Null }

function Rol-Instalado([string]$nombre) {
    $f = Get-WindowsFeature -Name $nombre -ErrorAction SilentlyContinue
    return ($f -and $f.Installed)
}

function Instalar-Rol([string]$nombre) {
    Clear-Host
    if (Rol-Instalado $nombre) {
        Write-Host "`nEl rol '$nombre' ya esta instalado :D`n"
        Start-Sleep 2
    } else {
        Write-Host "`nEl rol '$nombre' no esta instalado.`n"
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
    Clear-Host
    if (Verificar-Servicio $nombre) {
        Write-Host "`nEl servicio '$nombre' ya esta corriendo.`n"
        Start-Sleep 2
    } else {
        Set-Service -Name $nombre -StartupType Automatic
        Start-Service -Name $nombre
        Start-Sleep 2
        if (Verificar-Servicio $nombre) {
            Write-Host "`nServicio '$nombre' iniciado correctamente.`n"
        } else {
            Write-Host "`nERROR: No se pudo iniciar '$nombre'.`n"
        }
    }
    Pausa
}

function Detener-Servicio-Windows([string]$nombre) {
    Clear-Host
    try {
        Stop-Service $nombre -Force -ErrorAction Stop
        Write-Host "`nServicio '$nombre' detenido correctamente.`n"
    } catch { Write-Host "Error al detener '$nombre': $_" }
    Pausa
}

function Reiniciar-Servicio-Windows([string]$nombre) {
    Clear-Host
    try {
        Restart-Service $nombre -ErrorAction Stop
        Start-Sleep 2
        if (Verificar-Servicio $nombre) {
            Write-Host "`nServicio '$nombre' reiniciado correctamente.`n"
        } else {
            Write-Host "`nERROR: '$nombre' no pudo reiniciarse.`n"
        }
    } catch { Write-Host "Error al reiniciar '$nombre': $_" }
    Pausa
}

# ==================== RED ====================

function IP-Num([string]$ip) {
    $p = $ip.Split('.')
    return ([int]$p[0]*16777216)+([int]$p[1]*65536)+([int]$p[2]*256)+[int]$p[3]
}

function Siguiente-IP([string]$ip) {
    $p = $ip.Split('.')
    $p[3] = [string]([int]$p[3]+1)
    if ([int]$p[3] -gt 255) { $p[3]="0"; $p[2]=[string]([int]$p[2]+1) }
    if ([int]$p[2] -gt 255) { $p[2]="0"; $p[1]=[string]([int]$p[1]+1) }
    return $p -join '.'
}

function Red-Base([string]$ip, [string]$mask = "") {
    if ($mask -ne "" -and $mask -ne "X") {
        $ipB   = ([System.Net.IPAddress]::Parse($ip)).GetAddressBytes()
        $maskB = ([System.Net.IPAddress]::Parse($mask)).GetAddressBytes()
        $net   = for ($i=0; $i -lt 4; $i++) { $ipB[$i] -band $maskB[$i] }
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

function Configurar-IP-Estatica([string]$ipFija, [string]$mascara = "255.255.255.0") {
    $adaptador = Get-NetAdapter | Where-Object {
        $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Loopback'
    } | Select-Object -First 1

    if (-not $adaptador) { Write-Host "ERROR: No se encontro interfaz activa."; return $false }

    $ifIndex = $adaptador.ifIndex
    Write-Host "Asignando IP $ipFija en '$($adaptador.Name)'..."

    # Eliminar IPs previas para no acumularlas
    Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    Remove-NetRoute -InterfaceIndex $ifIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue

    $gateway = (Get-NetRoute -AddressFamily IPv4 |
                Where-Object { $_.DestinationPrefix -eq "0.0.0.0/0" } |
                Select-Object -First 1).NextHop

    try {
        $params = @{ InterfaceIndex=$ifIndex; IPAddress=$ipFija; PrefixLength=(Calcular-CIDR $mascara) }

        # Solo agregar DefaultGateway si pertenece a la misma red que la IP nueva
        # Si el gateway es de otra red (ej: 10.0.2.2 vs 192.168.x.x), omitirlo
        # para evitar el error "not on the same network segment"
        if ($gateway -and (Red-Base $gateway $mascara) -eq (Red-Base $ipFija $mascara)) {
            $params['DefaultGateway'] = $gateway
        }

        New-NetIPAddress @params -ErrorAction Stop | Out-Null
        Write-Host "IP estatica configurada correctamente."
        return $true
    } catch { Write-Host "ERROR al asignar IP: $_"; return $false }
}

function Configurar-IPFija-Interactivo {
    Clear-Host
    $adaptador = Get-NetAdapter | Where-Object {
        $_.Status -eq "Up" -and $_.Name -notmatch "Loopback"
    } | Select-Object -First 1

    if (-not $adaptador) { Write-Host "`nERROR: No se encontro interfaz activa.`n"; Pausa; return }

    $ifIndex = $adaptador.ifIndex
    $dhcp    = (Get-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv4).Dhcp

    if ($dhcp -eq "Enabled") {
        Write-Host "`nLa interfaz '$($adaptador.Name)' es dinamica. Configurando IP fija...`n"
        $ipFija = ""
        do {
            $ipFija = Read-Host "Ingrese la IP fija"
            if (-not (Validar-IP $ipFija)) { Write-Host "IP invalida."; Start-Sleep 2 }
        } while (-not (Validar-IP $ipFija))

        $dnsAct = (Get-DnsClientServerAddress -InterfaceIndex $ifIndex -AddressFamily IPv4).ServerAddresses |
                   Select-Object -First 1
        if (-not $dnsAct) { $dnsAct = "8.8.8.8" }

        Configurar-IP-Estatica $ipFija | Out-Null
        Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses $dnsAct
        Write-Host "IP fija $ipFija/24 configurada en '$($adaptador.Name)'`n"
    } else {
        $ipActual = (Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4).IPAddress
        Write-Host "`nLa interfaz '$($adaptador.Name)' ya tiene IP fija: $ipActual`n"
        Start-Sleep 2
    }
    Pausa
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
