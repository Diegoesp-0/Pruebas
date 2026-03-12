# ============================================================
# Funciones para gestion de los servidores HTTP
# ============================================================

# ----------------
# Generales
# ----------------

function printWarn {
    param([string]$msg)
    Write-Host "[!] $msg" -ForegroundColor Yellow
}

function printOK {
    param([string]$msg)
    Write-Host "[+] $msg" -ForegroundColor Green
}

function printError {
    param([string]$msg)
    Write-Host "[x] $msg" -ForegroundColor Red
}

function printInfo {
    param([string]$msg)
    Write-Host "[i] $msg" -ForegroundColor Cyan
}

# ----------------
# Pedir puerto al usuario + validacion de que sea un puerto usable lol
# ----------------
function pedirPuerto {
    param([int]$default = 80)

    while ($true) {
        $input = Read-Host "Puerto de escucha (default: $default, rango: 1024-65535)"

        # Si presiona Enter sin escribir, usar default
        if ([string]::IsNullOrWhiteSpace($input)) {
            $puerto = $default
        } else {
            # Validar que sea numero
            if ($input -notmatch '^\d+$') {
                printWarn "Ingresa solo numeros."
                continue
            }
            $puerto = [int]$input
        }

        # Rango valido (evitar puertos del sistema < 1024, excepto 80)
        if ($puerto -ne 80 -and ($puerto -lt 1024 -or $puerto -gt 65535)) {
            printWarn "Puerto fuera de rango. Usa 80 o entre 1024-65535."
            continue
        }

        if (validarPuerto -puerto $puerto) {
            return $puerto
        } else {
            printWarn "Elige otro puerto."
        }
    }
}

# ----------------
# Retorna $true si esta libre, $false si ocupado
# ----------------
function validarPuerto {
    param([int]$puerto)

    # Puertos reservados del sistema que no se deben usar
    $reservados = @(22, 23, 25, 443, 3306, 3389, 5432, 8443)
    if ($reservados -contains $puerto) {
        printWarn "El puerto $puerto esta reservado para otro servicio."
        return $false
    }

    # Verificar si el puerto esta en uso
    $enUso = Get-NetTCPConnection -LocalPort $puerto -ErrorAction SilentlyContinue
    if ($enUso) {
        # Identificar que proceso lo usa (informativo)
        $proceso = Get-Process -Id $enUso[0].OwningProcess -ErrorAction SilentlyContinue
        printWarn "Puerto $puerto ocupado por: $($proceso.ProcessName) (PID: $($enUso[0].OwningProcess))"
        return $false
    }

    return $true
}

# ----------------
# Configuracion del firewall, cierra el puerto default (80) y abre el que pide el usuario
# ----------------
function configurarFirewall {
    param(
        [int]$puertNuevo,
        [int]$puertoViejo = 80,
        [string]$nombreServicio = "HTTP"
    )

    printInfo "Configurando firewall..."

    # Eliminar regla vieja si existe
    Remove-NetFirewallRule -DisplayName "HTTP-$nombreServicio-$puertoViejo" -ErrorAction SilentlyContinue

    # Crear nueva regla para el puerto elegido
    New-NetFirewallRule `
        -DisplayName "HTTP-$nombreServicio-$puertNuevo" `
        -Direction Inbound `
        -Protocol TCP `
        -LocalPort $puertNuevo `
        -Action Allow | Out-Null

    printOK "Firewall: puerto $puertNuevo abierto."

    # Si el puerto viejo era 80 y el nuevo no es 80, cerrar el 80
    if ($puertoViejo -eq 80 -and $puertNuevo -ne 80) {
        # Solo cerrar si ningun otro servicio lo necesita
        $reglas = Get-NetFirewallRule -DisplayName "HTTP-*-80" -ErrorAction SilentlyContinue
        if (-not $reglas) {
            New-NetFirewallRule `
                -DisplayName "BLOCK-HTTP-80" `
                -Direction Inbound `
                -Protocol TCP `
                -LocalPort 80 `
                -Action Block | Out-Null
            printOK "Firewall: puerto 80 bloqueado (no en uso)."
        }
    }
}


