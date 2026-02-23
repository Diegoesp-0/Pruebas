#!/bin/bash

# =============== VARIABLES ==============================================

SCOPE=X
IPINICIAL=X
IPFINAL=X
GATEWAY=X
DNS=X
DNS2=X
LEASE=X
MASCARA=X
INTERFAZ=enp0s8

# =============== FUNCIONES =============================================

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

ip_a_numero(){
	IFS='.' read -r p1 p2 p3 p4 <<< "$1"
	echo $(( (p1 << 24) + (p2 << 16) + (p3 << 8) + p4 ))
}

validar_rango(){
	local ip_inicio=$1
	local ip_fin=$2

	validar_ip "$ip_inicio" || return 1
	validar_ip "$ip_fin"    || return 1

	# Deben estar en la misma subred /24
	IFS='.' read -r a1 b1 c1 _ <<< "$ip_inicio"
	IFS='.' read -r a2 b2 c2 _ <<< "$ip_fin"
	[[ "$a1.$b1.$c1" == "$a2.$b2.$c2" ]] || return 1

	local n_inicio n_fin
	n_inicio=$(ip_a_numero "$ip_inicio")
	n_fin=$(ip_a_numero "$ip_fin")
	[[ $n_inicio -lt $n_fin ]]
}

obtener_red(){
	IFS='.' read -r p1 p2 p3 _ <<< "$1"
	echo "$p1.$p2.$p3.0"
}

obtener_broadcast(){
	IFS='.' read -r p1 p2 p3 _ <<< "$1"
	echo "$p1.$p2.$p3.255"
}

validar_gateway(){
	local gateway=$1
	local ip_ref=$2

	validar_ip "$gateway" || return 1

	local red broadcast gw_red
	red=$(obtener_red "$ip_ref")
	broadcast=$(obtener_broadcast "$ip_ref")
	gw_red=$(obtener_red "$gateway")

	[[ "$gw_red" == "$red" ]]       || return 1
	[[ "$gateway" == "$red" ]]       && return 1
	[[ "$gateway" == "$broadcast" ]] && return 1

	return 0
}

validar_dns(){
	validar_ip "$1"
}

validar_lease(){
	local lease=$1
	[[ "$lease" =~ ^[0-9]+$ ]] || return 1
	[[ "$lease" -gt 0 ]]       || return 1
	return 0
}

incrementar_ip(){
	local ip=$1
	IFS='.' read -r p1 p2 p3 p4 <<< "$ip"

	p4=$((p4 + 1))
	if [[ $p4 -gt 255 ]]; then p4=0; p3=$((p3 + 1)); fi
	if [[ $p3 -gt 255 ]]; then p3=0; p2=$((p2 + 1)); fi
	if [[ $p2 -gt 255 ]]; then p2=0; p1=$((p1 + 1)); fi

	echo "$p1.$p2.$p3.$p4"
}

configurar_ip_estatica(){
	local ip=$1
	local interfaz=$2

	echo "Configurando IP estatica $ip/24 en $interfaz..."

	sudo ip addr flush dev "$interfaz" 2>/dev/null
	sudo ip addr add "$ip/24" dev "$interfaz"
	sudo ip link set "$interfaz" up

	if [[ $? -eq 0 ]]; then
		echo "IP estatica configurada correctamente"
		return 0
	else
		echo "Error al configurar la IP estatica"
		return 1
	fi
}

verificar(){
	clear
	if rpm -q dhcp-server > /dev/null 2>&1; then
		echo ""
		echo "DHCP-SERVER esta instalado :D"
		echo ""
	else
		echo ""
		echo "El paquete DHCP-SERVER no esta instalado"
		echo ""
		read -p "Desea descargar DHCP-SERVER? (S/s): " OPC

		if [[ "$OPC" == "S" || "$OPC" == "s" ]]; then
			echo "Descargando..."
			sudo zypper install -y dhcp-server
		fi
	fi
}

