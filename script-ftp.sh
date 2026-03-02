#!/bin/bash

# ============================================================================
# Script de Automatización de Servidor FTP - openSUSE Leap
# Administración de Sistemas
# Servidor: vsftpd (Very Secure FTP Daemon)
# ============================================================================

# Cargar librerías compartidas
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/utils.sh"
source "$SCRIPT_DIR/../lib/validaciones.sh"

# Variables Globales
readonly PAQUETE="vsftpd"
readonly VSFTPD_CONF="/etc/vsftpd.conf"
readonly FTP_ROOT="/srv/ftp"
readonly GRUPO_REPROBADOS="reprobados"
readonly GRUPO_RECURSADORES="recursadores"
readonly INTERFAZ_RED="enp0s9"

# ============================================================================
# FUNCIÓN: Mostrar ayuda
# ============================================================================
ayuda() {
    echo "Uso del script: $0"
    echo "Opciones:"
    echo -e "  -v, --verify       Verifica si está instalado vsftpd"
    echo -e "  -i, --install      Instala y configura el servidor FTP"
    echo -e "  -u, --users        Gestionar usuarios FTP"
    echo -e "  -r, --restart      Reiniciar servidor FTP"
    echo -e "  -s, --status       Verificar estado del servidor FTP"
    echo -e "  -l, --list         Listar usuarios y estructura FTP"
    echo -e "  -?, --help         Muestra esta ayuda"
}

# ============================================================================
# FUNCIÓN: Verificar instalación de vsftpd
# ============================================================================
verificar_Instalacion() {
    print_info "Verificando instalación de vsftpd"
    
    if rpm -q $PAQUETE &>/dev/null; then
        local version=$(rpm -q $PAQUETE --queryformat '%{VERSION}')
        print_completado "vsftpd ya está instalado (versión: $version)"
        return 0
    fi
    
    if command -v vsftpd &>/dev/null; then
        local version=$(vsftpd -v 2>&1 | head -1)
        print_completado "vsftpd encontrado: $version"
        return 0
    fi
    
    print_error "vsftpd no está instalado"
    return 1
}

# ============================================================================
# FUNCIÓN: Crear estructura de directorios base
# ============================================================================
crear_Estructura_Base() {
    print_info "Creando estructura de directorios FTP..."
    
    # Crear directorio raíz FTP si no existe
    if [ ! -d "$FTP_ROOT" ]; then
        sudo mkdir -p "$FTP_ROOT"
        print_completado "Directorio raíz creado: $FTP_ROOT"
    fi
    
    # Crear carpeta general (pública)
    if [ ! -d "$FTP_ROOT/general" ]; then
        sudo mkdir -p "$FTP_ROOT/general"
        print_completado "Carpeta 'general' creada"
    fi
    
    # Crear carpetas de grupos
    if [ ! -d "$FTP_ROOT/$GRUPO_REPROBADOS" ]; then
        sudo mkdir -p "$FTP_ROOT/$GRUPO_REPROBADOS"
        print_completado "Carpeta '$GRUPO_REPROBADOS' creada"
    fi
    
    if [ ! -d "$FTP_ROOT/$GRUPO_RECURSADORES" ]; then
        sudo mkdir -p "$FTP_ROOT/$GRUPO_RECURSADORES"
        print_completado "Carpeta '$GRUPO_RECURSADORES' creada"
    fi
    
    # Configurar permisos base
    # general: lectura para todos, escritura para usuarios autenticados
    sudo chmod 755 "$FTP_ROOT/general"
    sudo chown root:users "$FTP_ROOT/general"
    
    # Carpetas de grupo: solo accesibles por miembros del grupo
    sudo chmod 770 "$FTP_ROOT/$GRUPO_REPROBADOS"
    sudo chmod 770 "$FTP_ROOT/$GRUPO_RECURSADORES"
    
    print_completado "Estructura de directorios base configurada"
}

