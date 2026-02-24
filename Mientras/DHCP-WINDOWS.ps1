# =============== VARIABLES ==============================================
$SCOPE     = "X"
$IPINICIAL = "X"
$IPFINAL   = "X"
$GATEWAY   = "X"
$DNS       = "X"
$DNS2      = "X"
$LEASE     = "X"
$MASCARA   = "X"

# =============== HELPERS ================================================
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
    # Si se pasa mascara, calcula la red real aplicando AND bit a bit
    if ($mask -ne "" -and $mask -ne "X") {
        $ipBytes   = ([System.Net.IPAddress]::Parse($ip)).GetAddressBytes()
        $maskBytes = ([System.Net.IPAddress]::Parse($mask)).GetAddressBytes()
        $net = for ($i = 0; $i -lt 4; $i++) { $ipBytes[$i] -band $maskBytes[$i] }
        return $net -join '.'
    }
    # Sin mascara: trunca al tercer octeto (solo para validaciones rapidas)
    $p = $ip.Split('.'); return "$($p[0]).$($p[1]).$($p[2]).0"
}

function Calcular-CIDR([string]$mask) {
    $cidr = 0
    foreach ($b in ([System.Net.IPAddress]::Parse($mask)).GetAddressBytes()) {
        $cidr += ([Convert]::ToString($b,2).ToCharArray() | Where-Object {$_ -eq '1'}).Count
    }
    return $cidr
}

function Guardar-Variables {
    $c = Get-Content $PSCommandPath -Raw
    $c = $c -replace '(?m)^\$SCOPE\s*=\s*"[^"]*"',     "`$SCOPE     = `"$SCOPE`""
    $c = $c -replace '(?m)^\$IPINICIAL\s*=\s*"[^"]*"', "`$IPINICIAL = `"$IPINICIAL`""
    $c = $c -replace '(?m)^\$IPFINAL\s*=\s*"[^"]*"',   "`$IPFINAL   = `"$IPFINAL`""
    $c = $c -replace '(?m)^\$GATEWAY\s*=\s*"[^"]*"',   "`$GATEWAY   = `"$GATEWAY`""
    $c = $c -replace '(?m)^\$DNS\s*=\s*"[^"]*"',       "`$DNS       = `"$DNS`""
    $c = $c -replace '(?m)^\$DNS2\s*=\s*"[^"]*"',      "`$DNS2      = `"$DNS2`""
    $c = $c -replace '(?m)^\$LEASE\s*=\s*"[^"]*"',     "`$LEASE     = `"$LEASE`""
    $c = $c -replace '(?m)^\$MASCARA\s*=\s*"[^"]*"',   "`$MASCARA   = `"$MASCARA`""
    Set-Content $PSCommandPath $c -Encoding UTF8
}

function Pausa { Read-Host "`nPresione Enter para continuar" | Out-Null }

function DHCP-Instalado {
    $f = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
    return ($f -and $f.Installed)
}

# =============== OPCIONES DEL MENU ======================================
function Menu-Verificar {
    Clear-Host
    if (DHCP-Instalado) {
        Write-Host "`nDHCP-SERVER esta instalado :D`n"
    } else {
        Write-Host "`nEl rol DHCP-SERVER no esta instalado`n"
        $r = Read-Host "Desea instalarlo ahora? (S/s)"
        if ($r -eq 'S' -or $r -eq 's') {
            Install-WindowsFeature -Name DHCP -IncludeManagementTools
            Write-Host "Instalacion completada."
        }
    }
    Pausa
}