conf_parametros(){
	clear

	if ! rpm -q dhcp-server > /dev/null 2>&1; then
		echo ""
		echo "ERROR: DHCP-SERVER no esta instalado"
		echo "Ejecute primero: bash $0 verificar"
		echo ""
		return 1
	fi

	echo "========== CONFIGURAR PARAMETROS =========="
	read -p "Nombre del ambito: " SCOPE_T

	# ---- IP inicial y final ----
	while true; do
		clear
		echo "========== CONFIGURAR PARAMETROS =========="
		echo "Nombre del ambito: $SCOPE_T"
		read -p "IP del servidor (IP inicial del rango /24): " INICIAL_T

		if ! validar_ip "$INICIAL_T"; then
			echo "IP invalida, intente de nuevo"; sleep 2; continue
		fi

		read -p "IP final del rango: " FINAL_T

		if ! validar_ip "$FINAL_T"; then
			echo "IP final invalida, intente de nuevo"; sleep 2; continue
		fi

		if ! validar_rango "$INICIAL_T" "$FINAL_T"; then
			echo "El rango no es valido (deben estar en la misma red /24 y el inicio debe ser menor al fin)"
			sleep 2; continue
		fi
		break
	done

	# ---- Gateway ----
	while true; do
		clear
		echo "========== CONFIGURAR PARAMETROS =========="
		echo "Ambito:    $SCOPE_T"
		echo "IP inicio: $INICIAL_T"
		echo "IP fin:    $FINAL_T"
		read -p "Gateway (Enter para omitir): " GATEWAY_T

		if [[ -z "$GATEWAY_T" ]]; then
			GATEWAY_T="X"; break
		fi

		if validar_gateway "$GATEWAY_T" "$INICIAL_T"; then
			break
		else
			echo "Gateway invalido (debe estar en la misma red /24)"; sleep 2
		fi
	done

	# ---- DNS primario ----
	while true; do
		clear
		echo "========== CONFIGURAR PARAMETROS =========="
		echo "Ambito:    $SCOPE_T"
		echo "IP inicio: $INICIAL_T"
		echo "IP fin:    $FINAL_T"
		[[ "$GATEWAY_T" != "X" ]] && echo "Gateway:   $GATEWAY_T"
		read -p "DNS primario (Enter para usar IP del servidor): " DNS_T

		if [[ -z "$DNS_T" ]]; then
			DNS_T="$INICIAL_T"; DNS2_T="X"; break
		fi

		if ! validar_dns "$DNS_T"; then
			echo "DNS primario invalido"; sleep 2; continue
		fi

		# ---- DNS secundario ----
		while true; do
			clear
			echo "========== CONFIGURAR PARAMETROS =========="
			echo "Ambito:    $SCOPE_T"
			echo "IP inicio: $INICIAL_T"
			echo "IP fin:    $FINAL_T"
			[[ "$GATEWAY_T" != "X" ]] && echo "Gateway:   $GATEWAY_T"
			echo "DNS 1:     $DNS_T"
			read -p "DNS secundario (Enter para omitir): " DNS2_T

			if [[ -z "$DNS2_T" ]]; then
				DNS2_T="X"; break
			fi

			if ! validar_dns "$DNS2_T"; then
				echo "DNS secundario invalido"; sleep 2; continue
			fi

			if [[ "$DNS_T" == "$DNS2_T" ]]; then
				echo "El DNS secundario no puede ser igual al primario"; sleep 2; continue
			fi
			break
		done
		break
	done

	# ---- Lease ----
	while true; do
		clear
		echo "========== CONFIGURAR PARAMETROS =========="
		echo "Ambito:    $SCOPE_T"
		echo "IP inicio: $INICIAL_T"
		echo "IP fin:    $FINAL_T"
		[[ "$GATEWAY_T" != "X" ]] && echo "Gateway:   $GATEWAY_T"
		[[ "$DNS_T"     != "X" ]] && echo "DNS 1:     $DNS_T"
		[[ "$DNS2_T"    != "X" ]] && echo "DNS 2:     $DNS2_T"
		read -p "Lease (en segundos): " LEASE_T

		if ! validar_lease "$LEASE_T"; then
			echo "Lease invalido (debe ser un numero entero mayor a 0)"; sleep 2; continue
		fi
		break
	done

	# Mascara siempre /24
	local MASCARA_T="255.255.255.0"

	clear
	echo "========== RESUMEN DE PARAMETROS =========="
	echo "Ambito:    $SCOPE_T"
	echo "IP inicio: $INICIAL_T  (IP estatica del servidor)"
	local ip_reparto
	ip_reparto=$(incrementar_ip "$INICIAL_T")
	echo "IP reparto:$ip_reparto  (primera IP que se asignara)"
	echo "IP fin:    $FINAL_T"
	[[ "$GATEWAY_T" != "X" ]] && echo "Gateway:   $GATEWAY_T"
	[[ "$DNS_T"     != "X" ]] && echo "DNS 1:     $DNS_T"
	[[ "$DNS2_T"    != "X" ]] && echo "DNS 2:     $DNS2_T"
	echo "Lease:     $LEASE_T segundos"
	echo "Mascara:   $MASCARA_T (/24)"
	echo "Interfaz:  $INTERFAZ"
	echo "-------------------------------------------"
	read -p "Confirmar y guardar? (S/s, cualquier otra tecla cancela): " CONFIRM

	if [[ "$CONFIRM" != "S" && "$CONFIRM" != "s" ]]; then
		echo "Cancelado."; sleep 1; return 0
	fi

	sed -i "s/^SCOPE=.*/SCOPE=$SCOPE_T/"         "$0"
	sed -i "s/^IPINICIAL=.*/IPINICIAL=$INICIAL_T/" "$0"
	sed -i "s/^IPFINAL=.*/IPFINAL=$FINAL_T/"       "$0"
	sed -i "s/^GATEWAY=.*/GATEWAY=$GATEWAY_T/"     "$0"
	sed -i "s/^DNS=.*/DNS=$DNS_T/"                 "$0"
	sed -i "s/^DNS2=.*/DNS2=$DNS2_T/"              "$0"
	sed -i "s/^LEASE=.*/LEASE=$LEASE_T/"           "$0"
	sed -i "s/^MASCARA=.*/MASCARA=$MASCARA_T/"     "$0"

	echo ""
	echo "Parametros guardados correctamente."
	sleep 1
}

