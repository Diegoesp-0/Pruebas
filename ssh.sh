#!/bin/bash

verificar(){
	clear
	if rpm -q openssh-server > /dev/null 2>&1; then
		echo ""
		echo "OpenSSH-Server esta instalado :D"
		echo ""
	else
		echo ""
		echo "OpenSSH-Server no esta instalado"
		echo ""
		read -p "Desea instalarlo? (S/s): " OPC
		if [[ "$OPC" == "S" || "$OPC" == "s" ]]; then
			sudo zypper install -y openssh-server
		fi
	fi
}

iniciar(){
	clear
	if ! rpm -q openssh-server > /dev/null 2>&1; then
		echo ""
		echo "ERROR: OpenSSH-Server no esta instalado"
		echo "Ejecute primero: bash $0 verificar"
		echo ""
		return 1
	fi

	sudo ip link set enp0s9 promisc on
	sudo systemctl enable sshd
	sudo systemctl start sshd
	sleep 1

	if systemctl is-active --quiet sshd; then
		sudo firewall-cmd --permanent --add-service=ssh 2>/dev/null
		sudo firewall-cmd --reload 2>/dev/null
		echo ""
		echo "Servidor SSH iniciado correctamente"
		echo "Puerto 22 abierto en el firewall"
		echo ""
		IP=$(ip a show enp0s9 | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
		echo "Conectate desde PuTTY:"
		echo "  Host: $IP"
		echo "  Port: 22"
		echo ""
	else
		echo ""
		echo "ERROR: No se pudo iniciar SSH"
		echo ""
	fi
}

reiniciar(){
	clear
	sudo ip link set enp0s9 promisc on
	sudo systemctl restart sshd
	sleep 1

	if systemctl is-active --quiet sshd; then
		echo ""
		echo "SSH reiniciado correctamente"
		echo ""
	else
		echo ""
		echo "ERROR: No se pudo reiniciar SSH"
		echo ""
	fi
}

detener(){
	clear
	sudo systemctl stop sshd

	if [[ $? -eq 0 ]]; then
		echo ""
		echo "SSH detenido correctamente"
		echo ""
	else
		echo ""
		echo "ERROR: No se pudo detener SSH"
		echo ""
	fi
}

estado(){
	clear
	echo ""
	systemctl status sshd --no-pager
	echo ""
	echo "Conexiones activas:"
	ss -tnp | grep :22
	echo ""
}

if [[ "$1" == "help" ]]; then
	echo ""
	echo "============ COMANDOS ============"
	echo "verificar : Verificar si esta instalado OpenSSH-Server"
	echo "iniciar   : Instalar, habilitar e iniciar SSH"
	echo "reiniciar : Reiniciar el servicio SSH"
	echo "detener   : Detener el servicio SSH"
	echo "estado    : Ver estado del servicio y conexiones activas"
	echo ""
elif [[ "$1" == "verificar" ]]; then
	verificar
elif [[ "$1" == "iniciar" ]]; then
	iniciar
elif [[ "$1" == "reiniciar" ]]; then
	reiniciar
elif [[ "$1" == "detener" ]]; then
	detener
elif [[ "$1" == "estado" ]]; then
	estado
else
	echo ""
	echo "Uso: bash $0 <comando>"
	echo "     bash $0 help  para ver los comandos disponibles"
	echo ""
fi
