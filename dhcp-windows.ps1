$script:DHCP_SCOPE     = "X"
$script:DHCP_IPINICIAL = "X"
$script:DHCP_IPFINAL   = "X"
$script:DHCP_GATEWAY   = "X"
$script:DHCP_DNS       = "X"
$script:DHCP_DNS2      = "X"
$script:DHCP_LEASE     = "X"
$script:DHCP_MASCARA   = "X"

$script:DHCP_CONFIG = "$PSScriptRoot\dhcp-config.txt"

function DHCP-CargarConfig {
    if (-not (Test-Path $script:DHCP_CONFIG)) { return }
    $lineas = Get-Content $script:DHCP_CONFIG -ErrorAction SilentlyContinue
    foreach ($linea in $lineas) {
        if ($linea -match '^([^=]+)=(.*)$') {
            $clave = $matches[1].Trim()
            $valor = $matches[2].Trim()
            switch ($clave) {
                "SCOPE"     { $script:DHCP_SCOPE     = $valor }
                "IPINICIAL" { $script:DHCP_IPINICIAL = $valor }
                "IPFINAL"   { $script:DHCP_IPFINAL   = $valor }
                "GATEWAY"   { $script:DHCP_GATEWAY   = $valor }
                "DNS"       { $script:DHCP_DNS       = $valor }
                "DNS2"      { $script:DHCP_DNS2      = $valor }
                "LEASE"     { $script:DHCP_LEASE     = $valor }
                "MASCARA"   { $script:DHCP_MASCARA   = $valor }
            }
        }
    }
}
function DHCP-GuardarConfig {
    $contenido = @"
SCOPE=$script:DHCP_SCOPE
IPINICIAL=$script:DHCP_IPINICIAL
IPFINAL=$script:DHCP_IPFINAL
GATEWAY=$script:DHCP_GATEWAY
DNS=$script:DHCP_DNS
DNS2=$script:DHCP_DNS2
LEASE=$script:DHCP_LEASE
MASCARA=$script:DHCP_MASCARA
"@
    Set-Content -Path $script:DHCP_CONFIG -Value $contenido -Encoding UTF8
}

function DHCP-Verificar {
    Mostrar-Cabecera "VERIFICAR / INSTALAR DHCP"

    if (Rol-Instalado "DHCP") {
        Write-Host "`nEl rol DHCP-SERVER ya esta instalado.`n"
    } else {
        Write-Host "`nEl rol DHCP-SERVER NO esta instalado.`n"
        $r = Read-Host "Desea instalarlo ahora? (S/s)"
        if ($r -eq 'S' -or $r -eq 's') {
            Instalar-Rol "DHCP"
        }
    }
    Pausa
}

function DHCP-VerParametros {
    Mostrar-Cabecera "PARAMETROS DHCP ACTUALES"

    if ($script:DHCP_SCOPE -eq "X" -or $script:DHCP_IPINICIAL -eq "X") {
        Write-Host "`nNo hay parametros configurados aun.`n"
    } else {
        Write-Host ""
        Write-Host " Ambito    : $script:DHCP_SCOPE"
        Write-Host " IP Server : $script:DHCP_IPINICIAL"
        Write-Host " Reparto   : $(Siguiente-IP $script:DHCP_IPINICIAL)"
        Write-Host " IP Final  : $script:DHCP_IPFINAL"
        if ($script:DHCP_GATEWAY -ne "X") { Write-Host " Gateway   : $script:DHCP_GATEWAY" }
        if ($script:DHCP_DNS     -ne "X") { Write-Host " DNS 1     : $script:DHCP_DNS"     }
        if ($script:DHCP_DNS2    -ne "X") { Write-Host " DNS 2     : $script:DHCP_DNS2"    }
        Write-Host " Lease     : $script:DHCP_LEASE segundos"
        Write-Host " Mascara   : $script:DHCP_MASCARA"
        Write-Host ""
    }
    Pausa
}

