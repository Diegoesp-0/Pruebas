# ============================================================
# validaciones.ps1 - Funciones de validacion de entrada
# ============================================================

$SCRIPT_DIR_VAL = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$SCRIPT_DIR_VAL\utils.ps1"

function Validar-IP {
    param([string]$ip)

    # Validar formato X.X.X.X con numeros
    if ($ip -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
        Print-Error "Direccion IP invalida, tiene que contener un formato X.X.X.X unicamente con numeros positivos"
        return $false
    }

    $octetos = $ip -split '\.'
    $a = [int]$octetos[0]
    $b = [int]$octetos[1]
    $c = [int]$octetos[2]
    $d = [int]$octetos[3]

    # No puede ser 0.X.X.X ni X.X.X.0
    if ($a -eq 0 -or $d -eq 0) {
        Print-Error "Direccion IP invalida, no puede ser 0.X.X.X ni X.X.X.0"
        return $false
    }

    # Validar ceros a la izquierda y rango 0-255
    foreach ($oct in $octetos) {
        if ($oct -match '^0\d+') {
            Print-Error "Direccion IP invalida, no se pueden poner 0 a la izquierda a menos que sea 0"
            return $false
        }
        $val = [int]$oct
        if ($val -lt 0 -or $val -gt 255) {
            Print-Error "Direccion IP invalida, no puede ser mayor a 255 ni menor a 0"
            return $false
        }
    }

    # No puede ser 0.0.0.0 ni 255.255.255.255
    if ($ip -eq "0.0.0.0" -or $ip -eq "255.255.255.255") {
        Print-Error "Direccion IP invalida, no puede ser 0.0.0.0 ni 255.255.255.255"
        return $false
    }

    # Rango loopback reservado
    if ($a -eq 127) {
        Print-Error "Direccion IP invalida, el rango 127.0.0.1 al 127.255.255.255 esta reservado para host local"
        return $false
    }

    # Rango experimental
    if ($a -gt 240 -and $a -lt 255) {
        Print-Error "Direccion IP invalida, el rango 240.0.0.0 al 255.255.255.254 esta reservado para usos experimentales"
        return $false
    }

    # Rango multicast
    if ($a -gt 224 -and $a -lt 239) {
        Print-Error "Direccion IP invalida, el rango 224.0.0.0 al 239.255.255.255 esta reservado para multicast"
        return $false
    }

    return $true
}

function Validar-Mascara {
    param([string]$masc)

    if ($masc -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
        Print-Error "Mascara invalida, tiene que contener un formato X.X.X.X unicamente con numeros positivos"
        return $false
    }

    $octetos = $masc -split '\.'
    $a = [int]$octetos[0]
    $b = [int]$octetos[1]
    $c = [int]$octetos[2]
    $d = [int]$octetos[3]

    if ($a -eq 0) {
        Print-Error "Mascara invalida, no puede ser 0.X.X.X"
        return $false
    }

    foreach ($oct in $octetos) {
        if ($oct -match '^0\d+') {
            Print-Error "Mascara invalida, no se pueden poner 0 a la izquierda a menos que sea 0"
            return $false
        }
        $val = [int]$oct
        if ($val -lt 0 -or $val -gt 255) {
            Print-Error "Mascara invalida, no puede ser mayor a 255 ni menor a 0"
            return $false
        }
    }

    if ($a -lt 255) {
        foreach ($oct in @($b, $c, $d)) {
            if ($oct -gt 0) {
                Print-Error "Mascara invalida, necesitas terminar los bits del primer octeto (255.X.X.X)"
                return $false
            }
        }
    } elseif ($b -lt 255) {
        foreach ($oct in @($c, $d)) {
            if ($oct -gt 0) {
                Print-Error "Mascara invalida, necesitas terminar los bits del segundo octeto (255.255.X.X)"
                return $false
            }
        }
    } elseif ($c -lt 255) {
        if ($d -gt 0) {
            Print-Error "Mascara invalida, necesitas terminar los bits del tercer octeto (255.255.255.X)"
            return $false
        }
    } elseif ($d -gt 252) {
        Print-Error "Mascara invalida, no puede superar 255.255.255.252"
        return $false
    }

    return $true
}

function Validar-Usuario {
    param([string]$usuario)

    if ($usuario -notmatch '^[a-zA-Z0-9_\-]{3,20}$') {
        Print-Error "Nombre de usuario invalido. Solo letras, numeros, guion y guion bajo. Entre 3 y 20 caracteres."
        return $false
    }
    return $true
}

function Validar-Grupo {
    param([string]$grupo)

    if ($grupo -notin @("reprobados", "recursadores")) {
        Print-Error "Grupo invalido. Solo se permite: reprobados o recursadores"
        return $false
    }
    return $true
}