function Menu-VerParametros {
    Clear-Host
    if ($SCOPE -eq "X" -or $IPINICIAL -eq "X") {
        Write-Host "`nParametros no configurados aun.`n"
    } else {
        Write-Host "========== PARAMETROS =========="
        Write-Host "Ambito:        $SCOPE"
        Write-Host "IP Servidor:   $IPINICIAL"
        Write-Host "IP Reparto:    $(Siguiente-IP $IPINICIAL)"
        Write-Host "IP Final:      $IPFINAL"
        if ($GATEWAY -ne "X") { Write-Host "Gateway:       $GATEWAY" }
        if ($DNS     -ne "X") { Write-Host "DNS:           $DNS" }
        if ($DNS2    -ne "X") { Write-Host "DNS 2:         $DNS2" }
        Write-Host "Lease:         $LEASE seg"
        if ($MASCARA -ne "X") { Write-Host "Mascara:       $MASCARA" }
        Write-Host "================================`n"
    }
    Pausa
}

function Menu-Parametros {
    if (-not (DHCP-Instalado)) {
        Clear-Host; Write-Host "`nERROR: Instale DHCP-SERVER primero (opcion 1).`n"; Pausa; return
    }

    # Ambito
    Clear-Host; Write-Host "=== CONFIGURAR PARAMETROS ==="
    $sc = Read-Host "Nombre del ambito"

    # Rango IP
    while ($true) {
        Clear-Host; Write-Host "=== CONFIGURAR PARAMETROS ==="
        Write-Host "Ambito: $sc"
        $ini = Read-Host "IP inicial del rango (sera la IP del servidor)"
        if (-not (Validar-IP $ini)) { Write-Host "IP invalida."; Start-Sleep 2; continue }
        $fin = Read-Host "IP final del rango"
        if (-not (Validar-IP $fin)) { Write-Host "IP invalida."; Start-Sleep 2; continue }
        if ((IP-Num $ini) -ge (IP-Num $fin)) { Write-Host "La IP inicial debe ser menor a la final."; Start-Sleep 2; continue }
        break
    }

    # Gateway
    while ($true) {
        Clear-Host; Write-Host "=== CONFIGURAR PARAMETROS ==="
        Write-Host "Rango: $ini - $fin"
        $gw = Read-Host "Gateway (Enter para omitir)"
        if ([string]::IsNullOrEmpty($gw)) { $gw = "X"; break }
        if (-not (Validar-IP $gw)) { Write-Host "IP invalida."; Start-Sleep 2; continue }
        $redRef = Red-Base $ini; $redGW = Red-Base $gw
        $bcast  = ($ini.Split('.')[0..2] -join '.') + '.255'
        if ($redGW -ne $redRef -or $gw -eq $redRef -or $gw -eq $bcast) {
            Write-Host "Gateway fuera de la red o reservado."; Start-Sleep 2; continue
        }
        break
    }

    # DNS
    $d1 = "X"; $d2 = "X"
    while ($true) {
        Clear-Host; Write-Host "=== CONFIGURAR PARAMETROS ==="
        Write-Host "Rango: $ini - $fin$(if($gw -ne 'X'){" | GW: $gw"})"
        $d1 = Read-Host "DNS primario (Enter para omitir)"
        if ([string]::IsNullOrEmpty($d1)) { $d1 = "X"; break }
        if (-not (Validar-IP $d1)) { Write-Host "IP invalida."; Start-Sleep 2; continue }
        $d2 = Read-Host "DNS secundario (Enter para omitir)"
        if ([string]::IsNullOrEmpty($d2)) { $d2 = "X"; break }
        if (-not (Validar-IP $d2)) { Write-Host "IP invalida."; Start-Sleep 2; continue }
        if ($d1 -eq $d2) { Write-Host "Los DNS no pueden ser iguales."; Start-Sleep 2; continue }
        break
    }

    # Lease
    $ls = ""
    while ($true) {
        Clear-Host; Write-Host "=== CONFIGURAR PARAMETROS ==="
        $ls = Read-Host "Lease en segundos (ej: 86400 = 1 dia)"
        if ($ls -match '^\d+$' -and [int]$ls -gt 0) { break }
        Write-Host "Lease invalido."; Start-Sleep 2
    }

    # Mascara automatica
    # Mascara fija /24 (estable y correcta para 192.168.x.x)
$msk = "255.255.255.0"

# Validar que ambas IP esten en la misma red /24
$redIni = Red-Base $ini $msk
$redFin = Red-Base $fin $msk

if ($redIni -ne $redFin) {
    Write-Host "ERROR: Las IP no pertenecen a la misma red /24."
    Pausa
    return
}


    # Guardar
    $script:SCOPE=$sc; $script:IPINICIAL=$ini; $script:IPFINAL=$fin
    $script:GATEWAY=$gw; $script:DNS=$d1; $script:DNS2=$d2
    $script:LEASE=$ls; $script:MASCARA=$msk
    Guardar-Variables

    Clear-Host
    Write-Host "Parametros guardados correctamente.`n"
    Write-Host "Mascara calculada automaticamente: $msk"
    Pausa
}

