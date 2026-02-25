function Verificar-SSH {
    Clear-Host
    $cap = Get-WindowsCapability -Online -Name OpenSSH.Server*
    if ($cap.State -eq "Installed") {
        Write-Host ""
        Write-Host "OpenSSH-Server esta instalado :D"
        Write-Host ""
    } else {
        Write-Host ""
        Write-Host "OpenSSH-Server no esta instalado"
        Write-Host ""
        $opc = Read-Host "Desea instalarlo? (S/s)"
        if ($opc -eq "S" -or $opc -eq "s") {
            Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
        }
    }
}

function Iniciar-SSH {
    Clear-Host
    $cap = Get-WindowsCapability -Online -Name OpenSSH.Server*
    if ($cap.State -ne "Installed") {
        Write-Host ""
        Write-Host "ERROR: OpenSSH-Server no esta instalado"
        Write-Host "Ejecute primero: .\ssh_windows.ps1 verificar"
        Write-Host ""
        return
    }
    Set-Service -Name sshd -StartupType Automatic
    Start-Service sshd
    Start-Sleep -Seconds 1
    $svc = Get-Service -Name sshd
    if ($svc.Status -eq "Running") {
        $regla = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
        if (-not $regla) {
            New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (sshd)" -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
        }
        Write-Host ""
        Write-Host "Servidor SSH iniciado correctamente"
        Write-Host "Puerto 22 abierto en el firewall"
        Write-Host ""
        $IP = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.*" } | Select-Object -First 1).IPAddress
        Write-Host "Conectate desde PuTTY:"
        Write-Host "  Host: $IP"
        Write-Host "  Port: 22"
        Write-Host ""
    } else {
        Write-Host ""
        Write-Host "ERROR: No se pudo iniciar SSH"
        Write-Host ""
    }
}

function Reiniciar-SSH {
    Clear-Host
    Restart-Service sshd
    Start-Sleep -Seconds 1
    $svc = Get-Service -Name sshd
    if ($svc.Status -eq "Running") {
        Write-Host ""
        Write-Host "SSH reiniciado correctamente"
        Write-Host ""
    } else {
        Write-Host ""
        Write-Host "ERROR: No se pudo reiniciar SSH"
        Write-Host ""
    }
}

function Detener-SSH {
    Clear-Host
    Stop-Service sshd
    Start-Sleep -Seconds 1
    $svc = Get-Service -Name sshd
    if ($svc.Status -eq "Stopped") {
        Write-Host ""
        Write-Host "SSH detenido correctamente"
        Write-Host ""
    } else {
        Write-Host ""
        Write-Host "ERROR: No se pudo detener SSH"
        Write-Host ""
    }
}

function Estado-SSH {
    Clear-Host
    Write-Host ""
    Get-Service -Name sshd | Format-List Name, Status, StartType
    Write-Host "Conexiones activas en puerto 22:"
    netstat -ano | findstr ":22"
    Write-Host ""
}

$comando = $args[0]

if ($comando -eq "help") {
    Write-Host ""
    Write-Host "============ COMANDOS ============"
    Write-Host "verificar : Verificar si esta instalado OpenSSH-Server"
    Write-Host "iniciar   : Instalar, habilitar e iniciar SSH"
    Write-Host "reiniciar : Reiniciar el servicio SSH"
    Write-Host "detener   : Detener el servicio SSH"
    Write-Host "estado    : Ver estado del servicio y conexiones activas"
    Write-Host ""
} elseif ($comando -eq "verificar") {
    Verificar-SSH
} elseif ($comando -eq "iniciar") {
    Iniciar-SSH
} elseif ($comando -eq "reiniciar") {
    Reiniciar-SSH
} elseif ($comando -eq "detener") {
    Detener-SSH
} elseif ($comando -eq "estado") {
    Estado-SSH
} else {
    Write-Host ""
    Write-Host "Uso: .\ssh_windows.ps1 <comando>"
    Write-Host "     .\ssh_windows.ps1 help  para ver los comandos disponibles"
    Write-Host ""
}
