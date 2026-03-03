net localgroup Usuarios diego /add
net localgroup Usuarios diego
Restart-Service FTPSVC -Force