function DHCP-Configurar {
    if (-not (Rol-Instalado "DHCP")) {
        Mostrar-Cabecera "CONFIGURAR DHCP"
        Write-Host "`nERROR: Instale el rol DHCP primero (opcion 1).`n"
        Pausa
        return
    }

    Mostrar-Cabecera "CONFIGURAR DHCP - Ambito"
    $sc = ""
    while ([string]::IsNullOrWhiteSpace($sc)) {
        $sc = Read-Host "Nombre del ambito"
        if ([string]::IsNullOrWhiteSpace($sc)) {
            Write-Host "El nombre no puede estar vacio."
        }
    }

    $ini = ""; $fin = ""
    while ($true) {
        Mostrar-Cabecera "CONFIGURAR DHCP - Rango IP"
        Write-Host " Ambito: $sc`n"
        $ini = Read-Host "IP inicial del rango (sera la IP del servidor)"
        if (-not (Validar-IP $ini)) { Write-Host "IP invalida, intente de nuevo."; Start-Sleep 2; continue }
        $fin = Read-Host "IP final del rango"
        if (-not (Validar-IP $fin)) { Write-Host "IP invalida, intente de nuevo."; Start-Sleep 2; continue }
        if ((IP-Num $ini) -ge (IP-Num $fin)) {
            Write-Host "La IP inicial debe ser MENOR que la IP final."
            Start-Sleep 2; continue
        }
        break
    }

    $gw = "X"
    while ($true) {
        Mostrar-Cabecera "CONFIGURAR DHCP - Gateway"
        Write-Host " Rango: $ini  -->  $fin`n"
        $entrada = Read-Host "Gateway (Enter para omitir)"
        if ([string]::IsNullOrEmpty($entrada)) { $gw = "X"; break }
        if (-not (Validar-IP $entrada)) { Write-Host "IP invalida."; Start-Sleep 2; continue }
        $redRef = Red-Base $ini
        $redGW  = Red-Base $entrada
        $bcast  = ($ini.Split('.')[0..2] -join '.') + '.255'
        if ($redGW -ne $redRef -or $entrada -eq $redRef -or $entrada -eq $bcast) {
            Write-Host "Gateway fuera de la red o direccion reservada."
            Start-Sleep 2; continue
        }
        $gw = $entrada
        break
    }

    $d1 = "X"; $d2 = "X"
    while ($true) {
        Mostrar-Cabecera "CONFIGURAR DHCP - DNS"
        Write-Host " Rango: $ini --> $fin$(if($gw -ne 'X'){" | GW: $gw"})`n"
        $entradaD1 = Read-Host "DNS primario (Enter para omitir)"
        if ([string]::IsNullOrEmpty($entradaD1)) { $d1 = "X"; $d2 = "X"; break }
        if (-not (Validar-IP $entradaD1)) { Write-Host "IP invalida."; Start-Sleep 2; continue }
        $d1 = $entradaD1
        $entradaD2 = Read-Host "DNS secundario (Enter para omitir)"
        if ([string]::IsNullOrEmpty($entradaD2)) { $d2 = "X"; break }
        if (-not (Validar-IP $entradaD2)) { Write-Host "IP invalida."; Start-Sleep 2; continue }
        if ($entradaD2 -eq $d1) { Write-Host "El DNS secundario no puede ser igual al primario."; Start-Sleep 2; continue }
        $d2 = $entradaD2
        break
    }

    $ls = ""
    while ($true) {
        Mostrar-Cabecera "CONFIGURAR DHCP - Lease"
        $ls = Read-Host "Tiempo de concesion en segundos (ej: 86400 = 1 dia)"
        if ($ls -match '^\d+$' -and [int]$ls -gt 0) { break }
        Write-Host "Valor invalido, ingrese un numero entero positivo."
        Start-Sleep 2
    }
    $msk    = "255.255.255.0"
    $redIni = Red-Base $ini $msk
    $redFin = Red-Base $fin $msk
    if ($redIni -ne $redFin) {
        Mostrar-Cabecera "CONFIGURAR DHCP - Error"
        Write-Host "`nERROR: La IP inicial ($ini) y la IP final ($fin) no pertenecen a la misma red /24.`n"
        Pausa
        return
    }

    $script:DHCP_SCOPE     = $sc
    $script:DHCP_IPINICIAL = $ini
    $script:DHCP_IPFINAL   = $fin
    $script:DHCP_GATEWAY   = $gw
    $script:DHCP_DNS       = $d1
    $script:DHCP_DNS2      = $d2
    $script:DHCP_LEASE     = $ls
    $script:DHCP_MASCARA   = $msk

    DHCP-GuardarConfig

    Mostrar-Cabecera "CONFIGURAR DHCP - Guardado"
    Write-Host "`nParametros guardados correctamente."
    Write-Host " Mascara asignada automaticamente: $msk`n"
    Pausa
}

