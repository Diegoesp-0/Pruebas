# ==================== DNS - WINDOWS ====================
# Cargado por main-windows.ps1. NO ejecutar directamente.

$DNS_FILE           = $PSCommandPath
$DOMINIO            = "reprobados.com"
$DOMINIOS_GUARDADOS = @("reprobados.com")

# ==================== FUNCIONES DNS ====================

function dns_guardar_dominio {
    $c = Get-Content $DNS_FILE -Raw
    $c = $c -replace '(?m)^\$DOMINIO\s*=\s*"[^"]*"', "`$DOMINIO            = `"$script:DOMINIO`""
    Set-Content $DNS_FILE $c -Encoding UTF8
}

function dns_guardar_lista_dominios {
    $linea = '$DOMINIOS_GUARDADOS = @(' + (($DOMINIOS_GUARDADOS | ForEach-Object { '"' + $_ + '"' }) -join ', ') + ')'
    $c = Get-Content $DNS_FILE -Raw
    $c = $c -replace '(?m)^\$DOMINIOS_GUARDADOS\s*=\s*@\([^)]*\)', $linea
    Set-Content $DNS_FILE $c -Encoding UTF8
}

function dns_verificar {
    Clear-Host
    if (Rol-Instalado "DNS") {
        Write-Host ""
        Write-Host "El DNS ya esta instalado"
        Write-Host ""
        Start-Sleep 2
    } else {
        Write-Host ""
        Write-Host "El DNS no esta instalado"
        Write-Host ""
        $opc = Read-Host "Quieres instalar el rol DNS? (S/s)"
        if ($opc -eq "S" -or $opc -eq "s") {
            Clear-Host
            Write-Host ""
            Write-Host "Instalando DNS..."
            Install-WindowsFeature -Name DNS -IncludeManagementTools | Out-Null
            Write-Host "Instalacion completada"
            Write-Host ""
        }
    }
    Pausa
}

function dns_ipfija {
    Clear-Host
    Configurar-IPFija-Interactivo
    Pausa
}

function dns_iniciar {
    $svc = Get-Service -Name DNS -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") {
        Clear-Host
        Write-Host ""
        Write-Host "El servidor ya esta corriendo"
        Write-Host ""
        Start-Sleep 2
    } else {
        Clear-Host
        Set-Service -Name DNS -StartupType Automatic
        Start-Service -Name DNS
        Write-Host ""
        Write-Host "Iniciando servicio..."
        Write-Host ""
        $svc = Get-Service -Name DNS
        if ($svc.Status -eq "Running") {
            Write-Host "Servicio iniciado correctamente"
        } else {
            Write-Host "Error al iniciar el servicio"
        }
    }
    Pausa
}

function dns_configurar_zona {
    Clear-Host

    if (-not (Rol-Instalado "DNS")) {
        Write-Host ""; Write-Host "ERROR: Instale el rol DNS primero (opcion 1)."; Write-Host ""
        Pausa; return
    }

    $IP_SERVER = (Get-NetIPAddress -AddressFamily IPv4 |
                  Where-Object { $_.IPAddress -notmatch "^127\." } |
                  Select-Object -First 1).IPAddress

    if (-not $IP_SERVER) {
        Write-Host ""; Write-Host "ERROR: No se pudo obtener la IP del servidor."; Write-Host ""
        Pausa; return
    }

    # Deshabilitar firewall para evitar bloqueos
    Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False -ErrorAction SilentlyContinue

    do {
        Write-Host "=============== IP CLIENTE =============="
        Write-Host ""
        $IP_CLIENTE = Read-Host "Ingrese la IP a la que apuntara el Dominio"
        if (-not (Validar-IP $IP_CLIENTE)) {
            Clear-Host
            Write-Host ""
            Write-Host "La IP del cliente no es valida"
            Write-Host ""
            Start-Sleep 2
        }
    } while (-not (Validar-IP $IP_CLIENTE))

    $zona = Get-DnsServerZone -Name $DOMINIO -ErrorAction SilentlyContinue
    if (-not $zona) {
        Add-DnsServerPrimaryZone -Name $DOMINIO -ZoneFile "$DOMINIO.dns" -DynamicUpdate None
    }

    Remove-DnsServerResourceRecord -ZoneName $DOMINIO -Name "@"   -RRType A     -Force -ErrorAction SilentlyContinue
    Remove-DnsServerResourceRecord -ZoneName $DOMINIO -Name "www" -RRType A     -Force -ErrorAction SilentlyContinue
    Remove-DnsServerResourceRecord -ZoneName $DOMINIO -Name "www" -RRType CNAME -Force -ErrorAction SilentlyContinue
    Remove-DnsServerResourceRecord -ZoneName $DOMINIO -Name "ns1" -RRType A     -Force -ErrorAction SilentlyContinue

    Add-DnsServerResourceRecordA     -ZoneName $DOMINIO -Name "ns1" -IPv4Address $IP_SERVER
    Add-DnsServerResourceRecordA     -ZoneName $DOMINIO -Name "@"   -IPv4Address $IP_CLIENTE
    Add-DnsServerResourceRecordCName -ZoneName $DOMINIO -Name "www" -HostNameAlias "$DOMINIO."

    Restart-Service -Name DNS
    Write-Host ""
    Write-Host "Zona configurada y servicio reiniciado"
    Pausa
}

function dns_validar {
    Clear-Host
    Write-Host "Probando resolucion DNS..."
    nslookup $DOMINIO 127.0.0.1
    Write-Host "Probando ping..."
    ping -n 3 "www.$DOMINIO"
    Pausa
}

function dns_menu_dominios {
    while ($true) {
        Clear-Host
        Write-Host "========================================="
        Write-Host "         SELECCIONAR DOMINIO"
        Write-Host "========================================="
        Write-Host ""
        Write-Host "  Dominio activo: $DOMINIO"
        Write-Host ""
        for ($i = 0; $i -lt $DOMINIOS_GUARDADOS.Count; $i++) {
            Write-Host "  $($i+1). $($DOMINIOS_GUARDADOS[$i])"
        }
        Write-Host ""
        Write-Host "  A. Agregar dominio"
        Write-Host "  0. Volver"
        Write-Host ""
        $opc = Read-Host "Seleccione una opcion"

        if ($opc -eq "0") {
            break
        } elseif ($opc -eq "A" -or $opc -eq "a") {
            Write-Host ""
            $nuevoDom = Read-Host "Ingrese el nuevo dominio (ej: midominio.com)"
            if ([string]::IsNullOrWhiteSpace($nuevoDom)) {
                Write-Host "El dominio no puede estar vacio"
                Start-Sleep 2
                continue
            }
            if ($DOMINIOS_GUARDADOS -contains $nuevoDom) {
                Write-Host "El dominio [$nuevoDom] ya existe en la lista"
                Start-Sleep 2
            } else {
                $script:DOMINIOS_GUARDADOS += $nuevoDom
                dns_guardar_lista_dominios
                Write-Host "Dominio [$nuevoDom] agregado"
                Start-Sleep 2
            }
        } elseif ($opc -match '^\d+$' -and [int]$opc -ge 1 -and [int]$opc -le $DOMINIOS_GUARDADOS.Count) {
            $script:DOMINIO = $DOMINIOS_GUARDADOS[[int]$opc - 1]
            dns_guardar_dominio
            Write-Host ""
            Write-Host "Dominio seleccionado: $DOMINIO"
            Start-Sleep 2
            break
        } else {
            Write-Host "Opcion invalida"
            Start-Sleep 2
        }
    }
}

function dns_menu {
    while ($true) {
        Clear-Host
        $svc    = Get-Service -Name DNS -ErrorAction SilentlyContinue
        $estado = if ($svc -and $svc.Status -eq 'Running') { "ACTIVO" } else { "INACTIVO" }

        Write-Host "========================================="
        Write-Host "         CONFIGURADOR DNS                "
        Write-Host "========================================="
        Write-Host ""
        Write-Host "  Dominio activo: $DOMINIO"
        Write-Host "  Servicio DNS  : $estado"
        Write-Host ""
        Write-Host "  1. Verificar instalacion"
        Write-Host "  2. IP fija"
        Write-Host "  3. Iniciar servicio"
        Write-Host "  4. Configurar zona"
        Write-Host "  5. Validar"
        Write-Host "  6. Seleccionar dominio"
        Write-Host "  0. Volver"
        Write-Host "-----------------------------------------"

        $op = Read-Host "Seleccione una opcion"
        switch ($op) {
            "1" { dns_verificar       }
            "2" { dns_ipfija          }
            "3" { dns_iniciar         }
            "4" { dns_configurar_zona }
            "5" { dns_validar         }
            "6" { dns_menu_dominios   }
            "0" { return              }
            default { Write-Host "Opcion invalida"; Start-Sleep 2 }
        }
    }
}
