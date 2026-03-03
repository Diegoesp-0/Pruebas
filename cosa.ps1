$usuario = "diego"
$equipo = $env:COMPUTERNAME

# Quitar herencia y aplicar permisos directos
icacls "C:\FTP\LocalUser\$usuario" /inheritance:d
icacls "C:\FTP\LocalUser\$usuario" /grant "${equipo}\${usuario}:(OI)(CI)F"
icacls "C:\FTP\LocalUser\$usuario" /grant "Administrators:(OI)(CI)F"
icacls "C:\FTP\LocalUser\$usuario" /grant "SYSTEM:(OI)(CI)F"

# Verificar
icacls "C:\FTP\LocalUser\$usuario"

Restart-Service FTPSVC -Force
