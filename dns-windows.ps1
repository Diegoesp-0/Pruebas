$DNS_FILE          = $PSCommandPath
$DOMINIO           = "reprobados.com"
$DOMINIOS_GUARDADOS = @("reprobados.com")

# ==================== FUNCIONES DNS ====================

function dns_guardar_dominio {
    Guardar-Variable-EnArchivo $DNS_FILE "DOMINIO" $script:DOMINIO
}

function dns_guardar_lista_dominios {
    Guardar-Array-EnArchivo $DNS_FILE "DOMINIOS_GUARDADOS" $script:DOMINIOS_GUARDADOS
}

function dns_verificar { Instalar-Rol "DNS" }

function dns_ipfija { Configurar-IPFija-Interactivo }

function dns_iniciar { Iniciar-Servicio-Windows "DNS" }

function dns_configurar_zona {
    Clear-Host
    if (-not (Rol-Instalado "DNS")) {
        Write-Host "`nERROR: Instale el rol DNS primero (opcion 1).`n"; Pausa; return
    }

    $IP_SERVER = (Get-NetIPAddress -AddressFamily IPv4 |
                  Where-Object { $_.IPAddress -notmatch "^127\." } |
                  Select-Object -First 1).IPAddress
    if (-not $IP_SERVER) {
        Write-Host "`nERROR: No se pudo obtener la IP del servidor.`n"; Pausa; return
    }

    Write-Host "IP del servidor: $IP_SERVER`n"

    $IP_CLIENTE = ""
    do {
        Write-Host "=============== IP CLIENTE =============="
        $IP_CLIENTE = Read-Host "IP a la que apuntara el dominio [$DOMINIO]"
        if (-not (Validar-IP $IP_CLIENTE)) {
            Clear-Host; Write-Host "`nIP invalida.`n"; Start-Sleep 2
        }
    } while (-not (Validar-IP $IP_CLIENTE))

    # Deshabilitar firewall
    Write-Host "Desactivando firewall..."
    Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False -ErrorAction SilentlyContinue

    # Crear zona si no existe
    $zona = Get-DnsServerZone -Name $DOMINIO -ErrorAction SilentlyContinue
    if (-not $zona) {
        Add-DnsServerPrimaryZone -Name $DOMINIO -ZoneFile "$DOMINIO.dns" -DynamicUpdate None
        Write-Host "Zona '$DOMINIO' creada."
    } else {
        Write-Host "Zona '$DOMINIO' ya existe, actualizando registros."
    }

    # Limpiar registros anteriores
    Remove-DnsServerResourceRecord -ZoneName $DOMINIO -Name "@"   -RRType A     -Force -ErrorAction SilentlyContinue
    Remove-DnsServerResourceRecord -ZoneName $DOMINIO -Name "www" -RRType CNAME -Force -ErrorAction SilentlyContinue
    Remove-DnsServerResourceRecord -ZoneName $DOMINIO -Name "www" -RRType A     -Force -ErrorAction SilentlyContinue
    Remove-DnsServerResourceRecord -ZoneName $DOMINIO -Name "ns1" -RRType A     -Force -ErrorAction SilentlyContinue

    # Crear registros
    Add-DnsServerResourceRecordA     -ZoneName $DOMINIO -Name "ns1" -IPv4Address $IP_SERVER
    Add-DnsServerResourceRecordA     -ZoneName $DOMINIO -Name "@"   -IPv4Address $IP_CLIENTE
    Add-DnsServerResourceRecordCName -ZoneName $DOMINIO -Name "www" -HostNameAlias "$DOMINIO."

    Restart-Service -Name DNS
    Start-Sleep 2

    if (Verificar-Servicio "DNS") {
        Write-Host "`nZona [$DOMINIO] configurada correctamente."
        Write-Host "IP servidor : $IP_SERVER"
        Write-Host "IP cliente  : $IP_CLIENTE`n"
    } else {
        Write-Host "`nERROR: El servicio DNS no pudo reiniciarse.`n"
    }
    Pausa
}

