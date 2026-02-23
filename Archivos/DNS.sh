#!/bin/bash

DOMINIO="reprobados.com"
INTERFAZ="enp0s8"

# ==================== FUNCIONES ====================

validar_ip(){
	local ip=$1
	if [[ ! $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
		return 1
	fi
	IFS='.' read -r p1 p2 p3 p4 <<< "$ip"

	for p in $p1 $p2 $p3 $p4; do
		[[ $p -le 255 ]] || return 1
	done

	[[ $p1 -eq 0   && $p2 -eq 0   && $p3 -eq 0   && $p4 -eq 0   ]] && return 1
	[[ $p1 -eq 255 && $p2 -eq 255 && $p3 -eq 255 && $p4 -eq 255 ]] && return 1
	[[ $p1 -eq 127 ]] && return 1

	return 0
}

verificar(){
	clear
	if rpm -q bind > /dev/null 2>&1; then
		echo ""
		echo "BIND ya esta instalado :D"
		echo ""
		sleep 2
	else
		echo ""
		echo "BIND no esta instalado"
		echo ""
		read -p "Desea descargar BIND? (S/s): " OPC

		if [[ "$OPC" == "S" || "$OPC" == "s" ]]; then
			clear
			echo "Descargando BIND..."
			sudo zypper install -y bind bind-utils bind-doc
		fi
	fi
}

iniciar(){
	clear
	if systemctl is-active --quiet named; then
		echo ""
		echo "El servidor ya esta corriendo..."
		echo ""
		sleep 2
	else
		sudo systemctl enable named
		sudo systemctl start named
		sleep 2
		echo ""
		if systemctl is-active --quiet named; then
			echo "Servicio iniciado correctamente..."
		else
			echo "Error al iniciar el servicio..."
			echo "Revise: sudo journalctl -u named -n 30"
			exit 1
		fi
		echo ""
	fi
}

configurar_zona(){
	clear

	if ! rpm -q bind > /dev/null 2>&1; then
		echo ""
		echo "ERROR: BIND no esta instalado. Ejecute primero: bash $0 verificar"
		echo ""
		return 1
	fi

	# Obtener IP del servidor desde enp0s8 especificamente
	local IP_SERVER
	IP_SERVER=$(ip -4 addr show dev "$INTERFAZ" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1 | head -n1)

	if [[ -z "$IP_SERVER" ]]; then
		echo ""
		echo "ERROR: No se pudo obtener la IP de la interfaz $INTERFAZ"
		echo "Verifique que la interfaz este activa con: ip addr show $INTERFAZ"
		echo ""
		return 1
	fi

	echo "IP del servidor detectada: $IP_SERVER (interfaz $INTERFAZ)"
	echo ""

	# Solicitar IP del cliente
	local IP_CLIENTE
	while true; do
		echo "=============== IP CLIENTE =============="
		echo ""
		read -p "Ingrese la IP a la que apuntara el dominio [$DOMINIO]: " IP_CLIENTE

		if ! validar_ip "$IP_CLIENTE"; then
			clear
			echo ""
			echo "La IP del cliente no es valida..."
			echo ""
			sleep 2
			continue
		fi
		break
	done

	# Generar serial dinamico basado en fecha y hora
	local SERIAL
	SERIAL=$(date +%Y%m%d%H)

	# Agregar zona a named.conf si no existe
	if ! grep -q "\"$DOMINIO\"" /etc/named.conf; then
		sudo bash -c "cat >> /etc/named.conf << 'EOF'

zone \"$DOMINIO\" {
	type master;
	file \"/var/lib/named/db.$DOMINIO\";
};
EOF"
	fi

	# Crear archivo de zona
	sudo bash -c "cat > /var/lib/named/db.$DOMINIO << EOF
\\\$TTL 604800
@	IN	SOA	ns1.$DOMINIO. admin.$DOMINIO. (
		$SERIAL ; Serial
		604800  ; Refresh
		86400   ; Retry
		2419200 ; Expire
		604800) ; Negative TTL

@	IN	NS	ns1.$DOMINIO.
ns1	IN	A	$IP_SERVER
@	IN	A	$IP_CLIENTE
www	IN	CNAME	@
EOF"

	# Verificar sintaxis antes de reiniciar
	echo ""
	echo "Verificando sintaxis de la zona..."
	if ! sudo named-checkconf; then
		echo "ERROR: named.conf tiene errores de sintaxis"
		return 1
	fi

	if ! sudo named-checkzone "$DOMINIO" "/var/lib/named/db.$DOMINIO"; then
		echo "ERROR: El archivo de zona tiene errores"
		return 1
	fi

	# Abrir puerto DNS en firewall
	sudo firewall-cmd --add-service=dns --permanent 2>/dev/null
	sudo firewall-cmd --reload 2>/dev/null

	# Reiniciar servicio
	sudo systemctl restart named
	sleep 2

	if systemctl is-active --quiet named; then
		echo ""
		echo "Zona [$DOMINIO] configurada correctamente."
		echo "IP servidor: $IP_SERVER"
		echo "IP cliente:  $IP_CLIENTE"
		echo "Serial:      $SERIAL"
		echo ""
	else
		echo ""
		echo "ERROR: El servicio no pudo reiniciarse tras configurar la zona."
		echo "Revise: sudo journalctl -u named -n 30"
		return 1
	fi
}

validar(){
	clear
	echo "========== VALIDAR CONFIGURACION DNS =========="
	echo ""

	echo "--- Sintaxis named.conf ---"
	if sudo named-checkconf; then
		echo "named.conf: OK"
	else
		echo "named.conf: ERROR"
	fi

	echo ""
	echo "--- Sintaxis de zona [$DOMINIO] ---"
	if sudo named-checkzone "$DOMINIO" "/var/lib/named/db.$DOMINIO"; then
		echo "Zona: OK"
	else
		echo "Zona: ERROR"
	fi

	echo ""
	echo "--- Resolucion DNS ---"
	if command -v dig > /dev/null 2>&1; then
		dig @127.0.0.1 "$DOMINIO" A +short
		dig @127.0.0.1 "www.$DOMINIO" A +short
	else
		nslookup "$DOMINIO" 127.0.0.1
	fi

	echo ""
	echo "--- Ping (informativo) ---"
	ping -c 3 "www.$DOMINIO" 2>&1 || echo "Ping fallido (puede ser por firewall, no necesariamente un error DNS)"
	echo ""
}

ipfija(){
	clear
	local CONEXION
	CONEXION=$(nmcli -t -f NAME,DEVICE connection show --active | grep ":$INTERFAZ$" | cut -d: -f1)

	if [[ -z "$CONEXION" ]]; then
		echo ""
		echo "ERROR: No se encontro una conexion activa en $INTERFAZ"
		echo ""
		return 1
	fi

	local METODO
	METODO=$(nmcli -g ipv4.method connection show "$CONEXION")

	if [[ "$METODO" == "auto" ]]; then
		echo ""
		echo "La interfaz $INTERFAZ es dinamica. Configurando IP fija..."
		echo ""

		local IP_FIJA
		while true; do
			read -p "Ingrese la IP fija para $INTERFAZ: " IP_FIJA

			if ! validar_ip "$IP_FIJA"; then
				echo ""
				echo "IP invalida, intente de nuevo..."
				echo ""
				continue
			fi
			break
		done

		local GATEWAY
		GATEWAY=$(ip route | grep default | awk '{print $3}' | head -n1)
		local DNS_ACTUAL
		DNS_ACTUAL=$(nmcli -g ipv4.dns connection show "$CONEXION")
		[[ -z "$DNS_ACTUAL" ]] && DNS_ACTUAL="8.8.8.8"

		sudo nmcli connection modify "$CONEXION" ipv4.method manual
		sudo nmcli connection modify "$CONEXION" ipv4.addresses "$IP_FIJA/24"
		sudo nmcli connection modify "$CONEXION" ipv4.gateway "$GATEWAY"
		sudo nmcli connection modify "$CONEXION" ipv4.dns "$DNS_ACTUAL"
		sudo nmcli connection down "$CONEXION"
		sudo nmcli connection up "$CONEXION"

		echo ""
		echo "IP fija $IP_FIJA/24 configurada en $INTERFAZ"
		echo ""
	else
		local IP_ACTUAL
		IP_ACTUAL=$(ip -4 addr show dev "$INTERFAZ" | grep "inet " | awk '{print $2}' | head -n1)
		echo ""
		echo "La interfaz $INTERFAZ ya tiene IP fija: $IP_ACTUAL"
		echo ""
		sleep 2
	fi
}

guardar_dominios(){
	local -n _ARR=$1
	local NUEVA_LISTA="	local DOMINIOS=("
	for d in "${_ARR[@]}"; do
		NUEVA_LISTA+="\"$d\" "
	done
	NUEVA_LISTA="${NUEVA_LISTA% })"
	local script_real
	script_real=$(realpath "$0")
	sed -i "s|^\tlocal DOMINIOS=(.*|${NUEVA_LISTA}|" "$script_real"
}

menu(){
	local DOMINIOS=("reprobados.com")

	while true; do
		clear
		echo "======= SELECCIONAR DOMINIO ======="
		echo ""
		echo "  Dominio activo: $DOMINIO"
		echo ""
		for i in "${!DOMINIOS[@]}"; do
			echo "  $((i+1)). ${DOMINIOS[$i]}"
		done
		echo ""
		echo "  A. Agregar dominio"
		echo "  0. Salir"
		echo ""
		read -p "Seleccione una opcion: " OPC_DOM

		case "$OPC_DOM" in
			0)
				break
				;;
			A|a)
				echo ""
				read -p "Ingrese el nuevo dominio (ej: midominio.com): " NUEVO_DOM
				if [[ -z "$NUEVO_DOM" ]]; then
					echo "El dominio no puede estar vacio..."; sleep 2; continue
				fi
				local DUPLICADO=0
				for d in "${DOMINIOS[@]}"; do
					[[ "$d" == "$NUEVO_DOM" ]] && DUPLICADO=1 && break
				done
				if [[ $DUPLICADO -eq 1 ]]; then
					echo "El dominio [$NUEVO_DOM] ya existe..."; sleep 2
				else
					DOMINIOS+=("$NUEVO_DOM")
					guardar_dominios DOMINIOS
					echo "Dominio [$NUEVO_DOM] agregado..."; sleep 2
				fi
				;;
			*)
				if [[ "$OPC_DOM" =~ ^[0-9]+$ ]] && \
				   [[ "$OPC_DOM" -ge 1 ]] && \
				   [[ "$OPC_DOM" -le "${#DOMINIOS[@]}" ]]; then
					DOMINIO="${DOMINIOS[$((OPC_DOM-1))]}"
					sed -i "s/^DOMINIO=.*/DOMINIO=\"$DOMINIO\"/" "$(realpath "$0")"
					echo ""
					echo "Dominio seleccionado: $DOMINIO"
					sleep 2
					break
				else
					echo "Opcion invalida..."; sleep 2
				fi
				;;
		esac
	done
}

