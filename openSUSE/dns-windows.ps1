$script:DNS_DOMINIO   = "X"
$script:DNS_IP_FIJA   = "X"
$script:DNS_DOMINIOS  = @()

$script:DNS_CONFIG = "$PSScriptRoot\dns-config.txt"

function DNS-CargarConfig {
    if (-not (Test-Path $script:DNS_CONFIG)) {
        # Primera vez: inicializar con dominio por defecto
        $script:DNS_DOMINIOS = @("reprobados.com")
        $script:DNS_DOMINIO  = "reprobados.com"
        return
    }
    $lineas = Get-Content $script:DNS_CONFIG -ErrorAction SilentlyContinue
    foreach ($linea in $lineas) {
        if ($linea -match '^([^=]+)=(.*)$') {
            $clave = $matches[1].Trim()
            $valor = $matches[2].Trim()
            switch ($clave) {
                "DOMINIO"  { $script:DNS_DOMINIO = $valor }
                "IP_FIJA"  { $script:DNS_IP_FIJA = $valor }
                "DOMINIOS" {
                    # los dominios se guardan separados por "|"
                    if ($valor -ne "") {
                        $script:DNS_DOMINIOS = $valor -split '\|' | Where-Object { $_ -ne "" }
                    }
                }
            }
        }
    }
    # Asegurar que la lista no este vacia
    if ($script:DNS_DOMINIOS.Count -eq 0) {
        $script:DNS_DOMINIOS = @("reprobados.com")
    }
}

function DNS-GuardarConfig {
    $listaStr = $script:DNS_DOMINIOS -join '|'
    $contenido = @"
DOMINIO=$script:DNS_DOMINIO
IP_FIJA=$script:DNS_IP_FIJA
DOMINIOS=$listaStr
"@
    Set-Content -Path $script:DNS_CONFIG -Value $contenido -Encoding UTF8
}

function DNS-Verificar {
    Mostrar-Cabecera "VERIFICAR / INSTALAR DNS"

    if (Rol-Instalado "DNS") {
        Write-Host "`nEl rol DNS ya esta instalado.`n"
    } else {
        Write-Host "`nEl rol DNS NO esta instalado.`n"
        $r = Read-Host "Desea instalarlo ahora? (S/s)"
        if ($r -eq 'S' -or $r -eq 's') {
            Instalar-Rol "DNS"
        }
    }
    Pausa
}

function DNS-ConfigurarIPFija {
    Mostrar-Cabecera "CONFIGURAR IP ESTATICA"

    $estado = Detectar-EstadoIP

    if ($estado.EsDHCP) {
        Write-Host "`nLa interfaz '$($estado.Nombre)' tiene IP dinamica (DHCP)."
        Write-Host "Es necesario asignar una IP fija para el servidor DNS.`n"

        $ipFija = ""
        do {
            $ipFija = Read-Host "Ingrese la IP fija para el servidor"
            if (-not (Validar-IP $ipFija)) {
                Write-Host "IP invalida, intente de nuevo."
                $ipFija = ""
            }
        } while ($ipFija -eq "")

        $gateway = (Get-NetRoute -AddressFamily IPv4 |
                    Where-Object { $_.DestinationPrefix -eq "0.0.0.0/0" } |
                    Select-Object -First 1).NextHop

        $ok = Asignar-IPEstatica -ipFija  $ipFija `
                                 -prefijo 24       `
                                 -gateway $gateway
        if ($ok) {
            $script:DNS_IP_FIJA = $ipFija
            DNS-GuardarConfig
            Write-Host "`nIP fija guardada: $script:DNS_IP_FIJA"
        }
    } else {
        Write-Host "`nLa interfaz '$($estado.Nombre)' ya tiene IP estatica."
        $script:DNS_IP_FIJA = $estado.IP
        DNS-GuardarConfig
        Write-Host "IP detectada y guardada: $script:DNS_IP_FIJA"
    }
    Pausa
}

function DNS-Iniciar {
    Mostrar-Cabecera "INICIAR SERVICIO DNS"

    if (-not (Rol-Instalado "DNS")) {
        Write-Host "`nERROR: Instale el rol DNS primero (opcion 1).`n"; Pausa; return
    }

    $svc = Get-Service -Name DNS -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") {
        Write-Host "`nEl servicio DNS ya esta en ejecucion.`n"
    } else {
        try {
            Iniciar-Servicio "DNS"
        } catch {
            Write-Host "ERROR al iniciar el servicio DNS: $_"
        }
    }
    Pausa
}

