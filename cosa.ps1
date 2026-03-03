Import-Module WebAdministration

# Volver a modo None (que funciona)
$configPath = "C:\Windows\System32\inetsrv\config\applicationHost.config"
(Get-Content $configPath -Raw) -replace 'mode="IsolateRootDirectoryOnly"', 'mode="None"' | Set-Content $configPath

# Quitar acceso de diego a las carpetas que NO debe ver
icacls "C:\FTP\_recursadores" /deny "diego:(OI)(CI)RX"
icacls "C:\FTP\_usuarios" /deny "diego:(OI)(CI)RX"
icacls "C:\FTP\LocalUser" /deny "diego:(OI)(CI)RX"

# Quitar acceso de IUSR (anonymous) a todo excepto _general
icacls "C:\FTP\_recursadores" /deny "IUSR:(OI)(CI)RX"
icacls "C:\FTP\_reprobados" /deny "IUSR:(OI)(CI)RX"
icacls "C:\FTP\_usuarios" /deny "IUSR:(OI)(CI)RX"
icacls "C:\FTP\LocalUser" /deny "IUSR:(OI)(CI)RX"

Restart-Service FTPSVC -Force
