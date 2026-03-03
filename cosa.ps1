# 1. Ver si la carpeta existe
dir C:\FTP\LocalUser\

# 2. Si no aparece la carpeta "diego", ejecuta esto para crearla manualmente:
$usuario = "diego"
$grupo = "reprobados"   # cambia si es recursadores
$FTP_ROOT = "C:\FTP"

# Crear raiz de aislamiento
New-Item -Path "$FTP_ROOT\LocalUser\$usuario" -ItemType Directory -Force

# Crear carpetas reales si no existen
New-Item -Path "$FTP_ROOT\_general" -ItemType Directory -Force
New-Item -Path "$FTP_ROOT\_$grupo" -ItemType Directory -Force
New-Item -Path "$FTP_ROOT\_usuarios\$usuario" -ItemType Directory -Force

# Crear junction points
cmd /c "mklink /J `"$FTP_ROOT\LocalUser\$usuario\general`" `"$FTP_ROOT\_general`""
cmd /c "mklink /J `"$FTP_ROOT\LocalUser\$usuario\$grupo`" `"$FTP_ROOT\_$grupo`""
cmd /c "mklink /J `"$FTP_ROOT\LocalUser\$usuario\$usuario`" `"$FTP_ROOT\_usuarios\$usuario`""

# Dar permisos al usuario en su raiz
icacls "$FTP_ROOT\LocalUser\$usuario" /grant "${usuario}:(OI)(CI)RX" /T
icacls "$FTP_ROOT\_general" /grant "${usuario}:(OI)(CI)M"
icacls "$FTP_ROOT\_$grupo" /grant "${usuario}:(OI)(CI)M"
icacls "$FTP_ROOT\_usuarios\$usuario" /grant "${usuario}:(OI)(CI)F"

# Reiniciar FTP
Restart-Service FTPSVC -Force
