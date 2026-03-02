# ==================== MAIN - WINDOWS ====================
# Punto de entrada. Ejecutar con:
#   powershell -ExecutionPolicy Bypass -File main-windows.ps1

$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path

. "$SCRIPT_DIR\funciones_comunes-windows.ps1"
. "$SCRIPT_DIR\dhcp-windows.ps1"
. "$SCRIPT_DIR\dns-windows.ps1"

# ==================== MENU PRINCIPAL ====================

while ($true) {
    Clear-Host
    $svcDHCP = Get-Service DHCPServer -ErrorAction SilentlyContinue
    $svcDNS  = Get-Service DNS        -ErrorAction SilentlyContinue
    $estDHCP = if ($svcDHCP -and $svcDHCP.Status -eq 'Running') { "ACTIVO" } else { "INACTIVO" }
    $estDNS  = if ($svcDNS  -and $svcDNS.Status  -eq 'Running') { "ACTIVO" } else { "INACTIVO" }

    Write-Host "============================================"
    Write-Host "     ADMINISTRACION DE SERVIDORES           "
    Write-Host "          WINDOWS SERVER                    "
    Write-Host "============================================"
    Write-Host " DHCP : $estDHCP"
    Write-Host " DNS  : $estDNS"
    Write-Host "--------------------------------------------"
    Write-Host " 1. Configuracion DHCP"
    Write-Host " 2. Configuracion DNS"
    Write-Host " 0. Salir"
    Write-Host "============================================"

    $op = Read-Host "Seleccione una opcion"
    switch ($op) {
        "1" { dhcp_menu }
        "2" { dns_menu  }
        "0" { Clear-Host; Write-Host ""; Write-Host "Hasta luego."; Write-Host ""; exit 0 }
        default { Write-Host "Opcion invalida."; Start-Sleep 1 }
    }
}
