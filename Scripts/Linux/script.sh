#!/bin/bash
clear
nombre=$(whoami)
echo "Hola, $nombre. Bienvenido"

# Menu en un bucle infinito
while true; do
    # Mostrar opciones y leer la eleccion
    echo "Seleccione una opcion de 1 a 5:"
    echo "1) Actualizar el sistema"
    echo "2) Instalar paquete adicional"
    echo "3) Cambio de nombre al equipo"
    echo "4) Salir"
    read -p "Opcion: " op

    # Ejecutar accion segun la opcion seleccionada
    case $op in
        1) 
            echo "Opcion 1 seleccionada: Actualizando el sistema..."
            apt update -y && sudo apt upgrade -y
            echo "Sistema actualizado."
            sleep 10
            clear
            ;;
        2) 
            echo "Opcion 2 seleccionada: Instalacion de algun paquete (iptables, net-tools, etc.)."
            echo "Nombre de la aplicacion a instalar: "
            read nom
            apt install $nom -y
            sleep 2
            clear
            ;;
        3) 
            echo "Opcion 3 seleccionada: Cambiar nombre del hostname."
            echo "Nuevo nombre para el hostname: "
            read nov
            hostnamectl set-hostname $nov  # Cambiar el hostname
            echo "Nuevo nombre asignado: $nov"  # Mostrar el nuevo hostname
            sleep 2
            clear
            ;;
        4) 
            echo "Saliendo del programa..."
            break
            ;;
        *)
            echo "Opcion no valida. Por favor, elija una opcion entre 1 y 5."
            ;;
    esac
done
