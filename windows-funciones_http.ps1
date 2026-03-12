# ============================================================
# windows-funciones_http.ps1
# Funciones para gestion de servidores HTTP en Windows Server 2022 Core
# ============================================================

# =============== MENSAJES ===============
function Write-Ok    { param($msg) Write-Host "[+] $msg" -ForegroundColor Green  }
function Write-Info  { param($msg) Write-Host "[i] $msg" -ForegroundColor Cyan   }
function Write-Err   { param($msg) Write-Host "[x] $msg" -ForegroundColor Red    }
function Write-Warn  { param($msg) Write-Host "[!] $msg" -ForegroundColor Yellow }
function Write-Title { param($msg) Write-Host "`n---- $msg ----`n" -ForegroundColor Magenta }

# =============== RECARGAR PATH ===============
function Refrescar-Path {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path","User")
}

# =============== CHOCOLATEY ===============
function Asegurar-Chocolatey {
    Refrescar-Path
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        Write-Info "Chocolatey disponible."
        return
    }
    Write-Info "Instalando Chocolatey..."
    try {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol =
            [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression (
            (New-Object System.Net.WebClient).DownloadString(
                'https://community.chocolatey.org/install.ps1'
            )
        ) 2>&1 | Out-Null
        Refrescar-Path
        if (Get-Command choco -ErrorAction SilentlyContinue) {
            Write-Ok "Chocolatey instalado correctamente."
            return
        }
        $chocoDir = "$env:ALLUSERSPROFILE\chocolatey\bin"
        if (Test-Path "$chocoDir\choco.exe") {
            $env:Path += ";$chocoDir"
            Write-Ok "Chocolatey instalado (PATH actualizado manualmente)."
        } else {
            Write-Err "No se pudo instalar Chocolatey. Verifica la conexion a internet."
            exit 1
        }
    } catch {
        Write-Err "Error instalando Chocolatey: $_"
        exit 1
    }
}

# =============== VALIDAR PUERTO ===============
function validarPuerto {
    param([int]$puerto)
    $reservados = @(21, 22, 23, 25, 53, 443, 3306, 3389, 5432, 6379, 27017)
    if ($reservados -contains $puerto) {
        Write-Warn "Puerto $puerto reservado para otro servicio."
        return $false
    }
    $enUso = Get-NetTCPConnection -LocalPort $puerto -ErrorAction SilentlyContinue
    if ($enUso) {
        $proc = Get-Process -Id $enUso[0].OwningProcess -ErrorAction SilentlyContinue
        Write-Warn "Puerto $puerto ocupado por: $($proc.ProcessName) (PID: $($enUso[0].OwningProcess))"
        return $false
    }
    return $true
}

# =============== PEDIR PUERTO ===============
function pedirPuerto {
    param([int]$default = 80)
    Write-Host ""
    Write-Host "=== Configuracion de Puerto ===" -ForegroundColor Blue
    Write-Info "Puerto por defecto : $default"
    Write-Info "Otros comunes      : 8080, 8888"
    Write-Info "Bloqueados         : 21 22 23 25 53 443 3306 3389 5432 6379 27017"
    Write-Host ""
    while ($true) {
        $inp = Read-Host "Puerto de escucha (Enter = $default)"
        if ([string]::IsNullOrWhiteSpace($inp)) { $inp = "$default" }
        if ($inp -notmatch '^\d+$') { Write-Warn "Ingresa solo numeros."; continue }
        $puerto = [int]$inp
        if ($puerto -ne 80 -and ($puerto -lt 1024 -or $puerto -gt 65535)) {
            Write-Warn "Puerto fuera de rango. Usa 80 o entre 1024 y 65535."
            continue
        }
        if (validarPuerto -puerto $puerto) {
            Write-Ok "Puerto $puerto aceptado."
            return $puerto
        }
    }
}