# ----------------
# Instalar apache con chocolatey
# ----------------
function instalarApache {
    param([int]$puerto)

    Clear-Host
    Write-Host "--- Instalacion de Apache HTTP Server ---" -ForegroundColor Magenta
    Write-Host ""

    # ── Consultar versiones usando 'search' (funciona en Chocolatey v2.x) ──
    printInfo "Consultando versiones disponibles de apache-httpd..."

    # En Chocolatey v2, 'list' solo muestra paquetes locales
    # 'search' consulta el repositorio remoto
    $rawVersiones = choco search apache-httpd --exact --all-versions --limit-output 2>$null

    $versiones = @()
    foreach ($linea in $rawVersiones) {
        if ($linea -match '\|') {
            $ver = ($linea -split '\|')[1].Trim()
            if ($versiones -notcontains $ver) {
                $versiones += $ver
            }
        }
    }

    if ($versiones.Count -eq 0) {
        printError "No se encontraron versiones. Verifica internet y ejecuta: choco search apache-httpd --exact"
        return
    }

    # Mostrar versiones (maximo 3)
    Write-Host ""
    Write-Host "Versiones disponibles en repositorio:" -ForegroundColor Cyan
    $limite = [Math]::Min($versiones.Count, 3)
    for ($i = 0; $i -lt $limite; $i++) {
        $etiqueta = switch ($i) {
            0 { "[Latest - Desarrollo]" }
            1 { "[Estable anterior]"    }
            2 { "[LTS]"                 }
        }
        Write-Host "  $($i+1). $($versiones[$i])  $etiqueta"
    }
    Write-Host ""

    do {
        $selVer = Read-Host "Selecciona version (1-$limite)"
    } while ($selVer -notmatch "^[1-$limite]$")

    $versionElegida = $versiones[[int]$selVer - 1]

    # ── Instalacion silenciosa pasando el puerto directamente como parametro ──
    # Esto evita tener que editar httpd.conf manualmente
    printInfo "Instalando Apache $versionElegida en puerto $puerto..."

    choco install apache-httpd `
        --version="$versionElegida" `
        --params="`"/port:$puerto /installLocation:C:\Apache24`"" `
        --yes `
        --no-progress `
        --force

    if ($LASTEXITCODE -ne 0) {
        printError "Fallo la instalacion. Codigo: $LASTEXITCODE"
        return
    }

    # Recargar PATH
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path","User")

    printOK "Apache $versionElegida instalado en C:\Apache24"

    # ── Seguridad ──
    aplicarSeguridadApache -apachePath "C:\Apache24"

    # ── Index HTML ──
    crearHTML `
        -rutaWeb "C:\Apache24\htdocs" `
        -servicio "Apache HTTP Server" `
        -version $versionElegida `
        -puerto $puerto

    # ── Firewall ──
    configurarFirewall -puertNuevo $puerto -puertoViejo 80 -nombreServicio "Apache"

    # ── Verificar servicio ──
    Start-Sleep -Seconds 3
    $svc = Get-Service "Apache*" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($svc -and $svc.Status -eq "Running") {
        printOK "Apache corriendo en http://localhost:$puerto"
    } else {
        printWarn "Servicio no inicio automaticamente."
        printWarn "Intenta manualmente: net start Apache2.4"
    }
}

