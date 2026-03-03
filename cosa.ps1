$configPath = "C:\Windows\System32\inetsrv\config\applicationHost.config"
$content = Get-Content $configPath -Raw -Encoding UTF8

# Mostrar la seccion del sitio FTP
$match = [regex]::Match($content, '<site name="FTP-Servidor".*?</site>', [System.Text.RegularExpressions.RegexOptions]::Singleline)
$match.Value