# =============== FIREWALL ===============
function configurarFirewall {
    param([int]$puertoNuevo, [int]$puertoViejo = 80, [string]$nombreServicio = "HTTP")
    Write-Info "Configurando firewall..."
    Remove-NetFirewallRule -DisplayName "HTTP-$nombreServicio-$puertoViejo" -ErrorAction SilentlyContinue
    New-NetFirewallRule `
        -DisplayName "HTTP-$nombreServicio-$puertoNuevo" `
        -Direction Inbound -Protocol TCP -LocalPort $puertoNuevo `
        -Action Allow -Profile Any | Out-Null
    Write-Ok "Firewall: puerto $puertoNuevo abierto para $nombreServicio."
}

# =============== CREAR INDEX.HTML ===============
function crearHTML {
    param([string]$rutaWeb, [string]$servicio, [string]$version, [int]$puerto)
    if (-not (Test-Path $rutaWeb)) {
        New-Item -ItemType Directory -Path $rutaWeb -Force | Out-Null
    }
    # Usar WriteAllText con UTF8 sin BOM para evitar errores en nginx/apache
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    $contenido = @"
<!DOCTYPE html>
<html lang="es">
<head><meta charset="UTF-8"><title>Servidor HTTP - Windows</title></head>
<body>
<h1>Windows - Servidor Activo</h1>
<p>Servidor: $servicio</p>
<p>Version: $version</p>
<p>Puerto: $puerto</p>
</body>
</html>
"@
    [System.IO.File]::WriteAllText("$rutaWeb\index.html", $contenido, $utf8NoBom)
    Write-Ok "index.html creado en $rutaWeb"
}

# =============== BUSCAR RUTA NGINX ===============
function Obtener-Ruta-Nginx {
    # Choco v2 instala en: C:\ProgramData\chocolatey\lib\nginx\tools\nginx-VERSION\
    $libPath = "C:\ProgramData\chocolatey\lib\nginx\tools"
    if (Test-Path $libPath) {
        $exe = Get-ChildItem $libPath -Filter "nginx.exe" -Recurse `
            -ErrorAction SilentlyContinue -Depth 3 | Select-Object -First 1
        if ($exe) { return $exe.DirectoryName }
    }
    # Choco v1/herramienta instala en C:\tools\nginx-VERSION\
    if (Test-Path "C:\tools") {
        $exe = Get-ChildItem "C:\tools" -Filter "nginx.exe" -Recurse `
            -ErrorAction SilentlyContinue -Depth 5 | Select-Object -First 1
        if ($exe) { return $exe.DirectoryName }
    }
    # Rutas directas alternativas
    foreach ($r in @("C:\nginx", "C:\nginx\nginx")) {
        if (Test-Path "$r\nginx.exe") { return $r }
    }
    # Busqueda amplia - excluir bin\ de choco (es shim, no el exe real)
    $exe = Get-ChildItem "C:\" -Filter "nginx.exe" -Recurse `
        -ErrorAction SilentlyContinue -Depth 7 |
        Where-Object { $_.FullName -notlike "*\bin\*" } |
        Select-Object -First 1
    if ($exe) { return $exe.DirectoryName }
    return $null
}
# =============== INSTALAR IIS ===============
function instalarIIS {
    param([int]$puerto)
    Write-Title "Instalando IIS..."
    $winVer = (Get-WmiObject Win32_OperatingSystem).Caption
    $iisVersion = switch -Wildcard ($winVer) {
        "*Server 2022*" { "10.0" } "*Server 2019*" { "10.0" }
        "*Server 2016*" { "10.0" } "*Server 2012*" { "8.5"  }
        "*Windows 1*"   { "10.0" } default          { "10.0" }
    }
    Write-Info "Sistema: $winVer"
    Write-Info "Version IIS disponible: $iisVersion (determinada por Windows)"
    Write-Host ""
    $confirmar = Read-Host "Instalar IIS $iisVersion en puerto $puerto? (s/n)"
    if ($confirmar -ne 's') { return }

    $features = @("Web-Server","Web-Common-Http","Web-Static-Content",
                  "Web-Default-Doc","Web-Http-Errors","Web-Security",
                  "Web-Filtering","Web-Http-Logging","Web-Stat-Compression")
    foreach ($f in $features) {
        Install-WindowsFeature -Name $f -ErrorAction SilentlyContinue | Out-Null
    }
    Write-Ok "IIS instalado."

    $appcmd = "$env:SystemRoot\system32\inetsrv\appcmd.exe"
    & $appcmd set site "Default Web Site" /bindings:"http/*:${puerto}:" 2>&1 | Out-Null
    Write-Ok "Puerto configurado: $puerto"

    $webConfig = "$env:SystemDrive\inetpub\wwwroot\web.config"
    Set-Content -Path $webConfig -Encoding UTF8 -Value @"
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.webServer>
    <security>
      <requestFiltering removeServerHeader="true">
        <verbs>
          <add verb="TRACE" allowed="false" />
          <add verb="TRACK" allowed="false" />
        </verbs>
      </requestFiltering>
    </security>
    <httpProtocol>
      <customHeaders>
        <remove name="X-Powered-By" />
        <add name="X-Frame-Options"        value="SAMEORIGIN" />
        <add name="X-Content-Type-Options" value="nosniff"    />
      </customHeaders>
    </httpProtocol>
  </system.webServer>
</configuration>
"@
    Write-Ok "Seguridad configurada (web.config)."

    $webroot = "$env:SystemDrive\inetpub\wwwroot"
    $acl  = Get-Acl $webroot
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "IIS_IUSRS","ReadAndExecute","ContainerInherit,ObjectInherit","None","Allow")
    $acl.SetAccessRule($rule)
    Set-Acl $webroot $acl
    Write-Ok "Permisos aplicados: IIS_IUSRS -> ReadAndExecute."

    crearHTML -rutaWeb $webroot -servicio "IIS" -version $iisVersion -puerto $puerto
    configurarFirewall -puertoNuevo $puerto -puertoViejo 80 -nombreServicio "IIS"

    Start-Service W3SVC -ErrorAction SilentlyContinue
    Set-Service   W3SVC -StartupType Automatic
    Start-Sleep -Seconds 2

    $svc = Get-Service W3SVC -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") {
        Write-Ok "IIS activo en puerto $puerto"
    } else {
        Write-Err "IIS no arranco. Revisa el Visor de Eventos."
    }
}

