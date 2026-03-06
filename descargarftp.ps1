Install-WindowsFeature Web-Ftp-Ext -IncludeManagementTools

# Verificar
Get-WindowsFeature Web-Ftp-Server, Web-Ftp-Service, Web-Ftp-Ext | 
    Select Name, Installed, InstallState

    Stop-Service ftpsvc -Force
Start-Sleep -Seconds 3
Start-Service ftpsvc
Start-Sleep -Seconds 3

& "$env:SystemRoot\System32\inetsrv\appcmd.exe" start site "ServidorFTP"
& "$env:SystemRoot\System32\inetsrv\appcmd.exe" list site "ServidorFTP"
