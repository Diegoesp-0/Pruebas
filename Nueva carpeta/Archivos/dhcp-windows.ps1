# ==================== DHCP - WINDOWS ====================
# Cargado por main-windows.ps1. NO ejecutar directamente.

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
    $c = Get-Content $DHCP_FILE -Raw
    $c = $c -replace '(?m)^\$SCOPE\s*=\s*"[^"]*"',     "`$SCOPE     = `"$script:SCOPE`""
    $c = $c -replace '(?m)^\$IPINICIAL\s*=\s*"[^"]*"', "`$IPINICIAL = `"$script:IPINICIAL`""
    $c = $c -replace '(?m)^\$IPFINAL\s*=\s*"[^"]*"',   "`$IPFINAL   = `"$script:IPFINAL`""
    $c = $c -replace '(?m)^\$GATEWAY\s*=\s*"[^"]*"',   "`$GATEWAY   = `"$script:GATEWAY`""
    $c = $c -replace '(?m)^\$DNS\s*=\s*"[^"]*"',       "`$DNS       = `"$script:DNS`""
    $c = $c -replace '(?m)^\$DNS2\s*=\s*"[^"]*"',      "`$DNS2      = `"$script:DNS2`""
    $c = $c -replace '(?m)^\$LEASE\s*=\s*"[^"]*"',     "`$LEASE     = `"$script:LEASE`""
    $c = $c -replace '(?m)^\$MASCARA\s*=\s*"[^"]*"',   "`$MASCARA   = `"$script:MASCARA`""
    Set-Content $DHCP_FILE $c -Encoding UTF8
}

function dhcp_verificar {
    Clear-Host
    if (Rol-Instalado "DHCP") {
        Write-Host ""
        Write-Host "DHCP-SERVER esta instalado :D"
        Write-Host ""
    } else {
        Write-Host ""
        Write-Host "El rol DHCP-SERVER no esta instalado"
        Write-Host ""
        $r = Read-Host "Desea instalarlo ahora? (S/s)"
        if ($r -eq 'S' -or $r -eq 's') {
            Install-WindowsFeature -Name DHCP -IncludeManagementTools
            Write-Host "Instalacion completada."
        }
    }
    Pausa
}

function dhcp_ver_parametros {
    Clear-Host
    if ($SCOPE -eq "X" -or $IPINICIAL -eq "X") {
        Write-Host ""
        Write-Host "Parametros no configurados aun."
        Write-Host ""
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
        Write-Host "================================"
        Write-Host ""
    }
    Pausa
}

function dhcp_conf_parametros {
    if (-not (Rol-Instalado "DHCP")) {
        Clear-Host; Write-Host ""; Write-Host "ERROR: Instale DHCP-SERVER primero (opcion 1)."; Write-Host ""
        Pausa; return
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
        $mskCheck = "255.255.255.0"
        if ((Red-Base $ini $mskCheck) -ne (Red-Base $fin $mskCheck)) {
            Write-Host "Las IPs deben estar en la misma red /24."; Start-Sleep 2; continue
        }
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

    # Mascara fija /24
    $msk = "255.255.255.0"

    # Guardar en memoria y en archivo
    $script:SCOPE=$sc;   $script:IPINICIAL=$ini; $script:IPFINAL=$fin
    $script:GATEWAY=$gw; $script:DNS=$d1;        $script:DNS2=$d2
    $script:LEASE=$ls;   $script:MASCARA=$msk
    dhcp_guardar_variables

    Clear-Host
    Write-Host "Parametros guardados correctamente."
    Write-Host ""
    Write-Host "Mascara calculada automaticamente: $msk"
    Pausa
}

function dhcp_iniciar {
    Clear-Host
    if (-not (Rol-Instalado "DHCP")) {
        Write-Host ""; Write-Host "ERROR: Instale DHCP-SERVER primero (opcion 1)."; Write-Host ""
        Pausa; return
    }
    if ($SCOPE -eq "X" -or $IPINICIAL -eq "X" -or $MASCARA -eq "X") {
        Write-Host ""; Write-Host "ERROR: Configure los parametros primero (opcion 3)."; Write-Host ""
        Pausa; return
    }

    Write-Host "=== INICIAR SERVIDOR DHCP ==="

    # Configurar IP estatica — devuelve el objeto iface o $false
    $iface = Configurar-IP-Estatica $IPINICIAL $MASCARA
    if (-not $iface) { Pausa; return }

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
        Start-Sleep 2

        # Autorizar el servidor DHCP para que responda solicitudes
        try { Add-DhcpServerInDC -DnsName $env:COMPUTERNAME -IPAddress $IPINICIAL -ErrorAction SilentlyContinue } catch {}

        # Marcar configuracion inicial como completa (evita advertencia de no autorizado)
        try {
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12" `
                -Name "ConfigurationState" -Value 2 -ErrorAction SilentlyContinue
        } catch {}

        # Forzar escucha en la interfaz correcta
        Set-DhcpServerv4Binding -InterfaceAlias $iface.Name -BindingState $true -ErrorAction SilentlyContinue

        Write-Host ""
        Write-Host "Servidor DHCP iniciado correctamente."
        Write-Host "Red base     : $scopeReal"
        Write-Host "Rango activo : $(Siguiente-IP $IPINICIAL) - $IPFINAL"
        Write-Host "Mascara      : $MASCARA"
        Write-Host "Interfaz     : $($iface.Name)"
    } catch {
        Write-Host "ERROR: $_"
    }
    Pausa
}

function dhcp_detener {
    Clear-Host
    Write-Host "=== DETENER SERVIDOR DHCP ==="
    try {
        Stop-Service DHCPServer -Force -ErrorAction Stop
        Write-Host ""
        Write-Host "Servidor DHCP detenido correctamente."
        Write-Host ""
    } catch {
        Write-Host "Error: $_"
    }
    Pausa
}

function dhcp_monitor {
    if (-not (Rol-Instalado "DHCP") -or $IPINICIAL -eq "X") {
        Clear-Host; Write-Host ""; Write-Host "Verifique instalacion y parametros primero."; Write-Host ""
        Pausa; return
    }
    if ((Get-Service DHCPServer -ErrorAction SilentlyContinue).Status -ne 'Running') {
        Clear-Host; Write-Host ""; Write-Host "El servidor DHCP no esta en ejecucion (opcion 4)."; Write-Host ""
        Pausa; return
    }

    $scopeMon = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $SCOPE }
    if (-not $scopeMon) {
        Clear-Host; Write-Host ""; Write-Host "No se encontro el ambito '$SCOPE'. Inicie el servidor primero."; Write-Host ""
        Pausa; return
    }
    $red = $scopeMon.ScopeId.IPAddressToString

    try {
        while ($true) {
            Clear-Host
            Write-Host "========== MONITOR DHCP - $SCOPE =========="
            Write-Host "Rango: $(Siguiente-IP $IPINICIAL) - $IPFINAL   [Ctrl+C para salir]"
            Write-Host ""
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
        Write-Host ""
        Write-Host "Saliendo del monitor..."
        Pausa
    }
}

function dhcp_menu {
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
        Write-Host " 0. Volver"
        Write-Host "============================================"

        $op = Read-Host "Seleccione una opcion"
        switch ($op) {
            "1" { dhcp_verificar       }
            "2" { dhcp_ver_parametros  }
            "3" { dhcp_conf_parametros }
            "4" { dhcp_iniciar         }
            "5" { dhcp_detener         }
            "6" { dhcp_monitor         }
            "0" { return               }
            default { Write-Host "Opcion invalida."; Start-Sleep 1 }
        }
    }
}
