$DHCP_FILE = $PSCommandPath

# ==================== VARIABLES DHCP ====================

$SCOPE     = "X"
$IPINICIAL = "X"
$IPFINAL   = "X"
$GATEWAY   = "X"
$DNS       = "X"
$DNS2      = "X"
$LEASE     = "X"
$MASCARA   = "X"

# ==================== FUNCIONES DHCP ====================

function dhcp_guardar_variables {
    Guardar-Variable-EnArchivo $DHCP_FILE "SCOPE"     $script:SCOPE
    Guardar-Variable-EnArchivo $DHCP_FILE "IPINICIAL" $script:IPINICIAL
    Guardar-Variable-EnArchivo $DHCP_FILE "IPFINAL"   $script:IPFINAL
    Guardar-Variable-EnArchivo $DHCP_FILE "GATEWAY"   $script:GATEWAY
    Guardar-Variable-EnArchivo $DHCP_FILE "DNS"       $script:DNS
    Guardar-Variable-EnArchivo $DHCP_FILE "DNS2"      $script:DNS2
    Guardar-Variable-EnArchivo $DHCP_FILE "LEASE"     $script:LEASE
    Guardar-Variable-EnArchivo $DHCP_FILE "MASCARA"   $script:MASCARA
}

function dhcp_verificar { Instalar-Rol "DHCP" }

function dhcp_ver_parametros {
    Clear-Host
    if ($SCOPE -eq "X" -or $IPINICIAL -eq "X") {
        Write-Host "`nParametros no configurados aun.`n"
    } else {
        Write-Host "========== PARAMETROS DHCP =========="
        Write-Host "Ambito:         $SCOPE"
        Write-Host "IP Servidor:    $IPINICIAL"
        Write-Host "IP Reparto:     $(Siguiente-IP $IPINICIAL)"
        Write-Host "IP Final:       $IPFINAL"
        if ($GATEWAY -ne "X") { Write-Host "Gateway:        $GATEWAY" }
        if ($DNS     -ne "X") { Write-Host "DNS primario:   $DNS" }
        if ($DNS2    -ne "X") { Write-Host "DNS secundario: $DNS2" }
        Write-Host "Lease:          $LEASE seg"
        Write-Host "Mascara:        $MASCARA"
        Write-Host "======================================"
    }
    Pausa
}

function dhcp_conf_parametros {
    if (-not (Rol-Instalado "DHCP")) {
        Clear-Host; Write-Host "`nERROR: Instale DHCP primero (opcion 1).`n"; Pausa; return
    }

    Clear-Host; Write-Host "=== CONFIGURAR PARAMETROS DHCP ==="
    $sc = Read-Host "Nombre del ambito"

    # Rango
    while ($true) {
        Clear-Host; Write-Host "=== CONFIGURAR PARAMETROS DHCP ==="; Write-Host "Ambito: $sc"
        $ini = Read-Host "IP inicial (IP del servidor)"
        if (-not (Validar-IP $ini)) { Write-Host "IP invalida."; Start-Sleep 2; continue }
        $fin = Read-Host "IP final del rango"
        if (-not (Validar-IP $fin)) { Write-Host "IP invalida."; Start-Sleep 2; continue }
        if ((IP-Num $ini) -ge (IP-Num $fin)) { Write-Host "Inicial debe ser menor."; Start-Sleep 2; continue }
        if ((Red-Base $ini "255.255.255.0") -ne (Red-Base $fin "255.255.255.0")) {
            Write-Host "Deben estar en la misma red /24."; Start-Sleep 2; continue
        }
        break
    }

    # Gateway
    while ($true) {
        Clear-Host; Write-Host "=== CONFIGURAR PARAMETROS DHCP ==="; Write-Host "Rango: $ini - $fin"
        $gw = Read-Host "Gateway (Enter para omitir)"
        if ([string]::IsNullOrEmpty($gw)) { $gw = "X"; break }
        if (-not (Validar-IP $gw)) { Write-Host "IP invalida."; Start-Sleep 2; continue }
        $bcast = ($ini.Split('.')[0..2] -join '.') + '.255'
        if ((Red-Base $gw) -ne (Red-Base $ini) -or $gw -eq (Red-Base $ini) -or $gw -eq $bcast) {
            Write-Host "Gateway fuera de red o reservado."; Start-Sleep 2; continue
        }
        break
    }

    # DNS
    $d1 = "X"; $d2 = "X"
    while ($true) {
        Clear-Host; Write-Host "=== CONFIGURAR PARAMETROS DHCP ==="
        Write-Host "Rango: $ini - $fin$(if($gw -ne 'X'){" | GW: $gw"})"
        $d1 = Read-Host "DNS primario (Enter para omitir)"
        if ([string]::IsNullOrEmpty($d1)) { $d1 = "X"; break }
        if (-not (Validar-IP $d1)) { Write-Host "IP invalida."; Start-Sleep 2; continue }
        $d2 = Read-Host "DNS secundario (Enter para omitir)"
        if ([string]::IsNullOrEmpty($d2)) { $d2 = "X"; break }
        if (-not (Validar-IP $d2)) { Write-Host "IP invalida."; Start-Sleep 2; continue }
        if ($d1 -eq $d2) { Write-Host "No pueden ser iguales."; Start-Sleep 2; continue }
        break
    }

    # Lease
    $ls = ""
    while ($true) {
        Clear-Host; Write-Host "=== CONFIGURAR PARAMETROS DHCP ==="
        $ls = Read-Host "Lease en segundos (ej: 86400)"
        if ($ls -match '^\d+$' -and [int]$ls -gt 0) { break }
        Write-Host "Lease invalido."; Start-Sleep 2
    }

    $msk = "255.255.255.0"

    # Actualizar en memoria y guardar en archivo
    $script:SCOPE=$sc;   $script:IPINICIAL=$ini; $script:IPFINAL=$fin
    $script:GATEWAY=$gw; $script:DNS=$d1;        $script:DNS2=$d2
    $script:LEASE=$ls;   $script:MASCARA=$msk
    dhcp_guardar_variables

    Clear-Host
    Write-Host "`nParametros guardados.`n"
    Write-Host "Ambito: $sc | Rango: $(Siguiente-IP $ini) - $fin | Mascara: $msk`n"
    Pausa
}

