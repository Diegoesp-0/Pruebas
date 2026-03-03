Import-Module WebAdministration

# Ver el valor actual
Get-WebConfigurationProperty -PSPath "IIS:\" -Location "FTP-Servidor" -Filter "system.ftpServer/security/authentication" -Name "."

# Forma alternativa de establecer el aislamiento
$sitio = "FTP-Servidor"
Set-WebConfigurationProperty `
    -PSPath "IIS:\" `
    -Location $sitio `
    -Filter "system.ftpServer/userIsolation" `
    -Name "mode" `
    -Value "IsolateUsers"

# Verificar
Get-WebConfigurationProperty `
    -PSPath "IIS:\" `
    -Location $sitio `
    -Filter "system.ftpServer/userIsolation" `
    -Name "mode"
