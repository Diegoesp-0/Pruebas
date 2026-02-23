#!/bin/bash

DNS_FILE="$(realpath "${BASH_SOURCE[0]}")"
source "$(dirname "$DNS_FILE")/funciones_comunes.sh"

# ==================== VARIABLES DNS ====================

DOMINIO="reprobados.com"
DOMINIOS_GUARDADOS=("reprobados.com")

# ==================== FUNCIONES INTERNAS ====================

_dns_bin(){
	local nombre=$1
	local rutas=(
		"/usr/sbin/$nombre"
		"/sbin/$nombre"
		"/usr/bin/$nombre"
		"/usr/local/sbin/$nombre"
	)
	for ruta in "${rutas[@]}"; do
		if [[ -x "$ruta" ]]; then
			echo "$ruta"
			return 0
		fi
	done
	local found
	found=$(sudo sh -c "which $nombre 2>/dev/null")
	if [[ -n "$found" ]]; then
		echo "$found"
		return 0
	fi
	return 1
}

_dns_servicio(){
	if systemctl list-unit-files 2>/dev/null | grep -q "^named.service"; then
		echo "named"
	elif systemctl list-unit-files 2>/dev/null | grep -q "^bind.service"; then
		echo "bind"
	else
		echo "named"
	fi
}

# ==================== FUNCIONES DNS ====================

dns_verificar(){
	clear
	instalar_paquete "bind"
	instalar_paquete "bind-utils"

	echo ""
	echo "--- Verificando binarios de BIND ---"
	local checkconf checkzone
	checkconf=$(_dns_bin "named-checkconf")
	checkzone=$(_dns_bin "named-checkzone")

	if [[ -n "$checkconf" ]]; then
		echo "named-checkconf : $checkconf"
	else
		echo "named-checkconf : NO ENCONTRADO"
	fi

	if [[ -n "$checkzone" ]]; then
		echo "named-checkzone : $checkzone"
	else
		echo "named-checkzone : NO ENCONTRADO"
	fi

	echo ""
	echo "--- Servicio detectado: $(_dns_servicio) ---"
	echo ""
}

dns_ipfija(){
	clear
	local CONEXION
	CONEXION=$(nmcli -t -f NAME,DEVICE connection show --active | grep ":$INTERFAZ$" | cut -d: -f1)

	if [[ -z "$CONEXION" ]]; then
		echo ""; echo "ERROR: No se encontro conexion activa en $INTERFAZ"; echo ""
		return 1
	fi

	local METODO
	METODO=$(nmcli -g ipv4.method connection show "$CONEXION")

	if [[ "$METODO" == "auto" ]]; then
		echo ""; echo "La interfaz $INTERFAZ es dinamica. Configurando IP fija..."; echo ""

		local IP_FIJA
		while true; do
			read -p "Ingrese la IP fija para $INTERFAZ: " IP_FIJA
			if ! validar_ip "$IP_FIJA"; then
				echo ""; echo "IP invalida..."; echo ""; continue
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

		echo ""; echo "IP fija $IP_FIJA/24 configurada en $INTERFAZ"; echo ""
	else
		local IP_ACTUAL
		IP_ACTUAL=$(ip -4 addr show dev "$INTERFAZ" | grep "inet " | awk '{print $2}' | head -n1)
		echo ""; echo "La interfaz $INTERFAZ ya tiene IP fija: $IP_ACTUAL"; echo ""
		sleep 2
	fi
}

dns_iniciar(){
	clear
	local SERVICIO
	SERVICIO=$(_dns_servicio)
	iniciar_servicio "$SERVICIO"
}

dns_configurar_zona(){
	clear

	if ! paquete_instalado "bind"; then
		echo ""; echo "ERROR: BIND no instalado. Use opcion 1 primero."; echo ""
		return 1
	fi

	local IP_SERVER
	IP_SERVER=$(obtener_ip_interfaz)

	if [[ -z "$IP_SERVER" ]]; then
		echo ""; echo "ERROR: No se pudo obtener IP de $INTERFAZ"; echo ""
		return 1
	fi

	echo "IP del servidor: $IP_SERVER ($INTERFAZ)"; echo ""

	local IP_CLIENTE
	while true; do
		echo "=============== IP CLIENTE =============="
		echo ""
		read -p "IP a la que apuntara el dominio [$DOMINIO]: " IP_CLIENTE
		if ! validar_ip "$IP_CLIENTE"; then
			clear; echo ""; echo "IP invalida..."; echo ""; sleep 2; continue
		fi
		break
	done

	local SERIAL
	SERIAL=$(date +%Y%m%d%H)

	# Agregar zona a named.conf si no existe
	if ! grep -q "\"$DOMINIO\"" /etc/named.conf 2>/dev/null; then
		sudo bash -c "cat >> /etc/named.conf" << CONFEOF

zone "$DOMINIO" {
	type master;
	file "/var/lib/named/db.$DOMINIO";
};
CONFEOF
	fi

	# Crear archivo de zona
	sudo bash -c "cat > /var/lib/named/db.$DOMINIO" << ZONAEOF
\$TTL 604800
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
ZONAEOF

	echo ""; echo "Verificando sintaxis..."

	local CHECKCONF CHECKZONE
	CHECKCONF=$(_dns_bin "named-checkconf")
	CHECKZONE=$(_dns_bin "named-checkzone")

	if [[ -n "$CHECKCONF" ]]; then
		if ! sudo "$CHECKCONF"; then
			echo "ERROR: named.conf tiene errores"; return 1
		fi
		echo "named.conf: OK"
	else
		echo "ADVERTENCIA: named-checkconf no encontrado, omitiendo verificacion"
	fi

	if [[ -n "$CHECKZONE" ]]; then
		if ! sudo "$CHECKZONE" "$DOMINIO" "/var/lib/named/db.$DOMINIO"; then
			echo "ERROR: Zona tiene errores"; return 1
		fi
		echo "Zona: OK"
	else
		echo "ADVERTENCIA: named-checkzone no encontrado, omitiendo verificacion"
	fi

	echo "Desactivando firewall..."
	sudo systemctl stop firewalld 2>/dev/null
	sudo systemctl disable firewalld 2>/dev/null

	local SERVICIO
	SERVICIO=$(_dns_servicio)
	reiniciar_servicio "$SERVICIO"

	if verificar_servicio_activo "$SERVICIO"; then
		echo ""; echo "Zona [$DOMINIO] configurada correctamente."
		echo "IP servidor: $IP_SERVER | IP cliente: $IP_CLIENTE | Serial: $SERIAL"; echo ""
	else
		echo ""; echo "ERROR: Servicio no pudo reiniciarse."
		echo "Revise: sudo journalctl -u $SERVICIO -n 30"; return 1
	fi
}

