# Ver permisos exactos que tiene diego sobre su carpeta home
icacls "C:\FTP\LocalUser\diego"

$usuario = "diego"
icacls "C:\FTP\LocalUser\$usuario" /grant "${usuario}:(OI)(CI)F" /T
icacls "C:\FTP" /grant "${usuario}:(RX)"
icacls "C:\FTP\LocalUser" /grant "${usuario}:(RX)"
Restart-Service FTPSVC -Force