ver_parametros(){
	clear
	if [[ "$SCOPE" == "X" || "$IPINICIAL" == "X" || "$IPFINAL" == "X" || "$LEASE" == "X" ]]; then
		echo ""
		echo "Parametros no configurados aun."
		echo "Ejecute: bash $0 parametrosconf"
		echo ""
	else
		local ip_reparto
		ip_reparto=$(incrementar_ip "$IPINICIAL")
		echo "========== PARAMETROS CONFIGURADOS =========="
		echo "Ambito:         $SCOPE"
		echo "IP del servidor:$IPINICIAL  (IP estatica fija)"
		echo "IP reparto:     $ip_reparto  (primera IP que se asignara a clientes)"
		echo "IP final:       $IPFINAL"
		echo "Red:            $(obtener_red "$IPINICIAL")"
		echo "Broadcast:      $(obtener_broadcast "$IPINICIAL")"
		echo "Mascara:        255.255.255.0 (/24)"
		[[ "$GATEWAY" != "X" ]] && echo "Gateway:        $GATEWAY"
		[[ "$DNS"     != "X" ]] && echo "DNS primario:   $DNS"
		[[ "$DNS2"    != "X" ]] && echo "DNS secundario: $DNS2"
		echo "Lease:          $LEASE segundos"
		echo "Interfaz:       $INTERFAZ"
		echo ""
	fi
}