# =============== INSTALAR APACHE ===============
function instalarApache {
    param([int]$puerto)
    Write-Title "Instalando Apache HTTP Server..."
    Asegurar-Chocolatey

    Write-Info "Consultando versiones disponibles de apache-httpd..."
    $rawVersiones = choco search apache-httpd --exact --all-versions --limit-output 2>$null
    $versiones = @()
    foreach ($linea in $rawVersiones) {
        if ($linea -match '\|') {
            $ver = ($linea -split '\|')[1].Trim()
            if ($ver -match '^\d+\.\d+' -and $versiones -notcontains $ver) { $versiones += $ver }
        }
    }
    if ($versiones.Count -eq 0) { Write-Err "No se encontraron versiones. Verifica internet."; return }

    Write-Host ""
    Write-Host "Versiones disponibles:" -ForegroundColor Cyan
    $limite = [Math]::Min($versiones.Count, 3)
    for ($i = 0; $i -lt $limite; $i++) {
        $etiqueta = switch ($i) {
            0 { "[Latest - Desarrollo]" } 1 { "[Estable anterior]" } 2 { "[LTS]" }
        }
        Write-Host "  $($i+1). $($versiones[$i])  $etiqueta"
    }
    Write-Host ""
    do { $selVer = Read-Host "Selecciona version (1-$limite)" } while ($selVer -notmatch "^[1-$limite]$")
    $versionElegida = $versiones[[int]$selVer - 1]

    Write-Info "Instalando Apache $versionElegida en puerto $puerto..."
    choco install apache-httpd `
        --version="$versionElegida" `
        --params="`"/port:$puerto /installLocation:C:\Apache24`"" `
        --yes --no-progress --force 2>&1 | Out-Null

    if ($LASTEXITCODE -ne 0) { Write-Err "Fallo la instalacion. Codigo: $LASTEXITCODE"; return }
    Refrescar-Path

    # Buscar donde quedo instalado (el param /installLocation no siempre aplica)
    $posibles = @("C:\Apache24","$env:APPDATA\Apache24","$env:LOCALAPPDATA\Apache24")
    $apacheRoot = $posibles | Where-Object { Test-Path "$_\bin\httpd.exe" } | Select-Object -First 1
    if (-not $apacheRoot) {
        $httpd = Get-ChildItem "C:\" -Filter "httpd.exe" -Recurse `
            -ErrorAction SilentlyContinue -Depth 6 | Select-Object -First 1
        if ($httpd) { $apacheRoot = $httpd.DirectoryName -replace '\\bin$','' }
    }
    if (-not $apacheRoot) { Write-Err "No se encontro la instalacion de Apache."; return }
    Write-Ok "Apache instalado en: $apacheRoot"

    $httpdConf = "$apacheRoot\conf\httpd.conf"
    if (Test-Path $httpdConf) {
        $conf = Get-Content $httpdConf -Raw
        if ($conf -notmatch "Listen\s+$puerto") {
            $conf = $conf -replace 'Listen\s+\d+', "Listen $puerto"
            Set-Content $httpdConf $conf -Encoding UTF8
            Write-Ok "Puerto $puerto aplicado en httpd.conf."
        }
        if ($conf -notmatch 'TAREA6-SECURITY') {
            Add-Content -Path $httpdConf -Value @"

# TAREA6-SECURITY-START
ServerTokens Prod
ServerSignature Off

<LimitExcept GET POST HEAD>
    Require all denied
</LimitExcept>

Header always set X-Frame-Options "SAMEORIGIN"
Header always set X-Content-Type-Options "nosniff"
# TAREA6-SECURITY-END
"@
            Write-Ok "Seguridad configurada en httpd.conf."
        }
    }

    crearHTML -rutaWeb "$apacheRoot\htdocs" -servicio "Apache HTTP Server" -version $versionElegida -puerto $puerto
    configurarFirewall -puertoNuevo $puerto -puertoViejo 80 -nombreServicio "Apache"

    $svc = Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "^Apache" } | Select-Object -First 1
    if (-not $svc) {
        $httpdExe = "$apacheRoot\bin\httpd.exe"
        if (Test-Path $httpdExe) {
            Write-Info "Registrando servicio Apache..."
            & $httpdExe -k install 2>&1 | Out-Null
            Start-Sleep -Seconds 2
            $svc = Get-Service -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match "^Apache" } | Select-Object -First 1
        }
    }
    if ($svc) {
        Start-Service $svc.Name -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        $svc = Get-Service $svc.Name -ErrorAction SilentlyContinue
        if ($svc.Status -eq "Running") {
            Write-Ok "Apache activo en puerto $puerto"
        } else {
            Write-Err "Apache no arranco. Revisa: $apacheRoot\logs\error.log"
        }
    } else {
        Write-Err "No se pudo registrar el servicio Apache."
    }
}

