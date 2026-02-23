#!/bin/bash

SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"

source "$SCRIPT_DIR/funciones_comunes.sh"
source "$SCRIPT_DIR/dhcp.sh"
source "$SCRIPT_DIR/dns.sh"

# ==================== MENU PRINCIPAL ====================

while true; do
	clear
	echo "========================================="
	echo "     ADMINISTRACION DE SERVIDORES        "
	echo "========================================="
	echo ""
	echo "  Interfaz: $INTERFAZ"
	echo ""
	echo "  1. Configuracion DHCP"
	echo "  2. Configuracion DNS"
	echo "  0. Salir"
	echo ""
	read -p "Seleccione una opcion: " OPC

	if [ "$OPC" = "1" ]; then
		dhcp_menu
	elif [ "$OPC" = "2" ]; then
		dns_menu
	elif [ "$OPC" = "0" ]; then
		clear
		echo ""
		echo "Hasta luego."
		echo ""
		exit 0
	else
		echo "Opcion invalida..."; sleep 2
	fi
done