function DNS-ConfigurarZona {
    Mostrar-Cabecera "CONFIGURAR ZONA DNS"

    if (-not (Rol-Instalado "DNS")) {
        Write-Host "`nERROR: Instale el rol DNS primero (opcion 1).`n"; Pausa; return
    }
    if ($script:DNS_DOMINIO -eq "X") {
        Write-Host "`nERROR: Seleccione un dominio primero (opcion 6).`n"; Pausa; return
    }

    if ($script:DNS_IP_FIJA -eq "X" -or $script:DNS_IP_FIJA -eq "") {
        $script:DNS_IP_FIJA = (Get-NetIPAddress -AddressFamily IPv4 |
                               Where-Object { $_.IPAddress -notmatch '^127\.' } |
                               Select-Object -First 1).IPAddress
        Write-Host "IP del servidor detectada automaticamente: $script:DNS_IP_FIJA"
        DNS-GuardarConfig
    }

    $ipServidor = $script:DNS_IP_FIJA
    Write-Host ""
    Write-Host " Dominio : $script:DNS_DOMINIO"
    Write-Host " IP      : $ipServidor"
    Write-Host ""

    $zona = Get-DnsServerZone -Name $script:DNS_DOMINIO -ErrorAction SilentlyContinue
    if (-not $zona) {
        Add-DnsServerPrimaryZone -Name      $script:DNS_DOMINIO `
                                 -ZoneFile  "$script:DNS_DOMINIO.dns" `
                                 -DynamicUpdate None
        Write-Host "Zona '$script:DNS_DOMINIO' creada."
    } else {
        Write-Host "Zona '$script:DNS_DOMINIO' ya existe, actualizando registros..."
    }

    Remove-DnsServerResourceRecord -ZoneName $script:DNS_DOMINIO -Name "@"   -RRType A -Force -ErrorAction SilentlyContinue
    Remove-DnsServerResourceRecord -ZoneName $script:DNS_DOMINIO -Name "www" -RRType A -Force -ErrorAction SilentlyContinue
    Remove-DnsServerResourceRecord -ZoneName $script:DNS_DOMINIO -Name "ns1" -RRType A -Force -ErrorAction SilentlyContinue
    Remove-DnsServerResourceRecord -ZoneName $script:DNS_DOMINIO -Name "www" -RRType CNAME -Force -ErrorAction SilentlyContinue

    Add-DnsServerResourceRecordA     -ZoneName $script:DNS_DOMINIO -Name "ns1" -IPv4Address $ipServidor
    Add-DnsServerResourceRecordA     -ZoneName $script:DNS_DOMINIO -Name "@"   -IPv4Address $ipServidor
    Add-DnsServerResourceRecordCName -ZoneName $script:DNS_DOMINIO -Name "www" -HostNameAlias "$script:DNS_DOMINIO."

    try {
        $soaOld = Get-DnsServerResourceRecord -ZoneName $script:DNS_DOMINIO -RRType SOA -Name "@"
        $soaNew = $soaOld.Clone()
        $soaNew.RecordData.PrimaryServer     = "ns1.$script:DNS_DOMINIO."
        $soaNew.RecordData.ResponsiblePerson = "admin.$script:DNS_DOMINIO."
        Set-DnsServerResourceRecord -ZoneName     $script:DNS_DOMINIO `
                                    -OldInputObject $soaOld           `
                                    -NewInputObject $soaNew
        Write-Host "Registro SOA actualizado."
    } catch {
        Write-Host "Nota: no se pudo actualizar el SOA ($($_.Exception.Message)), continuando..."
    }

    # Reiniciar DNS para aplicar cambios
    Restart-Service -Name DNS
    Write-Host ""
    Write-Host "Zona '$script:DNS_DOMINIO' configurada y servicio DNS reiniciado."
    Write-Host ""
    Pausa
}

function DNS-Validar {
    Mostrar-Cabecera "VALIDAR DNS"

    if ($script:DNS_DOMINIO -eq "X") {
        Write-Host "`nERROR: Seleccione un dominio primero (opcion 6).`n"; Pausa; return
    }

    Write-Host "`nProbando resolucion DNS para '$script:DNS_DOMINIO'...`n"
    nslookup $script:DNS_DOMINIO 127.0.0.1

    Write-Host "`nProbando ping a 'www.$script:DNS_DOMINIO'...`n"
    ping -n 3 "www.$script:DNS_DOMINIO"

    Write-Host ""
    Pausa
}