# =============== INSTALAR NGINX ===============
function instalarNginx {
    param([int]$puerto)
    Write-Title "Instalando Nginx..."
    Asegurar-Chocolatey

    Write-Info "Consultando versiones disponibles de Nginx..."
    $rawVersiones = choco search nginx --exact --all-versions --limit-output 2>$null
    $versiones = @()
    foreach ($linea in $rawVersiones) {
        if ($linea -match '\|') {
            $ver = ($linea -split '\|')[1].Trim()
            if ($ver -match '^\d+\.\d+' -and $versiones -notcontains $ver) { $versiones += $ver }
        }
    }
    if ($versiones.Count -eq 0) { Write-Err "No se encontraron versiones de Nginx."; return }

    $mainline = $versiones | Where-Object {
        $p = $_ -split '\.'; $p.Count -ge 2 -and ([int]$p[1] % 2 -ne 0)
    } | Select-Object -First 1
    $stable = $versiones | Where-Object {
        $p = $_ -split '\.'; $p.Count -ge 2 -and ([int]$p[1] % 2 -eq 0)
    } | Select-Object -First 1
    if (-not $mainline) { $mainline = $versiones[0] }
    if (-not $stable)   { $stable   = if ($versiones.Count -ge 2) { $versiones[1] } else { $versiones[0] } }

    Write-Host ""
    Write-Host "Versiones disponibles:" -ForegroundColor Cyan
    Write-Host "  1. $mainline  [Mainline - Desarrollo]"
    Write-Host "  2. $stable    [Stable - LTS]"
    Write-Host ""
    do { $selVer = Read-Host "Selecciona version (1/2)" } while ($selVer -notmatch '^[12]$')
    $versionElegida = if ($selVer -eq "1") { $mainline } else { $stable }

    Write-Info "Instalando Nginx $versionElegida..."
    choco install nginx --version="$versionElegida" --yes --no-progress --force 2>&1 | Out-Null
    # choco puede retornar exit 0 aunque no reinstale (ya instalado); no cortar aqui
    Refrescar-Path

    # Verificar que nginx.exe exista antes de continuar
    $nginxRootCheck = Obtener-Ruta-Nginx
    if (-not $nginxRootCheck) {
        Write-Err "No se encontro nginx.exe. Verifica la instalacion de Chocolatey."
        Write-Info "Intenta manualmente: choco install nginx --version=$versionElegida --force"
        return
    }
    Write-Ok "Nginx $versionElegida disponible en: $nginxRootCheck"

    if (-not (Get-Command nssm -ErrorAction SilentlyContinue)) {
        Write-Info "Instalando NSSM..."
        choco install nssm --yes --no-progress 2>&1 | Out-Null
        Refrescar-Path
    }

    $nginxRoot = Obtener-Ruta-Nginx
    if (-not $nginxRoot) { Write-Err "No se encontro nginx.exe tras la instalacion."; return }
    Write-Info "Nginx encontrado en: $nginxRoot"

    $nginxConf = "$nginxRoot\conf\nginx.conf"
    # Escribir nginx.conf completo sin BOM (BOM causa "unknown directive" en nginx)
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    $nginxConfContent = @"
worker_processes  1;

events {
    worker_connections  1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;

    server_tokens off;

    sendfile        on;
    keepalive_timeout  65;

    server {
        listen       $puerto;
        server_name  localhost;

        add_header X-Frame-Options SAMEORIGIN always;
        add_header X-Content-Type-Options nosniff always;

        location / {
            root   html;
            index  index.html index.htm;
            autoindex off;
        }

        error_page   500 502 503 504  /50x.html;
        location = /50x.html {
            root   html;
        }
    }
}
"@
    [System.IO.File]::WriteAllText($nginxConf, $nginxConfContent, $utf8NoBom)
    Write-Ok "nginx.conf escrito sin BOM, puerto $puerto configurado."

    crearHTML -rutaWeb "$nginxRoot\html" -servicio "Nginx" -version $versionElegida -puerto $puerto
    configurarFirewall -puertoNuevo $puerto -puertoViejo 80 -nombreServicio "Nginx"

    $serviceName = "nginx-$puerto"
    $nginxExe    = "$nginxRoot\nginx.exe"
    $svcAnterior = Get-Service $serviceName -ErrorAction SilentlyContinue
    if ($svcAnterior) {
        Stop-Service $serviceName -Force -ErrorAction SilentlyContinue
        & nssm remove $serviceName confirm 2>&1 | Out-Null
    }
    & nssm install $serviceName $nginxExe 2>&1 | Out-Null
    & nssm set     $serviceName AppDirectory $nginxRoot 2>&1 | Out-Null
    & nssm set     $serviceName DisplayName "Nginx HTTP Server (puerto $puerto)" 2>&1 | Out-Null
    & nssm set     $serviceName Start SERVICE_AUTO_START 2>&1 | Out-Null
    & nssm set     $serviceName AppStdout "$nginxRoot\logs\service.log" 2>&1 | Out-Null
    & nssm set     $serviceName AppStderr "$nginxRoot\logs\service-error.log" 2>&1 | Out-Null

    Start-Service $serviceName -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    $svc = Get-Service $serviceName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") {
        Write-Ok "Nginx activo en puerto $puerto (servicio: $serviceName)"
    } else {
        Write-Err "Nginx no arranco. Revisa: $nginxRoot\logs\error.log"
        Write-Info "O inicia manualmente: nssm start $serviceName"
    }
}