dns_validar(){
	clear
	echo "========== VALIDAR CONFIGURACION DNS =========="
	echo ""

	local CHECKCONF CHECKZONE
	CHECKCONF=$(_dns_bin "named-checkconf")
	CHECKZONE=$(_dns_bin "named-checkzone")

	echo "--- Sintaxis named.conf ---"
	if [[ -n "$CHECKCONF" ]]; then
		if sudo "$CHECKCONF" 2>&1; then echo "named.conf: OK"
		else echo "named.conf: ERROR"; fi
	else
		echo "named-checkconf no encontrado"
	fi

	echo ""
	echo "--- Zona [$DOMINIO] ---"
	if [[ ! -f "/var/lib/named/db.$DOMINIO" ]]; then
		echo "Archivo no encontrado — configure la zona primero"
	elif [[ -n "$CHECKZONE" ]]; then
		if sudo "$CHECKZONE" "$DOMINIO" "/var/lib/named/db.$DOMINIO" 2>&1; then echo "Zona: OK"
		else echo "Zona: ERROR"; fi
	else
		echo "named-checkzone no encontrado"
	fi

	echo ""
	echo "--- Estado del servicio ---"
	local SERVICIO
	SERVICIO=$(_dns_servicio)
	if verificar_servicio_activo "$SERVICIO"; then
		echo "$SERVICIO: ACTIVO"
	else
		echo "$SERVICIO: INACTIVO — use opcion 3 para iniciarlo"
		echo ""; return 0
	fi

	echo ""
	echo "--- Resolucion DNS ---"
	if command -v dig > /dev/null 2>&1; then
		dig @127.0.0.1 "$DOMINIO" A +short +time=3
		dig @127.0.0.1 "www.$DOMINIO" A +short +time=3
	else
		nslookup "$DOMINIO" 127.0.0.1
	fi

	echo ""
	echo "--- Ping (informativo) ---"
	ping -c 3 "www.$DOMINIO" 2>&1 || echo "Ping fallido (puede ser firewall o ICMP bloqueado)"
	echo ""
}

dns_guardar_dominios(){
	local nueva_linea="DOMINIOS_GUARDADOS=("
	for d in "${DOMINIOS_GUARDADOS[@]}"; do
		nueva_linea+="\"$d\" "
	done
	nueva_linea="${nueva_linea% })"
	sed -i "s|^DOMINIOS_GUARDADOS=(.*|${nueva_linea}|" "$DNS_FILE"
}

dns_menu_dominios(){
	while true; do
		clear
		echo "======= SELECCIONAR DOMINIO ======="
		echo ""
		echo "  Dominio activo: $DOMINIO"
		echo ""
		for i in "${!DOMINIOS_GUARDADOS[@]}"; do
			echo "  $((i+1)). ${DOMINIOS_GUARDADOS[$i]}"
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
				echo "No puede estar vacio..."; sleep 2; continue
			fi
			local DUPLICADO=0
			for d in "${DOMINIOS_GUARDADOS[@]}"; do
				[[ "$d" == "$NUEVO_DOM" ]] && DUPLICADO=1 && break
			done
			if [[ $DUPLICADO -eq 1 ]]; then
				echo "Ya existe..."; sleep 2
			else
				DOMINIOS_GUARDADOS+=("$NUEVO_DOM")
				dns_guardar_dominios
				echo "Dominio [$NUEVO_DOM] guardado."; sleep 2
			fi

		elif [[ "$OPC_DOM" =~ ^[0-9]+$ ]] && \
		     [[ "$OPC_DOM" -ge 1 ]] && \
		     [[ "$OPC_DOM" -le "${#DOMINIOS_GUARDADOS[@]}" ]]; then
			DOMINIO="${DOMINIOS_GUARDADOS[$((OPC_DOM-1))]}"
			sed -i "s/^DOMINIO=.*/DOMINIO=\"$DOMINIO\"/" "$DNS_FILE"
			export DOMINIO
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
		echo "  6. Seleccionar / agregar dominio"
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
