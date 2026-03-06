Install-WindowsFeature -Name Web-Server, Web-Ftp-Server, Web-Ftp-Service, Web-Mgmt-Console -IncludeManagementTools

Get-WindowsFeature -Name Web-Server
Get-WindowsFeature -Name Web-Ftp-Server
