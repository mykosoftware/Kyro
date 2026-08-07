#!/usr/bin/env bash

set -e

echo "Instalando Kyro Optimizer..."

TMP_KYRO=$(mktemp)
TMP_UNINSTALL=$(mktemp)

curl -fsSL "https://raw.githubusercontent.com/mykosoftware/Kyro/main/Kyro.sh" -o "$TMP_KYRO"

curl -fsSL "https://raw.githubusercontent.com/mykosoftware/Kyro/main/uninstall.sh" -o "$TMP_UNINSTALL"

sudo install -Dm755 "$TMP_KYRO" /usr/local/bin/kyro
sudo install -Dm755 "$TMP_UNINSTALL" /usr/local/bin/kyro-uninstall

rm -f "$TMP_KYRO" "$TMP_UNINSTALL"

echo ""
echo "Kyro instalado correctamente."
echo ""
echo "Comandos disponibles:"
echo "  kyro"
echo "  kyro-uninstall"