# ----------------
# Instalar IIS
# ----------------
function instalarIIS {
    param([int]$puerto)

    Clear-Host
    Write-Host "--- Instalacion de IIS ---" -ForegroundColor Magenta
    Write-Host ""

    # IIS no tiene versiones elegibles manualmente (depende del Windows)
    # Pero podemos mostrar la version del sistema y la de IIS disponible
    $winVer = (Get-WmiObject Win32_OperatingSystem).Caption
    printInfo "Sistema actual: $winVer"

    # Determinar version IIS segun Windows
    $iisVersion = switch -Wildcard ($winVer) {
        "*Windows 11*"     { "10.0" }
        "*Windows 10*"     { "10.0" }
        "*Server 2022*"    { "10.0" }
        "*Server 2019*"    { "10.0" }
        "*Server 2016*"    { "10.0" }
        "*Server 2012*"    { "8.5"  }
        default             { "10.0" }
    }

    Write-Host ""
    Write-Host "Version IIS disponible para tu sistema: $iisVersion" -ForegroundColor Cyan
    Write-Host "(IIS se instala segun la version de Windows, no se puede elegir otra)"
    Write-Host ""

    $confirmar = Read-Host "¿Instalar IIS $iisVersion en puerto $puerto? (s/n)"
    if ($confirmar -ne 's') { return }

    # ── Instalacion ──
    printInfo "Instalando IIS..."

    # Instalar IIS con herramientas de administracion
    Install-WindowsFeature -Name Web-Server -IncludeManagementTools -ErrorAction Stop | Out-Null

    # Instalar modulos de seguridad adicionales
    Install-WindowsFeature -Name Web-Security | Out-Null         # Request Filtering
    Install-WindowsFeature -Name Web-IP-Security | Out-Null      # Restricciones IP

    printOK "IIS instalado."

    # ── Importar modulo WebAdministration (para manejar IIS con PS) ──
    Import-Module WebAdministration -ErrorAction Stop

    # ── Cambiar puerto ──
    printInfo "Configurando puerto $puerto..."

    # Limpiar binding por defecto (*:80:) y agregar el nuevo
    Remove-WebBinding -Name "Default Web Site" -BindingInformation "*:80:" -ErrorAction SilentlyContinue
    New-WebBinding -Name "Default Web Site" -Protocol "http" -Port $puerto -IPAddress "*"

    printOK "Puerto configurado: $puerto"

    # ── Seguridad: ocultar version del servidor ──
    SeguridadIIS

    # ── Firewall ──
    configurarFirewall -puertNuevo $puerto -puertoViejo 80 -nombreServicio "IIS"

    # ── Permisos: usuario dedicado para IIS ──
    Configurar-UsuarioIIS

    # ── Crear index.html ──
    CrearHTML -rutaWeb "C:\inetpub\wwwroot" -servicio "IIS" -version $iisVersion -puerto $puerto

    # ── Iniciar servicio ──
    Start-Service W3SVC
    Set-Service W3SVC -StartupType Automatic

    printOK "IIS activo en http://localhost:$puerto"
    Write-Host ""

    # Verificar con curl
    Start-Sleep -Seconds 2
    printInfo "Verificando headers HTTP..."
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:$puerto" -Method HEAD -UseBasicParsing
        Write-Host "Headers recibidos:" -ForegroundColor Cyan
        $response.Headers | Format-Table -AutoSize
    } catch {
        printWarn "No se pudo verificar automaticamente. Usa: curl -I http://localhost:$puerto"
    }
}

