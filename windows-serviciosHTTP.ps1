# ============================================================
# windows-serviciosHTTP.ps1
# Menu principal - Windows Server 2022 Core
# Uso: powershell -ExecutionPolicy RemoteSigned -File .\windows-serviciosHTTP.ps1
# ============================================================

#Requires -RunAsAdministrator

# Cargar funciones desde el mismo directorio
$rutaFunciones = "$PSScriptRoot\windows-funciones_http.ps1"
if (-not (Test-Path $rutaFunciones)) {
    Write-Host "[x] Archivo no encontrado: $rutaFunciones" -ForegroundColor Red
    exit 1
}
. $rutaFunciones

# =============== MENU PRINCIPAL ===============
function menuPrincipal {
    do {
        Clear-Host
        Write-Host ""
        Write-Host "================================================" -ForegroundColor Blue
        Write-Host "          GESTION DE SERVIDORES HTTP            " -ForegroundColor Blue
        Write-Host "================================================" -ForegroundColor Blue
        Write-Host "  1. Instalar servidor HTTP"
        Write-Host "  2. Ver estado de servidores"
        Write-Host "  3. Revisar respuesta HTTP"
        Write-Host "  4. Salir"
        Write-Host "------------------------------------------------" -ForegroundColor Blue
        Write-Host ""

        $op = Read-Host "Selecciona una opcion"

        switch ($op) {
            "1" {
                InstalarHTTP
                Read-Host "`nEnter para continuar"
            }
            "2" {
                VerificarHTTP
                Read-Host "`nEnter para continuar"
            }
            "3" {
                RevisarHTTP
                Read-Host "`nEnter para continuar"
            }
            "4" {
                Write-Host "Saliendo..." -ForegroundColor Cyan
                return
            }
            default {
                Write-Host "[!] Opcion no valida." -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    } while ($true)
}

menuPrincipal