# =============== INSTALAR HTTP (menu interno) ===============
function InstalarHTTP {
    Clear-Host
    Write-Host ""
    Write-Host "------------------------------------------------" -ForegroundColor Blue
    Write-Host "         INSTALACION DE SERVIDOR HTTP           " -ForegroundColor Blue
    Write-Host "------------------------------------------------" -ForegroundColor Blue
    Write-Host "  1. IIS  (nativo Windows)"
    Write-Host "  2. Apache HTTP Server"
    Write-Host "  3. Nginx"
    Write-Host "  0. Volver"
    Write-Host "------------------------------------------------" -ForegroundColor Blue
    Write-Host ""
    $s = Read-Host "Servidor"
    if ($s -eq "0") { return }
    if ($s -notin @("1","2","3")) { Write-Warn "Opcion no valida."; return }
    $puerto = pedirPuerto -default 80
    switch ($s) {
        "1" { instalarIIS    -puerto $puerto }
        "2" { instalarApache -puerto $puerto }
        "3" { instalarNginx  -puerto $puerto }
    }
}

# =============== VERIFICAR ESTADO ===============
function VerificarHTTP {
    Clear-Host
    Write-Host ""
    Write-Host "=== Estado de Servidores HTTP ===" -ForegroundColor Blue
    Write-Host ""

    Write-Host -NoNewline "  IIS     : "
    $iis = Get-Service W3SVC -ErrorAction SilentlyContinue
    if ($iis) {
        $ver    = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\InetStp" -ErrorAction SilentlyContinue).VersionString
        $appcmd = "$env:SystemRoot\system32\inetsrv\appcmd.exe"
        $puerto = & $appcmd list site "Default Web Site" 2>$null |
            Select-String ':(\d+):' | ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -First 1
        if ($iis.Status -eq "Running") {
            Write-Host "Activo -- version: $ver -- puerto: $puerto" -ForegroundColor Green
        } else { Write-Host "Detenido -- version: $ver" -ForegroundColor Yellow }
    } else { Write-Host "No instalado" -ForegroundColor Red }

    Write-Host -NoNewline "  Apache2 : "
    $apache = Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "^Apache" } | Select-Object -First 1
    if ($apache) {
        $apacheRoot = @("C:\Apache24","$env:APPDATA\Apache24") |
            Where-Object { Test-Path "$_\conf\httpd.conf" } | Select-Object -First 1
        $puerto = if ($apacheRoot) {
            Get-Content "$apacheRoot\conf\httpd.conf" |
                Select-String '^Listen\s+(\d+)' |
                ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -First 1
        } else { "?" }
        if ($apache.Status -eq "Running") {
            Write-Host "Activo -- puerto: $puerto" -ForegroundColor Green
        } else { Write-Host "Detenido -- puerto: $puerto" -ForegroundColor Yellow }
    } else { Write-Host "No instalado" -ForegroundColor Red }

    Write-Host -NoNewline "  Nginx   : "
    $nginx = Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "^nginx" } | Select-Object -First 1
    if ($nginx) {
        $nginxRoot = Obtener-Ruta-Nginx
        $puerto = if ($nginxRoot -and (Test-Path "$nginxRoot\conf\nginx.conf")) {
            Get-Content "$nginxRoot\conf\nginx.conf" |
                Select-String 'listen\s+(\d+)' |
                ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -First 1
        } else { "?" }
        if ($nginx.Status -eq "Running") {
            Write-Host "Activo -- puerto: $puerto (servicio: $($nginx.Name))" -ForegroundColor Green
        } else { Write-Host "Detenido -- puerto: $puerto" -ForegroundColor Yellow }
    } else { Write-Host "No instalado" -ForegroundColor Red }

    Write-Host ""
}

