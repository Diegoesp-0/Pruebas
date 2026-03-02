# ============================================================
# utils.ps1 - Funciones de utilidad y colores
# ============================================================

function Print-Error {
    param([string]$msg)
    Write-Host $msg -ForegroundColor Red
}

function Print-Completado {
    param([string]$msg)
    Write-Host $msg -ForegroundColor Green
}

function Print-Info {
    param([string]$msg)
    Write-Host $msg -ForegroundColor Yellow
}

function Print-Titulo {
    param([string]$msg)
    Write-Host ""
    Write-Host "==== $msg ====" -ForegroundColor Cyan
    Write-Host ""
}
