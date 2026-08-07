#!/usr/bin/env bash

set -e

echo "Instalando Kyro Optimizer..."

TMP_FILE=$(mktemp)

curl -fsSL "https://raw.githubusercontent.com/mykosoftware/Kyro/main/Kyro.sh" -o "$TMP_FILE"

sudo install -Dm755 "$TMP_FILE" /usr/local/bin/kyro

rm -f "$TMP_FILE"

echo ""
echo "Kyro instalado correctamente."
echo ""
echo "Ahora puedes ejecutar:"
echo "  kyro"