# ============================================================================
# FUNCIÓN: Crear grupos del sistema
# ============================================================================
crear_Grupos() {
    print_info "Verificando grupos del sistema..."
    
    # Crear grupo reprobados si no existe
    if ! getent group $GRUPO_REPROBADOS &>/dev/null; then
        sudo groupadd $GRUPO_REPROBADOS
        print_completado "Grupo '$GRUPO_REPROBADOS' creado"
    else
        print_info "Grupo '$GRUPO_REPROBADOS' ya existe"
    fi
    
    # Crear grupo recursadores si no existe
    if ! getent group $GRUPO_RECURSADORES &>/dev/null; then
        sudo groupadd $GRUPO_RECURSADORES
        print_completado "Grupo '$GRUPO_RECURSADORES' creado"
    else
        print_info "Grupo '$GRUPO_RECURSADORES' ya existe"
    fi
    
    # Asignar grupos a las carpetas
    sudo chgrp $GRUPO_REPROBADOS "$FTP_ROOT/$GRUPO_REPROBADOS"
    sudo chgrp $GRUPO_RECURSADORES "$FTP_ROOT/$GRUPO_RECURSADORES"
    
    print_completado "Grupos configurados correctamente"
}

# ============================================================================
# FUNCIÓN: Configurar vsftpd
# ============================================================================
configurar_Vsftpd() {
    print_info "Configurando vsftpd..."
    
    # Backup del archivo de configuración original
    if [ -f "$VSFTPD_CONF" ]; then
        sudo cp "$VSFTPD_CONF" "${VSFTPD_CONF}.backup.$(date +%Y%m%d_%H%M%S)"
        print_info "Backup de configuración creado"
    fi
    
    # Crear nueva configuración
    sudo tee "$VSFTPD_CONF" > /dev/null << 'EOF'
# Configuración vsftpd - Servidor FTP Seguro
# Generado automáticamente

# Configuración básica
listen=YES
listen_ipv6=NO

# Usuarios locales
local_enable=YES
write_enable=YES
local_umask=022

# Usuario anónimo
anonymous_enable=YES
anon_root=/srv/ftp/general
no_anon_password=YES
anon_upload_enable=NO
anon_mkdir_write_enable=NO
anon_other_write_enable=NO

# Enjaulado de usuarios (chroot)
chroot_local_user=YES
allow_writeable_chroot=YES
user_sub_token=$USER
local_root=/srv/ftp

# Seguridad
seccomp_sandbox=NO
hide_ids=YES
use_localtime=YES

# Permisos de archivos
file_open_mode=0666
local_umask=022

# Logging
xferlog_enable=YES
xferlog_file=/var/log/vsftpd.log
log_ftp_protocol=YES

# Configuración de conexión
connect_from_port_20=YES
idle_session_timeout=600
data_connection_timeout=120

# Banner
ftpd_banner=Bienvenido al servidor FTP - Acceso restringido

# Activar modo pasivo
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=40100

# Lista de usuarios permitidos
userlist_enable=YES
userlist_deny=NO
userlist_file=/etc/vsftpd.user_list

# SSL/TLS (Opcional - descomentar si se desea)
# ssl_enable=YES
# rsa_cert_file=/etc/ssl/certs/vsftpd.pem
# rsa_private_key_file=/etc/ssl/private/vsftpd.key
EOF

    print_completado "Archivo de configuración vsftpd creado"
    
    # Crear archivo de lista de usuarios vacío
    if [ ! -f /etc/vsftpd.user_list ]; then
        sudo touch /etc/vsftpd.user_list
        print_completado "Archivo de lista de usuarios creado"
    fi
}