function dhcp_iniciar {
    Clear-Host
    if (-not (Rol-Instalado "DHCP")) {
        Write-Host "`nERROR: Instale DHCP primero.`n"; Pausa; return
    }
    if ($SCOPE -eq "X" -or $IPINICIAL -eq "X" -or $MASCARA -eq "X") {
        Write-Host "`nERROR: Configure los parametros primero.`n"; Pausa; return
    }

    Write-Host "=== INICIAR SERVIDOR DHCP ===`n"
    if (-not (Configurar-IP-Estatica $IPINICIAL $MASCARA)) { Pausa; return }

    $red = Red-Base $IPINICIAL $MASCARA
    try {
        $prev = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue |
                Where-Object { $_.ScopeId -eq $red }
        if ($prev) { Remove-DhcpServerv4Scope -ScopeId $prev.ScopeId -Force }

        Add-DhcpServerv4Scope `
            -Name $SCOPE -StartRange (Siguiente-IP $IPINICIAL) -EndRange $IPFINAL `
            -SubnetMask $MASCARA -LeaseDuration ([TimeSpan]::FromSeconds([int]$LEASE)) -State Active

        $scopeReal = (Get-DhcpServerv4Scope | Where-Object { $_.Name -eq $SCOPE }).ScopeId.IPAddressToString
        if ($GATEWAY -ne "X") { Set-DhcpServerv4OptionValue -ScopeId $scopeReal -Router $GATEWAY }
        $dns = @()
        if ($DNS  -ne "X") { $dns += $DNS  }
        if ($DNS2 -ne "X") { $dns += $DNS2 }
        if ($dns.Count -gt 0) { Set-DhcpServerv4OptionValue -ScopeId $scopeReal -DnsServer $dns }

        Set-Service DHCPServer -StartupType Automatic
        Start-Service DHCPServer

        Write-Host "`n========== SERVIDOR DHCP ACTIVO =========="
        Write-Host "IP servidor : $IPINICIAL"
        Write-Host "Rango       : $(Siguiente-IP $IPINICIAL) - $IPFINAL"
        Write-Host "Mascara     : $MASCARA"
        if ($GATEWAY -ne "X") { Write-Host "Gateway     : $GATEWAY" }
        if ($DNS     -ne "X") { Write-Host "DNS 1       : $DNS" }
        if ($DNS2    -ne "X") { Write-Host "DNS 2       : $DNS2" }
        Write-Host "Lease       : $LEASE seg`n"
    } catch { Write-Host "ERROR: $_" }
    Pausa
}

function dhcp_reiniciar { Reiniciar-Servicio-Windows "DHCPServer" }
function dhcp_detener   { Detener-Servicio-Windows   "DHCPServer" }

function dhcp_monitor {
    if (-not (Rol-Instalado "DHCP") -or $IPINICIAL -eq "X") {
        Clear-Host; Write-Host "`nVerifique instalacion y parametros primero.`n"; Pausa; return
    }
    if (-not (Verificar-Servicio "DHCPServer")) {
        Clear-Host; Write-Host "`nEl servidor DHCP no esta en ejecucion.`n"; Pausa; return
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
                } else { Write-Host "Sin clientes activos." }
            } catch { Write-Host "Error leyendo leases: $_" }
            Start-Sleep 3
        }
    } catch [System.Management.Automation.PipelineStoppedException] {
        Write-Host "`nSaliendo del monitor..."; Pausa
    }
}

function dhcp_menu {
    while ($true) {
        Clear-Host
        $estado = if (Verificar-Servicio "DHCPServer") { "ACTIVO" } else { "INACTIVO" }
        Write-Host "============================================"
        Write-Host "      ADMINISTRADOR DHCP - WINDOWS          "
        Write-Host "============================================"
        Write-Host " Ambito  : $(if($SCOPE -ne 'X'){$SCOPE}else{'No configurado'})"
        Write-Host " Rango   : $(if($IPINICIAL -ne 'X'){"$(Siguiente-IP $IPINICIAL) - $IPFINAL"}else{'No configurado'})"
        Write-Host " Servicio: $estado"
        Write-Host "--------------------------------------------"
        Write-Host " 1. Verificar / Instalar DHCP"
        Write-Host " 2. Ver parametros"
        Write-Host " 3. Configurar parametros"
        Write-Host " 4. Iniciar servidor"
        Write-Host " 5. Reiniciar servidor"
        Write-Host " 6. Detener servidor"
        Write-Host " 7. Monitor de clientes"
        Write-Host " 0. Volver"
        Write-Host "============================================"
        $op = Read-Host "Seleccione una opcion"
        switch ($op) {
            "1" { dhcp_verificar       }
            "2" { dhcp_ver_parametros  }
            "3" { dhcp_conf_parametros }
            "4" { dhcp_iniciar         }
            "5" { dhcp_reiniciar       }
            "6" { dhcp_detener         }
            "7" { dhcp_monitor         }
            "0" { return               }
            default { Write-Host "Opcion invalida."; Start-Sleep 1 }
        }
    }
}