iniciar_servidor(){
	clear

	if ! rpm -q dhcp-server > /dev/null 2>&1; then
		echo ""
		echo "ERROR: DHCP-SERVER no esta instalado"
		echo "Ejecute primero: bash $0 verificar"
		echo ""
		return 1
	fi

	if [[ "$SCOPE" == "X" || "$IPINICIAL" == "X" || "$IPFINAL" == "X" || "$LEASE" == "X" ]]; then
		echo ""
		echo "ERROR: Los parametros no estan configurados"
		echo "Ejecute primero: bash $0 parametrosconf"
		echo ""
		return 1
	fi

	echo "========== INICIAR SERVIDOR DHCP =========="
	echo ""

	# Configurar IP estatica en enp0s8
	if ! configurar_ip_estatica "$IPINICIAL" "$INTERFAZ"; then
		return 1
	fi
	echo ""

	# Configurar interfaz en /etc/sysconfig/dhcpd
	if [[ -f /etc/sysconfig/dhcpd ]]; then
		sudo sed -i "s/^DHCPD_INTERFACE=.*/DHCPD_INTERFACE=\"$INTERFAZ\"/"  /etc/sysconfig/dhcpd
		sudo sed -i "s/^DHCPD6_INTERFACE=.*/DHCPD6_INTERFACE=\"\"/"         /etc/sysconfig/dhcpd
	else
		sudo bash -c "cat > /etc/sysconfig/dhcpd << 'EOF'
DHCPD_INTERFACE=\"$INTERFAZ\"
DHCPD6_INTERFACE=\"\"
DHCPD_OTHER_ARGS=\"\"
DHCPD_RUN_CHROOTED=\"no\"
EOF"
	fi

	local ip_reparto red broadcast
	ip_reparto=$(incrementar_ip "$IPINICIAL")
	red=$(obtener_red "$IPINICIAL")
	broadcast=$(obtener_broadcast "$IPINICIAL")

	# Crear directorio y archivo de leases si no existen
	sudo mkdir -p /var/lib/dhcp/db
	sudo touch /var/lib/dhcp/db/dhcpd.leases

	# Generar /etc/dhcpd.conf
	{
		echo "ddns-update-style none;"
		echo "authoritative;"
		echo "default-lease-time $LEASE;"
		echo "max-lease-time $LEASE;"
		echo ""
		echo "subnet $red netmask 255.255.255.0 {"
		echo "    range $ip_reparto $IPFINAL;"
		echo "    option subnet-mask 255.255.255.0;"
		echo "    option broadcast-address $broadcast;"
		[[ "$GATEWAY" != "X" ]] && echo "    option routers $GATEWAY;"
		if [[ "$DNS" != "X" ]]; then
			if [[ "$DNS2" != "X" ]]; then
				echo "    option domain-name-servers $DNS, $DNS2;"
			else
				echo "    option domain-name-servers $DNS;"
			fi
		fi
		echo "}"
	} | sudo tee /etc/dhcpd.conf > /dev/null

	# Reiniciar servicio
	sudo systemctl stop dhcpd.service 2>/dev/null
	sleep 1

	echo "Iniciando servicio DHCP..."
	sudo systemctl start dhcpd.service
	sleep 2

	if systemctl is-active --quiet dhcpd.service; then
		sudo systemctl enable dhcpd.service 2>/dev/null
		echo ""
		echo "========== SERVIDOR DHCP ACTIVO =========="
		echo "IP del servidor: $IPINICIAL"
		echo "Rango:           $ip_reparto - $IPFINAL"
		echo "Mascara:         255.255.255.0"
		[[ "$GATEWAY" != "X" ]] && echo "Gateway:         $GATEWAY"
		[[ "$DNS"     != "X" ]] && echo "DNS primario:    $DNS"
		[[ "$DNS2"    != "X" ]] && echo "DNS secundario:  $DNS2"
		echo "Lease:           $LEASE segundos"
		echo "Interfaz:        $INTERFAZ"
		echo "-------------------------------------------"
		echo ""
	else
		echo ""
		echo "ERROR: No se pudo iniciar el servidor DHCP"
		echo "Revise el log con: sudo journalctl -u dhcpd.service -n 30"
		echo ""
		return 1
	fi
}

reiniciar_servidor(){
	clear
	echo "========== REINICIAR SERVIDOR DHCP =========="
	echo ""

	sudo systemctl restart dhcpd.service
	sleep 2

	if systemctl is-active --quiet dhcpd.service; then
		echo "Servidor DHCP reiniciado correctamente"
	else
		echo "ERROR: No se pudo reiniciar el servidor DHCP"
		echo "Revise el log con: sudo journalctl -u dhcpd.service -n 30"
	fi
	echo ""
}

detener_servidor(){
	clear
	echo "========== DETENER SERVIDOR DHCP =========="
	echo ""

	sudo systemctl stop dhcpd.service

	if [[ $? -eq 0 ]]; then
		echo "Servidor DHCP detenido correctamente"
	else
		echo "Error al detener el servidor DHCP"
	fi
	echo ""
}