# ============================================================================
# FUNCIÓN: Instalar y configurar servidor FTP
# ============================================================================
instalar_FTP() {
    print_titulo "Instalación y Configuración de Servidor FTP"
    
    # 1. Verificar si vsftpd ya está instalado
    if verificar_Instalacion; then
        print_info "¿Desea reconfigurar el servidor FTP? [s/N]: "
        read -r reconf
        if [[ ! "$reconf" =~ ^[Ss]$ ]]; then
            print_info "Operación cancelada"
            return 0
        fi
    else
        print_info "Instalando vsftpd..."
        
        sudo zypper --non-interactive --quiet install $PAQUETE > /dev/null 2>&1 &
        pid=$!
        
        print_info "vsftpd se está instalando..."
        wait $pid
        
        if [ $? -eq 0 ]; then
            print_completado "vsftpd instalado correctamente"
        else
            print_error "Error en la instalación de vsftpd"
            return 1
        fi
    fi
    
    echo ""
    
    # 2. Crear grupos del sistema
    crear_Grupos
    echo ""
    
    # 3. Crear estructura de directorios
    crear_Estructura_Base
    echo ""
    
    # 4. Configurar vsftpd
    configurar_Vsftpd
    echo ""
    
    # 5. Habilitar y activar el servicio
    print_info "Habilitando servicio vsftpd en el arranque..."
    if sudo systemctl enable vsftpd 2>/dev/null; then
        print_completado "Servicio vsftpd habilitado"
    else
        print_error "No se pudo habilitar el servicio vsftpd"
        return 1
    fi
    
    print_info "Iniciando servicio vsftpd..."
    if systemctl is-active --quiet vsftpd; then
        print_info "Servicio ya estaba activo, reiniciando..."
        if sudo systemctl restart vsftpd 2>/dev/null; then
            print_completado "Servicio vsftpd reiniciado"
        else
            print_error "Error al reiniciar el servicio vsftpd"
            return 1
        fi
    else
        if sudo systemctl start vsftpd 2>/dev/null; then
            print_completado "Servicio vsftpd iniciado"
        else
            print_error "Error al iniciar el servicio vsftpd"
            print_error "Revise los logs: journalctl -u vsftpd"
            return 1
        fi
    fi
    
    # 6. Configurar firewall
    print_info "Configurando firewall para FTP..."
    if command -v firewall-cmd &>/dev/null; then
        # Puerto de control FTP
        if sudo firewall-cmd --add-service=ftp --permanent 2>/dev/null; then
            print_completado "Servicio FTP agregado al firewall (permanente)"
        fi
        
        # Puertos pasivos
        if sudo firewall-cmd --add-port=40000-40100/tcp --permanent 2>/dev/null; then
            print_completado "Puertos pasivos 40000-40100/tcp abiertos"
        fi
        
        if sudo firewall-cmd --reload 2>/dev/null; then
            print_completado "Firewall recargado"
        fi
    else
        print_error "firewalld no encontrado, configure el firewall manualmente"
        print_info "Abra el puerto 21 TCP y puertos 40000-40100 TCP"
    fi
    
    # 7. Verificación final
    echo ""
    print_info "Verificando estado del servidor FTP..."
    echo ""
    
    if systemctl is-active --quiet vsftpd; then
        print_completado "Servicio vsftpd: activo y corriendo"
    else
        print_error "Servicio vsftpd: NO está corriendo"
        return 1
    fi
    
    if ss -tulnp 2>/dev/null | grep -q ":21 "; then
        print_completado "Puerto 21: escuchando"
    else
        print_error "Puerto 21: NO está escuchando"
    fi
    
    # 8. Obtener IP de la interfaz enp0s9
    local ip=$(ip addr show $INTERFAZ_RED 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
    
    if [ -z "$ip" ]; then
        print_error "No se pudo obtener la IP de la interfaz $INTERFAZ_RED"
        print_info "Verifique que la interfaz esté configurada"
        ip=$(ip addr show | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d'/' -f1 | head -1)
    fi
    
    # 9. Resumen
    echo ""
    print_completado "══════════════════════════════════════"
    print_completado "  Servidor FTP listo"
    print_completado "══════════════════════════════════════"
    print_info "  IP del servidor : ${verde}$ip${nc}"
    print_info "  Interfaz        : ${verde}$INTERFAZ_RED${nc}"
    print_info "  Puerto FTP      : ${verde}21${nc}"
    print_info "  Acceso anónimo  : ${verde}ftp://$ip/general${nc}"
    print_info "  Raíz FTP        : ${verde}$FTP_ROOT${nc}"
    print_completado "══════════════════════════════════════"
    echo ""
    print_info "Ahora puede crear usuarios con: $0 -u"
}

# ============================================================================
# FUNCIÓN: Validar nombre de usuario
# ============================================================================
validar_Usuario() {
    local usuario="$1"
    
    # Verificar que no esté vacío
    if [ -z "$usuario" ]; then
        print_error "El nombre de usuario no puede estar vacío"
        return 1
    fi
    
    # Verificar longitud (3-32 caracteres)
    if [ ${#usuario} -lt 3 ] || [ ${#usuario} -gt 32 ]; then
        print_error "El nombre de usuario debe tener entre 3 y 32 caracteres"
        return 1
    fi
    
    # Verificar formato (solo letras, números, guiones y guiones bajos)
    if [[ ! "$usuario" =~ ^[a-z][a-z0-9_-]*$ ]]; then
        print_error "El nombre de usuario debe comenzar con letra minúscula"
        print_error "y solo puede contener letras, números, guiones y guiones bajos"
        return 1
    fi
    
    # Verificar que no exista
    if id "$usuario" &>/dev/null; then
        print_error "El usuario '$usuario' ya existe en el sistema"
        return 1
    fi
    
    return 0
}

# ============================================================================
# FUNCIÓN: Validar contraseña
# ============================================================================
validar_Contrasena() {
    local password="$1"
    
    # Verificar longitud mínima
    if [ ${#password} -lt 6 ]; then
        print_error "La contraseña debe tener al menos 6 caracteres"
        return 1
    fi
    
    return 0
}

# ============================================================================
# FUNCIÓN: Crear usuario FTP
# ============================================================================
crear_Usuario_FTP() {
    local usuario="$1"
    local password="$2"
    local grupo="$3"
    
    print_info "Creando usuario '$usuario' en grupo '$grupo'..."
    
    # Crear usuario del sistema sin home en /home
    # El home será /srv/ftp (enjaulado por vsftpd)
    if sudo useradd -m -d "$FTP_ROOT" -s /bin/bash -g "$grupo" "$usuario" 2>/dev/null; then
        print_completado "Usuario del sistema creado"
    else
        print_error "Error al crear usuario del sistema"
        return 1
    fi
    
    # Establecer contraseña
    echo "$usuario:$password" | sudo chpasswd
    if [ $? -eq 0 ]; then
        print_completado "Contraseña establecida"
    else
        print_error "Error al establecer contraseña"
        return 1
    fi
    
    # Crear directorio personal del usuario dentro de FTP
    local user_dir="$FTP_ROOT/$usuario"
    if [ ! -d "$user_dir" ]; then
        sudo mkdir -p "$user_dir"
        sudo chown "$usuario:$grupo" "$user_dir"
        sudo chmod 755 "$user_dir"
        print_completado "Directorio personal creado: $user_dir"
    fi
    
    # Agregar usuario a la lista de usuarios permitidos
    if ! grep -q "^$usuario$" /etc/vsftpd.user_list 2>/dev/null; then
        echo "$usuario" | sudo tee -a /etc/vsftpd.user_list > /dev/null
        print_completado "Usuario agregado a la lista de acceso FTP"
    fi
    
    # Dar permisos de escritura en carpeta general usando ACL si está disponible
    if command -v setfacl &>/dev/null; then
        sudo setfacl -m u:${usuario}:rwx "$FTP_ROOT/general" 2>/dev/null && \
            print_completado "Permisos ACL configurados en 'general'" || \
            print_info "Usando permisos estándar en 'general'"
        
        # Dar permisos en carpeta de grupo
        sudo setfacl -m u:${usuario}:rwx "$FTP_ROOT/$grupo" 2>/dev/null && \
            print_completado "Permisos ACL configurados en '$grupo'" || \
            print_info "Usando permisos estándar en '$grupo'"
    else
        print_info "ACL no disponible, usando permisos estándar"
    fi
    
    print_completado "Usuario '$usuario' creado exitosamente"
    return 0
}

# ============================================================================
# FUNCIÓN: Cambiar usuario de grupo
# ============================================================================
cambiar_Grupo_Usuario() {
    local usuario="$1"
    
    # Verificar que el usuario existe
    if ! id "$usuario" &>/dev/null; then
        print_error "El usuario '$usuario' no existe"
        return 1
    fi
    
    # Obtener grupo actual
    local grupo_actual=$(id -gn "$usuario")
    print_info "Grupo actual de '$usuario': $grupo_actual"
    
    # Preguntar nuevo grupo
    echo ""
    echo "Grupos disponibles:"
    echo "  1) $GRUPO_REPROBADOS"
    echo "  2) $GRUPO_RECURSADORES"
    read -p "Seleccione el nuevo grupo [1-2]: " opcion
    
    local nuevo_grupo
    case $opcion in
        1) nuevo_grupo="$GRUPO_REPROBADOS" ;;
        2) nuevo_grupo="$GRUPO_RECURSADORES" ;;
        *)
            print_error "Opción inválida"
            return 1
            ;;
    esac
    
    if [ "$grupo_actual" == "$nuevo_grupo" ]; then
        print_info "El usuario ya pertenece al grupo '$nuevo_grupo'"
        return 0
    fi
    
    # Cambiar grupo principal del usuario
    if sudo usermod -g "$nuevo_grupo" "$usuario"; then
        print_completado "Usuario '$usuario' movido al grupo '$nuevo_grupo'"
        
        # Actualizar permisos con ACL si está disponible
        if command -v setfacl &>/dev/null; then
            sudo setfacl -m u:${usuario}:rwx "$FTP_ROOT/$nuevo_grupo" 2>/dev/null
            sudo setfacl -x u:${usuario} "$FTP_ROOT/$grupo_actual" 2>/dev/null
            print_completado "Permisos ACL actualizados"
        fi
    else
        print_error "Error al cambiar el grupo del usuario"
        return 1
    fi
}

# ============================================================================
# FUNCIÓN: Gestionar usuarios FTP
# ============================================================================
gestionar_Usuarios() {
    print_titulo "Gestión de Usuarios FTP"
    
    # Verificar que vsftpd esté instalado
    if ! verificar_Instalacion &>/dev/null; then
        print_error "vsftpd no está instalado"
        print_info "Ejecute primero: $0 -i"
        return 1
    fi
    
    echo "Opciones:"
    echo "  1) Crear nuevos usuarios"
    echo "  2) Cambiar grupo de un usuario"
    echo "  3) Eliminar usuario"
    echo "  4) Volver"
    echo ""
    read -p "Seleccione una opción [1-4]: " opcion
    
    case $opcion in
        1)
            # Crear nuevos usuarios
            echo ""
            read -p "¿Cuántos usuarios desea crear?: " num_usuarios
            
            if ! [[ "$num_usuarios" =~ ^[0-9]+$ ]] || [ "$num_usuarios" -lt 1 ]; then
                print_error "Número de usuarios inválido"
                return 1
            fi
            
            for ((i=1; i<=num_usuarios; i++)); do
                echo ""
                print_titulo "Usuario $i de $num_usuarios"
                
                # Pedir nombre de usuario
                while true; do
                    read -p "Nombre de usuario: " usuario
                    if validar_Usuario "$usuario"; then
                        break
                    fi
                done
                
                # Pedir contraseña
                while true; do
                    read -s -p "Contraseña: " password
                    echo ""
                    if validar_Contrasena "$password"; then
                        read -s -p "Confirmar contraseña: " password2
                        echo ""
                        if [ "$password" == "$password2" ]; then
                            break
                        else
                            print_error "Las contraseñas no coinciden"
                        fi
                    fi
                done
                
                # Preguntar grupo
                echo ""
                echo "¿A qué grupo pertenece?"
                echo "  1) $GRUPO_REPROBADOS"
                echo "  2) $GRUPO_RECURSADORES"
                read -p "Seleccione el grupo [1-2]: " grupo_opcion
                
                local grupo
                case $grupo_opcion in
                    1) grupo="$GRUPO_REPROBADOS" ;;
                    2) grupo="$GRUPO_RECURSADORES" ;;
                    *)
                        print_error "Opción inválida, asignando a '$GRUPO_REPROBADOS'"
                        grupo="$GRUPO_REPROBADOS"
                        ;;
                esac
                
                # Crear usuario
                if crear_Usuario_FTP "$usuario" "$password" "$grupo"; then
                    echo ""
                    print_completado "Usuario '$usuario' creado en grupo '$grupo'"
                else
                    print_error "Error al crear usuario '$usuario'"
                fi
            done
            
            # Reiniciar servicio
            echo ""
            print_info "Reiniciando servicio vsftpd..."
            sudo systemctl restart vsftpd
            print_completado "Servicio reiniciado"
            ;;
            
        2)
            # Cambiar grupo
            echo ""
            listar_Usuarios_FTP
            echo ""
            read -p "Ingrese el nombre del usuario: " usuario
            cambiar_Grupo_Usuario "$usuario"
            
            if [ $? -eq 0 ]; then
                print_info "Reiniciando servicio vsftpd..."
                sudo systemctl restart vsftpd
            fi
            ;;
            
        3)
            # Eliminar usuario
            echo ""
            listar_Usuarios_FTP
            echo ""
            read -p "Ingrese el nombre del usuario a eliminar: " usuario
            
            if ! id "$usuario" &>/dev/null; then
                print_error "El usuario '$usuario' no existe"
                return 1
            fi
            
            read -p "¿Está seguro de eliminar el usuario '$usuario'? [s/N]: " confirmar
            if [[ "$confirmar" =~ ^[Ss]$ ]]; then
                # Eliminar de la lista de vsftpd
                sudo sed -i "/^$usuario$/d" /etc/vsftpd.user_list
                
                # Eliminar directorio personal
                sudo rm -rf "$FTP_ROOT/$usuario"
                
                # Eliminar usuario del sistema
                sudo userdel "$usuario"
                
                print_completado "Usuario '$usuario' eliminado"
                
                print_info "Reiniciando servicio vsftpd..."
                sudo systemctl restart vsftpd
            else
                print_info "Operación cancelada"
            fi
            ;;
            
        4)
            return 0
            ;;
            
        *)
            print_error "Opción inválida"
            ;;
    esac
}

