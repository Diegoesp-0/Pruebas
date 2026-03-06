Get-WindowsFeature Web-Ftp-Server, Web-Ftp-Service, Web-Ftp-Ext | 
    Select Name, Installed, InstallState

    sc.exe query ftpsvc
sc.exe qc ftpsvc

# Ver logs de FTP en el visor de eventos (canal más específico)
Get-WinEvent -ListLog "*ftp*","*iis*" -ErrorAction SilentlyContinue | 
    Select LogName, RecordCount

# Intentar leer el canal de IIS
Get-WinEvent -LogName "Microsoft-IIS-FTPServer/Operational" -MaxEvents 10 `
    -ErrorAction SilentlyContinue | Format-List TimeCreated, Message
