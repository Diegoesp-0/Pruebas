# ---------- Cargar libreria compartida ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

# Validaciones de IP
validar_IP(){
	# Variable
	local ip="$1"
	echo -en "${rojo}"

	# Validar formato X.X.X.X solo con numeros
	if ! [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
		echo -e "Direccion IP invalida, tiene que contener un formato X.X.X.X unicamente con numeros positivos${nc}"
    	return 1
   	fi
	
	# Validar cada octeto entre 0 y 255
    	IFS='.' read -r a b c d <<< "$ip"
	if [[ "$a" -eq 0  || "$d" -eq 0 ]]; then
		echo -e "Direccion IP invalida, no puede ser 0.X.X.X ni X.X.X.0${nc}"
		return 1
	fi
	
	# Validar que no tenga 0 al izquierda y que no pasen los rangos de 8 bits
	for octeto in $a $b $c $d; do
	if [[ "$octeto" =~ ^0[0-9]+ ]]; then
		echo -e "Direccion IP invalida, no se pueden poner 0 a la izquierda a menos que sea 0${nc}"
		return 1
	fi
		if [[ "$octeto" -lt 0 || "$octeto" -gt 255 ]]; then
				echo -e "Direccion IP invalida, no puede ser mayor a 255 ni menor a 0${nc}"
				return 1
		fi
	done

	# Validar que no sea 0.0.0.0 ni 255.255.255.255
	if [[ "$ip" = "0.0.0.0" || "$ip" = "255.255.255.255" ]]; then
		echo -e "Direccion IP invalida, no puede ser 0.0.0.0 ni 255.255.255.255${nc}"
		return 1
	fi

    # Validar los espacios reservados para uso experimental (127.0.0.1-127.255.255.255)
	if [[ "$a" -eq 127 ]]; then
		echo -e "Direccion IP invalida, las direcciones del rango 127.0.0.1 al 127.255.255.255 estan reservadas para host local${nc}"
		return 1
	fi

	# Validar los espacios reservados para uso experimental (240.0.0.0-255.255.255.254)
	if [[ "$a" -gt 240 && "$a" -lt 255 ]]; then
		echo -e "Direccion IP invalida, las direcciones del rango 240.0.0.0 al 255.255.255.254 estan reservadas para usos experimentales${nc}"
		return 1
	fi

	# Validar los espacios reservados para multicast (224.0.0.0-239.255.255.255)
	if [[ "$a" -gt 224 && "$a" -lt 239 ]]; then
		echo -e "Direccion IP invalida, las direcciones del rango 224.0.0.0 al 239.255.255.255 estan reservadas para multicast${nc}"
		return 1
	fi

	echo -en "${nc}"
    	return 0
}

validar_Mascara(){
	local masc="$1"
	echo -en "${rojo}"
	
	# Validar formato X.X.X.X solo con numeros
	if ! [[ "$masc" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
		echo -e "Mascara invalida, tiene que contener un formato X.X.X.X unicamente con numeros positivos${nc}"
		return 1
	fi

	# Validar cada octeto entre 0 y 255
	IFS='.' read -r a b c d <<< "$masc"
	if [ "$a" -eq 0 ]; then
		echo -e "Mascara invalida, no puede ser 0.X.X.X${nc}"
		return 1
	fi
	
	# Validar que no tenga 0 al izquierda y que no pasen los rangos de 8 bits
	for octeto in $a $b $c $d; do
		if [[ "$octeto" =~ ^0[0-9]+ ]]; then
			echo -e "Mascara invalida, no se pueden poner 0 a la izquierda a menos que sea 0${nc}"
			return 1
		fi
		if [[ "$octeto" -lt 0 || "$octeto" -gt 255 ]]; then
				echo -e "Mascara invalida, no puede ser mayor a 255 ni menor a 0${nc}"
				return 1
		fi
	done

	# Validar los bits de la mascara
	if [ "$a" -lt 255 ]; then
		for octeto in $b $c $d; do
			if [ "$octeto" -gt 0 ]; then
				echo -e "Mascara invalida, ocupas acabar los bits del primer octeto (255.X.X.X)${nc}"
				return 1
			fi
		done
	elif [ "$b" -lt 255 ]; then
		for octeto in $c $d; do
			if [ "$octeto" -gt 0 ]; then
				echo -e "Mascara invalida, ocupas acabar los bits del segundo octeto (255.255.X.X)${nc}"
				return 1
			fi
		done
	elif [ "$c" -lt 255 ]; then
		for octeto in $d; do
			if [ "$octeto" -gt 0 ]; then
				echo -e "Mascara invalida, ocupas acabar los bits del tercer octeto (255.255.255.X)${nc}"
				return 1
			fi
		done
	elif [ "$d" -gt 252 ]; then
		echo -e "Mascara invalida, no puede superar 255.255.255.252${nc}"
		return 1
	fi

	echo -en "${nc}"
	return 0
}

validar_Dominio() {
    local domain="$1"
    local domain_regex='^([a-zA-Z0-9]([-a-zA-Z0-9]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
    
    if [[ ! $domain =~ $domain_regex ]]; then
        print_warning "Formato de dominio inválido: $domain"
        return 1
    fi
    
    return 0
}