function DNS-GestionDominios {
    while ($true) {
        Clear-Host
        Write-Host "============================================"
        Write-Host "         GESTION DE DOMINIOS DNS            "
        Write-Host "============================================"
        Write-Host " Dominio activo: $script:DNS_DOMINIO"
        Write-Host "--------------------------------------------"
        for ($i = 0; $i -lt $script:DNS_DOMINIOS.Count; $i++) {
            $marca = if ($script:DNS_DOMINIOS[$i] -eq $script:DNS_DOMINIO) { " <-- activo" } else { "" }
            Write-Host " $($i+1). $($script:DNS_DOMINIOS[$i])$marca"
        }
        Write-Host "--------------------------------------------"
        Write-Host " A. Agregar nuevo dominio"
        Write-Host " 0. Volver"
        Write-Host "============================================"

        $opc = Read-Host "Seleccione una opcion"

        if ($opc -eq "0") {
            break
        } elseif ($opc -eq "A" -or $opc -eq "a") {
            $nuevo = Read-Host "Ingrese el nuevo dominio (ej: midominio.com)"
            if ([string]::IsNullOrWhiteSpace($nuevo)) {
                Write-Host "El dominio no puede estar vacio."; Start-Sleep 2; continue
            }
            if ($script:DNS_DOMINIOS -contains $nuevo) {
                Write-Host "El dominio '$nuevo' ya existe en la lista."; Start-Sleep 2
            } else {
                $script:DNS_DOMINIOS += $nuevo
                DNS-GuardarConfig
                Write-Host "Dominio '$nuevo' agregado."
                Start-Sleep 2
            }
        } elseif ($opc -match '^\d+$' -and
                  [int]$opc -ge 1    -and
                  [int]$opc -le $script:DNS_DOMINIOS.Count) {
            $script:DNS_DOMINIO = $script:DNS_DOMINIOS[[int]$opc - 1]
            DNS-GuardarConfig
            Write-Host ""
            Write-Host "Dominio activo ahora: $script:DNS_DOMINIO"
            Start-Sleep 2
            break
        } else {
            Write-Host "Opcion invalida."; Start-Sleep 2
        }
    }
}

function DNS-Todo {
    DNS-Verificar
    DNS-ConfigurarIPFija
    DNS-Iniciar
    DNS-ConfigurarZona
    DNS-Validar
}

function DNS-Menu {

    DNS-CargarConfig

    while ($true) {
        Clear-Host
        $svc    = Get-Service -Name DNS -ErrorAction SilentlyContinue
        $estado = if ($svc -and $svc.Status -eq 'Running') { "ACTIVO" } else { "INACTIVO" }

        Write-Host "============================================"
        Write-Host "        ADMINISTRADOR DNS - WINDOWS          "
        Write-Host "============================================"
        Write-Host " Dominio : $(if($script:DNS_DOMINIO -ne 'X'){$script:DNS_DOMINIO}else{'No seleccionado'})"
        Write-Host " IP Fija : $(if($script:DNS_IP_FIJA -ne 'X'){$script:DNS_IP_FIJA}else{'No configurada'})"
        Write-Host " Interfaz: $NOMBRE_IFACE"
        Write-Host " Servicio: $estado"
        Write-Host "--------------------------------------------"
        Write-Host " 1. Verificar / Instalar DNS"
        Write-Host " 2. Configurar IP fija"
        Write-Host " 3. Iniciar servicio"
        Write-Host " 4. Configurar zona"
        Write-Host " 5. Validar resolucion"
        Write-Host " 6. Gestionar dominios"
        Write-Host " 7. Ejecutar todo (flujo completo)"
        Write-Host " 0. Volver al menu principal"
        Write-Host "============================================"

        $op = Read-Host "Seleccione una opcion"
        switch ($op) {
            "1" { DNS-Verificar        }
            "2" { DNS-ConfigurarIPFija }
            "3" { DNS-Iniciar          }
            "4" { DNS-ConfigurarZona   }
            "5" { DNS-Validar          }
            "6" { DNS-GestionDominios  }
            "7" { DNS-Todo             }
            "0" { return               }
            default { Write-Host "Opcion invalida."; Start-Sleep 1 }
        }
    }
}
