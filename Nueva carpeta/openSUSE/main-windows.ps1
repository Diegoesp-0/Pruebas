
$esAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent() `
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $esAdmin) {
    Write-Host ""
    Write-Host "  ERROR: Este script debe ejecutarse como Administrador."
    Write-Host "  Haga clic derecho en PowerShell y elija 'Ejecutar como administrador'."
    Write-Host ""
    Read-Host "Presione Enter para salir" | Out-Null
    exit 1
}

$rutaComunes = "$PSScriptRoot\funciones_comunes.ps1"
$rutaDHCP    = "$PSScriptRoot\dhcp-windows.ps1"
$rutaDNS     = "$PSScriptRoot\dns-windows.ps1"

foreach ($ruta in @($rutaComunes, $rutaDHCP, $rutaDNS)) {
    if (-not (Test-Path $ruta)) {
        Write-Host "ERROR: No se encontro el archivo '$ruta'."
        Write-Host "Asegurese de que todos los archivos esten en la misma carpeta."
        Read-Host "Presione Enter para salir" | Out-Null
        exit 1
    }
}

. $rutaComunes
. $rutaDHCP
. $rutaDNS

while ($true) {
    Clear-Host

    $estadoDHCP = if ((Get-Service DHCPServer -ErrorAction SilentlyContinue).Status -eq 'Running') {
        "ACTIVO" } else { "INACTIVO" }
    $estadoDNS  = if ((Get-Service DNS -ErrorAction SilentlyContinue).Status -eq 'Running') {
        "ACTIVO" } else { "INACTIVO" }

    Write-Host "============================================"
    Write-Host "   ADMINISTRADOR DE RED - WINDOWS SERVER    "
    Write-Host "============================================"
    Write-Host ""
    Write-Host " Interfaz de red : $NOMBRE_IFACE"
    Write-Host " DHCP Server     : $estadoDHCP"
    Write-Host " DNS Server      : $estadoDNS"
    Write-Host ""
    Write-Host "--------------------------------------------"
    Write-Host " 1. Administrar DHCP"
    Write-Host " 2. Administrar DNS"
    Write-Host " 0. Salir"
    Write-Host "============================================"

    $op = Read-Host "Seleccione una opcion"
    switch ($op) {
        "1" { DHCP-Menu  }
        "2" { DNS-Menu   }
        "0" { Clear-Host; exit 0 }
        default { Write-Host "Opcion invalida."; Start-Sleep 1 }
    }
}
