#!/bin/bash

source "$(dirname "$0")/funciones_comunes.sh"

# ==================== VARIABLES DNS ====================

DOMINIO="reprobados.com"

# ==================== FUNCIONES DNS ====================

dns_verificar(){
	clear
	instalar_paquete "bind"
	instalar_paquete "bind-utils"
}

dns_ipfija(){
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
				echo ""; echo "IP invalida, intente de nuevo..."; echo ""
				continue
			fi
			break
		done

		local GATEWAY_NM
		GATEWAY_NM=$(ip route | grep default | awk '{print $3}' | head -n1)
		local DNS_ACTUAL
		DNS_ACTUAL=$(nmcli -g ipv4.dns connection show "$CONEXION")
		[[ -z "$DNS_ACTUAL" ]] && DNS_ACTUAL="8.8.8.8"

		sudo nmcli connection modify "$CONEXION" ipv4.method manual
		sudo nmcli connection modify "$CONEXION" ipv4.addresses "$IP_FIJA/24"
		sudo nmcli connection modify "$CONEXION" ipv4.gateway "$GATEWAY_NM"
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

dns_iniciar(){
	clear
	iniciar_servicio "named"
}

dns_configurar_zona(){
	clear

	if ! paquete_instalado "bind"; then
		echo ""
		echo "ERROR: BIND no esta instalado. Use la opcion 'verificar' primero."
		echo ""
		return 1
	fi

	local IP_SERVER
	IP_SERVER=$(obtener_ip_interfaz)

	if [[ -z "$IP_SERVER" ]]; then
		echo ""
		echo "ERROR: No se pudo obtener la IP de la interfaz $INTERFAZ"
		echo "Verifique que la interfaz este activa: ip addr show $INTERFAZ"
		echo ""
		return 1
	fi

	echo "IP del servidor: $IP_SERVER (interfaz $INTERFAZ)"
	echo ""

	local IP_CLIENTE
	while true; do
		echo "=============== IP CLIENTE =============="
		echo ""
		read -p "IP a la que apuntara el dominio [$DOMINIO]: " IP_CLIENTE

		if ! validar_ip "$IP_CLIENTE"; then
			clear
			echo ""; echo "La IP del cliente no es valida..."; echo ""
			sleep 2; continue
		fi
		break
	done

	local SERIAL
	SERIAL=$(date +%Y%m%d%H)

	if ! grep -q "\"$DOMINIO\"" /etc/named.conf; then
		sudo bash -c "cat >> /etc/named.conf << 'EOF'

zone \"$DOMINIO\" {
	type master;
	file \"/var/lib/named/db.$DOMINIO\";
};
EOF"
	fi

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

	echo ""
	echo "Verificando sintaxis..."

	if ! sudo named-checkconf; then
		echo "ERROR: named.conf tiene errores de sintaxis"
		return 1
	fi

	if ! sudo named-checkzone "$DOMINIO" "/var/lib/named/db.$DOMINIO"; then
		echo "ERROR: El archivo de zona tiene errores"
		return 1
	fi

	sudo firewall-cmd --add-service=dns --permanent 2>/dev/null
	sudo firewall-cmd --reload 2>/dev/null

	reiniciar_servicio "named"

	if verificar_servicio_activo "named"; then
		echo ""
		echo "Zona [$DOMINIO] configurada correctamente."
		echo "IP servidor: $IP_SERVER"
		echo "IP cliente:  $IP_CLIENTE"
		echo "Serial:      $SERIAL"
		echo ""
	else
		echo ""
		echo "ERROR: El servicio no pudo reiniciarse."
		echo "Revise: sudo journalctl -u named -n 30"
		return 1
	fi
}

dns_validar(){
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
	ping -c 3 "www.$DOMINIO" 2>&1 || echo "Ping fallido (puede ser firewall, no necesariamente error DNS)"
	echo ""
}

dns_guardar_dominios(){
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

dns_menu_dominios(){
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
		echo "  0. Volver"
		echo ""
		read -p "Seleccione una opcion: " OPC_DOM

		if [ "$OPC_DOM" = "0" ]; then
			break
		elif [ "$OPC_DOM" = "A" ] || [ "$OPC_DOM" = "a" ]; then
			echo ""
			read -p "Nuevo dominio (ej: midominio.com): " NUEVO_DOM
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
				dns_guardar_dominios DOMINIOS
				echo "Dominio [$NUEVO_DOM] agregado..."; sleep 2
			fi
		elif [[ "$OPC_DOM" =~ ^[0-9]+$ ]] && \
		     [[ "$OPC_DOM" -ge 1 ]] && \
		     [[ "$OPC_DOM" -le "${#DOMINIOS[@]}" ]]; then
			DOMINIO="${DOMINIOS[$((OPC_DOM-1))]}"
			sed -i "s/^DOMINIO=.*/DOMINIO=\"$DOMINIO\"/" "$(realpath "$0")"
			echo ""; echo "Dominio seleccionado: $DOMINIO"; sleep 2
			break
		else
			echo "Opcion invalida..."; sleep 2
		fi
	done
}

dns_menu(){
	while true; do
		clear
		echo "========================================="
		echo "         CONFIGURACION DNS               "
		echo "========================================="
		echo ""
		echo "  Dominio activo: $DOMINIO"
		echo ""
		echo "  1. Verificar instalacion"
		echo "  2. Configurar IP fija"
		echo "  3. Iniciar servicio"
		echo "  4. Configurar zona"
		echo "  5. Validar configuracion"
		echo "  6. Seleccionar dominio"
		echo "  0. Volver al menu principal"
		echo ""
		read -p "Seleccione una opcion: " OPC

		if [ "$OPC" = "1" ]; then dns_verificar
		elif [ "$OPC" = "2" ]; then dns_ipfija
		elif [ "$OPC" = "3" ]; then dns_iniciar
		elif [ "$OPC" = "4" ]; then dns_configurar_zona
		elif [ "$OPC" = "5" ]; then dns_validar
		elif [ "$OPC" = "6" ]; then dns_menu_dominios
		elif [ "$OPC" = "0" ]; then break
		else
			echo "Opcion invalida..."; sleep 2
		fi

		if [ "$OPC" != "0" ]; then
			read -p "Presione Enter para continuar..."
		fi
	done
}