# =============== REVISAR HTTP ===============
function RevisarHTTP {
    Clear-Host
    Write-Host ""
    Write-Host "=== Revision de Servidores HTTP ===" -ForegroundColor Blue
    Write-Host ""
    Write-Host "  [1] IIS"
    Write-Host "  [2] Apache2"
    Write-Host "  [3] Nginx"
    Write-Host "  [4] Todos"
    Write-Host ""
    $opcion = Read-Host "Selecciona [1-4]"
    if ($opcion -notmatch '^[1234]$') { Write-Warn "Opcion invalida."; return }

    function Curl-Servidor {
        param([string]$nombre, [int]$puerto)
        Write-Host ""
        Write-Host "--- $nombre (puerto $puerto) ---" -ForegroundColor Blue
        Write-Host "Headers:" -ForegroundColor Cyan
        try {
            $resp = Invoke-WebRequest -Uri "http://localhost:$puerto" -Method Head -UseBasicParsing -ErrorAction Stop
            $resp.Headers.GetEnumerator() | ForEach-Object { Write-Host "  $($_.Key): $($_.Value)" }
        } catch { Write-Err "Sin respuesta en puerto $puerto" }
        Write-Host "Index:" -ForegroundColor Cyan
        try {
            $resp = Invoke-WebRequest -Uri "http://localhost:$puerto" -UseBasicParsing -ErrorAction Stop
            Write-Host $resp.Content
        } catch { Write-Err "No se pudo obtener index de puerto $puerto" }
    }

    $appcmd = "$env:SystemRoot\system32\inetsrv\appcmd.exe"
    $puertoIIS = if (Test-Path $appcmd) {
        & $appcmd list site "Default Web Site" 2>$null |
            Select-String ':(\d+):' | ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -First 1
    } else { 80 }

    $apacheRoot   = @("C:\Apache24","$env:APPDATA\Apache24") |
        Where-Object { Test-Path "$_\conf\httpd.conf" } | Select-Object -First 1
    $puertoApache = if ($apacheRoot) {
        Get-Content "$apacheRoot\conf\httpd.conf" |
            Select-String '^Listen\s+(\d+)' |
            ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -First 1
    } else { 80 }

    $nginxRoot    = Obtener-Ruta-Nginx
    $puertoNginx  = if ($nginxRoot -and (Test-Path "$nginxRoot\conf\nginx.conf")) {
        Get-Content "$nginxRoot\conf\nginx.conf" |
            Select-String 'listen\s+(\d+)' |
            ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -First 1
    } else { 80 }

    switch ($opcion) {
        "1" { Curl-Servidor "IIS"    ([int]$puertoIIS)    }
        "2" { Curl-Servidor "Apache" ([int]$puertoApache) }
        "3" { Curl-Servidor "Nginx"  ([int]$puertoNginx)  }
        "4" {
            Curl-Servidor "IIS"    ([int]$puertoIIS)
            Curl-Servidor "Apache" ([int]$puertoApache)
            Curl-Servidor "Nginx"  ([int]$puertoNginx)
        }
    }
}