function DHCP-Iniciar {
    Mostrar-Cabecera "INICIAR SERVIDOR DHCP"

    if (-not (Rol-Instalado "DHCP")) {
        Write-Host "`nERROR: Instale el rol DHCP primero (opcion 1).`n"; Pausa; return
    }
    if ($script:DHCP_SCOPE     -eq "X" -or
        $script:DHCP_IPINICIAL -eq "X" -or
        $script:DHCP_MASCARA   -eq "X") {
        Write-Host "`nERROR: Configure los parametros primero (opcion 3).`n"; Pausa; return
    }

    # Asignar IP estatica en la tarjeta fija
    $ok = Asignar-IPEstatica -ipFija  $script:DHCP_IPINICIAL `
                             -prefijo (Calcular-CIDR $script:DHCP_MASCARA) `
                             -gateway $script:DHCP_GATEWAY
    if (-not $ok) { Pausa; return }

    $red = Red-Base $script:DHCP_IPINICIAL $script:DHCP_MASCARA
    try {
 
        $prev = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue |
                Where-Object { $_.ScopeId.IPAddressToString -eq $red }
        if ($prev) {
            Remove-DhcpServerv4Scope -ScopeId $prev.ScopeId -Force
            Write-Host "Ambito anterior eliminado."
        }

        Add-DhcpServerv4Scope `
            -Name          $script:DHCP_SCOPE                          `
            -StartRange    (Siguiente-IP $script:DHCP_IPINICIAL)       `
            -EndRange      $script:DHCP_IPFINAL                        `
            -SubnetMask    $script:DHCP_MASCARA                        `
            -LeaseDuration ([TimeSpan]::FromSeconds([int]$script:DHCP_LEASE)) `
            -State         Active

        # Obtener el ScopeId real asignado por Windows
        $scopeReal = (Get-DhcpServerv4Scope |
                      Where-Object { $_.Name -eq $script:DHCP_SCOPE }).ScopeId.IPAddressToString

        if ($script:DHCP_GATEWAY -ne "X") {
            Set-DhcpServerv4OptionValue -ScopeId $scopeReal -Router $script:DHCP_GATEWAY
        }

        $listaDNS = @()
        if ($script:DHCP_DNS  -ne "X") { $listaDNS += $script:DHCP_DNS  }
        if ($script:DHCP_DNS2 -ne "X") { $listaDNS += $script:DHCP_DNS2 }
        if ($listaDNS.Count -gt 0) {
            Set-DhcpServerv4OptionValue -ScopeId $scopeReal -DnsServer $listaDNS
        }

        Iniciar-Servicio "DHCPServer"

        Write-Host ""
        Write-Host "Servidor DHCP configurado correctamente."
        Write-Host " Red base      : $scopeReal"
        Write-Host " Rango activo  : $(Siguiente-IP $script:DHCP_IPINICIAL) - $script:DHCP_IPFINAL"
        Write-Host " Mascara       : $script:DHCP_MASCARA"
        Write-Host " Interfaz      : $NOMBRE_IFACE"
    } catch {
        Write-Host "ERROR al crear el ambito DHCP: $_"
    }
    Pausa
}

function DHCP-Detener {
    Mostrar-Cabecera "DETENER SERVIDOR DHCP"
    try {
        Detener-Servicio "DHCPServer"
    } catch {
        Write-Host "ERROR: $_"
    }
    Pausa
}

