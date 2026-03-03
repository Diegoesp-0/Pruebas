# Ver que hay exactamente dentro de LocalUser\diego
dir C:\FTP\LocalUser\diego\

# Y ver los atributos (para confirmar que los junctions estan bien)
cmd /c "dir /AL C:\FTP\LocalUser\diego\"

$usuario = "diego"

# Dar permiso al usuario en la raiz C:\FTP (IIS lo necesita para navegar)
icacls "C:\FTP" /grant "${usuario}:(RX)" 
icacls "C:\FTP\LocalUser" /grant "${usuario}:(RX)"
icacls "C:\FTP\LocalUser\$usuario" /grant "${usuario}:(OI)(CI)RX" /T

Restart-Service FTPSVC -Force