function Menu-Iniciar {
    Clear-Host
    if (-not (DHCP-Instalado)) {
        Write-Host "`nERROR: Instale DHCP-SERVER primero (opcion 1).`n"; Pausa; return
    }
    if ($SCOPE -eq "X" -or $IPINICIAL -eq "X" -or $MASCARA -eq "X") {
        Write-Host "`nERROR: Configure los parametros primero (opcion 3).`n"; Pausa; return
    }

    Write-Host "=== INICIAR SERVIDOR DHCP ==="

    # Configurar IP estatica
    $iface = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Loopback' } | Select-Object -First 1
    if (-not $iface) { Write-Host "ERROR: No se encontro interfaz activa."; Pausa; return }

    Write-Host "Asignando IP estatica $IPINICIAL en '$($iface.Name)'..."
    Remove-NetIPAddress -InterfaceAlias $iface.Name -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
    try {
        New-NetIPAddress -InterfaceAlias $iface.Name -IPAddress $IPINICIAL -PrefixLength (Calcular-CIDR $MASCARA) -ErrorAction Stop | Out-Null
    } catch {
        Write-Host "ERROR al asignar IP: $_"; Pausa; return
    }

    # Crear ambito DHCP
    $red = Red-Base $IPINICIAL $MASCARA
    try {
        # Eliminar ambito anterior con el mismo ScopeId si existe
        $prev = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Where-Object { $_.ScopeId -eq $red }
        if ($prev) { Remove-DhcpServerv4Scope -ScopeId $prev.ScopeId -Force }

        Add-DhcpServerv4Scope `
            -Name          $SCOPE `
            -StartRange    (Siguiente-IP $IPINICIAL) `
            -EndRange      $IPFINAL `
            -SubnetMask    $MASCARA `
            -LeaseDuration ([TimeSpan]::FromSeconds([int]$LEASE)) `
            -State Active

        # Obtener el ScopeId real que asigno Windows
        $scopeReal = (Get-DhcpServerv4Scope | Where-Object { $_.Name -eq $SCOPE }).ScopeId.IPAddressToString

        if ($GATEWAY -ne "X") { Set-DhcpServerv4OptionValue -ScopeId $scopeReal -Router $GATEWAY }

        $dns = @()
        if ($DNS  -ne "X") { $dns += $DNS  }
        if ($DNS2 -ne "X") { $dns += $DNS2 }
        if ($dns.Count -gt 0) { Set-DhcpServerv4OptionValue -ScopeId $scopeReal -DnsServer $dns }

        Set-Service DHCPServer -StartupType Automatic
        Start-Service DHCPServer

        Write-Host "`nServidor DHCP iniciado correctamente."
        Write-Host "Red base     : $scopeReal"
        Write-Host "Rango activo : $(Siguiente-IP $IPINICIAL) - $IPFINAL"
        Write-Host "Mascara      : $MASCARA"
        Write-Host "Interfaz     : $($iface.Name)"
    } catch {
        Write-Host "ERROR: $_"
    }
    Pausa
}