# ----------------
# USUARIO DEDICADO PARA IIS
# ----------------
function configurarUsuarioIIS {
    printInfo "Configurando usuario dedicado para IIS..."

    $usuario = "iis_webuser"
    $rutaWeb = "C:\inetpub\wwwroot"

    # Crear usuario local con contraseña aleatoria (sin acceso interactivo)
    $pass = [System.Web.Security.Membership]::GeneratePassword(16, 4)
    # Si no tienes System.Web, usa esto:
    $pass = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 16 | ForEach-Object {[char]$_})

    try {
        # Crear usuario si no existe
        $existente = Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue
        if (-not $existente) {
            $securePass = ConvertTo-SecureString $pass -AsPlainText -Force
            New-LocalUser -Name $usuario -Password $securePass `
                -Description "Usuario dedicado IIS - sin login interactivo" `
                -PasswordNeverExpires $true `
                -UserMayNotChangePassword $true | Out-Null
            printOK "Usuario '$usuario' creado."
        }

        # Dar permisos SOLO sobre wwwroot (lectura)
        $acl = Get-Acl $rutaWeb
        $regla = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $usuario, "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow"
        )
        $acl.SetAccessRule($regla)
        Set-Acl $rutaWeb $acl
        printOK "Permisos configurados: '$usuario' solo puede leer $rutaWeb"

    } catch {
        printWarn "No se pudo crear usuario dedicado: $_"
    }
}

# ----------------
# Instalar simple-http-server con pip/cargo
# ----------------
function instalarNginx {
    param([int]$puerto)

    Clear-Host
    Write-Host "--- Instalacion de Nginx para Windows ---" -ForegroundColor Magenta
    Write-Host ""

    # ── Consultar versiones disponibles dinamicamente ──
    printInfo "Consultando versiones disponibles de Nginx..."

    $rawVersiones = choco search nginx --exact --all-versions --limit-output 2>$null

    $versiones = @()
    foreach ($linea in $rawVersiones) {
        if ($linea -match '\|') {
            $ver = ($linea -split '\|')[1].Trim()
            if ($versiones -notcontains $ver) { $versiones += $ver }
        }
    }

    if ($versiones.Count -eq 0) {
        printError "No se encontraron versiones de Nginx en Chocolatey."
        return
    }

    # Separar mainline (desarrollo, numero menor impar) de stable (par)
    # Ej: 1.27.x = mainline/desarrollo, 1.26.x = stable
    $mainline = $versiones | Where-Object {
        $partes = $_ -split '\.'
        $partes.Count -ge 2 -and ([int]$partes[1] % 2 -ne 0)
    } | Select-Object -First 1

    $stable = $versiones | Where-Object {
        $partes = $_ -split '\.'
        $partes.Count -ge 2 -and ([int]$partes[1] % 2 -eq 0)
    } | Select-Object -First 1

    # Si no hay distincion clara, usar las primeras dos
    if (-not $mainline) { $mainline = $versiones[0] }
    if (-not $stable)   { $stable   = if ($versiones.Count -ge 2) { $versiones[1] } else { $versiones[0] } }

    Write-Host ""
    Write-Host "Versiones disponibles:" -ForegroundColor Cyan
    Write-Host "  1. $mainline  [Mainline - Desarrollo]"
    Write-Host "  2. $stable    [Stable - LTS]"
    Write-Host ""

    do {
        $selVer = Read-Host "Selecciona version (1/2)"
    } while ($selVer -notmatch '^[12]$')

    $versionElegida = if ($selVer -eq "1") { $mainline } else { $stable }

    # ── Instalar Nginx ──
    printInfo "Instalando Nginx $versionElegida..."
    choco install nginx --version="$versionElegida" --yes --no-progress --force
    
    if ($LASTEXITCODE -ne 0) {
        printError "Fallo la instalacion de Nginx."
        return
    }

    # Recargar PATH
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path","User")

    # ── Instalar NSSM para registrar Nginx como servicio real de Windows ──
    # La tarea programada no funciona porque nginx.exe necesita seguir corriendo
    printInfo "Instalando NSSM (gestor de servicios)..."
    choco install nssm --yes --no-progress | Out-Null

    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path","User")

    # ── Encontrar nginx.exe ──
    $posiblesRutas = @(
        "C:\tools\nginx",
        "C:\nginx",
        "C:\ProgramData\chocolatey\lib\nginx\tools\nginx-$versionElegida"
    )
    $nginxPath = $posiblesRutas | Where-Object { Test-Path "$_\nginx.exe" } | Select-Object -First 1

    if (-not $nginxPath) {
        printInfo "Buscando nginx.exe en disco..."
        $encontrado = Get-ChildItem -Path "C:\" -Filter "nginx.exe" -Recurse -ErrorAction SilentlyContinue |
                      Select-Object -First 1
        if ($encontrado) { $nginxPath = $encontrado.DirectoryName }
    }

    if (-not $nginxPath) {
        printError "No se encontro nginx.exe. Revisa la instalacion."
        return
    }

    printInfo "Nginx encontrado en: $nginxPath"

    # ── Configurar puerto en nginx.conf ──
    $nginxConf = "$nginxPath\conf\nginx.conf"
    printInfo "Configurando puerto $puerto en nginx.conf..."

    # Reemplazar el puerto en el bloque server { listen X; }
    (Get-Content $nginxConf) -replace 'listen\s+\d+\s*;', "listen $puerto;" |
        Set-Content $nginxConf

    printOK "Puerto $puerto configurado."

    # ── Seguridad: ocultar version en nginx.conf ──
    aplicarSeguridadNginx -nginxPath $nginxPath

    # ── Index HTML personalizado ──
    crearHTML `
        -rutaWeb "$nginxPath\html" `
        -servicio "Nginx" `
        -version $versionElegida `
        -puerto $puerto

    # ── Registrar como servicio Windows con NSSM ──
    $serviceName = "nginx-$puerto"
    printInfo "Registrando Nginx como servicio '$serviceName' con NSSM..."

    # Eliminar servicio anterior si existe
    nssm stop $serviceName 2>$null | Out-Null
    nssm remove $serviceName confirm 2>$null | Out-Null

    # Crear nuevo servicio
    nssm install $serviceName "$nginxPath\nginx.exe"
    nssm set $serviceName AppDirectory $nginxPath
    nssm set $serviceName DisplayName "Nginx HTTP Server (puerto $puerto)"
    nssm set $serviceName Description "Servidor Nginx instalado via script"
    nssm set $serviceName Start SERVICE_AUTO_START

    # Iniciar servicio
    Start-Service $serviceName -ErrorAction SilentlyContinue

    # ── Firewall ──
    configurarFirewall -puertNuevo $puerto -puertoViejo 80 -nombreServicio "Nginx"

    # ── Verificar ──
    Start-Sleep -Seconds 3
    $svc = Get-Service $serviceName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") {
        printOK "Nginx corriendo en http://localhost:$puerto"
    } else {
        printWarn "El servicio no inicio. Revisa el log: $nginxPath\logs\error.log"
        printWarn "O inicia manualmente: nssm start $serviceName"
    }
}

# ── Seguridad Nginx: ocultar version del servidor ──
function aplicarSeguridadNginx {
    param([string]$nginxPath)

    printInfo "Aplicando seguridad en Nginx..."
    $nginxConf = "$nginxPath\conf\nginx.conf"

    $contenido = Get-Content $nginxConf -Raw

    # server_tokens off: oculta version en headers y paginas de error
    if ($contenido -notmatch 'server_tokens') {
        $contenido = $contenido -replace 'http \{', "http {`n    server_tokens off;"
    }

    # Headers de seguridad dentro del bloque server
    if ($contenido -notmatch 'X-Frame-Options') {
        $contenido = $contenido -replace 'server \{', "server {`n        add_header X-Frame-Options SAMEORIGIN;`n        add_header X-Content-Type-Options nosniff;"
    }

    $contenido | Set-Content $nginxConf
    printOK "Seguridad Nginx configurada (server_tokens off, security headers)."
}