# ============================================================================
# FUNCIÓN: Listar usuarios FTP
# ============================================================================
listar_Usuarios_FTP() {
    print_titulo "Usuarios FTP Configurados"
    
    if [ ! -f /etc/vsftpd.user_list ]; then
        print_info "No hay usuarios FTP configurados"
        return 0
    fi
    
    if [ ! -s /etc/vsftpd.user_list ]; then
        print_info "La lista de usuarios está vacía"
        return 0
    fi
    
    printf "%-20s %-20s %-30s\n" "USUARIO" "GRUPO" "DIRECTORIO"
    echo "----------------------------------------------------------------------"
    
    while IFS= read -r usuario; do
        if id "$usuario" &>/dev/null; then
            local grupo=$(id -gn "$usuario")
            local dir="$FTP_ROOT/$usuario"
            printf "%-20s %-20s %-30s\n" "$usuario" "$grupo" "$dir"
        fi
    done < /etc/vsftpd.user_list
    
    echo ""
}

# ============================================================================
# FUNCIÓN: Listar estructura FTP
# ============================================================================
listar_Estructura() {
    print_titulo "Estructura del Servidor FTP"
    
    if [ ! -d "$FTP_ROOT" ]; then
        print_error "El directorio FTP no existe: $FTP_ROOT"
        return 1
    fi
    
    print_info "Raíz FTP: $FTP_ROOT"
    print_info "Interfaz: $INTERFAZ_RED"
    
    local ip=$(ip addr show $INTERFAZ_RED 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
    if [ -n "$ip" ]; then
        print_info "IP: $ip"
    fi
    
    echo ""
    
    # Usar tree si está disponible, sino usar find
    if command -v tree &>/dev/null; then
        sudo tree -L 2 -p -u -g "$FTP_ROOT"
    else
        sudo find "$FTP_ROOT" -maxdepth 2 -type d -exec ls -ld {} \;
    fi
    
    echo ""
    listar_Usuarios_FTP
}

# ============================================================================
# FUNCIÓN: Reiniciar servicio FTP
# ============================================================================
reiniciar_FTP() {
    print_info "Reiniciando servidor FTP..."
    
    if ! systemctl is-active --quiet vsftpd; then
        print_error "El servicio vsftpd no está activo"
        read -p "¿Desea iniciarlo en lugar de reiniciarlo? (y/n): " opc
        if [[ "$opc" = "y" ]]; then
            sudo systemctl start vsftpd
        else
            return 1
        fi
    else
        sudo systemctl restart vsftpd
    fi
    
    if systemctl is-active --quiet vsftpd; then
        print_completado "Servidor vsftpd reiniciado correctamente"
        sudo systemctl status vsftpd --no-pager
    else
        print_error "Error al reiniciar el servidor vsftpd"
        print_info "Ejecute: sudo journalctl -xeu vsftpd.service"
    fi
}

# ============================================================================
# FUNCIÓN: Ver estado del servidor
# ============================================================================
ver_Estado() {
    print_titulo "ESTADO DEL SERVIDOR FTP"
    sudo systemctl status vsftpd --no-pager
    echo ""
    
    print_info "Conexiones FTP activas:"
    sudo ss -tnp | grep :21 || echo "  No hay conexiones activas"
    
    echo ""
    local ip=$(ip addr show $INTERFAZ_RED 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
    if [ -n "$ip" ]; then
        print_info "IP de la interfaz $INTERFAZ_RED: $ip"
    else
        print_error "No se pudo obtener la IP de $INTERFAZ_RED"
    fi
}

# ============================================================================
# VERIFICAR PERMISOS DE ROOT
# ============================================================================
if [[ $EUID -ne 0 ]]; then
    print_error "Este script debe ejecutarse como root o con sudo"
    exit 1
fi

# ============================================================================
# PROCESAMIENTO DE ARGUMENTOS
# ============================================================================
case $1 in
    -v | --verify)  verificar_Instalacion ;;
    -i | --install) instalar_FTP ;;
    -u | --users)   gestionar_Usuarios ;;
    -s | --status)  ver_Estado ;;
    -r | --restart) reiniciar_FTP ;;
    -l | --list)    listar_Estructura ;;
    -? | --help)    ayuda ;;
    *)              ayuda ;;
esac