function DHCP-Monitor {
    if (-not (Rol-Instalado "DHCP") -or $script:DHCP_IPINICIAL -eq "X") {
        Mostrar-Cabecera "MONITOR DHCP"
        Write-Host "`nVerifique instalacion y parametros primero.`n"
        Pausa; return
    }
    if ((Get-Service DHCPServer -ErrorAction SilentlyContinue).Status -ne 'Running') {
        Mostrar-Cabecera "MONITOR DHCP"
        Write-Host "`nEl servidor DHCP no esta en ejecucion. Inicielo primero (opcion 4).`n"
        Pausa; return
    }

    $scopeMon = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq $script:DHCP_SCOPE }
    if (-not $scopeMon) {
        Mostrar-Cabecera "MONITOR DHCP"
        Write-Host "`nNo se encontro el ambito '$script:DHCP_SCOPE'. Inicie el servidor primero.`n"
        Pausa; return
    }
    $red = $scopeMon.ScopeId.IPAddressToString

    try {
        while ($true) {
            Clear-Host
            Write-Host "===== MONITOR DHCP  |  Ambito: $script:DHCP_SCOPE ====="
            Write-Host " Rango: $(Siguiente-IP $script:DHCP_IPINICIAL) - $script:DHCP_IPFINAL"
            Write-Host " [Ctrl+C para salir]`n"
            try {
                $leases = Get-DhcpServerv4Lease -ScopeId $red -ErrorAction Stop |
                          Where-Object { $_.AddressState -like '*Active*' }
                if ($leases) {
                    Write-Host (" IP".PadRight(18) + "MAC".PadRight(22) + "Hostname")
                    Write-Host ("-" * 62)
                    foreach ($l in $leases) {
                        $h = if ($l.HostName) { $l.HostName } else { "Desconocido" }
                        Write-Host (" " + $l.IPAddress.ToString().PadRight(17) +
                                    $l.ClientId.PadRight(22) + $h)
                    }
                    Write-Host ("-" * 62)
                    Write-Host " Clientes activos: $($leases.Count)"
                } else {
                    Write-Host " Sin clientes activos en este momento."
                }
            } catch {
                Write-Host "Error al leer concesiones: $_"
            }
            Start-Sleep 3
        }
    } catch [System.Management.Automation.PipelineStoppedException] {
        Write-Host "`nSaliendo del monitor..."
        Pausa
    }
}

function DHCP-Menu {
    DHCP-CargarConfig

    while ($true) {
        Clear-Host
        $svc    = Get-Service DHCPServer -ErrorAction SilentlyContinue
        $estado = if ($svc -and $svc.Status -eq 'Running') { "ACTIVO" } else { "INACTIVO" }

        Write-Host "============================================"
        Write-Host "       ADMINISTRADOR DHCP - WINDOWS         "
        Write-Host "============================================"
        Write-Host " Ambito  : $(if($script:DHCP_SCOPE -ne 'X'){$script:DHCP_SCOPE}else{'No configurado'})"
        Write-Host " Rango   : $(if($script:DHCP_IPINICIAL -ne 'X'){"$(Siguiente-IP $script:DHCP_IPINICIAL) - $script:DHCP_IPFINAL"}else{'No configurado'})"
        Write-Host " Interfaz: $NOMBRE_IFACE"
        Write-Host " Servicio: $estado"
        Write-Host "--------------------------------------------"
        Write-Host " 1. Verificar / Instalar DHCP"
        Write-Host " 2. Ver parametros actuales"
        Write-Host " 3. Configurar parametros"
        Write-Host " 4. Iniciar servidor"
        Write-Host " 5. Detener servidor"
        Write-Host " 6. Monitor de clientes"
        Write-Host " 0. Volver al menu principal"
        Write-Host "============================================"

        $op = Read-Host "Seleccione una opcion"
        switch ($op) {
            "1" { DHCP-Verificar     }
            "2" { DHCP-VerParametros }
            "3" { DHCP-Configurar    }
            "4" { DHCP-Iniciar       }
            "5" { DHCP-Detener       }
            "6" { DHCP-Monitor       }
            "0" { return             }
            default { Write-Host "Opcion invalida."; Start-Sleep 1 }
        }
    }
}
