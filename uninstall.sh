#!/usr/bin/env bash

set -e

echo "Desinstalando Kyro Optimizer..."

if [ -f /usr/local/bin/kyro ]; then
    sudo rm -f /usr/local/bin/kyro
    echo "Kyro eliminado correctamente."
else
    echo "Kyro no está instalado."
fi

echo ""
echo "Desinstalación completada."
