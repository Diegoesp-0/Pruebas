Import-Module WebAdministration
Set-ItemProperty "IIS:\Sites\FTP-Servidor" -Name ftpServer.userIsolation.mode -Value 3
Restart-Service FTPSVC -Force

$configPath = "C:\Windows\System32\inetsrv\config\applicationHost.config"
(Get-Content $configPath -Raw) -replace 'mode="IsolateAllDirectories"', 'mode="IsolateRootDirectoryOnly"' | Set-Content $configPath
Restart-Service FTPSVC -Force