# ==================== COMANDOS ====================

if [ "$1" = "verificar" ]; then
	verificar
fi

if [ "$1" = "iniciar" ]; then
	iniciar
fi

if [ "$1" = "configurar" ]; then
	configurar_zona
fi

if [ "$1" = "validar" ]; then
	validar
fi

if [ "$1" = "ipfija" ]; then
	ipfija
fi

if [ "$1" = "menu" ]; then
	menu
fi

if [ "$1" = "todo" ]; then
	verificar
	ipfija
	iniciar
	configurar_zona
	validar
fi

if [ "$1" = "help" ] || [ -z "$1" ]; then
	echo ""
	echo "============ COMANDOS ============"
	echo "verificar  : Verificar si BIND esta instalado"
	echo "ipfija     : Configurar IP fija en $INTERFAZ"
	echo "iniciar    : Iniciar el servicio named"
	echo "configurar : Configurar zona DNS para el dominio activo"
	echo "validar    : Verificar sintaxis y resolver el dominio"
	echo "menu       : Seleccionar o agregar dominios"
	echo "todo       : Ejecutar todo el flujo completo"
	echo ""
fi

if [ -n "$1" ] && \
   [ "$1" != "verificar" ] && \
   [ "$1" != "iniciar" ] && \
   [ "$1" != "configurar" ] && \
   [ "$1" != "validar" ] && \
   [ "$1" != "ipfija" ] && \
   [ "$1" != "menu" ] && \
   [ "$1" != "todo" ] && \
   [ "$1" != "help" ]; then
	echo ""
	echo "Comando desconocido: $1"
	echo "Ejecute: bash $0 help"
	echo ""
fi
