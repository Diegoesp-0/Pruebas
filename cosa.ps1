# 1. Cambiar el modo directamente sin tocar el XML
Import-Module WebAdministration
Set-ItemProperty "IIS:\Sites\FTP-Servidor" -Name ftpServer.userIsolation.mode -Value 0

# 2. Ver por que no arranca FTPSVC
sc.exe query FTPSVC
net start FTPSVC
# Ver el log de errores
Get-EventLog -LogName System -Newest 5 | Where-Object {$_.Source -like "*ftp*" -or $_.Message -like "*ftp*"} | Select-Object TimeGenerated, Message

# Verificar que el XML es valido
$configPath = "C:\Windows\System32\inetsrv\config\applicationHost.config"
try {
    [xml](Get-Content $configPath) | Out-Null
    Write-Host "XML valido" -ForegroundColor Green
} catch {
    Write-Host "XML CORRUPTO: $_" -ForegroundColor Red
}