monitor(){
	clear

	if ! rpm -q dhcp-server > /dev/null 2>&1; then
		echo ""
		echo "ERROR: DHCP-SERVER no esta instalado"
		echo ""
		return 1
	fi

	if [[ "$SCOPE" == "X" || "$IPINICIAL" == "X" || "$IPFINAL" == "X" || "$LEASE" == "X" ]]; then
		echo ""
		echo "ERROR: Los parametros no estan configurados"
		echo ""
		return 1
	fi

	if ! systemctl is-active --quiet dhcpd.service; then
		echo ""
		echo "ERROR: El servidor DHCP no esta en ejecucion"
		echo "Ejecute: bash $0 iniciar"
		echo ""
		return 1
	fi

	trap 'echo ""; echo "Saliendo del monitor..."; trap - SIGINT SIGTERM; return 0' SIGINT SIGTERM

	local lease_file="/var/lib/dhcp/db/dhcpd.leases"
	local ip_reparto
	ip_reparto=$(incrementar_ip "$IPINICIAL")

	while true; do
		clear
		echo "========== MONITOR DHCP =========="
		echo "Servidor : $SCOPE  ($IPINICIAL)"
		echo "Rango    : $ip_reparto - $IPFINAL"
		echo "Actualiza cada 3 segundos  (Ctrl+C para salir)"
		echo "-------------------------------------------"

		if [[ ! -f "$lease_file" ]]; then
			echo ""
			echo "No se encontro el archivo de leases: $lease_file"
			echo ""
			sleep 3
			continue
		fi

		local ahora
		ahora=$(date +%s)

		# Parsear leases activos con bash puro (sin awk externo)
		local ip="" mac="" hostname="" ends="" binding=""
		local -a activos=()

		while IFS= read -r linea; do
			linea="${linea#"${linea%%[![:space:]]*}"}"   # ltrim

			if [[ "$linea" =~ ^lease\ ([0-9.]+)\ \{ ]]; then
				ip="${BASH_REMATCH[1]}"
				mac=""; hostname="Desconocido"; ends=""; binding=""

			elif [[ "$linea" =~ ^hardware\ ethernet\ ([^;]+) ]]; then
				mac="${BASH_REMATCH[1]}"

			elif [[ "$linea" =~ ^client-hostname\ \"([^\"]+)\" ]]; then
				hostname="${BASH_REMATCH[1]}"

			elif [[ "$linea" =~ ^ends\ [0-9]+\ ([0-9/]+\ [0-9:]+)\; ]]; then
				ends="${BASH_REMATCH[1]}"

			elif [[ "$linea" == "ends never;" ]]; then
				ends="never"

			elif [[ "$linea" =~ ^binding\ state\ (.+)\; ]]; then
				binding="${BASH_REMATCH[1]}"

			elif [[ "$linea" == "}" && -n "$ip" && -n "$mac" ]]; then
				if [[ "$binding" == "active" ]]; then
					local activo=0
					if [[ "$ends" == "never" ]]; then
						activo=1
					elif [[ -n "$ends" ]]; then
						local ts_fin
						ts_fin=$(date -d "$ends" +%s 2>/dev/null || echo 0)
						[[ $ts_fin -gt $ahora ]] && activo=1
					fi

					if [[ $activo -eq 1 ]]; then
						activos+=("$ip|$mac|$hostname")
					fi
				fi
				ip=""; mac=""; hostname="Desconocido"; ends=""; binding=""
			fi
		done < "$lease_file"

		# Eliminar duplicados (puede haber entradas repetidas por renovaciones)
		local -A seen=()
		local count=0
		echo ""
		printf "%-16s %-19s %s\n" "IP" "MAC" "Hostname"
		echo "-------------------------------------------"
		for entrada in "${activos[@]}"; do
			local k="${entrada%%|*}"
			if [[ -z "${seen[$k]+_}" ]]; then
				seen[$k]=1
				IFS='|' read -r _ip _mac _host <<< "$entrada"
				printf "%-16s %-19s %s\n" "$_ip" "$_mac" "$_host"
				((count++))
			fi
		done

		echo "-------------------------------------------"
		echo "Clientes activos: $count"
		echo ""

		sleep 3
	done
}

# ============= COMANDOS ===================================================

case "$1" in
	help)
		echo ""
		echo "============ COMANDOS ============"
		echo "verificar      : Verificar si esta instalado DHCP-SERVER"
		echo "parametros     : Ver parametros actuales"
		echo "parametrosconf : Configurar parametros"
		echo "iniciar        : Iniciar el servidor DHCP"
		echo "reiniciar      : Reiniciar el servidor DHCP"
		echo "detener        : Detener el servidor DHCP"
		echo "monitor        : Ver clientes conectados en tiempo real"
		echo ""
		;;
	verificar)      verificar ;;
	parametros)     ver_parametros ;;
	parametrosconf) conf_parametros ;;
	iniciar)        iniciar_servidor ;;
	reiniciar)      reiniciar_servidor ;;
	detener)        detener_servidor ;;
	monitor)        monitor ;;
	*)
		echo ""
		echo "Uso: bash $0 <comando>"
		echo "     bash $0 help  para ver los comandos disponibles"
		echo ""
		;;
esac
