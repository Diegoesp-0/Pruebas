#!/bin/bash

# ==================== VARIABLES COMUNES ====================

INTERFAZ="enp0s8"

# ==================== FUNCIONES COMUNES ====================

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

instalar_paquete(){
	local paquete=$1

	if rpm -q "$paquete" > /dev/null 2>&1; then
		echo ""
		echo "$paquete ya esta instalado :D"
		echo ""
		sleep 2
	else
		echo ""
		echo "$paquete no esta instalado"
		echo ""
		read -p "Desea instalar $paquete? (S/s): " OPC

		if [[ "$OPC" == "S" || "$OPC" == "s" ]]; then
			echo "Instalando $paquete..."
			sudo zypper install -y "$paquete"
		fi
	fi
}

paquete_instalado(){
	local paquete=$1
	rpm -q "$paquete" > /dev/null 2>&1
}

obtener_ip_interfaz(){
	ip -4 addr show dev "$INTERFAZ" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1 | head -n1
}

obtener_red(){
	IFS='.' read -r p1 p2 p3 _ <<< "$1"
	echo "$p1.$p2.$p3.0"
}

obtener_broadcast(){
	IFS='.' read -r p1 p2 p3 _ <<< "$1"
	echo "$p1.$p2.$p3.255"
}

configurar_ip_estatica(){
	local ip=$1
	local interfaz=$2

	echo "Configurando IP estatica $ip/24 en $interfaz..."

	# Eliminar todas las IPs IPv4 existentes en la interfaz antes de agregar la nueva
	local ips_actuales
	ips_actuales=$(ip -4 addr show dev "$interfaz" 2>/dev/null | grep "inet " | awk '{print $2}')
	for ip_vieja in $ips_actuales; do
		sudo ip addr del "$ip_vieja" dev "$interfaz" 2>/dev/null
	done

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

verificar_servicio_activo(){
	local servicio=$1
	systemctl is-active --quiet "$servicio"
}

iniciar_servicio(){
	local servicio=$1

	if verificar_servicio_activo "$servicio"; then
		echo ""
		echo "El servicio $servicio ya esta corriendo..."
		echo ""
		sleep 2
	else
		sudo systemctl enable "$servicio"
		sudo systemctl start "$servicio"
		sleep 2
		echo ""
		if verificar_servicio_activo "$servicio"; then
			echo "Servicio $servicio iniciado correctamente..."
		else
			echo "Error al iniciar el servicio $servicio"
			echo "Revise: sudo journalctl -u $servicio -n 30"
			return 1
		fi
		echo ""
	fi
}

detener_servicio(){
	local servicio=$1

	sudo systemctl stop "$servicio"

	if [[ $? -eq 0 ]]; then
		echo "Servicio $servicio detenido correctamente"
	else
		echo "Error al detener el servicio $servicio"
	fi
}

reiniciar_servicio(){
	local servicio=$1

	sudo systemctl restart "$servicio"
	sleep 2

	if verificar_servicio_activo "$servicio"; then
		echo "Servicio $servicio reiniciado correctamente"
	else
		echo "ERROR: No se pudo reiniciar el servicio $servicio"
		echo "Revise: sudo journalctl -u $servicio -n 30"
		return 1
	fi
}