function dns_validar {
    Clear-Host
    Write-Host "========== VALIDAR CONFIGURACION DNS ==========`n"

    Write-Host "--- Estado del servicio ---"
    if (Verificar-Servicio "DNS") {
        Write-Host "DNS: ACTIVO`n"
    } else {
        Write-Host "DNS: INACTIVO — use opcion 3 para iniciarlo`n"; Pausa; return
    }

    Write-Host "--- Zona [$DOMINIO] ---"
    $zona = Get-DnsServerZone -Name $DOMINIO -ErrorAction SilentlyContinue
    if ($zona) {
        Write-Host "Zona encontrada: $DOMINIO"
        Get-DnsServerResourceRecord -ZoneName $DOMINIO -ErrorAction SilentlyContinue |
            Where-Object { $_.RecordType -in @("A","CNAME","NS","SOA") } |
            Format-Table -Property Name, RecordType, RecordData -AutoSize
    } else {
        Write-Host "Zona '$DOMINIO' no encontrada — configure la zona primero`n"; Pausa; return
    }

    Write-Host "`n--- Resolucion DNS ---"
    nslookup $DOMINIO 127.0.0.1
    nslookup "www.$DOMINIO" 127.0.0.1

    Write-Host "`n--- Ping (informativo) ---"
    ping -n 3 "www.$DOMINIO"
    Pausa
}

function dns_menu_dominios {
    while ($true) {
        Clear-Host
        Write-Host "======= SELECCIONAR DOMINIO ======="
        Write-Host "`n  Dominio activo: $DOMINIO`n"
        for ($i = 0; $i -lt $DOMINIOS_GUARDADOS.Count; $i++) {
            Write-Host "  $($i+1). $($DOMINIOS_GUARDADOS[$i])"
        }
        Write-Host "`n  A. Agregar dominio"
        Write-Host "  0. Volver`n"
        $opc = Read-Host "Seleccione una opcion"

        if ($opc -eq "0") {
            break
        } elseif ($opc -eq "A" -or $opc -eq "a") {
            $nuevoDom = Read-Host "`nNuevo dominio (ej: midominio.com)"
            if ([string]::IsNullOrWhiteSpace($nuevoDom)) {
                Write-Host "No puede estar vacio."; Start-Sleep 2; continue
            }
            if ($DOMINIOS_GUARDADOS -contains $nuevoDom) {
                Write-Host "El dominio [$nuevoDom] ya existe."; Start-Sleep 2
            } else {
                $script:DOMINIOS_GUARDADOS += $nuevoDom
                dns_guardar_lista_dominios
                Write-Host "Dominio [$nuevoDom] guardado."; Start-Sleep 2
            }
        } elseif ($opc -match '^\d+$' -and [int]$opc -ge 1 -and [int]$opc -le $DOMINIOS_GUARDADOS.Count) {
            $script:DOMINIO = $DOMINIOS_GUARDADOS[[int]$opc - 1]
            dns_guardar_dominio
            Write-Host "`nDominio seleccionado: $DOMINIO"; Start-Sleep 2
            break
        } else {
            Write-Host "Opcion invalida."; Start-Sleep 2
        }
    }
}

function dns_menu {
    while ($true) {
        Clear-Host
        $estado = if (Verificar-Servicio "DNS") { "ACTIVO" } else { "INACTIVO" }
        Write-Host "========================================="
        Write-Host "      CONFIGURACION DNS - WINDOWS        "
        Write-Host "========================================="
        Write-Host ""
        Write-Host "  Dominio activo : $DOMINIO"
        Write-Host "  Servicio DNS   : $estado"
        Write-Host ""
        Write-Host "  1. Verificar instalacion"
        Write-Host "  2. Configurar IP fija"
        Write-Host "  3. Iniciar servicio"
        Write-Host "  4. Configurar zona"
        Write-Host "  5. Validar configuracion"
        Write-Host "  6. Seleccionar / agregar dominio"
        Write-Host "  0. Volver"
        Write-Host ""
        $op = Read-Host "Seleccione una opcion"
        switch ($op) {
            "1" { dns_verificar       }
            "2" { dns_ipfija          }
            "3" { dns_iniciar         }
            "4" { dns_configurar_zona }
            "5" { dns_validar         }
            "6" { dns_menu_dominios   }
            "0" { return              }
            default { Write-Host "Opcion invalida."; Start-Sleep 1 }
        }
    }
}
