# 1. Ver eventos del sistema en el momento exacto del fallo
$antes = (Get-Date).AddMinutes(-2)
& "$env:SystemRoot\System32\inetsrv\appcmd.exe" start site "ServidorFTP"
Get-WinEvent -LogName "System","Application" -ErrorAction SilentlyContinue | 
    Where-Object { $_.TimeCreated -gt $antes } |
    Format-List TimeCreated, ProviderName, Id, Message

# 2. Ver canal operacional de IIS FTP
Get-WinEvent -LogName "Microsoft-IIS-FTPServer/Operational" -MaxEvents 20 `
    -ErrorAction SilentlyContinue | Format-List TimeCreated, Message

# 3. Ver si hay otro proceso usando el puerto 21
netstat -ano | Select-String ":21"
Get-Process -Id (netstat -ano | Select-String ":21" | 
    ForEach-Object { ($_ -split "\s+")[-1] } | 
    Select-Object -First 1) -ErrorAction SilentlyContinue