# ----------------
# Oculta los comentarios peligrosos jajaj dependiendo del servidor
# ----------------

function SeguridadIIS {
    printInfo "Aplicando configuracion de seguridad en IIS..."

    Import-Module WebAdministration -ErrorAction SilentlyContinue

    # 1. Ocultar header "Server: Microsoft-IIS/X.X"
    try {
        Set-WebConfigurationProperty `
            -PSPath "MACHINE/WEBROOT/APPHOST" `
            -Filter "system.webServer/security/requestFiltering" `
            -Name "removeServerHeader" `
            -Value $true
        printOK "Header 'Server' ocultado."
    } catch {
        printWarn "No se pudo ocultar header Server (puede requerir IIS 10+)."
    }

    # 2. Eliminar header "X-Powered-By"
    try {
        Remove-WebConfigurationProperty `
            -PSPath "MACHINE/WEBROOT/APPHOST" `
            -Filter "system.webServer/httpProtocol/customHeaders" `
            -Name "." `
            -AtElement @{name='X-Powered-By'} `
            -ErrorAction SilentlyContinue
        printOK "Header 'X-Powered-By' eliminado."
    } catch {
        printWarn "Header X-Powered-By no encontrado (puede que ya no existiera)."
    }

    # 3. Agregar headers de seguridad
    # X-Frame-Options: evita Clickjacking (que tu pagina sea metida en un iframe)
    Add-WebConfigurationProperty `
        -PSPath "MACHINE/WEBROOT/APPHOST" `
        -Filter "system.webServer/httpProtocol/customHeaders" `
        -Name "." `
        -Value @{name='X-Frame-Options'; value='SAMEORIGIN'} `
        -ErrorAction SilentlyContinue

    # X-Content-Type-Options: evita que el navegador "adivine" el tipo de archivo
    Add-WebConfigurationProperty `
        -PSPath "MACHINE/WEBROOT/APPHOST" `
        -Filter "system.webServer/httpProtocol/customHeaders" `
        -Name "." `
        -Value @{name='X-Content-Type-Options'; value='nosniff'} `
        -ErrorAction SilentlyContinue

    # 4. Deshabilitar metodos HTTP peligrosos (TRACE, TRACK)
    # TRACE permite a atacantes robar cookies mediante Cross-Site Tracing (XST)
    Add-WebConfigurationProperty `
        -PSPath "MACHINE/WEBROOT/APPHOST" `
        -Filter "system.webServer/security/requestFiltering/verbs" `
        -Name "." `
        -Value @{verb='TRACE'; allowed='false'} `
        -ErrorAction SilentlyContinue

    Add-WebConfigurationProperty `
        -PSPath "MACHINE/WEBROOT/APPHOST" `
        -Filter "system.webServer/security/requestFiltering/verbs" `
        -Name "." `
        -Value @{verb='TRACK'; allowed='false'} `
        -ErrorAction SilentlyContinue

    printOK "Seguridad IIS configurada."
}

function SeguridadApache {
    param([string]$apachePath)

    printInfo "Aplicando seguridad en Apache..."
    $httpdConf = "$apachePath\conf\httpd.conf"

    # Ocultar version: ServerTokens Prod (solo muestra "Apache", no la version)
    # ServerSignature Off (quita la firma del pie de pagina de errores)
    $seguridad = @"

# === SEGURIDAD: Ocultar informacion del servidor ===
ServerTokens Prod
ServerSignature Off

# Deshabilitar metodos peligrosos
<LimitExcept GET POST HEAD>
    Require all denied
</LimitExcept>

# Headers de seguridad
Header always set X-Frame-Options "SAMEORIGIN"
Header always set X-Content-Type-Options "nosniff"
"@

    Add-Content -Path $httpdConf -Value $seguridad
    printOK "Seguridad Apache configurada."
}

# ----------------
# Crear una pagina html personalizada
# ----------------
function CrearHTML {
    param(
        [string]$rutaWeb,      # Ej: C:\inetpub\wwwroot
        [string]$servicio,     # Ej: IIS
        [string]$version,      # Ej: 10.0
        [int]$puerto           # Ej: 8080
    )

    $contenido = @"

<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title> Servidor HTTP UwU </title>

    <style>
        .infoServ { 
            background: rgb(249, 181, 192); 
            border:1px solid #982f4a; 
            padding:2rem 3rem;
            border-radius:8px; 
            text-align:center; 
            color: rgb(255, 235, 239);
        }
        span { 
            color: #f44462; 
        }
        h1 { 
            color: #982f4a; 
        }
    </style>

</head>
<body style="background-color: rgb(255, 226, 231)">
    <div class="infoServ">
        <h1>Servidor Activo!!</h1>
        <div class="info">Servidor: <strong>$servicio</strong></div>
        <div class="info">Version: <strong>$version</strong></div>
        <div class="info">Puerto: <strong>$puerto</strong></div>
        <p> Disfruta la canción :3 </p>
    </div>

</body>
</html>
"@        

    # Crear directorio si no existe
    if (-not (Test-Path $rutaWeb)) {
        New-Item -ItemType Directory -Path $rutaWeb -Force | Out-Null
    }

    $contenido | Out-File -FilePath "$rutaWeb\index.html" -Encoding UTF8
    printOK "index.html creado en $rutaWeb"
}

# ----------------
# Funcion "principal"
# ----------------
function InstalarHTTP {
    Clear-Host
    Write-Host ""
    Write-Host "------------------------------------------------" -ForegroundColor Blue
    Write-Host "            GESTION SERVIDOR HTTPS              " -ForegroundColor Blue
    Write-Host "------------------------------------------------" -ForegroundColor Blue
    Write-Host "  1. IIS  (nativo Windows)"
    Write-Host "  2. Apache HTTP Server"
    Write-Host "  3. Nginx"
    Write-Host "  0. Volver"
    Write-Host "------------------------------------------------" -ForegroundColor Blue
    Write-Host ""

    $s = Read-Host "Servidor"

    if ($s -eq "0") { return }
    if ($s -notin @("1","2","3")) {
        printWarn "Opcion no valida."
        return
    }

    # Pedir puerto DESPUeS de elegir servidor
    Write-Host ""
    $puerto = pedirPuerto -default 80

    switch ($s) {
        "1" { 
            instalarIIS    -puerto $puerto 
        }
        "2" { 
            instalarApache -puerto $puerto 
        }
        "3" { 
            instalarNginx -puerto $puerto 
        }
    }
}
