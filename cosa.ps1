$usuario = "diego"

# Este es el permiso critico que falta - el usuario debe ser dueno de su propia raiz
icacls "C:\FTP\LocalUser\$usuario" /setowner $usuario /T
icacls "C:\FTP\LocalUser\$usuario" /grant "${usuario}:(OI)(CI)F" /T

# Tambien en la raiz superior
icacls "C:\FTP" /grant "${usuario}:(RX)"
icacls "C:\FTP\LocalUser" /grant "${usuario}:(RX)"

Restart-Service FTPSVC -Force
Start-WebSite -Name "FTP-Servidor"
