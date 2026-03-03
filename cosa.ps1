Import-Module WebAdministration

$configPath = "C:\Windows\System32\inetsrv\config\applicationHost.config"

# Volver al modo de aislamiento correcto
(Get-Content $configPath -Raw) -replace 'mode="None"', 'mode="IsolateRootDirectoryOnly"' | Set-Content $configPath

# Asegurarse que diego tiene permisos en su raiz de aislamiento
icacls "C:\FTP\LocalUser\diego" /grant "diego:(OI)(CI)RX" /T

# Para anonymous: la raiz es LocalUser\Public, que ya tiene solo el junction a _general
# Quitar acceso de anonymous a todo excepto _general
icacls "C:\FTP" /deny "IUSR:(OI)(CI)RX"
icacls "C:\FTP\_general" /grant "IUSR:(OI)(CI)RX"
icacls "C:\FTP\LocalUser\Public" /grant "IUSR:(OI)(CI)RX"

Restart-Service FTPSVC -Force
