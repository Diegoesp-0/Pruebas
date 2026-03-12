# ============================================================
# menuHTTP.ps1 - Solo contiene el menu principal
# ============================================================

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[!] Debes ejecutar este script como Administrador." -ForegroundColor Red
    exit 1
}

$rutaFunciones = "$PSScriptRoot\librerias\funcionesHTTP.ps1"
if (-not (Test-Path $rutaFunciones)) {
    Write-Host "[!] Archivo no encontrado: $rutaFunciones" -ForegroundColor Red
    exit 1
}
. $rutaFunciones

function menuPrincipalHTTP {
    do {
        Clear-Host
        Write-Host ""
        Write-Host "========== servicios HTTP ==========" -ForegroundColor Blue
        Write-Host "  1. Instalar servidor HTTP"
        Write-Host "  2. Gestionar servicios activos"
        Write-Host "  3. Ver estado de puertos"
        Write-Host "  4. Salir"
        Write-Host "-----------------------------------------"
        Write-Host ""

        $op = Read-Host "Selecciona una opcion"

        switch ($op) {
            "1" {
                InstalarHTTP
                Read-Host "`nEnter para continuar"
            }
            "2" {
                Get-Service W3SVC,Apache24 -ErrorAction SilentlyContinue | Format-Table
                Read-Host "`nEnter para continuar"
            }
            "3" {
                netstat -ano | findstr "LISTENING"
                Read-Host "`nEnter para continuar"
            }
            "4" { Write-Host "Saliendo..."; return }
            default {
                Write-Host "[!] Opcion no valida." -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    } while ($true)
}

menuPrincipalHTTP