function Menu-Detener {
    Clear-Host
    Write-Host "=== DETENER SERVIDOR DHCP ==="
    try {
        Stop-Service DHCPServer -Force -ErrorAction Stop
        Write-Host "`nServidor DHCP detenido correctamente.`n"
    } catch {
        Write-Host "Error: $_"
    }
    Pausa
}

function Menu-Monitor {
    if (-not (DHCP-Instalado) -or $IPINICIAL -eq "X") {
        Clear-Host; Write-Host "`nVerifique instalacion y parametros primero.`n"; Pausa; return
    }
    if ((Get-Service DHCPServer -ErrorAction SilentlyContinue).Status -ne 'Running') {
        Clear-Host; Write-Host "`nEl servidor DHCP no esta en ejecucion (opcion 4).`n"; Pausa; return
    }

    $scopeMon = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $SCOPE }
    if (-not $scopeMon) {
        Clear-Host; Write-Host "`nNo se encontro el ambito '$SCOPE'. Inicie el servidor primero.`n"; Pausa; return
    }
    $red = $scopeMon.ScopeId.IPAddressToString

    try {
        while ($true) {
            Clear-Host
            Write-Host "========== MONITOR DHCP - $SCOPE =========="
            Write-Host "Rango: $(Siguiente-IP $IPINICIAL) - $IPFINAL   [Ctrl+C para salir]`n"
            try {
                $leases = Get-DhcpServerv4Lease -ScopeId $red -ErrorAction Stop |
                          Where-Object { $_.AddressState -like '*Active*' }
                if ($leases) {
                    Write-Host ("IP").PadRight(16) + ("MAC").PadRight(20) + "Hostname"
                    Write-Host ("-" * 58)
                    foreach ($l in $leases) {
                        $h = if ($l.HostName) { $l.HostName } else { "Desconocido" }
                        Write-Host "$($l.IPAddress.ToString().PadRight(16))$($l.ClientId.PadRight(20))$h"
                    }
                    Write-Host ("-" * 58)
                    Write-Host "Clientes activos: $($leases.Count)"
                } else {
                    Write-Host "Sin clientes activos en este momento."
                }
            } catch { Write-Host "Error leyendo leases: $_" }
            Start-Sleep 3
        }
    } catch [System.Management.Automation.PipelineStoppedException] {
        Write-Host "`nSaliendo del monitor..."
        Pausa
    }
}

# =============== MENU PRINCIPAL =========================================
while ($true) {
    Clear-Host
    $svc    = Get-Service DHCPServer -ErrorAction SilentlyContinue
    $estado = if ($svc -and $svc.Status -eq 'Running') { "ACTIVO" } else { "INACTIVO" }
    

    Write-Host "============================================"
    Write-Host "        ADMINISTRADOR DHCP SERVER           "
    Write-Host "============================================"
    Write-Host " Ambito  : $(if($SCOPE -ne 'X'){$SCOPE}else{'No configurado'})"
    Write-Host " Rango   : $(if($IPINICIAL -ne 'X'){"$(Siguiente-IP $IPINICIAL) - $IPFINAL"}else{'No configurado'})"
    Write-Host " Servicio: $estado"
    Write-Host "--------------------------------------------"
    Write-Host " 1. Verificar / Instalar DHCP"
    Write-Host " 2. Ver parametros actuales"
    Write-Host " 3. Configurar parametros"
    Write-Host " 4. Iniciar servidor"
    Write-Host " 5. Detener servidor"
    Write-Host " 6. Monitor de clientes"
    Write-Host " 0. Salir"
    Write-Host "============================================"

    $op = Read-Host "Seleccione una opcion"
    switch ($op) {
        "1" { Menu-Verificar     }
        "2" { Menu-VerParametros }
        "3" { Menu-Parametros    }
        "4" { Menu-Iniciar       }
        "5" { Menu-Detener       }
        "6" { Menu-Monitor       }
        "0" { Clear-Host; exit   }
        default { Write-Host "Opcion invalida."; Start-Sleep 1 }
    }
}
