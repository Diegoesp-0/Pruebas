$configFile = "$env:SystemRoot\System32\inetsrv\config\applicationHost.config"
[xml]$xml = Get-Content $configFile
$xml.configuration.'system.applicationHost'.sites.site | 
    Where-Object { $_.name -eq "ServidorFTP" } | 
    Select-Object -ExpandProperty OuterXml

    # Eliminar
& "$env:SystemRoot\System32\inetsrv\appcmd.exe" delete site "ServidorFTP"

# Crear con appcmd puro
& "$env:SystemRoot\System32\inetsrv\appcmd.exe" add site `
    /name:"ServidorFTP" `
    /bindings:"ftp/*:21:" `
    /physicalPath:"C:\ftp"

# Configurar FTP directo en el XML
$configFile = "$env:SystemRoot\System32\inetsrv\config\applicationHost.config"
[xml]$xml = Get-Content $configFile

$site = $xml.configuration.'system.applicationHost'.sites.site | 
    Where-Object { $_.name -eq "ServidorFTP" }

# Crear nodo ftpServer manualmente
$ftpServer = $xml.CreateElement("ftpServer")

$userIso = $xml.CreateElement("userIsolation")
$userIso.SetAttribute("mode", "IsolateAllDirectories")
$ftpServer.AppendChild($userIso) | Out-Null

$security = $xml.CreateElement("security")
$auth = $xml.CreateElement("authentication")
$basic = $xml.CreateElement("basicAuthentication")
$basic.SetAttribute("enabled", "true")
$anon = $xml.CreateElement("anonymousAuthentication")
$anon.SetAttribute("enabled", "true")
$auth.AppendChild($basic) | Out-Null
$auth.AppendChild($anon) | Out-Null

$ssl = $xml.CreateElement("ssl")
$ssl.SetAttribute("controlChannelPolicy", "SslAllow")
$ssl.SetAttribute("dataChannelPolicy", "SslAllow")
$security.AppendChild($auth) | Out-Null
$security.AppendChild($ssl) | Out-Null
$ftpServer.AppendChild($security) | Out-Null

$site.AppendChild($ftpServer) | Out-Null
$xml.Save($configFile)

# Reiniciar y arrancar
Stop-Service ftpsvc -Force
Start-Sleep -Seconds 3
Start-Service ftpsvc
Start-Sleep -Seconds 3

& "$env:SystemRoot\System32\inetsrv\appcmd.exe" start site "ServidorFTP"
& "$env:SystemRoot\System32\inetsrv\appcmd.exe" list site "ServidorFTP"
