Get-EventLog -LogName Application -Newest 20 | 
    Where-Object { $_.Message -match "ftp|iis|ftpsvc" -or $_.Source -match "ftp|iis" } | 
    Format-List TimeGenerated, Source, EntryType, Message

    # Ver si existe el log de FTP
$logPath = "$env:SystemRoot\System32\LogFiles\FTPSVC2"
if (Test-Path $logPath) {
    Get-ChildItem $logPath | Sort-Object LastWriteTime -Descending | Select-Object -First 3
    Get-Content (Get-ChildItem $logPath | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName) -Tail 30
} else {
    Write-Host "No existe $logPath, buscando..."
    Get-ChildItem "$env:SystemRoot\System32\LogFiles" -Recurse -Filter "*.log" | 
        Sort-Object LastWriteTime -Descending | Select-Object -First 5
}

# Ver TODOS los sitios IIS
& "$env:SystemRoot\System32\inetsrv\appcmd.exe" list site

# Ver qué proceso usa el puerto 21
netstat -ano | Select-String ":21 "
$pid21 = (netstat -ano | Select-String ":21\s" | Select-Object -First 1) -replace ".*\s(\d+)$",'$1'
if ($pid21) { Get-Process -Id $pid21.Trim() -ErrorAction SilentlyContinue }

# Ver eventos de TODOS los sources en los ultimos 5 minutos
$desde = (Get-Date).AddMinutes(-5)
Get-EventLog -LogName System -After $desde | Format-List TimeGenerated, Source, EntryType, Message
Get-EventLog -LogName Application -After $desde | Format-List TimeGenerated, Source, EntryType, Message
