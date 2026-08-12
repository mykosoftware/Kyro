#!/bin/bash

# ═══════════════════════════════════════════════════════
#  Kyro Optimizer – Mantenimiento y diagnóstico del sistema
#  Licencia: GPL-3.0
#  Versión: 5.1.Lexia
#  By: Myko Software
# ═══════════════════════════════════════════════════════

set -uo pipefail

umask 077

VERSION="5.1.Lexia"

# ─── Colores ───────────────────────────────────────────
CYAN="\e[36m"
GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
MAGENTA="\e[35m"
ORANGE="\e[38;5;208m"
WHITE="\e[1;97m"
BOLD="\e[1m"
DIM="\e[2m"
RESET="\e[0m"

STATE_FILE="$HOME/.cache/kyro_last_run"

# Acumulan ajustes aplicados en esta sesión para persistirlos.
KYRO_SYSCTL=()
KYRO_NET=()

# ─── Rutas del script y actualizaciones ────────────────
SCRIPT_PATH="${BASH_SOURCE[0]}"
if [[ "$SCRIPT_PATH" != /* ]]; then
    SCRIPT_PATH="$(cd "$(dirname "$SCRIPT_PATH")" 2>/dev/null && pwd)/$(basename "$SCRIPT_PATH")"
fi
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" 2>/dev/null && pwd)"
README_PATH="$SCRIPT_DIR/README.md"

UPDATE_AVAILABLE=""
UPDATE_STATE_FILE="$HOME/.cache/kyro_update"

UPDATE_URL="${UPDATE_URL:-https://raw.githubusercontent.com/mykosoftware/Kyro/main/Kyro.sh}"

# ─── Utilidades ────────────────────────────────────────
command_exists() { command -v "$1" >/dev/null 2>&1; }

require_commands() {
    local missing=() cmd
    for cmd in "$@"; do
        command_exists "$cmd" || missing+=("$cmd")
    done
    if (( ${#missing[@]} > 0 )); then
        echo -e "${RED}[ ERROR ]${RESET} Faltan dependencias: ${missing[*]}" >&2
        return 1
    fi
    return 0
}

pause() {
    read -rp $'\nPresiona ENTER para continuar...' _ || true
}

confirmar() {
    local pregunta="$1" respuesta
    [[ "$AUTO_SI" == "1" ]] && return 0
    read -rp "$pregunta [y/N] " respuesta || respuesta="n"
    [[ "${respuesta,,}" == "y" ]]
}

# ─── Sudo: autentica una sola vez y con aviso claro ───
# Evita que una operación falle a mitad de camino por falta de permisos.
check_sudo() {
    if [[ "$(id -u)" -eq 0 ]]; then
        return 0
    fi
    if ! command -v sudo >/dev/null 2>&1; then
        echo -e "${RED}[ ERROR ] sudo no está instalado. No se pueden aplicar cambios de sistema.${RESET}"
        return 1
    fi
    if ! sudo -n true 2>/dev/null; then
        echo -e "${YELLOW}Se necesita permisos de administrador.${RESET}"
        if ! sudo -v 2>/dev/null; then
            echo -e "${RED}[ ERROR ] No se pudo autenticar con sudo. Abortando.${RESET}"
            return 1
        fi
    fi
    return 0
}

# ─── Modo no interactivo ───────────────────────────────
# AUTO_SI=1 hace que confirmar() responda "sí" sin preguntar
# (solo lo usa el modo CLI con --yes). El valor por defecto es seguro.
AUTO_SI=0

# ─── Gestión de temporales/procesos ───────────────────
# Todos los temporales de Kyro viven en un directorio privado de ejecución.
# Esto evita fugas incluso cuando una función usa $(...).
KYRO_TMP_FILES=()
KYRO_BG_PIDS=()
KYRO_SPINNER_PIDS=()
KYRO_CLEANING=0
KYRO_TMP_DIR=$(command mktemp -d "${TMPDIR:-/tmp}/kyro.XXXXXXXX") || {
    echo "Kyro: no se pudo crear el directorio temporal." >&2
    exit 1
}

crear_temporal() {
    command mktemp "$KYRO_TMP_DIR/kyro.XXXXXXXX"
}

eliminar_temporal() {
    local f="$1"
    [[ -z "$f" ]] && return 0
    rm -f -- "$f" "$f.rc" 2>/dev/null || true
}

kill_tree() {
    local pid="$1" child
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    for child in $(pgrep -P "$pid" 2>/dev/null || true); do
        kill_tree "$child"
    done
    kill -TERM "$pid" 2>/dev/null || true
}

cleanup() {
    local rc="$?" f pid
    [[ "$KYRO_CLEANING" == "1" ]] && return "$rc"
    KYRO_CLEANING=1

    for pid in "${KYRO_BG_PIDS[@]:-}" "${KYRO_SPINNER_PIDS[@]:-}"; do
        [[ -n "$pid" && "$pid" != "$$" ]] || continue
        kill_tree "$pid"
        wait "$pid" 2>/dev/null || true
    done

    for f in "${KYRO_TMP_FILES[@]:-}"; do
        eliminar_temporal "$f"
    done
    rm -rf -- "$KYRO_TMP_DIR" 2>/dev/null || true

    restaurar_terminal
    return "$rc"
}
# ─── Seguridad de terminal ─────────────────────────────
# Si el usuario pulsa Ctrl+C restauramos el cursor (el panel en vivo lo
# oculta) y salimos limpiamente; evita continuar tras una interrupción.
restaurar_terminal() {
    [[ -t 1 ]] || return 0
    tput cnorm 2>/dev/null || true
    tput sgr0 2>/dev/null || true
    printf '\r\033[K' 2>/dev/null || true
}

# EXIT siempre pasa por cleanup; INT/TERM salen con código 130 y luego
# disparan EXIT, garantizando restauración de cursor, temporales y procesos.
trap 'exit 130' INT TERM
trap 'cleanup' EXIT

# ─── Rutas protegidas: jamás se eliminan ───────────────
# Wine, Proton y herramientas de compatibilidad (prefijos, prefixs de
# Steam/Lutris/Heroic/Bottles, etc.). La limpieza y el borrado por
# selección comprueban siempre esta lista antes de tocar algo.
PROTEGER_RUTAS=(
    "$HOME/.wine"
    "$HOME/.local/share/wineprefixes"
    "$HOME/.local/share/prefixes"
    "$HOME/.local/share/lutris"
    "$HOME/.local/share/heroic"
    "$HOME/.local/share/bottles"
    "$HOME/.local/share/Steam/steamapps/compatdata"
    "$HOME/.local/share/steam/steamapps/compatdata"
    "$HOME/.local/share/Steam/steamapps/common/Proton*"
    "$HOME/.local/share/steam/steamapps/common/Proton*"
    "$HOME/.var/app/net.lutris.Lutris"
    "$HOME/.var/app/com.usebottles.bottles"
    "$HOME/.var/app/com.valvesoftware.Steam"
    "$HOME/.var/app/com.heroicgameslauncher.hgl"
    "$HOME/GameHub"
)

# Uso: if ruta_protegida "$dir"; then ... no tocar ...; fi
ruta_protegida() {
    local r="$1" p pp rp m mm
    rp=$(readlink -f "$r" 2>/dev/null || echo "$r")
    for p in "${PROTEGER_RUTAS[@]}"; do
        [[ -n "$p" ]] || continue
        if [[ "$p" == *[\*\?\[]* ]]; then
            # Patrón con comodín (p. ej. ".../common/Proton*")
            for m in $p; do
                [[ -e "$m" ]] || continue
                mm=$(readlink -f "$m" 2>/dev/null || echo "$m")
                [[ "$rp" == "$mm" ]] && return 0
                [[ "$rp" == "$mm"/* ]] && return 0
            done
        else
            pp=$(readlink -f "$p" 2>/dev/null || echo "$p")
            [[ "$rp" == "$pp" ]] && return 0
            [[ "$rp" == "$pp"/* ]] && return 0
        fi
    done
    return 1
}

tamano_de() {
    local ruta="$1"
    if [[ -e "$ruta" ]]; then
        du -sb "$ruta" 2>/dev/null | awk '{print $1}'
    else
        echo 0
    fi
}

formatear_bytes() {
    local bytes="$1"
    numfmt --to=iec --suffix=B "$bytes" 2>/dev/null || echo "${bytes}B"
}

# Repite una cadena N veces.
repetir() {
    local char="$1" n="$2" i out=""
    for ((i = 0; i < n; i++)); do
        out+="$char"
    done
    printf '%s' "$out"
}

registrar_ultima_accion() {
    mkdir -p "$HOME/.cache" 2>/dev/null || true
    echo "$1|$(date '+%Y-%m-%d %H:%M:%S')" > "$STATE_FILE" 2>/dev/null || true
}

# ─── Barra de progreso con degradado de color ──────────
progress_bar() {
    local msg="$1"
    local dur="${2:-2}"
    local ancho=28
    local pasos=32
    local delay
    delay=$(awk -v d="$dur" -v p="$pasos" 'BEGIN{printf "%.5f", d/p}')

    for ((i = 1; i <= pasos; i++)); do
        local llenos=$((i * ancho / pasos))
        local vacios=$((ancho - llenos))
        local pct=$((i * 100 / pasos))
        local color="$CYAN"
        (( pct < 40 )) && color="$GREEN"
        (( pct >= 40 && pct < 70 )) && color="$YELLOW"
        (( pct >= 70 )) && color="$GREEN"
        printf "\r${BOLD}%s${RESET} [" "$msg"
        printf "${color}%s${RESET}" "$(repetir '█' "$llenos")"
        printf "${DIM}%s${RESET}" "$(repetir '░' "$vacios")"
        printf "] ${BOLD}%3d%%${RESET}" "$pct"
        sleep "$delay"
    done
    echo ""
}

# ─── Barra de pulso: animación indefinida con "luz" ─────
barra_pulso() {
    local msg="$1"
    local dur="${2:-1.5}"
    local ancho=26
    local pasos=14
    local delay
    delay=$(awk -v d="$dur" -v p="$pasos" 'BEGIN{printf "%.5f", d/p}')
    local dir=1 pos=0
    for ((t = 0; t < pasos * 2; t++)); do
        (( pos >= ancho - 1 )) && dir=-1
        (( pos <= 0 )) && dir=1
        local left="$pos" right=$((ancho - pos - 1)) k
        printf "\r${BOLD}%s${RESET} [${DIM}" "$msg"
        printf "%s" "$(repetir '░' "$pos")"
        printf "${ORANGE}█${RESET}"
        printf "${DIM}%s${RESET}]" "$(repetir '░' "$right")"
        pos=$((pos + dir))
        sleep "$delay"
    done
    echo ""
}

# Spinner con marcos alternativos.
spinner() {
    local msg="$1"; shift
    local style="${1:-braille}"
    # El primer parámetro tras el mensaje es estilo solo si coincide con uno.
    case "$style" in
        dots|barra|puntos|braille) shift ;;
        *) style="braille" ;;
    esac
    local -a frames=()
    case "$style" in
        dots)    frames=( '⠂' '⠁' '⠂' '⠄' ) ;;
        barra)   frames=( '▏' '▎' '▍' '▌' '▋' '▊' '▉' '▊' '▋' '▌' '▍' '▎' ) ;;
        puntos)  frames=( '●' '○' ) ;;
        *)       frames=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' ) ;;
    esac

    local tmp_out tmp_rc pid frame i=0 rc=0
    tmp_out=$(crear_temporal) || { echo -e "${RED}[ ERROR ]${RESET} No se pudo crear temporal para spinner."; return 1; }
    tmp_rc="${tmp_out}.rc"

    ( "$@" >"$tmp_out" 2>&1; rc=$?; printf '%s\n' "$rc" >"$tmp_rc" ) &
    pid=$!
    KYRO_SPINNER_PIDS+=("$pid")

    while kill -0 "$pid" 2>/dev/null; do
        frame="${frames[i % ${#frames[@]}]}"
        ((i++))
        printf "\r${MAGENTA}%s${RESET} %s " "$frame" "$msg"
        sleep 0.10
    done
    wait "$pid" 2>/dev/null || true
    local -a _remaining=() _p
    for _p in "${KYRO_SPINNER_PIDS[@]:-}"; do
        [[ "$_p" != "$pid" ]] && _remaining+=("$_p")
    done
    KYRO_SPINNER_PIDS=("${_remaining[@]:-}")

    [[ -s "$tmp_rc" ]] && rc=$(<"$tmp_rc")
    printf "\r\033[K"
    if [[ "$rc" -eq 0 ]]; then
        echo -e "${GREEN}[ OK ]${RESET} $msg"
    else
        echo -e "${RED}[ ERROR ]${RESET} $msg ${DIM}(código $rc)${RESET}"
    fi
    cat "$tmp_out" 2>/dev/null || true
    eliminar_temporal "$tmp_out"
    return "$rc"
}

# Barra de visual de porcentajes.
barra_pct() {
    local pct="$1"
    local ancho=20
    [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
    (( pct > 100 )) && pct=100
    local llenos=$((pct * ancho / 100))
    local vacios=$((ancho - llenos))
    local color="$GREEN"
    (( pct >= 60 )) && color="$YELLOW"
    (( pct >= 85 )) && color="$RED"
    printf "${color}%s${RESET}${DIM}%s${RESET} %3d%%" \
        "$(repetir '▮' "$llenos")" "$(repetir '▯' "$vacios")" "$pct"
}

# Calcula el % de uso de CPU entre dos lecturas de /proc/stat.
calcular_cpu_pct() {
    local linea_b="$1" linea_a="$2"
    local _ bu bn bs bi bio bir bso bst
    local au an as ai aio air aso ast
    read -r _ bu bn bs bi bio bir bso bst _ <<< "$linea_b"
    read -r _ au an as ai aio air aso ast _ <<< "$linea_a"
    bu=${bu:-0}; bn=${bn:-0}; bs=${bs:-0}; bi=${bi:-0}; bio=${bio:-0}; bir=${bir:-0}; bso=${bso:-0}; bst=${bst:-0}
    au=${au:-0}; an=${an:-0}; as=${as:-0}; ai=${ai:-0}; aio=${aio:-0}; air=${air:-0}; aso=${aso:-0}; ast=${ast:-0}
    local bidle=$((bi + bio))
    local aidle=$((ai + aio))
    local btotal=$((bu + bn + bs + bi + bio + bir + bso + bst))
    local atotal=$((au + an + as + ai + aio + air + aso + ast))
    local totald=$((atotal - btotal))
    local idled=$((aidle - bidle))
    local pct=0
    if (( totald > 0 )); then
        pct=$(( (100 * (totald - idled)) / totald ))
    fi
    echo "$pct"
}

# ─── Cabecera ─────────────────────────────────────────
header() {
    clear
    local GREEN="\e[1;32m" GRAY="\e[0;37m"
    echo ""

    # Arte ASCII: Taza en primer plano intercalada con KY y RO al fondo
    echo -e "${GREEN}  █   █  █   █${RESET}"
    echo -e "${GREEN}  █  █    █ █   ${GRAY}   (  (   ${RESET}"
    echo -e "${GREEN}  ███      █    ${GRAY}    )  )  ${RESET}"
    echo -e "${GREEN}  █  █     █    ${GRAY} .------------.  ${RESET}"
    echo -e "${GREEN}  █   █    █    ${GRAY}/              \____ ${RESET}"
    echo -e "${GREEN}               ${GRAY}|   .--------.   |   \ ${RESET}"
    echo -e "${GREEN}  ████   ████  ${GRAY}|  |          |  |    |${RESET}"
    echo -e "${GREEN}  █   █  █  █  ${GRAY}|  |          |  |___/ ${RESET}"
    echo -e "${GREEN}  ████   █  █  ${GRAY} \  \        /  /      ${RESET}"
    echo -e "${GREEN}  █  █   █  █  ${GRAY}  '------------'       ${RESET}"
    echo -e "${GREEN}  █   █  ████  ${GRAY}.----------------.     ${RESET}"

    echo -e "${CYAN}
        Kyro Optimizer v${VERSION}
        GPL-3.0 | Linux
${RESET}"
    if [[ -f "$STATE_FILE" ]]; then
        local ultima
        ultima=$(cat "$STATE_FILE" 2>/dev/null || true)
        if [[ -n "$ultima" ]]; then
            echo -e "${DIM}   Última acción: ${ultima/|/ - }${RESET}\n"
        fi
    fi
    if [[ -n "$UPDATE_AVAILABLE" ]]; then
        echo -e "${ORANGE}◈  ¡Nueva versión ${BOLD}${UPDATE_AVAILABLE}${RESET}${ORANGE} disponible!${RESET}"
        echo -e "${ORANGE}    Opción 26 del menú para actualizar.${RESET}\n"
    elif [[ -f "$UPDATE_STATE_FILE" ]]; then
        local update_pendiente
        update_pendiente=$(cat "$UPDATE_STATE_FILE" 2>/dev/null || true)
        [[ -n "$update_pendiente" ]] && UPDATE_AVAILABLE="$update_pendiente"
        if [[ -n "$UPDATE_AVAILABLE" ]]; then
            echo -e "${ORANGE}◈  ¡Nueva versión ${BOLD}${UPDATE_AVAILABLE}${RESET}${ORANGE} disponible!${RESET}"
            echo -e "${ORANGE}    Opción 26 del menú para actualizar.${RESET}\n"
        fi
    fi
}

# ─── Detección del gestor de paquetes ─────────────────
detectar_pkg_manager() {
    if command -v pacman >/dev/null; then
        echo "pacman"
    elif command -v apt >/dev/null; then
        echo "apt"
    elif command -v dnf >/dev/null; then
        echo "dnf"
    elif command -v zypper >/dev/null; then
        echo "zypper"
    elif command -v apk >/dev/null; then
        echo "apk"
    else
        echo "desconocido"
    fi
}

# ─── Detección de GPU (para gaming) ───────────────────
detectar_gpu_modelo() {
    command -v lspci >/dev/null 2>&1 || { echo ""; return; }
    lspci 2>/dev/null | grep -iE 'VGA compatible controller|3D controller' | head -1 | sed 's/^[0-9a-f:. ]*//'
}

detectar_gpu_vendor() {
    local linea
    linea=$(detectar_gpu_modelo)
    if echo "$linea" | grep -qi 'nvidia'; then echo "nvidia"
    elif echo "$linea" | grep -qiE 'amd|ati|radeon'; then echo "amd"
    elif echo "$linea" | grep -qi 'intel'; then echo "intel"
    else echo "desconocido"; fi
}

# ─── Resumen del sistema (ventanita) ──────────────────
system_box() {
    clear
    local kernel shell mem_used mem_total mem_pct mem_avail
    kernel=$(uname -r)
    shell=$(basename "${SHELL:-$0}")
    local pkgs="?"
    local user=${USER:-$(whoami)}
    local hostname=${HOSTNAME:-$(hostname)}
    local distro
    distro=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
    [[ -z "$distro" ]] && distro="Desconocida"
    local arch
    arch=$(uname -m)

    # CPU
    local cpu_model cores cpu_pct_1m
    cpu_model=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ *//')
    [[ -z "$cpu_model" ]] && cpu_model="Desconocido"
    cores=$(nproc 2>/dev/null || echo "?")
    local load1 load5 load15
    read -r load1 load5 load15 _ < /proc/loadavg 2>/dev/null
    load1=${load1:-0}; load5=${load5:-0}; load15=${load15:-0}

    # GPU
    local gpu
    gpu=$(detectar_gpu_modelo)
    [[ -z "$gpu" ]] && gpu="Desconocida"

    # Memoria
    read -r mem_total mem_used mem_avail mem_pct < <(free -m | awk '/^Mem:/ {printf "%s %s %s %d", $2, $3, $7, ($3/$2)*100}')
    [[ -z "$mem_avail" ]] && mem_avail=0

    # Swap
    local swap_total
    read -r swap_total _ <<< "$(info_swap)"

    # Disco (HOME y raíz)
    local disk_total disk_used disk_pct root_total root_used root_pct
    read -r disk_total disk_used disk_pct < <(df -h "$HOME" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $2, $3, $5}')
    read -r root_total root_used root_pct < <(df -h / 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $2, $3, $5}')

    # Uptime
    local uptime up_days up_hrs up_min
    uptime=$(uptime -p 2>/dev/null | sed 's/^up //')

    # Temperatura
    local tempv=0 tempc
    if command -v sensors >/dev/null 2>&1; then
        tempc=$(sensors 2>/dev/null | grep -m1 -oE '[0-9]+\.[0-9]+°C' | grep -oE '^[0-9]+' | head -1)
        [[ -n "$tempc" ]] && tempv=$tempc
    elif compgen -G "/sys/class/thermal/thermal_zone*/temp" >/dev/null; then
        local tz tv
        for tz in /sys/class/thermal/thermal_zone*/temp; do
            tv=$(cat "$tz" 2>/dev/null)
            (( tv > tempv )) && tempv=$((tv / 1000))
        done
    fi

    # Paquetes + gestor
    local pkg_manager
    pkg_manager=$(detectar_pkg_manager)
    case "$pkg_manager" in
        pacman) pkgs=$(pacman -Qq 2>/dev/null | wc -l) ;;
        apt)    pkgs=$(dpkg-query -f '${binary:Package}\n' -W 2>/dev/null | wc -l) ;;
        dnf)    pkgs=$(rpm -qa 2>/dev/null | wc -l) ;;
        zypper) pkgs=$(rpm -qa 2>/dev/null | wc -l) ;;
        apk)    pkgs=$(apk list --installed 2>/dev/null | wc -l) ;;
    esac

    # Escritorio / sesión
    local de terminal session
    de="${XDG_CURRENT_DESKTOP:-${DESKTOP_SESSION:-n/a}}"
    terminal="${TERM_PROGRAM:-${TERM:-}}"
    session="${XDG_SESSION_TYPE:-n/a}"

    # Red
    local ip wan
    ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | head -1 | cut -d/ -f1)
    [[ -z "$ip" ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$ip" ]] && ip="n/a"

    # Procesos
    local procs
    procs=$(ps -e --no-headers 2>/dev/null | wc -l)
    [[ -z "$procs" ]] && procs=0

    # Kernel errors 7 días
    local kerr
    kerr=$(journalctl -k -p err --since "-7 days" -o cat 2>/dev/null | grep -icE 'error|fail|critical|panic|oops' || true)

    # Última acción registrada
    local ultima
    ultima=$(cat "$STATE_FILE" 2>/dev/null | head -1 | cut -d'|' -f1)
    [[ -z "$ultima" ]] && ultima="—"

    # ─────────────────────── Render ───────────────────────
    local W=50
    local C="${CYAN}" G="${GREEN}" W2="${WHITE}" D="${DIM}" R="${RESET}"
    local SEP
    SEP=$(printf '%*s' "$W" | tr ' ' '═')
    local TOP_IZQ TOP_DER
    TOP_IZQ=$(printf '%*s' $(( W / 2 - 6 )) | tr ' ' '═')
    TOP_DER=$(printf '%*s' $(( W - 12 - (W / 2 - 6) )) | tr ' ' '═')

    echo -e "${C}${BOLD}╔${TOP_IZQ} KYRO SYSTEM ${TOP_DER}╗${R}"

    fila_sys() {
        local lbl="$1" val="$2"
        local ancho_lbl=${#lbl}
        local ancho_val=$(( W - ancho_lbl - 2 ))
        # Recorta valores largos para que nunca rompan la caja.
        if (( ${#val} > ancho_val )); then
            val="${val:0:$(( ancho_val - 3 ))}..."
        fi
        printf "${C}║${R}  ${C}%s${R}${W2}%-${ancho_val}s${R}${C}║${R}\n" "$lbl" "$val"
    }

    fila_sys "Distro"       "$distro"
    fila_sys "Kernel"       "$kernel"
    fila_sys "Arquitectura" "$arch"
    fila_sys "Escritorio"   "${de:-n/a}"
    fila_sys "Sesión"       "${session:-n/a}"
    fila_sys "Terminal"     "${terminal:-n/a}"

    echo -e "${C}╠${SEP}╣${R}"
    fila_sys "CPU"          "${cpu_model}  (${cores} núcleos)"
    fila_sys "Carga"        "$load1 / $load5 / $load15  (1m/5m/15m)"
    fila_sys "GPU"          "$gpu"

    echo -e "${C}╠${SEP}╣${R}"
    fila_sys "RAM total"    "${mem_total} MB   (uso ${mem_pct}%)"
    fila_sys "RAM en uso"   "${mem_used} MB"
    fila_sys "RAM libre"    "${mem_avail} MB"
    fila_sys "Swap"         "${swap_total} MB"

    echo -e "${C}╠${SEP}╣${R}"
    fila_sys "Disco HOME"   "$disk_used / $disk_total  (${disk_pct}%)"
    fila_sys "Disco raíz"   "$root_used / $root_total  (${root_pct}%)"
    fila_sys "Temperatura"  "${tempv:-0}°C"
    fila_sys "Procesos"     "$procs"
    fila_sys "Err. kernel"  "$kerr  (últ. 7 días)"

    echo -e "${C}╠${SEP}╣${R}"
    fila_sys "Gestor"       "${pkg_manager:-n/a}"
    fila_sys "Paquetes"     "$pkgs"
    fila_sys "Usuario"      "$user"
    fila_sys "Host"         "$hostname"
    fila_sys "IP LAN"       "${ip:-n/a}"

    echo -e "${C}╚${SEP}╝${R}"

    echo ""
    echo -e "   ${D}Uptime:${R} ${W2}${uptime}${R}   ${D}Última acción:${R} ${G}${ultima}${R}"
    echo ""

    # ── Barras de uso ──
    echo -e "   ${BOLD}Uso de RAM:${RESET}   $(barra_pct "${mem_pct:-0}")"
    echo -e "   ${BOLD}Uso de disco:${RESET} $(barra_pct "${disk_pct:-0}")  ${D}(${disk_used} / ${disk_total} en ${HOME})${R}"

    pause
}

# ═══════════════════════════════════════════════════════
#  FUNCIONES DE LIMPIEZA
# ═══════════════════════════════════════════════════════

# Elimina una ruta y devuelve el espacio realmente liberado (bytes).
# Mide el tamaño ANTES de borrar (con permisos de superusuario si el
# directorio pertenece a root) y reporta cuánto se pudo quitar. Esto evita
# el "0B" que ocurría al medir árboles completos con du que necesitaban root.
eliminar_y_medir() {
    local ruta="$1" mostrar="$2" antes=0 rc=0
    [[ -e "$ruta" ]] || { echo 0; return; }
    if [[ -d "$ruta" ]]; then
        antes=$(sudo -n du -sb "$ruta" 2>/dev/null || du -sb "$ruta" 2>/dev/null || echo 0)
        antes="${antes%%[[:space:]]*}"
        [[ "$antes" =~ ^[0-9]+$ ]] || antes=0
    else
        antes=$(stat -c %s "$ruta" 2>/dev/null || echo 0)
        [[ "$antes" =~ ^[0-9]+$ ]] || antes=0
    fi
    antes=${antes:-0}
    if [[ -d "$ruta" || -f "$ruta" ]]; then
        if [[ -w "$(dirname "$ruta")" ]]; then
            rm -rf "$ruta" 2>/dev/null && rc=0 || rc=1
        else
            sudo rm -rf "$ruta" 2>/dev/null && rc=0 || rc=1
        fi
        if [[ "${mostrar:-1}" == "1" ]]; then
            echo -e "   ${GREEN}[ OK ]${RESET} $(truncate_path "$ruta")  ${DIM}($(formatear_bytes "$antes"))${RESET}" >&2
        fi
    fi
    if [[ "$rc" -eq 0 ]]; then echo "$antes"; else echo 0; fi
}

cache() {
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}  🧹  Limpieza de caché todo-en-uno${RESET}"
    echo -e "${DIM}     Gestor oficial · AUR · Navegadores · Apps · Sistema${RESET}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${RESET}"
    echo ""
    local pkg liberado
    pkg=$(detectar_pkg_manager)
    liberado=0

    # ── 0) Permisos: la limpieza toca varias zonas de sistema ──
    if ! check_sudo; then
        pause
        return
    fi

    # ── 1) Caché del gestor de paquetes oficial ──
    # El sudo de cada comando es inocuo si ya eres root (ejecuta directo),
    # así que la limpieza corre tanto como root como con sudo elevado.
    case "$pkg" in
            pacman)
                if command -v paccache >/dev/null; then
                    spinner "Purga caché oficial (pacman)" sudo paccache -rk2
                else
                    echo -e "${RED}paccache no encontrado. Instala pacman-contrib.${RESET}"
                fi
                ;;
            apt)
                spinner "Limpiando caché oficial (apt)" sudo apt clean
                ;;
            dnf)
                spinner "Limpiando caché oficial (dnf)" sudo dnf clean all
                ;;
            zypper)
                spinner "Limpiando caché oficial (zypper)" sudo zypper clean -a
                ;;
            apk)
                spinner "Limpiando caché oficial (apk)" apk cache clean
                ;;
        esac

    # ── 2) Caché de AUR / asistentes ──
    local aur_dir=("$HOME/.cache/yay" "$HOME/.cache/paru" "$HOME/.cache/pamac" "$HOME/.cache/aur" "$HOME/.cache/aurs")
    for _d in "${aur_dir[@]}"; do
        [[ -d "$_d" ]] && liberado=$((liberado + $(eliminar_y_medir "$_d" 1)))
    done

    # ── 3) Cachés de navegadores ──
    local browsers=(
        "$HOME/.cache/google-chrome" "$HOME/.cache/chromium" "$HOME/.cache/chromium/Default/Cache"
        "$HOME/.cache/brave-browser" "$HOME/.cache/microsoft-edge" "$HOME/.cache/vivaldi"
        "$HOME/.cache/opera" "$HOME/.cache/opera-beta" "$HOME/.cache/mozilla/firefox"
        "$HOME/.cache/firefox" "$HOME/.cache/librewolf" "$HOME/.cache/torbrowser"
        "$HOME/.cache/zen" "$HOME/.cache/waterfox" "$HOME/.cache/falkon"
    )
    for _d in "${browsers[@]}"; do
        [[ -d "$_d" ]] && liberado=$((liberado + $(eliminar_y_medir "$_d" 1)))
    done

    # ── 4) Caché de AppImage ──
    local appimage_dir=(
        "$HOME/.cache/AppImage" "$HOME/.cache/appimages" "$HOME/.cache/AppImageLauncher"
        "$HOME/.local/share/appimagekit"
    )
    for _d in "${appimage_dir[@]}"; do
        [[ -d "$_d" ]] && liberado=$((liberado + $(eliminar_y_medir "$_d" 1)))
    done

    # ── 5) Miniaturas, fontconfig y cachés de bajo riesgo ──
    local sys_cache=(
        "$HOME/.cache/thumbnails" "$HOME/.cache/fontconfig" "$HOME/.cache/dconf"
        "$HOME/.cache/wallpaper" "$HOME/.cache/mesa_shader_cache" "$HOME/.cache/electron"
        "$HOME/.cache/menus" "$HOME/.cache/event-sound-catalog.tdb"
        "$HOME/.cache/node-gyp" "$HOME/.cache/go-build" "$HOME/.cache/gopls"
        "$HOME/.cache/rubocop_cache" "$HOME/.cache/rubygems" "$HOME/.cache/matplotlib"
        "$HOME/.cache/jupyter" "$HOME/.cache/mimeapps.list"
        "$HOME/.cache/speech-dispatcher" "$HOME/.cache/webkitgtk"
        "$HOME/.cache/gtk-3.0" "$HOME/.cache/icons"
    )
    for c in "${sys_cache[@]}"; do
        [[ -d "$c" || -f "$c" ]] && liberado=$((liberado + $(eliminar_y_medir "$c" 1)))
    done

    # ── 6) Cachés de lenguajes / dev ──
    local lang_cache=(
        "$HOME/.cache/pip" "$HOME/.cache/uv" "$HOME/.cache/pipx"
        "$HOME/.cache/composer" "$HOME/.cache/pypoetry" "$HOME/.cache/pipenv"
        "$HOME/.cache/poetry" "$HOME/.cache/deno" "$HOME/.cache/bun"
        "$HOME/.cache/yarn" "$HOME/.cache/pnpm" "$HOME/.npm/_cacache"
        "$HOME/.cache/rustls" "$HOME/.cache/mix" "$HOME/.cache/mypy_cache"
        "$HOME/.cache/huggingface" "$HOME/.cache/ms-playwright"
        "$HOME/.cache/parcel" "$HOME/.cache/hugo_cache" "$HOME/.cache/solana"
        "$HOME/.cargo/registry/cache"
    )
    for _d in "${lang_cache[@]}"; do
        [[ -d "$_d" ]] && liberado=$((liberado + $(eliminar_y_medir "$_d" 1)))
    done

    # ── 7) Cachés de apps de mensajería y escritorio ──
    local app_cache=(
        "$HOME/.cache/discord" "$HOME/.cache/slack" "$HOME/.cache/spotify"
        "$HOME/.cache/signal-desktop" "$HOME/.cache/Code" "$HOME/.cache/codium"
        "$HOME/.cache/gramps" "$HOME/.cache/Microsoft/clipit" "$HOME/.cache/JetBrains"
        "$HOME/.cache/google-chrome-unstable" "$HOME/.cache/telegram-desktop"
        "$HOME/.cache/zoom" "$HOME/.cache/teams" "$HOME/.cache/evolution"
        "$HOME/.cache/Thunderbird" "$HOME/.cache/obs-studio" "$HOME/.cache/qutebrowser"
    )
    for _d in "${app_cache[@]}"; do
        [[ -d "$_d" ]] && liberado=$((liberado + $(eliminar_y_medir "$_d" 1)))
    done

    # ── 8) Logs del sistema (vacuum) y núcleos de crash antiguos ──
    if command -v journalctl >/dev/null 2>&1; then
        spinner "Sistema: reduciendo logs a 7 días" sudo journalctl --vacuum-time=7d
    fi
    if [[ -d /var/lib/systemd/coredump ]]; then
        local core_old
        core_old=$(sudo find /var/lib/systemd/coredump -type f -mtime +7 2>/dev/null | wc -l)
        if (( core_old > 0 )); then
            if confirmar "¿Eliminar ${core_old} volcados de memoria (coredumps) de hace más de 7 días?"; then
                sudo find /var/lib/systemd/coredump -type f -mtime +7 -delete 2>/dev/null
                echo -e "   ${GREEN}[ OK ] Coredumps antiguos eliminados${RESET}"
            fi
        fi
    fi

    # ── 9) Caché de Flatpak (solo los directorios de caché de cada app) ──
    # Nunca se tocan los datos de las apps (databases/, config/, etc.),
    # únicamente el subdirectorio "cache" que cada Flatpak regenera solo.
    if command -v flatpak >/dev/null 2>&1; then
        local fp_caches fp_total fp=0
        mapfile -d $'\n' fp_caches < <(find "$HOME/.var/app" -maxdepth 2 -type d -name cache 2>/dev/null)
        fp_total=0
        for _c in "${fp_caches[@]:-}"; do
            _c=$(echo "$_c" | tr -d '\n')
            [[ -z "$_c" ]] && continue
            fp_total=$((fp_total + $(tamano_de "$_c")))
        done
        if (( fp_total > 0 )); then
            if confirmar "¿Vaciar la caché de las apps Flatpak ($(formatear_bytes "$fp_total"))?"; then
                for _c in "${fp_caches[@]:-}"; do
                    _c=$(echo "$_c" | tr -d '\n')
                    [[ -z "$_c" ]] || eliminar_y_medir "$_c" 0 >/dev/null
                done
                echo -e "   ${GREEN}[ OK ] Caché Flatpak vaciada${RESET}"
            fi
        fi
    fi

    # ── Reporte final (espacio real liberado, suma de cada elemento) ──
    echo ""
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${RESET}"
    echo -e "${GREEN}[ OK ]  Limpieza de caché completada${RESET}"
    echo -e "${DIM}   Espacio realmente liberado: ${BOLD}${WHITE}$(formatear_bytes "$liberado")${RESET}${DIM}${RESET}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${RESET}"
    registrar_ultima_accion "Limpieza de caché todo-en-uno ($(formatear_bytes "$liberado") liberados)"
    pause
}

paquetes_huerfanos() {
    echo -e "${YELLOW}Buscando paquetes huérfanos...${RESET}"
    local pkg
    pkg=$(detectar_pkg_manager)
    local orphans=""

    case "$pkg" in
        pacman)
            orphans=$(pacman -Qtdq 2>/dev/null || true)
            if [[ -n "$orphans" ]]; then
                echo "$orphans"
                echo -e "${DIM}Total: $(echo "$orphans" | wc -l) paquete(s)${RESET}"
                if confirmar "¿Eliminar estos paquetes?"; then
                    mapfile -t orphan_pkgs < <(printf '%s\n' "$orphans")
                    sudo pacman -Rns "${orphan_pkgs[@]}"
                    echo -e "${GREEN}[ OK ] Huérfanos eliminados${RESET}"
                    registrar_ultima_accion "Huérfanos eliminados (pacman)"
                fi
            else
                echo -e "${GREEN}[ OK ] No hay huérfanos${RESET}"
            fi
            ;;
        apt)
            orphans=$(apt-get -s autoremove 2>/dev/null | grep "^Remv" | awk '{print $2}' || true)
            if [[ -n "$orphans" ]]; then
                echo "$orphans"
                echo -e "${DIM}Total: $(echo "$orphans" | wc -l) paquete(s)${RESET}"
                if confirmar "¿Eliminar estos paquetes?"; then
                    sudo apt autoremove --purge -y
                    echo -e "${GREEN}[ OK ] Huérfanos eliminados${RESET}"
                    registrar_ultima_accion "Huérfanos eliminados (apt)"
                fi
            else
                echo -e "${GREEN}[ OK ] No hay huérfanos${RESET}"
            fi
            ;;
        dnf)
            orphans=$(dnf repoquery --extras 2>/dev/null || true)
            if [[ -n "$orphans" ]]; then
                echo "$orphans"
                if confirmar "¿Eliminar estos paquetes?"; then
                    sudo dnf autoremove -y
                    echo -e "${GREEN}[ OK ] Huérfanos eliminados${RESET}"
                    registrar_ultima_accion "Huérfanos eliminados (dnf)"
                fi
            else
                echo -e "${GREEN}[ OK ] No hay huérfanos${RESET}"
            fi
            ;;
        zypper)
            orphans=$(zypper packages --unneeded 2>/dev/null | awk 'NR>4 && /\bi\b/ {for(i=1;i<=NF;i++) if($i ~ /^.../) print $i}' | sort -u | head -80 || true)
            if [[ -n "$orphans" ]]; then
                echo "$orphans"
                echo -e "${DIM}Total: $(echo "$orphans" | wc -l) paquete(s)${RESET}"
                if confirmar "¿Eliminar estos paquetes?"; then
                    mapfile -t zypper_orphans < <(printf '%s\n' "$orphans" | awk 'NF {print $1}')
                    sudo zypper rm "${zypper_orphans[@]}"
                    echo -e "${GREEN}[ OK ] Huérfanos eliminados${RESET}"
                    registrar_ultima_accion "Huérfanos eliminados (zypper)"
                fi
            else
                echo -e "${GREEN}[ OK ] No hay huérfanos${RESET}"
            fi
            ;;
        *)
            echo -e "${RED}Gestión de huérfanos no disponible.${RESET}"
            ;;
    esac
    pause
}

logs() {
    echo -e "${YELLOW}Limpiando logs...${RESET}"
    if ! command -v journalctl >/dev/null; then
        echo -e "${RED}journalctl no disponible. No se limpiaron logs.${RESET}"
        pause
        return
    fi
    if ! check_sudo; then
        pause
        return
    fi
    local antes despues
    antes=$(sudo journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMG]' | head -1 || echo "0")
    # Rotar primero libera los archivos activos y suelta inodos.
    sudo journalctl --rotate 2>/dev/null || true
    spinner "Reduciendo logs a 7 días" sudo journalctl --vacuum-time=7d
    despues=$(sudo journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMG]' | head -1 || echo "0")
    echo -e "${GREEN}[ OK ] Logs del sistema reducidos (7 días)${RESET}"
    echo -e "${DIM}   Uso antes: ${antes}  →  Uso ahora: ${despues}${RESET}"
    if confirmar "¿Limitar también el journal a 300 MB en disco (evita crecimientos futuros)?"; then
        if ! grep -q '^SystemMaxUse' /etc/systemd/journald.conf 2>/dev/null; then
            echo -e "SystemMaxUse=300M\nSystemKeepFree=100M" | sudo tee -a /etc/systemd/journald.conf >/dev/null 2>&1
            sudo systemctl restart systemd-journald 2>/dev/null || sudo journalctl --flush 2>/dev/null
            echo -e "   ${GREEN}[ OK ] Journal limitado a 300 MB (persistente)${RESET}"
        else
            echo -e "   ${YELLOW}[ WARN ] El journal ya tiene un límite definido.${RESET}"
        fi
    fi
    registrar_ultima_accion "Logs reducidos a 7 días"
    pause
}

papelera() {
    local TRASH="$HOME/.local/share/Trash"
    if [[ -d "$TRASH" ]] && [[ -n "$(ls -A "$TRASH" 2>/dev/null)" ]]; then
        local tamano
        tamano=$(du -sh "$TRASH" 2>/dev/null | awk '{print $1}')
        echo -e "Tamaño actual de la papelera: ${BOLD}${tamano}${RESET}"
        if confirmar "¿Vaciar papelera?"; then
            progress_bar "Vaciando papelera" 1.5
            rm -rf "${TRASH:?}"/* "${TRASH:?}"/.[!.]* 2>/dev/null || true
            echo -e "${GREEN}[ OK ] Papelera vaciada${RESET} ${DIM}(${tamano} liberados)${RESET}"
            registrar_ultima_accion "Papelera vaciada (${tamano} liberados)"
        fi
    else
        echo -e "${YELLOW}La papelera está vacía o no existe.${RESET}"
    fi
    pause
}

# ═══════════════════════════════════════════════════════
#  FUNCIONES DE ANÁLISIS
# ═══════════════════════════════════════════════════════

# Modela una ruta para mostrar: sustituye $HOME por ~ (ahorra columna sin recortar).
truncate_path() {
    local path="$1"
    path="${path/$HOME/\~}"
    echo "$path"
}

# ¿La ruta contiene algún componente oculto (cat. ~/.config, ~/.local, ~/.mozilla)?
# Esas zonas guardan configuraciones y perfiles de aplicaciones (extensiones del
# navegador, escritorio, etc.) y NUNCA deben entrar en limpiezas de vacíos.
ruta_con_oculto() {
    [[ "$1" == *"/."* ]]
}

# 8) Buscar directorios vacíos en HOME.
# Seguridad: solo toca directorios vacíos en zonas VISIBLES (sin componentes
# ocultos). Los perfiles de navegador, .config, .local, .cache y Wine/Proton
# quedan siempre fuera del escaneo, aunque estén vacíos en ese momento.
directorios_vacios() {
    echo -e "${YELLOW}Analizando directorios vacíos en HOME...${RESET}"

    local tmpfile tmpfiltro
    tmpfile=$(crear_temporal)
    tmpfiltro=$(crear_temporal)
    spinner "Buscando directorios vacíos" bash -c "find \"$HOME\" -maxdepth 5 -type d -empty 2>/dev/null > \"$tmpfile\""
    # Nunca se tocarán directorios de Wine/Proton, rutas ocultas de
    # configuración y perfiles de aplicaciones/extensiones.
    local protegidos ocultos
    protegidos=0
    ocultos=0
    while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        if ruta_protegida "$dir"; then
            protegidos=$((protegidos + 1))
            continue
        fi
        if ruta_con_oculto "$dir"; then
            ocultos=$((ocultos + 1))
            continue
        fi
        echo "$dir" >> "$tmpfiltro"
    done < "$tmpfile"
    local total
    total=$(wc -l < "$tmpfiltro")

    if [[ "$total" -eq 0 ]]; then
        echo -e "       ${GREEN}[ OK ] No se encontraron directorios vacíos en zonas visibles.${RESET}"
        if (( protegidos > 0 || ocultos > 0 )); then
            echo -e "       ${YELLOW}[ WARN ] Se omitieron ${protegidos} protegido(s) (Wine/Proton) y ${ocultos} de configuración/perfiles.${RESET}"
        fi
    else
        printf "       ${YELLOW}📁 Directorios vacíos (zonas visibles): %3d${RESET}\n" "$total"
        if (( protegidos > 0 || ocultos > 0 )); then
            echo -e "       ${DIM}      (${protegidos} de compatibilidad y ${ocultos} de configuración/perfiles omitidos)${RESET}"
        fi
        printf "       ${YELLOW}   (mostrando todos)${RESET}\n"
        while IFS= read -r dir; do
            [[ -n "$dir" ]] || continue
            printf "       %s\n" "$(truncate_path "$dir")"
        done < "$tmpfiltro"
    fi

    if [[ "$total" -gt 0 ]]; then
        echo ""
        if confirmar "¿Deseas eliminar todos los directorios visibles listados arriba (${total})?"; then
            progress_bar "Eliminando directorios vacíos" 1.5
            local eliminados=0
            while IFS= read -r dir; do
                [[ -n "$dir" ]] || continue
                # Doble comprobación: nada de rutas protegidas ni ocultas.
                if ruta_protegida "$dir" || ruta_con_oculto "$dir"; then
                    continue
                fi
                if rmdir "$dir" 2>/dev/null; then
                    eliminados=$((eliminados + 1))
                fi
            done < "$tmpfiltro"
            echo -e "${GREEN}[ OK ] Se eliminaron ${eliminados} de ${total} directorios vacíos${RESET}"
            if (( protegidos > 0 || ocultos > 0 )); then
                echo -e "${YELLOW}   ${protegidos} de Wine/Proton y ${ocultos} de configuración/perfiles quedaron intactos.${RESET}"
            fi
            registrar_ultima_accion "Directorios vacíos eliminados (${eliminados})"
        else
            echo -e "${YELLOW}No se eliminó ningún directorio.${RESET}"
        fi
    fi

    rm -f "$tmpfile" "$tmpfiltro"
    pause
}

# ─━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Optimización de hardware VERSÁTIL
# ─━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Detecta el dispositivo base. Fallos de compatibilidad:
#   /dev/mapper/*, ZRAM overlay, btrfs/LVM, NVMe.
detectar_dispositivo_base() {
    local root_dev base_dev
    base_dev=$(findmnt -no SOURCE / 2>/dev/null | head -1)
    [[ -z "$base_dev" ]] && base_dev=$(df --output=source / 2>/dev/null | tail -1)

    # Resuelve dispositivos mapeados (/dev/mapper/*)
    if [[ "$base_dev" == /dev/mapper/* ]] && command -v lsblk >/dev/null; then
        base_dev=$(lsblk -no pkname "$base_dev" 2>/dev/null | head -1)
    fi

    # Extrae el dispositivo físico si aún hay capas (LVM/btrfs)
    if command -v lsblk >/dev/null; then
        local potential
        potential=$(lsblk -no pkname "$base_dev" 2>/dev/null | head -1)
        if [[ -n "$potential" ]]; then
            base_dev="$potential"
        fi
    fi

    # Normaliza NVMe / sdX
    if [[ "$base_dev" =~ (/dev/)?(sd|hd|vd|nvme[0-9]n[0-9]|mmcblk[0-9]+)[a-z0-9]*$ ]]; then
        base_dev="${BASH_REMATCH[2]}"
    else
        base_dev=$(basename "${base_dev}" 2>/dev/null | sed -E 's/p?[0-9]+$//')
        [[ "$base_dev" =~ ^(sd|hd|vd|nvme|mmcblk) ]] || base_dev=""
    fi
    [[ -z "$base_dev" ]] && base_dev="sda"
    echo "$base_dev"
}

# Información de swap: suma total (MB), si es zram, archivos de swap.
info_swap() {
    local total=0 i=0
    local file_list=""
    local zram_activo=0
    if [[ -f /proc/swaps ]]; then
        while IFS= read -r linea; do
            [[ "$linea" == Filename* ]] && continue
            local nombre tipo tam
            read -r nombre tipo tam _ <<< "$linea"
            [[ -z "$nombre" ]] && continue
            total=$((total + tam / 1024))
            if [[ "$tipo" == "file" ]]; then
                file_list="$file_list $nombre"
            fi
            if [[ "$nombre" == /dev/zram* ]]; then
                zram_activo=1
            fi
        done < /proc/swaps
    fi
    printf "%d %d %s" "$total" "$zram_activo" "$file_list"
}

# Tipo de sistema de archivos de un directorio.
tipo_fs_de() {
    local ruta="$1"
    findmnt -no FSTYPE -T "$ruta" 2>/dev/null | head -1
}

# Crea un archivo de swap de forma segura y compatible con múltiples
# sistemas de archivos y todas las variantes de CachyOS (btrfs es el
# predeterminado). En btrfs un swap requiere la bandera NOCOW (chattr +C),
# sin compresión; de lo contrario swapon falla con "Invalid argument".
# Uso: crear_archivo_swap <tamaño_mb> [ruta_fija]
crear_archivo_swap() {
    local tamano_mb="$1"
    local fuerza="${2:-}"
    local candidato r fs
    local rutas=("/swapfile_kyro" "/swap.kyro" "/var/swapfile_kyro" "/var/swap.kyro")

    if [[ -n "$fuerza" ]]; then
        candidato="$fuerza"
    else
        candidato="/swapfile_kyro"
        for r in "${rutas[@]}"; do
            if [[ ! -e "$r" ]] && [[ -d "$(dirname "$r")" ]]; then
                candidato="$r"
                break
            fi
        done
    fi

    fs=$(tipo_fs_de "$(dirname "$candidato")")
    [[ -z "$fs" ]] && fs="desconocida"

    # Si existe un archivo previo (posiblemente roto) se elimina para
    # reconstruirlo con las características correctas del sistema.
    if [[ -e "$candidato" ]]; then
        sudo rm -f "$candidato" 2>/dev/null
    fi

    echo -e "${DIM}   Creando ${tamano_mb} MB de swap en $candidato (fs: $fs)...${RESET}"

    local creado=1
    if [[ "$fs" == "btrfs" ]]; then
        # CachyOS usa btrfs por defecto. btrfs-progs ≥ 5.18 tiene
        # 'mkswapfile' que crea un archivo con NOCOW y sin compresión.
        if command -v btrfs >/dev/null 2>&1 && \
           sudo btrfs filesystem mkswapfile --size "${tamano_mb}M" "$candidato" >/dev/null 2>&1; then
            creado=0
        else
            # Respaldo manual: truncate + chattr +C (antes de escribir).
            sudo truncate -s 0 "$candidato" 2>/dev/null
            sudo chattr +C "$candidato" 2>/dev/null || true
            if sudo fallocate -l "${tamano_mb}M" "$candidato" 2>/dev/null || \
               sudo dd if=/dev/zero of="$candidato" bs=1M count="$tamano_mb" status=none 2>/dev/null; then
                creado=0
            fi
        fi
    else
        if sudo fallocate -l "${tamano_mb}M" "$candidato" 2>/dev/null || \
           sudo dd if=/dev/zero of="$candidato" bs=1M count="$tamano_mb" status=none 2>/dev/null; then
            creado=0
        fi
    fi

    local tam_real=0
    [[ -f "$candidato" ]] && tam_real=$(( $(stat -c %s "$candidato" 2>/dev/null || echo 0) / 1048576 ))
    if [[ "$creado" -ne 0 ]] || [[ ! -f "$candidato" ]] || (( tam_real < tamano_mb )); then
        echo -e "${RED}[ ERROR ] No se pudo crear el archivo de swap en $candidato${RESET}"
        sudo rm -f "$candidato" 2>/dev/null || true
        return 1
    fi

    sudo chmod 600 "$candidato"
    sudo mkswap "$candidato" >/dev/null 2>&1

    if sudo swapon "$candidato" 2>/dev/null; then
        if ! grep -qF "$candidato" /etc/fstab 2>/dev/null; then
            echo "$candidato none swap sw 0 0" | sudo tee -a /etc/fstab >/dev/null 2>&1 || true
        fi
        # Regenera la unidad de swap de systemd y la pone en marcha
        # (evita units rotas del tipo 'swapfile_kyro.swap').
        sudo systemctl daemon-reload >/dev/null 2>&1
        local unidad
        unidad=$(systemd-escape -p --suffix=swap "$candidato")
        sudo systemctl reset-failed "$unidad" >/dev/null 2>&1 || true
        sudo systemctl start "$unidad" >/dev/null 2>&1 || sudo swapon -a >/dev/null 2>&1
        echo -e "${GREEN}[ OK ] Swap creado y activado en $candidato (${tamano_mb} MB, $fs)${RESET}"
        registrar_ultima_accion "Swap ampliado +${tamano_mb} MB en $candidato"
        return 0
    else
        echo -e "${RED}[ ERROR ] swapon falló para $candidato (fs: $fs, compresión/COW activa?)${RESET}"
        return 1
    fi
}

optimizar_hardware() {
    clear
    echo -e "${CYAN}${BOLD}╭─ Optimizador de hardware ─────────────────────────────────────╮${RESET}"
    echo -e "${CYAN}│${RESET} Analizando CPU, RAM, almacenamiento, swap y salud...${CYAN}"
    echo -e "${CYAN}╰──────────────────────────────────────────────────────────────────╯${RESET}"

    # ── Perfil de uso: 4 perfiles con recomendaciones más precisas ──
    echo ""
    echo -e "${BOLD}¿Qué perfil prefieres para las recomendaciones?${RESET}"
    echo -e "${CYAN}  1)${RESET} ${BOLD}Máximo rendimiento${RESET}  ${DIM}(menor swappiness, más caché en RAM)${RESET}"
    echo -e "${CYAN}  2)${RESET} ${BOLD}Equilibrado (recomendado)${RESET} ${DIM}(buen rendimiento sin sacrificar estabilidad)${RESET}"
    echo -e "${CYAN}  3)${RESET} ${BOLD}Máxima estabilidad${RESET}    ${DIM}(menos riesgo, ajustes conservadores)${RESET}"
    echo -e "${CYAN}  4)${RESET} ${BOLD}Gaming (rendimiento puro)${RESET} ${DIM}(swap generoso, latencia mínima)${RESET}"
    local perfil
    read -rp "Elige [1/2/3/4] (por defecto: 2): " perfil || perfil="2"
    case "$perfil" in
        1) perfil="rendimiento" ;;
        3) perfil="estabilidad" ;;
        4) perfil="gaming" ;;
        *) perfil="equilibrado" ;;
    esac
    echo ""

    # ── Detección de disco (multiplataforma) ──
    local base_dev es_nvme=0 rotational tipo_disco
    base_dev=$(detectar_dispositivo_base)
    [[ "$base_dev" == nvme* ]] && es_nvme=1

    rotational="?"
    [[ -f "/sys/block/$base_dev/queue/rotational" ]] && rotational=$(cat "/sys/block/$base_dev/queue/rotational" 2>/dev/null)

    case "$rotational" in
        0) tipo_disco="SSD" ;;
        1) tipo_disco="HDD" ;;
        *) tipo_disco="Desconocido" ;;
    esac
    (( es_nvme == 1 )) && tipo_disco="SSD (NVMe)"

    # ── CPU ──
    local cpu_model nucleos
    cpu_model=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ *//')
    [[ -z "$cpu_model" ]] && cpu_model="Desconocido"
    nucleos=$(nproc 2>/dev/null || echo "?")

    # ── RAM ──
    local ram_mb ram_gb
    ram_mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    [[ -z "$ram_mb" ]] && ram_mb=0
    ram_gb=$(awk -v m="$ram_mb" 'BEGIN{printf "%.1f", m/1024}')

    # ── Portátil / batería ──
    local es_laptop="No"
    compgen -G "/sys/class/power_supply/BAT*" >/dev/null 2>&1 && es_laptop="Sí"

    # ── Governors disponibles y actuales ──
    local gobernadores=""
    local gov_ruta="/sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors"
    [[ -f "$gov_ruta" ]] && gobernadores=$(cat "$gov_ruta" 2>/dev/null)
    local governor_actual="N/D"
    [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]] && \
        governor_actual=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)

    # ── Schedulers disponibles ──
    local sched_actual="N/D" sched_disponibles=""
    if [[ -f "/sys/block/$base_dev/queue/scheduler" ]]; then
        sched_disponibles=$(cat "/sys/block/$base_dev/queue/scheduler" 2>/dev/null)
        sched_actual=$(echo "$sched_disponibles" | grep -oP '\[\K[^\]]+' 2>/dev/null)
        [[ -z "$sched_actual" ]] && sched_actual=$(echo "$sched_disponibles" | awk '{print $1}')
    fi

    # ── Información de swap ──
    read -r swap_total swap_zram swap_archivos <<< "$(info_swap)"
    swap_total=${swap_total:-0}
    swap_zram=${swap_zram:-0}

    # ── Errores del kernel (detección) ──
    local err_total=0
    local kernel_src=""
    if command -v journalctl >/dev/null 2>&1; then
        kernel_src=$(journalctl -k -p err --since "-7 days" -o cat 2>/dev/null | tail -120 || true)
    elif command -v dmesg >/dev/null 2>&1; then
        kernel_src=$(dmesg 2>/dev/null | tail -120 || true)
    fi
    if [[ -n "$kernel_src" ]]; then
        err_total=$(echo "$kernel_src" | grep -icE 'error|fail|critical|panic|oops|fault' || true)
    fi

    # ── Cálculo de recomendaciones ──
    # swap base por perfil:
    #   rendimiento: todo quepa (swap ≈ RAM hasta 16G)
    #   equilibrado/estabilidad: mitad de la RAM (≤ 16G)
    #   gaming: swap generoso — 12-14G en equipos de 8-16G (juegos pesados).
    local swap_rec swappiness_rec vcp_rec dirtybg_rec dirty_rec comp_rec pagecluster_rec max_map_rec
    local es_ssd=0
    [[ "$tipo_disco" == "SSD"* ]] && es_ssd=1

    if (( ram_mb <= 2048 )); then swap_rec=$((ram_mb * 2))
    elif (( ram_mb <= 4096 )); then
        [[ "$perfil" == "gaming" ]] && swap_rec=$((ram_mb * 2)) || swap_rec=$ram_mb
    elif (( ram_mb <= 8192 )); then
        if [[ "$perfil" == "gaming" ]]; then swap_rec=14336
        elif [[ "$perfil" == "rendimiento" ]]; then swap_rec=$ram_mb
        else swap_rec=$((ram_mb / 2)); fi
    elif (( ram_mb <= 16384 )); then
        if [[ "$perfil" == "gaming" ]]; then swap_rec=12288
        elif [[ "$perfil" == "rendimiento" ]]; then swap_rec=$ram_mb
        else swap_rec=$((ram_mb / 2)); fi
    else
        [[ "$perfil" == "gaming" ]] && swap_rec=8192 || swap_rec=4096
    fi
    # Con zram activa solo se reduce el swap a disco salvo en gaming
    # (los juegos pesados necesitan ese margen extra).
    if (( swap_zram == 1 )) && [[ "$perfil" != "gaming" ]]; then
        swap_rec=$((swap_rec / 2)); (( swap_rec < 512 )) && swap_rec=512
    fi

    # vm.swappiness según perfil, RAM y tipo de disco (HDD usa más swap).
    case "$perfil" in
        rendimiento)
            (( ram_mb >= 16384 )) && swappiness_rec=5
            (( ram_mb >= 8192 && ram_mb < 16384 )) && swappiness_rec=10
            (( ram_mb < 8192 )) && swappiness_rec=15
            ;;
        gaming)
            # rendimiento puro: apps y juegos permanecen en RAM.
            (( ram_mb >= 8192 )) && swappiness_rec=5
            (( ram_mb < 8192 )) && swappiness_rec=10
            ;;
        estabilidad)
            (( ram_mb >= 16384 )) && swappiness_rec=15
            (( ram_mb >= 8192 && ram_mb < 16384 )) && swappiness_rec=25
            (( ram_mb < 8192 )) && swappiness_rec=35
            ;;
        *)  # equilibrado
            (( ram_mb >= 16384 )) && swappiness_rec=10
            (( ram_mb >= 8192 && ram_mb < 16384 )) && swappiness_rec=20
            (( ram_mb < 8192 )) && swappiness_rec=30
            ;;
    esac
    [[ "$tipo_disco" == "HDD" ]] && swappiness_rec=$((swappiness_rec + 20))
    (( swappiness_rec > 60 )) && swappiness_rec=60
    (( swap_zram == 1 )) && swappiness_rec=100

    # Caché de inodos/entradas (más baja = se conserva más en RAM).
    case "$perfil" in
        rendimiento) vcp_rec=50 ;;
        gaming)      vcp_rec=25 ;;
        *)           vcp_rec=100 ;;
    esac

    # Escrituras diferidas (porcentaje de RAM antes de volcar a disco).
    case "$perfil" in
        rendimiento|gaming)
            if (( es_ssd == 1 )); then dirtybg_rec=3; dirty_rec=10; else dirtybg_rec=5; dirty_rec=15; fi ;;
        estabilidad) dirtybg_rec=10; dirty_rec=20 ;;
        *)           dirtybg_rec=5;  dirty_rec=15 ;;
    esac

    # Proactividad de compactación (menor = menos ciclos de CPU en RAM).
    case "$perfil" in
        rendimiento|gaming) comp_rec=0 ;;
        estabilidad) comp_rec=20 ;;
        *)           comp_rec=10 ;;
    esac

    # Page-cluster: 0 en SSD (menos lecturas de página en swap), 3 en HDD.
    if (( es_ssd == 1 )); then pagecluster_rec=0; else pagecluster_rec=3; fi

    # límite de mapas de memoria: los juegos (Vulkan/Proton) piden más de 1M;
    # el valor alto evita "out of memory: kill process" en cargas pesadas.
    if [[ "$perfil" == "gaming" ]]; then max_map_rec=2147483642
    elif [[ "$perfil" == "rendimiento" ]]; then max_map_rec=1048576
    else max_map_rec=0; fi

    local governor_rec
    if [[ "$perfil" == "gaming" ]]; then
        governor_rec="performance"
    elif [[ "$perfil" == "estabilidad" ]]; then
        governor_rec="powersave"
    elif [[ "$perfil" == "equilibrado" ]]; then
        if [[ "$es_laptop" == "Sí" ]]; then governor_rec="powersave"; else governor_rec="ondemand"; fi
    elif [[ "$es_laptop" == "Sí" ]]; then
        governor_rec="powersave"
    else
        governor_rec="performance"
    fi
    # Ajusta según disponibilidad real
    if [[ -n "$gobernadores" ]]; then
        if ! echo "$gobernadores" | tr ' ' '\n' | grep -qx "$governor_rec"; then
            # Elige el más próximo disponible (prefiere ondemand/performance)
            governor_rec=$(echo "$gobernadores" | tr ' ' '\n' | grep -E '^(performance|ondemand|schedutil|powersave)$' | head -1)
            [[ -z "$governor_rec" ]] && governor_rec=$(echo "$gobernadores" | awk '{print $1}')
        fi
    fi

    if (( es_nvme == 1 )); then
        sched_rec="none"
    elif [[ "$tipo_disco" == SSD* ]]; then
        sched_rec="mq-deadline"
    else
        sched_rec="bfq"
    fi
    if [[ -n "$sched_disponibles" ]]; then
        if ! echo "$sched_disponibles" | tr ' ' '\n' | sed 's/\[//g;s/\]//g' | grep -qx "$sched_rec"; then
            sched_rec=$(echo "$sched_disponibles" | tr ' ' '\n' | grep -E 'none|mq-deadline|kyber' | head -1)
            [[ -z "$sched_rec" ]] && sched_rec=$(echo "$sched_disponibles" | awk '{print $1}')
        fi
    fi

    # ── Mostrar detección ──
    echo ""
    echo -e "${CYAN}${BOLD}╭─ Hardware detectado ────────────────────────────────────────────╮${RESET}"
    local gpu_model
    gpu_model=$(detectar_gpu_modelo)
    echo -e "${CYAN}│${RESET} CPU:                        ${cpu_model} (${nucleos} núcleos)"
    echo -e "${CYAN}│${RESET} RAM:                        ${ram_gb} GiB (${ram_mb} MB)"
    [[ -n "$gpu_model" ]] && echo -e "${CYAN}│${RESET} GPU:                        ${gpu_model}"
    echo -e "${CYAN}│${RESET} Disco (/):                  /dev/${base_dev}  ->  ${tipo_disco}"
    echo -e "${CYAN}│${RESET} Portátil (batería):         ${es_laptop}"
    echo -e "${CYAN}│${RESET} Gobernador actual:          ${governor_actual}"
    echo -e "${CYAN}│${RESET} Gobernadores disponibles:   ${gobernadores:-N/D}"
    echo -e "${CYAN}│${RESET} Planificador E/S:           ${sched_actual}"
    echo -e "${CYAN}│${RESET} Swap total:                 ${swap_total} MB$( (( swap_zram == 1 )) && echo " (zram activo)" )"
    echo -e "${CYAN}╰──────────────────────────────────────────────────────────────────╯${RESET}"

    # ── Detección de errores de hardware ──
    # (Aquí son señales de alerta; el diagnóstico detallado es la opción 7)
    echo ""
    echo -e "${CYAN}${BOLD}╭─ Salud / errores de hardware ──────────────────────────────────╮${RESET}"
    if (( err_total > 0 )); then
        echo -e "${CYAN}│${RESET} ${ORANGE}◐${RESET} Se hallaron ${BOLD}${err_total}${RESET} evento(s) con aspecto de error en el kernel."
        echo -e "${CYAN}│${RESET} ${DIM}Pueden ser benignos; usa la opción 7 para clasificarlos.${RESET}"
    else
        echo -e "${CYAN}│${RESET} ${GREEN}[ OK ]${RESET} Sin errores críticos de hardware detectados recientemente."
    fi
    echo -e "${CYAN}╰──────────────────────────────────────────────────────────────────╯${RESET}"

    echo ""
    echo -e "${CYAN}${BOLD}╭─ Recomendaciones (perfil: ${BOLD}${perfil}${RESET}${CYAN}) ───────────────────────╮${RESET}"
    echo -e "${CYAN}│${RESET} Swap recomendado:              ${swap_rec} MB   (actual: ${swap_total} MB)"
    echo -e "${CYAN}│${RESET} vm.swappiness:                 ${swappiness_rec}"
    echo -e "${CYAN}│${RESET} vm.vfs_cache_pressure:         ${vcp_rec}"
    echo -e "${CYAN}│${RESET} dirty_ratio / background:      ${dirty_rec} / ${dirtybg_rec}"
    echo -e "${CYAN}│${RESET} vm.compaction_proactiveness:   ${comp_rec}"
    echo -e "${CYAN}│${RESET} vm.page-cluster:               ${pagecluster_rec}"
    if (( max_map_rec > 0 )); then
        echo -e "${CYAN}│${RESET} vm.max_map_count:              ${max_map_rec}"
    fi
    echo -e "${CYAN}│${RESET} Gobernador de CPU:             ${governor_rec}"
    echo -e "${CYAN}│${RESET} Planificador E/S:              ${sched_rec}"
    echo -e "${CYAN}╰──────────────────────────────────────────────────────────────────╯${RESET}"
    echo ""

    if ! confirmar "¿Deseas aplicar ahora los ajustes recomendados (se te preguntará uno por uno)?"; then
        echo -e "${YELLOW}No se aplicó ningún cambio.${RESET}"
        registrar_ultima_accion "Análisis de hardware (${tipo_disco}, ${ram_gb}GiB RAM, perfil ${perfil})"
        pause
        return
    fi

    # Aplicador interno: aplica el sysctl y guarda el par para persistir.
    local ajustes=()
    local clave_valor
    aplicar_hw_sysctl() {
        local cv="$1" sum=""
        if sudo sysctl -w "$cv" >/dev/null 2>&1; then
            ajustes+=("$cv")
            echo -e "   ${GREEN}[ OK ]${RESET} $cv"
            return 0
        fi
        echo -e "   ${YELLOW}[ WARN ]${RESET} $cv (no aplicable)"
        return 1
    }

    # ── Aplicar sysctls de memoria virtual ──
    echo ""
    echo -e "${BOLD}▸ Memoria virtual:${RESET}"
    if confirmar "  → ¿Aplicar vm.swappiness=${swappiness_rec}?"; then aplicar_hw_sysctl "vm.swappiness=$swappiness_rec"; fi
    if confirmar "  → ¿Aplicar vm.vfs_cache_pressure=${vcp_rec}?"; then aplicar_hw_sysctl "vm.vfs_cache_pressure=$vcp_rec"; fi
    if confirmar "  → ¿Aplicar dirty_ratio=${dirty_rec} / background=${dirtybg_rec}?"; then
        aplicar_hw_sysctl "vm.dirty_ratio=$dirty_rec"
        aplicar_hw_sysctl "vm.dirty_background_ratio=$dirtybg_rec"
    fi
    if confirmar "  → ¿Aplicar vm.compaction_proactiveness=${comp_rec}?"; then aplicar_hw_sysctl "vm.compaction_proactiveness=$comp_rec"; fi
    if confirmar "  → ¿Aplicar vm.page-cluster=${pagecluster_rec}?"; then aplicar_hw_sysctl "vm.page-cluster=$pagecluster_rec"; fi
    if (( max_map_rec > 0 )); then
        if confirmar "  → ¿Aplicar vm.max_map_count=${max_map_rec} (requerido por juegos)?"; then aplicar_hw_sysctl "vm.max_map_count=$max_map_rec"; fi
    fi
    if (( ${#ajustes[@]} > 0 )); then
        guardar_sysctls "99-kyro-optimizer.conf" "${ajustes[@]}"
    fi

    # ── Aplicar gobernador de CPU ──
    if [[ "$governor_actual" != "N/D" ]]; then
        if confirmar "  → ¿Aplicar gobernador de CPU '${governor_rec}'?"; then
            local ok=1
            for gpath in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
                [[ -f "$gpath" ]] || continue
                echo "$governor_rec" | sudo tee "$gpath" >/dev/null 2>&1 || ok=0
            done
            if [[ "$ok" -eq 1 ]]; then
                echo -e "${GREEN}[ OK ] Gobernador aplicado${RESET}"
            else
                echo -e "${YELLOW}[ WARN ] No se pudo aplicar en todos los núcleos${RESET}"
            fi
            if confirmar "    → ¿Persistir tras reiniciar con un servicio systemd?"; then
                persistir_optimizacion "$governor_rec" "$sched_rec" "$base_dev"
            fi
        fi
    else
        echo -e "${DIM}Este equipo no expone cpufreq; se omite el ajuste de gobernador.${RESET}"
    fi

    # ── Aplicar planificador de E/S ──
    if [[ -f "/sys/block/$base_dev/queue/scheduler" ]]; then
        if confirmar "  → ¿Aplicar planificador de E/S '${sched_rec}' a /dev/${base_dev}?"; then
            if echo "$sched_rec" | sudo tee "/sys/block/$base_dev/queue/scheduler" >/dev/null 2>&1; then
                echo -e "${GREEN}[ OK ] Planificador aplicado${RESET}"
            else
                echo -e "${RED}[ ERROR ] No se pudo aplicar ('${sched_rec}' puede no estar disponible en este disco)${RESET}"
            fi
        fi
    fi

    # ── Ampliar swap si hace falta ──
    if (( swap_rec > swap_total + 256 )); then
        local deficit=$((swap_rec - swap_total))
        echo ""
        echo -e "${YELLOW}Tu swap actual (${swap_total} MB) es menor al recomendado (${swap_rec} MB).${RESET}"
        if confirmar "  → ¿Crear un swap adicional de ${deficit} MB?"; then
            crear_archivo_swap "$deficit"
        fi
    elif (( swap_total > 0 )); then
        echo -e "${GREEN}[ OK ] Tu swap actual ya es adecuado para tu RAM${RESET}"
    fi

    registrar_ultima_accion "Optimización de hardware (${tipo_disco}, ${ram_gb} GiB RAM, perfil ${perfil})"
    pause
}

# Persistencia con systemd (gobernador + planificador; lo demás va en sysctl.d).
persistir_optimizacion() {
    local gov="$1" sched="$2" dev="$3"
    local bin="/usr/local/bin/kyro-perf-apply.sh"
    local svc="/etc/systemd/system/kyro-perf.service"
    echo -e "${DIM}Creando servicio persistente kyro-perf.service...${RESET}"
    if sudo tee "$bin" >/dev/null 2>&1 <<EOF
#!/bin/bash
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -w "\$g" ] && echo "$gov" > "\$g" 2>/dev/null
done
echo "$sched" > /sys/block/$dev/queue/scheduler 2>/dev/null || true
exit 0
EOF
        then :; else
        echo -e "${RED}No se pudo escribir el script persistente.${RESET}"
        return
    fi
    sudo chmod +x "$bin"
    sudo tee "$svc" >/dev/null <<EOF
[Unit]
Description=Ajustes de rendimiento Kyro
After=multi-user.target

[Service]
Type=oneshot
ExecStart=$bin

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload >/dev/null 2>&1
    sudo systemctl enable --now kyro-perf.service >/dev/null 2>&1 && \
        echo -e "${GREEN}[ OK ] Servicio kyro-perf activado y persistente en cada arranque${RESET}" || \
        echo -e "${YELLOW}[ WARN ] No se pudo activar el servicio (systemd no disponible?)${RESET}"
}

# ═══════════════════════════════════════════════════════
#  DIAGNÓSTICO DE ERRORES DE HARDWARE (SMART + kernel)
# ═══════════════════════════════════════════════════════
errores_hardware() {
    clear
    echo -e "${CYAN}${BOLD}╭─ Diagnóstico de hardware ────────────────────────────────────────╮${RESET}"
    echo -e "${CYAN}│${RESET} Revisando log del kernel, SMART y temperatura...${CYAN}"
    echo -e "${CYAN}╰──────────────────────────────────────────────────────────────────╯${RESET}"
    echo ""
    if ! check_sudo; then
        pause
        return
    fi

    # 1) Kernel / journalctl
    # Se guarda el log en crudo para poder distinguir señales reales del ruido
    # habitual (USB, ACPI, "pcie"...). Los términos genéricos NO son fallo.
    local kernel_raw="" kernel_src=""
    if command -v journalctl >/dev/null 2>&1; then
        kernel_raw=$(journalctl -k -o cat --no-pager --since "7 days ago" 2>/dev/null)
    elif command -v dmesg >/dev/null 2>&1; then
        kernel_raw=$(dmesg 2>/dev/null)
    fi
    kernel_src=$(printf '%s\n' "$kernel_raw" | grep -iE 'error|fail|critical|panic|oops|fault|thermal|nvme|pcie|usb' | tail -15 || true)
    echo -e "${BOLD}▸ Posibles eventos del kernel (últimos):${RESET}"
    echo -e "${DIM}   (pueden ser benignos; se clasifican más abajo)${RESET}"
    if [[ -n "$kernel_src" ]]; then
        echo "$kernel_src"
    else
        echo -e "   ${GREEN}[ OK ] No se encontraron eventos recientes del kernel.${RESET}"
    fi
    echo ""

    # 2) SMART de discos
    echo -e "${BOLD}▸ Estado SMART de los discos:${RESET}"
    if ! command -v smartctl >/dev/null; then
        echo -e "   ${YELLOW}smartmontools no instalado. Instálalo para activar SMART (smartctl).${RESET}"
    else
        local discos=()
        mapfile -d $'\n' discos < <(lsblk -dno NAME 2>/dev/null | grep -E '^(sd[a-z]|nvme[0-9]n[0-9]+)$')
        local marcador=0
        for d in "${discos[@]}"; do
            d=$(echo "$d" | tr -d '\n ')
            [[ -z "$d" ]] && continue
            local h t
            h=$(sudo smartctl -H /dev/"$d" 2>/dev/null | grep -iE 'overall|result' | head -1)
            t=$(sudo smartctl -A /dev/"$d" 2>/dev/null | awk '/Temperature_Celsius/{print $10; exit}')
            echo -n "      /dev/$d "
            if echo "$h" | grep -qi 'passed'; then
                printf "${GREEN}[ OK ] Sano${RESET}"
            elif echo "$h" | grep -qi 'failed'; then
                printf "${RED}[ ERROR ] FALLO detectado${RESET}"
            else
                printf "${YELLOW}sin datos SMART${RESET}"
            fi
            [[ -n "$t" ]] && echo -n " (${t} °C)"
            echo ""
            marcador=1
        done
        (( marcador == 0 )) && echo -e "   ${YELLOW}No hay discos SMART legibles.${RESET}"
    fi
    echo ""

    # 3) Errores de NVMe y de memoria (ECC/MCE): señales de mayor certeza.
    echo -e "${BOLD}▸ Errores NVMe y de memoria (ECC/MCE):${RESET}"
    local hay_nvme_err=0 hay_mem_err=0
    while IFS= read -r dev_name; do
        [[ -n "$dev_name" ]] || continue
        local entradas nerrors
        entradas=$(sudo smartctl -l error "/dev/$dev_name" 2>/dev/null | grep -i 'Error Information Log Entries' | grep -oE '[0-9]+' | head -1)
        [[ -z "$entradas" ]] && continue
        (( entradas > 0 )) && hay_nvme_err=1
        echo "      /dev/$dev_name: $entradas entrada(s) de error registrada(s)"
    done < <(lsblk -dno NAME 2>/dev/null | grep -E '^nvme[0-9]n[0-9]+$')
    local mce
    mce=$(journalctl -k --no-pager --since "7 days ago" 2>/dev/null | grep -icE 'machine check|mce:|uncorrected|Hardware Error|CE\b|UE\b' || true)
    if (( mce > 0 )); then
        hay_mem_err=1
        echo "      MCE / hardware: ${mce} evento(s); puede apuntar a RAM defectuosa (memtest86+)"
    fi
    if command -v edac-util >/dev/null 2>&1; then
        sudo edac-util --report 2>/dev/null | head -10
    fi
    if (( hay_nvme_err == 0 )) && (( hay_mem_err == 0 )); then
        echo -e "   ${GREEN}[ OK ] Sin errores NVMe ni de memoria detectados recientemente.${RESET}"
    fi
    echo ""

    # 4) Temperatura
    echo -e "${BOLD}▸ Temperatura del sistema:${RESET}"
    if command -v sensors >/dev/null; then
        local info
        info=$(sensors 2>/dev/null | grep -m5 -E 'Package id 0|Tctl|Composite|temp[1245]|CPU' )
        if [[ -n "$info" ]]; then
            echo "$info"
        else
            echo -e "   ${YELLOW}sensors no reporta datos.${RESET}"
        fi
    elif compgen -G "/sys/class/thermal/thermal_zone*/temp" >/dev/null; then
        for tz in /sys/class/thermal/thermal_zone*/temp; do
            local tipo=""
            tipo=$(cat "$(dirname "$tz")/type" 2>/dev/null)
            local valor
            valor=$(cat "$tz" 2>/dev/null)
            (( valor > 0 )) && echo "      ${tipo:-thermal_zone}: "$((valor / 1000))"°C"
        done
    else
        echo -e "   ${YELLOW}No hay sensores de temperatura disponibles.${RESET}"
    fi

    echo ""
    echo -e "${BOLD}▸ Conclusión:${RESET}"

    # Señales FUERTES = fallos reales de hardware (alta certeza).
    # Señales DÉBILES = términos genéricos que también aparecen en uso normal.
    local senales_fuertes="" senales_debiles=""
    senales_fuertes=$(printf '%s\n' "$kernel_raw" | grep -iE \
        'Hardware Error|Machine Check|MCE|uncorrectable|ECC.*error|panic:|Oops:|BUG:|kernel BUG|fatal|hotplug|I/O error|No such device|failed command|CE\b|UE\b' | head -8 || true)
    senales_debiles=$(printf '%s\n' "$kernel_raw" | grep -iE 'error|fail|critical|fault|thermal|nvme|pcie|usb' | head -8 || true)
    if (( hay_nvme_err == 1 || hay_mem_err == 1 )); then
        senales_fuertes="${senales_fuertes}"$'\n'"registros de error NVMe/MCE (ver sección 3)"
    fi

    # Estado de los discos (referencia cruzada): si algún disco ha fallado
    # en salud SMART, es señal fuerte.
    local smart_fallido=""
    if command -v smartctl >/dev/null 2>&1; then
        while IFS= read -r d; do
            [[ -n "$d" ]] || continue
            if sudo smartctl -H "/dev/$d" 2>/dev/null | grep -q 'FAILED'; then
                smart_fallido="/dev/$d"
                break
            fi
        done < <(lsblk -dno NAME 2>/dev/null | grep -E '^(sd[a-z]|nvme[0-9]n[0-9]+)$')
    fi

    if [[ -n "$senales_fuertes" ]] || [[ -n "$smart_fallido" ]]; then
        echo -e "   ${RED}[ WARN ] Hay señales de posible fallo de hardware.${RESET}"
        [[ -n "$smart_fallido" ]] && echo -e "      ${RED}S.M.A.R.T.: ${smart_fallido} reporta FALLO de salud.${RESET}"
        [[ -n "$senales_fuertes" ]] && echo -e "      ${DIM}Eventos:${RESET}" && printf '      %s\n' "$senales_fuertes"
        echo -e "   ${DIM}Si persisten, revisa RAM (memtest86+), alimentación y discos.${RESET}"
    elif [[ -n "$senales_debiles" ]]; then
        echo -e "   ${YELLOW}[ WARN ] Hay eventos con aspecto de error, pero pueden ser no problemáticos.${RESET}"
        echo -e "   ${YELLOW}No se puede asegurar con certeza que exista un fallo real.${RESET}"
        echo -e "   ${DIM}Para confirmar o descartar, haz un análisis a profundidad A.${RESET}"
        if confirmar "→ Realizar análisis a profundidad de los eventos detectados?"; then
            analizar_a_fondo_errores
        fi
    else
        echo -e "   ${GREEN}[ OK ] Sin señales de fallo de hardware.${RESET}"
    fi
    registrar_ultima_accion "Diagnóstico de errores de hardware"
    pause
}

# ─── Análisis a fondo de los eventos detectados ────────
# ayudta a confirmar/descartar si los eventos del kernel son un fallo real.
analizar_a_fondo_errores() {
    clear
    echo -e "${CYAN}${BOLD}╭─ Análisis a fondo ──────────────────────────────────────────────╮${RESET}"
    echo -e "${CYAN}│${RESET} Diagnóstico detallado de los eventos registrados.${CYAN}"
    echo -e "${CYAN}╰──────────────────────────────────────────────────────────────────╯${RESET}"
    echo ""

    echo -e "${BOLD}▸ Últimas 50 líneas del anillo del kernel:${RESET}"
    if command -v journalctl >/dev/null 2>&1; then
        journalctl -k --no-pager -n 50 2>/dev/null | tail -50 || true
    else
        dmesg 2>/dev/null | tail -50 || true
    fi
    echo ""

    echo -e "${BOLD}▸ Temperatura (zonas térmicas):${RESET}"
    if compgen -G "/sys/class/thermal/thermal_zone*/temp" >/dev/null; then
        for tz in /sys/class/thermal/thermal_zone*/temp; do
            local ttipo="" tval=""
            ttipo=$(cat "$(dirname "$tz")/type" 2>/dev/null)
            tval=$(cat "$tz" 2>/dev/null)
            (( tval > 0 )) && echo "      ${ttipo:-thermal_zone}: $((tval / 1000))°C"
        done
    else
        echo -e "   ${YELLOW}Sin zonas térmicas expuestas.${RESET}"
    fi
    echo ""

    echo -e "${BOLD}▸ Estado SMART detallado de cada disco:${RESET}"
    if command -v smartctl >/dev/null 2>&1; then
        local dsd=()
        mapfile -d $'\n' dsd < <(lsblk -dno NAME 2>/dev/null | grep -E '^(sd[a-z]|nvme[0-9]n[0-9]+)$')
        for d in "${dsd[@]}"; do
            d=$(echo "$d" | tr -d '\n ')
            [[ -n "$d" ]] || continue
            echo "  ── /dev/$d ──"
            sudo smartctl -A "/dev/$d" 2>/dev/null | grep -E 'Reallocated_Sector|Current_Pending|Offline_Unc|Temperature|UDMA_CRC|Raw_Read|Command_Timeout' || echo "    (sin atributos críticos)"
        done
    else
        echo -e "   ${YELLOW}smartmontools no instalado.${RESET}"
    fi
    echo ""

    echo -e "${BOLD}▸ Memoria y errores de MCE (si están disponibles):${RESET}"
    if [[ -d /sys/devices/system/memory ]]; then
        echo "  Log de MCE: $(journalctl -k --no-pager | grep -ci 'machine check' 2>/dev/null || echo 0) evento(s)"
    fi
    echo -e "${DIM}Si el análisis profundo confirma fallos, ejecuta memtest86+ una noche.${RESET}"
    echo ""
    registrar_ultima_accion "Análisis a fondo de errores de hardware"
    pause
}

# ─── Optimización rápida (un solo clic) ─────────────────

# Aplica un sysctl de forma segura y lo anota para persistirlo.
aplicar_sysctl() {
    local clave="$1" valor="$2"
    if sudo sysctl -w "$clave=$valor" >/dev/null 2>&1; then
        echo -e "   ${GREEN}[ OK ]${RESET} $clave = $valor"
        KYRO_SYSCTL+=("$clave=$valor")
        return 0
    fi
    echo -e "   ${YELLOW}[ WARN ]${RESET} $clave (no aplicable)"
    return 1
}

# Guarda una lista de "clave=valor" en /etc/sysctl.d (persistencia).
guardar_sysctls() {
    local archivo="$1"; shift
    local elem lista=""
    for elem in "$@"; do lista+="$elem"$'\n'; done
    if printf '%s' "$lista" | sudo tee "/etc/sysctl.d/$archivo" >/dev/null 2>&1; then
        echo -e "   ${GREEN}[ OK ] Guardado en /etc/sysctl.d/$archivo${RESET}"
        return 0
    fi
    echo -e "   ${YELLOW}[ WARN ] No se pudo guardar la persistencia.${RESET}"
    return 1
}

optimizacion_rapida() {
    clear
    echo -e "${CYAN}${BOLD}╭─ Optimización rápida ─────────────────────────────────────────────╮${RESET}"
    echo -e "${CYAN}│${RESET} Ajustes de rendimiento seguros aplicados de forma automática.${CYAN}"
    echo -e "${CYAN}╰──────────────────────────────────────────────────────────────────╯${RESET}"
    echo ""
    if ! confirmar "¿Deseas aplicar tweaks seguros ahora?"; then
        echo -e "${YELLOW}Cancelado.${RESET}"
        return
    fi
    echo ""
    KYRO_SYSCTL=()

    # ── Detección del entorno ──
    local ram_mb sw vcp dirty_bg dirty comp page_cluster sched_rec
    ram_mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    [[ -z "$ram_mb" ]] && ram_mb=0
    if (( ram_mb >= 16384 )); then sw=5; elif (( ram_mb >= 8192 )); then sw=10; else sw=30; fi

    local dev rotational tipo_disco="SSD"
    dev=$(detectar_dispositivo_base)
    rotational=$(cat "/sys/block/$dev/queue/rotational" 2>/dev/null || echo 0)
    if [[ "$dev" == nvme* ]]; then
        tipo_disco="SSD (NVMe)"; sched_rec="none"
    elif [[ "$rotational" == "0" ]]; then
        tipo_disco="SSD"; sched_rec="mq-deadline"
    else
        tipo_disco="HDD"; sched_rec="bfq"
    fi
    vcp=50
    if (( ram_mb >= 16384 )); then dirty_bg=3; dirty=10; else dirty_bg=5; dirty=15; fi
    comp=10
    if [[ "$tipo_disco" == "SSD" || "$tipo_disco" == "SSD (NVMe)" ]]; then page_cluster=0; else page_cluster=3; fi

    # ── Memoria virtual (sysctl) ──
    echo -e "${BOLD}▸ Memoria virtual (sysctl):${RESET}"
    aplicar_sysctl "vm.swappiness" "$sw"
    aplicar_sysctl "vm.vfs_cache_pressure" "$vcp"
    aplicar_sysctl "vm.dirty_background_ratio" "$dirty_bg"
    aplicar_sysctl "vm.dirty_ratio" "$dirty"
    aplicar_sysctl "vm.page-cluster" "$page_cluster"
    aplicar_sysctl "vm.compaction_proactiveness" "$comp"
    echo ""

    # ── Gobernador de CPU ──
    local gov="performance"
    compgen -G "/sys/class/power_supply/BAT*" >/dev/null 2>&1 && gov="powersave"
    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors ]]; then
        local avail
        avail=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null)
        if ! echo "$avail" | tr ' ' '\n' | grep -qx "$gov"; then
            gov=$(echo "$avail" | awk '{print $1}')
        fi
    fi
    echo -e "${BOLD}▸ Gobernador de CPU: ${gov}${RESET}"
    local govok=0
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [[ -f "$g" ]] && echo "$gov" | sudo tee "$g" >/dev/null 2>&1 && govok=1
    done
    [[ "$govok" -eq 1 ]] && echo -e "   ${GREEN}[ OK ]${RESET}" || echo -e "   ${YELLOW}[ WARN ] sin cpufreq (se omite)${RESET}"
    echo ""

    # ── Planificador E/S en todos los discos ──
    echo -e "${BOLD}▸ Planificador de E/S (${sched_rec}) en todos los discos:${RESET}"
    local sched_ok=0 q
    for q in /sys/block/*/queue/scheduler; do
        [[ -f "$q" ]] || continue
        if echo "$(cat "$q" 2>/dev/null)" | tr ' ' '\n' | sed 's/\[//;s/\]//' | grep -qx "$sched_rec"; then
            echo "$sched_rec" | sudo tee "$q" >/dev/null 2>&1 && sched_ok=1
        fi
    done
    [[ "$sched_ok" -eq 1 ]] && echo -e "   ${GREEN}[ OK ] aplicado${RESET}" || echo -e "   ${YELLOW}[ WARN ] sin discos ajustables${RESET}"
    echo ""

    # ── Persistencia ──
    echo -e "${BOLD}▸ Persistencia:${RESET}"
    if confirmar "  → ¿Guardar estos ajustes para que apliquen en cada arranque?"; then
        persistir_ajustes_rapidos "$gov" "$sched_rec"
    else
        echo -e "   ${DIM}Los cambios durarán hasta el próximo reinicio.${RESET}"
    fi

    registrar_ultima_accion "Optimización rápida ($tipo_disco, gov=$gov, swappiness=$sw)"
    echo ""
    echo -e "${GREEN}[ OK ] Optimización rápida finalizada${RESET}"
    pause
}

# Servicio systemd para persistir la optimización rápida entre reinicios.
persistir_ajustes_rapidos() {
    local gov="$1" sched="$2"
    local bin="/usr/local/bin/kyro-quick-apply.sh"
    local svc="/etc/systemd/system/kyro-quick.service"
    local tmpbin l
    tmpbin=$(crear_temporal)

    cat > "$tmpbin" <<EOF
#!/bin/bash
# Generado por Kyro (optimización rápida). No editar a mano.
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -w "\$g" ] && echo "$gov" > "\$g" 2>/dev/null
done
for q in /sys/block/*/queue/scheduler; do
    if grep -q "$sched" "\$q" 2>/dev/null; then
        [ -w "\$q" ] && echo "$sched" > "\$q" 2>/dev/null
    fi
done
exit 0
EOF
    for l in "${KYRO_SYSCTL[@]}"; do
        echo "sysctl -w \"$l\" >/dev/null 2>&1" >> "$tmpbin"
    done

    if sudo install -m 755 "$tmpbin" "$bin" >/dev/null 2>&1; then
        sudo tee "$svc" >/dev/null <<EOF
[Unit]
Description=Ajustes de rendimiento rápidos de Kyro
After=multi-user.target

[Service]
Type=oneshot
ExecStart=$bin

[Install]
WantedBy=multi-user.target
EOF
        sudo systemctl daemon-reload >/dev/null 2>&1
        if sudo systemctl enable --now kyro-quick.service >/dev/null 2>&1; then
            echo -e "   ${GREEN}[ OK ] Ajustes persistentes (kyro-quick.service)${RESET}"
        else
            echo -e "   ${YELLOW}[ WARN ] Script guardado, pero no se pudo activar el servicio.${RESET}"
        fi
        rm -f "$tmpbin"
        return 0
    fi
    rm -f "$tmpbin"
    echo -e "   ${RED}[ ERROR ] No se pudo escribir el script persistente (¿sudo?).${RESET}"
    return 1
}

# ─━━─ Panel en vivo ─────────────────────────────────
consumo() {
    tput civis 2>/dev/null || true
    local salir=false
    local primera=true

    while ! $salir; do
        local b a cpu_pct mem_pct temp_str ultima hora
        b=$(grep -m1 '^cpu ' /proc/stat 2>/dev/null)
        sleep 0.25
        a=$(grep -m1 '^cpu ' /proc/stat 2>/dev/null)
        cpu_pct=$(calcular_cpu_pct "$b" "$a")

        mem_pct=$(free -m 2>/dev/null | awk '/^Mem:/ {printf "%d", ($3/$2)*100}')

        if command -v sensors >/dev/null; then
            temp_str=$(sensors 2>/dev/null | grep -m1 -E "Package id 0|Tctl|Composite|CPU" | awk -F: '{print $2}' | xargs)
        elif compgen -G "/sys/class/thermal/thermal_zone*/temp" >/dev/null; then
            for tz in /sys/class/thermal/thermal_zone*/temp; do
                tt=$(cat "$tz" 2>/dev/null)
                (( tt > 0 )) && { temp_str="$((tt / 1000))°C"; break; }
            done
        fi
        [[ -z "${temp_str:-}" ]] && temp_str="N/D"

        ultima="Sin registrar todavía"
        if [[ -f "$STATE_FILE" ]]; then
            local raw
            raw=$(cat "$STATE_FILE" 2>/dev/null || true)
            [[ -n "$raw" ]] && ultima="${raw/|/ - }"
        fi
        hora=$(date '+%H:%M:%S')

        if $primera; then
            clear
            primera=false
        else
            tput cup 0 0 2>/dev/null || true
        fi

        echo -e "${CYAN}${BOLD}╭─ Panel en vivo ── ${hora} ─────────────────────────╮${RESET}\033[K"
        echo -e "${CYAN}│${RESET} CPU    $(barra_pct "${cpu_pct:-0}")\033[K"
        echo -e "${CYAN}│${RESET} RAM    $(barra_pct "${mem_pct:-0}")\033[K"
        echo -e "${CYAN}│${RESET} Temp   ${BOLD}${temp_str}${RESET}\033[K"
        echo -e "${CYAN}│${RESET} Última acción: ${ultima}\033[K"
        echo -e "${CYAN}╰──────────────────────────────────────────────────────╯${RESET}\033[K"
        echo -e "${DIM}Presiona 'q' y luego ENTER para salir...${RESET}\033[K"

        local tecla
        read -r -t 1 -n 1 tecla 2>/dev/null || tecla=""
        [[ "$tecla" == "q" ]] && salir=true
    done

    tput cnorm 2>/dev/null || true
}

monitor() {
    if command -v btop >/dev/null; then
        btop
    elif command -v htop >/dev/null; then
        htop
    else
        top
    fi
}

# ═══════════════════════════════════════════════════════
#  FUNCIONES EXTRAS
# ═══════════════════════════════════════════════════════

# 14) Cachés de aplicaciones (Flatpak, pip, npm, cargo, go...)
limpiar_caches_apps() {
    echo -e "${YELLOW}Limpiando cachés de aplicaciones...${RESET}"
    local dirs=(
        "$HOME/.cache/pip" "$HOME/.cache/uv" "$HOME/.cache/pipx"
        "$HOME/.npm" "$HOME/.cache/npm" "$HOME/.cache/yarn"
        "$HOME/.cache/pnpm" "$HOME/.cache/cargo" "$HOME/.cache/go-build"
        "$HOME/.cache/composer" "$HOME/.cache/ms-playwright"
        "$HOME/.cache/pypoetry" "$HOME/.cache/pipenv" "$HOME/.cache/poetry"
        "$HOME/.cache/deno" "$HOME/.cache/bun" "$HOME/.cache/electron"
        "$HOME/.cache/node-gyp" "$HOME/.cache/mesa_shader_cache"
        "$HOME/.cache/hugo_cache" "$HOME/.cache/parcel" "$HOME/.gradle/caches"
        "$HOME/.cache/rustls" "$HOME/.cache/mix" "$HOME/.cache/mypy_cache"
    )
    local antes=0 despues=0 d liberado=0
    for d in "${dirs[@]}"; do
        antes=$(( antes + $(tamano_de "$d") ))
    done

    if command -v flatpak >/dev/null 2>&1; then
        antes=$(( antes + $(tamano_de "$HOME/.var/app") ))
        if confirmar "¿Eliminar runtimes/paquetes Flatpak no utilizados?"; then
            spinner "Flatpak: limpiando lo no usado" flatpak uninstall --unused --assumeyes
        fi
        if confirmar "¿Vaciar caché de Flatpak?"; then
            rm -rf "$HOME/.var/app"/*/cache 2>/dev/null || true
        fi
        if confirmar "¿Reparar el almacén de Flatpak (flatpak repair --user)?"; then
            spinner "Flatpak: reparando almacén" flatpak repair --user
        fi
    fi
    if command -v pip3 >/dev/null 2>&1; then
        spinner "pip: vaciando caché" pip3 cache purge
    fi
    if command -v npm >/dev/null 2>&1; then
        spinner "npm: vaciando caché" npm cache clean --force --loglevel=error
    fi
    if command -v yarn >/dev/null 2>&1; then
        spinner "yarn: vaciando caché" yarn cache clean 2>/dev/null || true
    fi
    if command -v pnpm >/dev/null 2>&1; then
        spinner "pnpm: vaciando caché" pnpm store prune 2>/dev/null || true
    fi
    if command -v uv >/dev/null 2>&1; then
        spinner "uv: vaciando caché" uv cache clean
    fi
    if command -v poetry >/dev/null 2>&1; then
        spinner "poetry: vaciando caché" poetry cache clear --all . 2>/dev/null || true
    fi
    if command -v cargo >/dev/null 2>&1; then
        spinner "cargo: limpiando caché" cargo cache --autoclean 2>/dev/null || true
        rm -rf "$HOME/.cache/cargo/.fingerprint" 2>/dev/null || true
    fi
    if command -v go >/dev/null 2>&1; then
        spinner "Go: limpiando caché de build" go clean -cache 2>/dev/null || true
    fi
    if command -v gradle >/dev/null 2>&1; then
        spinner "gradle: podando caché" gradle --stop 2>/dev/null; rm -rf "$HOME/.gradle/wrapper/dists" 2>/dev/null || true
    fi
    if command -v docker >/dev/null 2>&1 && confirmar "¿Podar imágenes y caches de Docker (contenedores parados quedarán a salvo)? [y/N]" ; then
        sudo docker builder prune -f 2>/dev/null || true
        sudo docker image prune -f 2>/dev/null || true
    fi
    if command -v podman >/dev/null 2>&1; then
        # -a elimina imágenes sin usar; no borra contenedores activos.
        sudo podman system prune -af 2>/dev/null || true
    fi
    if command -v composer >/dev/null 2>&1; then
        rm -rf "$HOME/.cache/composer" 2>/dev/null || true
    fi

    for d in "${dirs[@]}"; do
        despues=$(( despues + $(tamano_de "$d") ))
    done
    despues=$(( despues + $(tamano_de "$HOME/.var/app") ))
    liberado=$(( antes - despues ))
    (( liberado < 0 )) && liberado=0
    echo -e "${GREEN}[ OK ] Cachés de aplicaciones limpias${RESET}  ${DIM}($(formatear_bytes "$liberado") liberados)${RESET}"
    registrar_ultima_accion "Limpieza de cachés de apps ($(formatear_bytes "$liberado"))"
    pause
}

# 15) Refrescar repositorios y mirrors (pacman/apt/dnf)
refrescar_repos() {
    echo -e "${YELLOW}Refrescando repositorios y mirrors...${RESET}"
    local pkg
    pkg=$(detectar_pkg_manager)
    case "$pkg" in
        pacman)
            if command -v cachyos-rate-mirrors >/dev/null 2>&1; then
                if confirmar "¿Optimizar mirrors con cachyos-rate-mirrors?"; then
                    spinner "Optimizando mirrors CachyOS" sudo cachyos-rate-mirrors
                fi
            elif command -v rate-mirrors >/dev/null 2>&1; then
                if confirmar "¿Optimizar mirrors de Arch primario?"; then
                    spinner "Optimizando mirrors Arch" sudo rate-mirrors --protocol http arch
                fi
            fi
            spinner "Refrescando índice de pacman" sudo pacman -Sy
            echo -e "${DIM}Aviso: tras reflejar, haz 'pacman -Su' completo antes de instalar paquetes (evita actualizaciones parciales).${RESET}"
            ;;
        apt)
            spinner "Actualizando listas de apt" sudo apt update
            ;;
        dnf)
            spinner "Generando caché de dnf" sudo dnf makecache
            ;;
        *)
            echo -e "${YELLOW}Gestor de paquetes no soportado.${RESET}"
            ;;
    esac
    echo -e "${GREEN}[ OK ] Repositorios sincronizados${RESET}"
    registrar_ultima_accion "Sincronización de repositorios"
    pause
}

# 16) Limpiar kernels antiguos (mantiene el actual protegido)
limpiar_kernels_viejos() {
    echo -e "${YELLOW}Analizando kernels instalados...${RESET}"
    local kpkg okg activo
    kpkg=$(pacman -Qq 2>/dev/null | grep -E '^(linux)' | grep -Ev 'firmware|api-headers' | sort)
    if [[ -z "$kpkg" ]]; then
        echo -e "${GREEN}[ OK ] No se detectaron paquetes de kernel.${RESET}"
        pause
        return 0
    fi
    echo "Paquetes de kernel detectados:"
    echo "$kpkg" | sed 's/^/   - /'
    okg=$(uname -r)
    # LC_ALL=C fuerza salida en inglés y se extrae el nombre del paquete
    # que contiene el módulo del kernel en ejecución.
    activo=$(LC_ALL=C pacman -Qo "/usr/lib/modules/$okg" 2>/dev/null | head -1 | sed 's/.*is owned by //; s/ [^ ]*$//')
    [[ -z "$activo" ]] && activo="desconocido"
    echo -e "${DIM}Kernel en ejecución: ${okg}${RESET}"
    echo -e "${RED}El paquete activo (${activo}) y los *-meta están protegidos.${RESET}"

    local sel p
    read -rp $'\nIngresa los paquetes a eliminar separados por comas (vacío = cancelar): ' sel
    [[ -z "$sel" ]] && { echo -e "${YELLOW}Cancelado.${RESET}"; pause; return 0; }
    local qarr=() quitar=()
    IFS=, read -ra qarr <<< "$sel"
    for p in "${qarr[@]}"; do
        p=$(echo "$p" | xargs)
        [[ -z "$p" ]] && continue
        if echo "$kpkg" | grep -qx "$p"; then
            if [[ "$p" == "$activo" ]] || [[ "$p" == *-meta ]]; then
                echo -e "${YELLOW}$p está protegido; no se eliminará.${RESET}"
            else
                quitar+=("$p")
            fi
        else
            echo -e "${YELLOW}$p no es un kernel instalado; omitido.${RESET}"
        fi
    done
    if (( ${#quitar[@]} == 0 )); then
        echo -e "${YELLOW}Nada que eliminar.${RESET}"
        pause
        return 0
    fi
    if confirmar "¿Eliminar ${quitar[*]}?"; then
        sudo pacman -Rns --noconfirm "${quitar[@]}"
        echo -e "${GREEN}[ OK ] Kernels eliminados. El cargador se regenera solo en el arranque.${RESET}"
        registrar_ultima_accion "Limpieza de kernels viejos (${#quitar[@]})"
    fi
    pause
}

# 17) Revisar archivos .pacnew / .pacsave en /etc
revisar_pacnew() {
    echo -e "${YELLOW}Buscando archivos .pacnew / .pacsave en /etc...${RESET}"
    local tmpfile
    tmpfile=$(crear_temporal)
    find /etc -type f \( -name '*.pacnew' -o -name '*.pacsave' \) 2>/dev/null | sort > "$tmpfile"
    local total
    total=$(wc -l < "$tmpfile" 2>/dev/null || echo 0)
    if [[ "$total" -eq 0 ]]; then
        echo -e "${GREEN}[ OK ] No hay archivos .pacnew ni .pacsave${RESET}"
    else
        echo -e "${YELLOW}[ WARN ] ${total} archivo(s) pendientes de revisar:${RESET}"
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            local sz fecha
            sz=$(du -h "$f" 2>/dev/null | awk '{print $1}')
            fecha=$(stat -c '%y' "$f" 2>/dev/null | cut -d' ' -f1)
            printf "   - %-45s  [%s, %s]\n" "$f" "$sz" "$fecha"
        done < "$tmpfile"
        echo ""

        local decidir_todos=0 aplicados=0 movidos=0 ignorados=0 f b opc salir=0
        while IFS= read -r f <&3; do
            [[ -z "$f" ]] && continue
            (( decidir_todos != 0 )) && salir=1 && break
            [[ "$salir" -eq 1 ]] && break

            if [[ "$f" == *.pacnew ]]; then
                b=${f%.pacnew}
                echo -e "${BOLD}── ${f}${RESET}  ${DIM}(es la nueva versión de ${b})${RESET}"
                while true; do
                    read -rp "   (v)er diff  (a)plicar  (i)gnorar  (t)odos  (s)alir: " opc || opc="s"
                    case "${opc,,}" in
                        v)
                            ver_diff_pacnew "$b" "$f"
                            ;;
                        a)
                            sudo cp -a "$b" "$b.pacsave" 2>/dev/null || true
                            sudo cp -a "$f" "$b" 2>/dev/null && echo -e "   ${GREEN}[ OK ] ${b} actualizado (backup: ${b}.pacsave)${RESET}"
                            aplicados=$((aplicados + 1))
                            break
                            ;;
                        i)
                            ignorados=$((ignorados + 1))
                            break
                            ;;
                        t)
                            decidir_todos=1
                            break
                            ;;
                        s|q)
                            salir=1
                            break
                            ;;
                    esac
                done
                if [[ "$decidir_todos" -eq 1 ]]; then
                    sudo cp -a "$b" "$b.pacsave" 2>/dev/null || true
                    sudo cp -a "$f" "$b" 2>/dev/null && echo -e "   ${GREEN}[ OK ] ${b} actualizado (todos)${RESET}"
                    aplicados=$((aplicados + 1))
                fi
            else
                # .pacsave: versión antigua guardada; ofrecemos ver/restaurar/ignorar.
                b=${f%.pacsave}
                echo -e "${BOLD}── ${f}${RESET}  ${DIM}(es una copia de seguridad antigua de ${b})${RESET}"
                while true; do
                    read -rp "   (v)er diff  (r)estaurar  (i)gnorar  (t)odos  (s)alir: " opc || opc="s"
                    case "${opc,,}" in
                        v)
                            ver_diff_pacnew "$f" "$b"
                            ;;
                        r)
                            sudo cp -a "$f" "$b" 2>/dev/null && echo -e "   ${GREEN}[ OK ] ${b} restaurado desde el backup${RESET}"
                            aplicados=$((aplicados + 1))
                            break
                            ;;
                        i)
                            ignorados=$((ignorados + 1))
                            break
                            ;;
                        t)
                            decidir_todos=1
                            break
                            ;;
                        s|q)
                            salir=1
                            break
                            ;;
                    esac
                done
                if [[ "$decidir_todos" -eq 1 ]]; then
                    sudo cp -a "$f" "$b" 2>/dev/null && echo -e "   ${GREEN}[ OK ] ${b} restaurado (todos)${RESET}"
                    aplicados=$((aplicados + 1))
                fi
            fi
        done 3< "$tmpfile"
        echo ""
        echo -e "${BOLD}Resumen:${RESET} ${aplicados} aplicado(s), ${ignorados} ignorado(s)"
        if (( decidir_todos == 1 )); then
            echo -e "${DIM}   (resto del archivo: decisión 'todos' detiene la lista)${RESET}"
        fi
        registrar_ultima_accion "Revisión de .pacnew/.pacsave (${aplicados} aplicados, ${ignorados} ignorados)"
    fi
    rm -f "$tmpfile"
    pause
}

# Muestra las diferencias entre dos archivos (pipe a less si está disponible).
ver_diff_pacnew() {
    local a="$1" b="$2" out
    if [[ -r "$a" ]] && [[ -r "$b" ]]; then
        if command -v colordiff >/dev/null 2>&1; then
            out=$(colordiff -u "$a" "$b" 2>/dev/null)
        else
            out=$(diff -u "$a" "$b" 2>/dev/null)
        fi
        if [[ -z "$out" ]]; then
            echo -e "   ${DIM}Sin diferencias entre ambos archivos.${RESET}"
            return 0
        fi
        if command -v less >/dev/null 2>&1; then
            printf '%s\n' "$out" | less -R
        else
            printf '%s\n' "$out"
        fi
    else
        echo -e "${YELLOW}   No se pudieron leer los archivos para comparar.${RESET}"
    fi
}

# 18) Diagnóstico de red y DNS
diagnostico_red() {
    echo -e "${YELLOW}Diagnóstico de red y DNS...${RESET}"
    local gw
    gw=$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')
    echo -e "${BOLD}▸ Puerta de enlace:${RESET} ${gw:-N/D}"

    if command -v resolvectl >/dev/null 2>&1; then
        echo -e "${BOLD}▸ Estado de DNS (resolved):${RESET}"
        resolvectl status 2>/dev/null | head -n 12 || true
        if confirmar "¿Vaciar caché de DNS?"; then
            sudo resolvectl flush-caches
            echo -e "${GREEN}[ OK ] Caché DNS vaciada${RESET}"
        fi
    fi
    if command -v nmcli >/dev/null 2>&1; then
        if nmcli -t -f RUNNING general 2>/dev/null | grep -q running; then
            echo -e "${GREEN}[ OK ] NetworkManager ejecutándose${RESET}"
        else
            echo -e "${YELLOW}NetworkManager no se está ejecutando.${RESET}"
        fi
        if confirmar "¿Reiniciar NetworkManager?"; then
            sudo systemctl restart NetworkManager
            echo -e "${GREEN}[ OK ] NetworkManager reiniciado${RESET}"
        fi
    fi
    if command -v ping >/dev/null 2>&1; then
        echo -e "${BOLD}▸ Conectividad (ping 1.1.1.1):${RESET}"
        ping -c 3 -W 2 1.1.1.1 2>&1 | tail -3 || true
    fi

    # ── TCP: control de congestión y qdisc activos ──
    echo -e "${BOLD}▸ TCP activo:${RESET}"
    echo -e "   ${DIM}Control de congestión:${RESET} $(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo "n/d")"
    echo -e "   ${DIM}Qdisc por defecto:${RESET}      $(cat /proc/sys/net/core/default_qdisc 2>/dev/null || echo "n/d")"
    local _if_act
    _if_act=$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')
    if [[ -n "$_if_act" ]] && [[ "$_if_act" != "lo" ]]; then
        if command -v tc >/dev/null 2>&1; then
            echo -e "   ${DIM}Qdisc activo (${_if_act}):${RESET} $(tc qdisc show dev "$_if_act" 2>/dev/null | head -1 || echo "n/d")"
        else
            echo -e "   ${DIM}Qdisc activo (${_if_act}):${RESET} n/d (iproute2 incompleto)"
        fi
    fi

    # ── Benchmark de resolución DNS ──
    echo -e "${BOLD}▸ Benchmark de DNS (tiempo medio de resolución):${RESET}"
    local dns_ok=0
    if command -v dig >/dev/null 2>&1; then
        local dnsr=("1.1.1.1" "8.8.8.8")
        for srv in "${dnsr[@]}"; do
            local t
            t=$(dig +time=2 +tries=1 @$srv kyro.example.test A +noall +comments 2>/dev/null | grep -m1 'Query time' | grep -oE '[0-9]+')
            [[ -n "$t" ]] && echo -e "   ${DIM}${srv}:${RESET} ${t} ms" && dns_ok=1
        done
    fi
    local sistema_time=""
    if command -v resolvectl >/dev/null 2>&1; then
        sistema_time=$(resolvectl query google.com 2>/dev/null | grep -oE '[0-9]+ ms' | head -1)
    fi
    [[ -n "$sistema_time" ]] && echo -e "   ${DIM}resolved (sistema):${RESET} ${sistema_time}" && dns_ok=1
    (( dns_ok == 0 )) && echo -e "   ${YELLOW}No se pudo medir (instala 'dnsutils' para dig).${RESET}"

    registrar_ultima_accion "Diagnóstico de red/DNS"
    pause
}

# ─── Verificación de integridad de paquetes ─────────────
# Detecta archivos corruptos/faltantes y ofrece reparación automática.
corrupcion() {
    echo -e "${YELLOW}Revisando integridad de paquetes...${RESET}"
    local pkg tmpfile disponible rc_verif
    pkg=$(detectar_pkg_manager)
    tmpfile=$(crear_temporal)
    disponible=1
    rc_verif=0

    # La verificación con pacman/debsums requiere permisos de sistema.
    if ! check_sudo; then
        rm -f "$tmpfile"
        pause
        return
    fi

    case "$pkg" in
        pacman)
            # Compatible con locales EN/ES: busca "N missing files" o
            # "N archivos no encontrados" con N > 0 y omite los "0".
            # Nota: pacman -Qk devuelve 1 ante warnings (permisos) o archivos
            # faltantes, así que el grep decide y NO el código de salida:
            # la verificación en sí sí se ejecutó correctamente (igual que
            # con debsums más abajo).
            spinner "Verificando integridad con pacman" bash -c \
                "sudo pacman -Qk 2>/dev/null > '$tmpfile'"
            rc_verif=0
            local problemas
            problemas=$(grep -E '[1-9][0-9]* (missing files|archivos no encontrados)' "$tmpfile" 2>/dev/null | head -c 1048576)
            echo -n "$problemas" > "$tmpfile"
            ;;
        apt)
            if command -v debsums >/dev/null; then
                # debsums -c devuelve 1 cuando detecta archivos corruptos
                # (por eso se fuerza rc_verif=0: la ejecución sí fue correcta).
                spinner "Verificando integridad con debsums" bash -c \
                    "sudo debsums -c 2>/dev/null > '$tmpfile'"
                rc_verif=0
            else
                echo -e "${RED}Instala 'debsums' para esta verificación.${RESET}"
                disponible=0
            fi
            ;;
        *)
            echo -e "${RED}Verificación no disponible para este gestor.${RESET}"
            disponible=0
            ;;
    esac

    if [[ "$disponible" -eq 1 ]] && (( rc_verif == 0 )); then
        local total
        # Cuenta líneas NO vacías: el archivo no termina en salto de línea
        # (echo -n), así que wc -l subestimaría por 1. grep -c imprime el
        # conteo aunque no haya coincidencias (y devuelve 1), por eso se
        # captura su salida y el fallback solo cubre un file inexistente.
        total=$(grep -c . "$tmpfile" 2>/dev/null)
        total=${total:-0}

        if [[ "$total" -eq 0 ]]; then
            echo -e "${GREEN}[ OK ] No se encontraron paquetes ni archivos corruptos${RESET}"
        else
            echo -e "${YELLOW}[ WARN ] Se encontraron ${total} paquete(s)/archivo(s) con problemas de integridad${RESET}"
            if confirmar "¿Ver el detalle?"; then
                echo ""
                cat "$tmpfile"
                echo ""
            fi
            reparar_paquetes_danados "$pkg" "$tmpfile"
        fi
        registrar_ultima_accion "Verificación de integridad (${total} problema(s))"
    elif (( rc_verif != 0 )); then
        echo -e "${YELLOW}[ WARN ] No se pudo completar la verificación (faltan permisos sudo o el gestor falla).${RESET}"
    fi

    rm -f "$tmpfile"
    pause
}

# Reinstala los paquetes con archivos faltantes/corruptos y re-verifica.
reparar_paquetes_danados() {
    local pkg="$1" tmp="$2"
    local -a paquetes=()
    case "$pkg" in
        pacman)
            mapfile -t paquetes < <(cut -d: -f1 "$tmp" | sort -u)
            ;;
        apt)
            # debsums -c devuelve rutas; se mapean a su paquete con dpkg -S.
            mapfile -t paquetes < <(while IFS= read -r f; do
                        [[ -z "$f" ]] && continue
                        [[ "$f" != /* ]] && f="/$f"
                        dpkg -S "$f" 2>/dev/null | cut -d: -f1
                    done < "$tmp" | sort -u)
            ;;
    esac

    if (( ${#paquetes[@]} == 0 )); then
        echo -e "${YELLOW}No se pudieron identificar los paquetes; reinstálalos manualmente.${RESET}"
        return 0
    fi

    echo ""
    echo -e "${YELLOW}Paquetes a reparar:${RESET}"
    printf '   - %s\n' "${paquetes[@]}"
    if confirmar "¿Reinstalar automáticamente estos paquetes para repararlos?"; then
        local ok=1
        case "$pkg" in
            pacman)
                spinner "Reinstalando paquetes (pacman)" sudo pacman -S --noconfirm "${paquetes[@]}" || ok=0
                ;;
            apt)
                spinner "Reinstalando paquetes (apt)" sudo apt-get -y install --reinstall "${paquetes[@]}" || ok=0
                ;;
        esac
        if [[ "$ok" -eq 1 ]]; then
            echo -e "${GREEN}[ OK ] Reparación completada${RESET}"
        else
            echo -e "${RED}[ ERROR ] La reparación terminó con errores; revisa los mensajes de arriba.${RESET}"
        fi

        # Re-verificación después de reparar.
        local tmp2 restantes
        tmp2=$(crear_temporal)
        case "$pkg" in
            pacman)
                sudo pacman -Qk 2>/dev/null | grep -E '[1-9][0-9]* (missing files|archivos no encontrados)' > "$tmp2"
                ;;
            apt)
                sudo debsums -c 2>/dev/null > "$tmp2"
                ;;
        esac
        restantes=$(wc -l < "$tmp2" 2>/dev/null || echo 0)
        if (( restantes > 0 )); then
            echo -e "${YELLOW}[ WARN ] Quedan ${restantes} problema(s) sin resolver.${RESET}"
        else
            echo -e "${GREEN}[ OK ] Re-verificación sin errores. Todo correcto.${RESET}"
        fi
        rm -f "$tmp2"
    fi
}

# ─── Buscar archivos grandes (> 1 GB) y liberar espacio ──
# Envía a la papelera (o borra, si se confirma) los archivos y carpetas
# elegidos, sin tocar jamás las rutas protegidas (Wine/Proton, etc.).
mover_a_papelera() {
    local ruta="$1" files destino base i=1
    if command -v gio >/dev/null 2>&1; then
        if gio trash "$ruta" 2>/dev/null; then
            return 0
        fi
    fi
    files="$HOME/.local/share/Trash/files"
    mkdir -p "$files" 2>/dev/null || return 1
    base=$(basename "$ruta")
    destino="$files/$base"
    while [[ -e "$destino" ]]; do
        destino="$files/${base}_${i}"
        i=$((i + 1))
    done
    if mv -f "$ruta" "$destino" 2>/dev/null; then
        return 0
    fi
    return 1
}

archivos_grandes() {
    clear
    echo -e "${CYAN}${BOLD}╭─ Archivos y carpetas grandes (>1 GB) ────────────────────────────╮${RESET}"
    echo -e "${CYAN}│${RESET} Puedes enviar a la papelera lo que ya no uses.${CYAN}"
    echo -e "${CYAN}╰──────────────────────────────────────────────────────────────────╯${RESET}"
    echo ""

    local tmp ddir rutas=() n=0 sel
    tmp=$(crear_temporal)
    ddir=$(crear_temporal)

    # 1) Archivos > 1 GB (con tamaño en bytes), excluye la papelera.
    spinner "Buscando archivos > 1 GB" bash -c \
        "find \"$HOME\" -maxdepth 6 -type f -size +1G \
           -not -path '*/Trash/*' -not -path '*/.local/share/Trash/*' \
           -exec stat -c '%s %n' {} \; 2>/dev/null > \"$tmp\""

    # 2) Carpetas de gran tamaño (hasta profundidad 3), excl. papelera y protegidas.
    local dir bytes
    while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        case "$dir" in
            "$HOME"|"$HOME/."*|*/Trash*/) continue ;;
        esac
        ruta_protegida "$dir" && continue
        bytes=$(du -sb "$dir" 2>/dev/null | awk '{print $1}')
        if [[ -n "$bytes" ]] && (( bytes > 1073741824 )); then
            echo "$bytes $dir" >> "$ddir"
        fi
    done < <(find "$HOME" -maxdepth 2 -mindepth 1 -type d 2>/dev/null | sort)
    sort -k1,1nr "$ddir" | head -20 >> "$tmp"
    sort -k1,1nr "$tmp" -o "$tmp"

    if [[ ! -s "$tmp" ]]; then
        echo -e "${GREEN}[ OK ] No se encontraron archivos ni carpetas mayores a 1 GB${RESET}"
        rm -f "$tmp" "$ddir"
        pause
        return
    fi

    local line ruta tipo protegida
    while IFS= read -r line; do
        read -r bytes ruta <<< "$line"
        [[ -n "$ruta" ]] || continue
        protegida=""
        ruta_protegida "$ruta" && protegida="${YELLOW} [protegido]${RESET}"
        if [[ -d "$ruta" ]]; then tipo="carpeta"; else tipo="archivo"; fi
        n=$((n + 1))
        rutas+=("$ruta")
        printf "  ${CYAN}%2d)${RESET} ${DIM}%-8s${RESET} %9s  %s%s\n" \
            "$n" "$tipo" "$(formatear_bytes "$bytes")" "$(truncate_path "$ruta")" "$protegida"
    done < "$tmp"

    echo ""
    read -rp $'Números a ENVIAR A LA PAPELERA (p.ej. "1 4") o Enter para salir: ' sel || sel=""
    if [[ -z "$sel" ]]; then
        echo -e "${YELLOW}No se modificó nada.${RESET}"
        rm -f "$tmp" "$ddir"
        pause
        return
    fi

    local idx
    for idx in $sel; do
        [[ "$idx" =~ ^[0-9]+$ ]] || { echo -e "${YELLOW}  '${idx}' no es un número válido.${RESET}"; continue; }
        (( idx >= 1 && idx <= n )) || { echo -e "${YELLOW}  ${idx} fuera de rango.${RESET}"; continue; }
        ruta=${rutas[$((idx - 1))]}
        [[ -e "$ruta" ]] || { echo -e "${YELLOW}  Ya no existe: $(truncate_path "$ruta")${RESET}"; continue; }
        if ruta_protegida "$ruta"; then
            echo -e "${RED}[ ERROR ] No se puede tocar (protegido): $(truncate_path "$ruta")${RESET}"
            continue
        fi
        echo ""
        echo -e "  ${BOLD}Seleccionado [${idx}]:${RESET} $(truncate_path "$ruta")"
        if confirmar "  → ¿Enviar a la papelera?"; then
            if mover_a_papelera "$ruta"; then
                echo -e "  ${GREEN}[ OK ] Enviado a la papelera: $(truncate_path "$ruta")${RESET}"
            else
                echo -e "  ${RED}[ ERROR ] Falló al mover. ¿Borrar definitivamente?${RESET}"
                if confirmar "    → ¿Borrar permanentemente $(truncate_path "$ruta")?"; then
                    rm -rf "$ruta" 2>/dev/null && echo -e "  ${GREEN}[ OK ] Eliminado definitivamente${RESET}" || echo -e "  ${RED}[ ERROR ] No se pudo eliminar (permisos)${RESET}"
                fi
            fi
        else
            echo -e "  ${YELLOW}  Omitido.${RESET}"
        fi
    done
    registrar_ultima_accion "Limpieza de archivos grandes (selección manual)"
    rm -f "$tmp" "$ddir"
    pause
}

# ─── Servicios systemd fallidos ────────────────────────
# Si un unit de swap falla (p. ej. swapfile_kyro.swap), se reconstruye
# el archivo de swap automáticamente y se reinicia el unit.
servicios_fallidos() {
    echo -e "${YELLOW}Revisando servicios systemd fallidos...${RESET}"
    if ! command -v systemctl >/dev/null; then
        echo -e "${RED}systemctl no está disponible en este sistema.${RESET}"
        pause
        return
    fi

    local tmpfile
    tmpfile=$(crear_temporal)
    systemctl --failed --no-legend --plain > "$tmpfile" 2>/dev/null

    local total
    total=$(wc -l < "$tmpfile")

    if [[ "$total" -eq 0 ]]; then
        echo -e "${GREEN}[ OK ] No hay servicios fallidos${RESET}"
    else
        echo -e "${YELLOW}[ WARN ] ${total} servicio(s) con fallos:${RESET}"
        awk '{print "   - " $1}' "$tmpfile"
        if confirmar "¿Intentar reiniciar estos servicios?"; then
            if ! check_sudo; then
                rm -f "$tmpfile"
                pause
                return
            fi
            local ok=0 fail=0 reparados=0
            local linea unidad
            while IFS= read -r linea <&3; do
                unidad=$(echo "$linea" | awk '{print $1}')
                [[ -z "$unidad" ]] && continue
                if sudo systemctl restart "$unidad" 2>/dev/null; then
                    echo -e "${GREEN}[ OK ] ${unidad} reiniciado${RESET}"
                    ok=$((ok + 1))
                else
                    # Reparación automática de swaps rotos (típico en btrfs).
                    if [[ "$unidad" == *.swap ]]; then
                        local src mb reparado=0 ram_mb rec_mb
                        src=$(systemctl show -p What --value "$unidad" 2>/dev/null)
                        # Si systemd no reporta la ruta, se infiere del nombre
                        # de la unidad (swapfile_kyro.swap -> /swapfile_kyro).
                        if [[ -z "$src" ]]; then
                            src=$(systemd-escape -p --unescape "${unidad%.swap}" 2>/dev/null)
                            [[ -e "$src" ]] || src="/swapfile_kyro"
                        fi
                        # Tamaño objetivo basado en la RAM (mín. 1 GB).
                        ram_mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
                        [[ -z "$ram_mb" ]] && ram_mb=4096
                        (( ram_mb > 16384 )) && rec_mb=4096 || rec_mb=$((ram_mb / 2))
                        (( rec_mb < 1024 )) && rec_mb=1024
                        # Si el archivo existe, recuperamos su tamaño real.
                        if [[ -f "$src" ]]; then
                            local sz
                            sz=$(stat -c %s "$src" 2>/dev/null || echo 0)
                            (( sz / 1048576 > rec_mb )) && rec_mb=$((sz / 1048576))
                        fi
                        if confirmar "  → El swap '$src' no funciona. ¿Reconstruirlo automáticamente (~${rec_mb} MB)?"; then
                            # Desactiva el swap y la unidad antes de reconstruir,
                            # evitando el fallo "dispositivo en uso".
                            sudo swapon -s 2>/dev/null | grep -qF "$src" && sudo swapoff "$src" 2>/dev/null || true
                            sudo systemctl stop "$unidad" 2>/dev/null || true
                            if crear_archivo_swap "$rec_mb" "$src"; then
                                sudo systemctl reset-failed "$unidad" 2>/dev/null || true
                                if sudo systemctl restart "$unidad" 2>/dev/null || sudo swapon -a 2>/dev/null; then
                                    echo -e "${GREEN}[ OK ] ${unidad} reparado y en marcha${RESET}"
                                    ok=$((ok + 1))
                                    reparados=$((reparados + 1))
                                    reparado=1
                                fi
                            fi
                        fi
                        if [[ "$reparado" -eq 0 ]]; then
                            echo -e "${RED}[ ERROR ] No se pudo recuperar ${unidad}${RESET}"
                            echo -e "${DIM}   Diagnóstico: journalctl -u ${unidad} --no-pager | tail -20${RESET}"
                            fail=$((fail + 1))
                        fi
                    else
                        echo -e "${RED}[ ERROR ] Falló el reinicio de ${unidad}${RESET}"
                        echo -e "${DIM}   Diagnóstico: journalctl -u ${unidad} --no-pager | tail -20${RESET}"
                        fail=$((fail + 1))
                    fi
                fi
            done 3< "$tmpfile"
                if (( reparados > 0 )); then
                    echo -e "${GREEN}[ OK ] ${reparados} unit(s) de swap reconstruidos correctamente${RESET}"
                fi
                registrar_ultima_accion "Servicios reiniciados (${ok} ok, ${fail} fallidos)"
            else
                registrar_ultima_accion "Revisión de servicios fallidos (${total} encontrados)"
            fi
        fi

        rm -f "$tmpfile"
        pause
    }


# ═══════════════════════════════════════════════════════
#  FUNCIONES NUEVAS: ACTUALIZACIONES Y README
# ═══════════════════════════════════════════════════════

# Descarga el script actualizado a un archivo temporal.
# Uso: descargar_script_remoto <archivo_destino>
descargar_script_remoto() {
    local destino="$1"
    if command -v curl >/dev/null 2>&1; then
        if curl -fsSL --connect-timeout 10 --max-time 60 -o "$destino" "$UPDATE_URL" 2>/dev/null; then
            return 0
        fi
    fi
    if command -v wget >/dev/null 2>&1; then
        if wget -q --show-progress --timeout=60 -O "$destino" "$UPDATE_URL" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# Devuelve la versión más reciente publicada en UPDATE_URL,
# o vacío si no se pudo consultar.
obtener_version_remota() {
    local linea
    if command -v curl >/dev/null 2>&1; then
        linea=$(curl -fsSL --connect-timeout 5 --max-time 10 "$UPDATE_URL" 2>/dev/null | grep -m1 '^VERSION=' )
    fi
    if [[ -z "$linea" ]] && command -v wget >/dev/null 2>&1; then
        linea=$(wget -q --timeout=10 -O - "$UPDATE_URL" 2>/dev/null | grep -m1 '^VERSION=' )
    fi
    [[ -n "$linea" ]] && echo "${linea#VERSION=}" | tr -d '"' || echo ""
}

# Compara dos versiones "a.b.c": devuelve 0 si $1 > $2.
version_es_mayor() {
    local v1="$1" v2="$2"
    [[ "$v1" == "$v2" ]] && return 1
    if [[ "$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | head -n1)" == "$v2" ]]; then
        return 0
    fi
    return 1
}

# Consulta si hay una actualización y muestra un aviso en la cabecera.
# Uso: comprobar_update [--aviso]
comprobar_update() {
    local remota="$UPDATE_AVAILABLE"
    [[ -n "$remota" ]] || remota=$(obtener_version_remota)

    if [[ -z "$remota" ]]; then
        [[ "${1:-}" != "--aviso" ]] && echo -e "${YELLOW}[ WARN ] No se pudo consultar la última versión (sin conexión).${RESET}"
        return 1
    fi

    if version_es_mayor "$remota" "$VERSION"; then
        UPDATE_AVAILABLE="$remota"
        if [[ "${1:-}" != "--aviso" ]]; then
            echo -e "${ORANGE}◈ Nueva versión disponible: ${BOLD}${remota}${RESET} ${DIM}(actual: ${VERSION})${RESET}"
        fi
        return 0
    fi
    return 1
}

# comprobar_update_fondo: ejecuta el chequeo en segundo plano y guarda el
# resultado en un archivo provisional (no bloquea el menú si no hay red).
# Uso: comprobar_update_fondo
comprobar_update_fondo() {
    mkdir -p "$(dirname "$UPDATE_STATE_FILE")" 2>/dev/null || true
    local remota
    remota=$(obtener_version_remota)
    if [[ -n "$remota" ]] && version_es_mayor "$remota" "$VERSION"; then
        echo "$remota" > "$UPDATE_STATE_FILE" 2>/dev/null
    else
        rm -f "$UPDATE_STATE_FILE" 2>/dev/null
    fi
}

# Sustituye el script actual por uno recién descargado de forma robusta.
# `install` escribe directamente sobre el archivo en ejecución y por eso puede
# fallar con "Text file busy" (ETXTBSY). La estrategia aquí es:
#   1) Copiar el nuevo script a un temporal en el MISMO directorio.
#   2) Renombrarlo sobre el destino con mv: rename() reemplaza la entrada del
#      directorio y funciona aunque el script esté corriendo.
#   3) Si aún falla, borrar el destino y volver a instalarlo (quita-y-pon).
# Usa sudo cuando el directorio destino no sea escribible por el usuario
# (instalaciones en /usr/local/bin, /usr/bin, etc.).
# Uso: reemplazar_script <temporal> <destino> [--sudo-ya]
reemplazar_script() {
    local tmp="$1" dest="$2" dir upd=0 new usar_sudo=0
    dir=$(dirname "$dest")
    new="$dir/.kyro_new_$$"

    # No somos root y el directorio no es escribible: se necesitará sudo.
    # --sudo-ya: el llamador ya autenticó (check_sudo), no se vuelve a pedir.
    if [[ "$(id -u)" -ne 0 ]] && [[ ! -w "$dir" ]]; then
        usar_sudo=1
        if [[ "${3:-}" != "--sudo-ya" ]] && ! check_sudo; then
            echo -e "${RED}[ ERROR ] Sin permisos de escritura ni sudo. No se pudo actualizar.${RESET}"
            return 1
        fi
    fi

    # ── 1) Copia al temporal del mismo directorio + rename ──
    if [[ "$usar_sudo" -eq 0 ]]; then
        if cp -f "$tmp" "$new" 2>/dev/null && chmod 755 "$new" 2>/dev/null && mv -f "$new" "$dest" 2>/dev/null; then
            upd=1
        else
            rm -f "$new" 2>/dev/null
        fi
    fi

    # ── 2) Con sudo (directorio de sistema) ──
    if [[ "$upd" -eq 0 ]]; then
        if sudo cp -f "$tmp" "$new" 2>/dev/null && sudo chmod 755 "$new" 2>/dev/null && sudo mv -f "$new" "$dest" 2>/dev/null; then
            upd=1
        fi
        sudo rm -f "$new" 2>/dev/null
    fi

    # ── 3) Último recurso: borrar y reinstalar ──
    if [[ "$upd" -eq 0 ]] && [[ "$usar_sudo" -eq 0 ]]; then
        rm -f "$dest" 2>/dev/null
        install -m 755 "$tmp" "$dest" 2>/dev/null && upd=1
    fi
    if [[ "$upd" -eq 0 ]]; then
        sudo rm -f "$dest" 2>/dev/null
        sudo install -m 755 "$tmp" "$dest" 2>/dev/null && upd=1
    fi

    [[ "$upd" -eq 1 ]]
}

# actualizaciones_auto: revisa si hay una nueva versión y,
# si existe, ofrece actualizarla manualmente (como un "botón").
actualizaciones_auto() {
    clear
    echo -e "${CYAN}${BOLD}╭─ Actualizador de Kyro ────────────────────────────────╮${RESET}"
    echo -e "${CYAN}│${RESET} Tu versión: ${BOLD}${VERSION}${RESET}${CYAN}"
    echo -e "${CYAN}╰────────────────────────────────────────────────────────────╯${RESET}"
    echo ""

    local remota
    remota=$(obtener_version_remota)

    if [[ -z "$remota" ]]; then
        echo -e "${YELLOW}No se pudo contactar el servidor de actualizaciones.${RESET}"
        echo -e "${DIM}Revisa tu conexión o la variable UPDATE_URL (arriba del script).${RESET}"
        pause
        return
    fi

    if ! version_es_mayor "$remota" "$VERSION"; then
        echo -e "${GREEN}[ OK ] Ya estás en la última versión (${VERSION}).${RESET}"
        registrar_ultima_accion "Comprobación de actualizaciones (sin novedades)"
        pause
        return
    fi

    echo -e "${GREEN}[ OK ] Se encontró una actualización:${RESET} ${BOLD}${VERSION} → ${remota}${RESET}"
    echo ""

    if confirmar "¿Descargar e instalar la versión ${remota} ahora?"; then
        local tmp
        tmp=$(crear_temporal) || { echo -e "${RED}[ ERROR ] No se pudo crear un temporal para la actualización.${RESET}"; pause; return 1; }
        echo -e "${YELLOW}Descargando Kyro ${remota}...${RESET}"
        if descargar_script_remoto "$tmp"; then
            # Valida el script descargado antes de tocar el instalado.
            if ! bash -n "$tmp" 2>/dev/null; then
                echo -e "${RED}[ ERROR ] La descarga está corrupta (no es un script válido).${RESET}"
                echo -e "${DIM}   No se tocó tu instalación. Inténtalo de nuevo.${RESET}"
                eliminar_temporal "$tmp"
                pause
                return
            fi
            # Sustituye el script actual por el nuevo y lo deja ejecutable.
            if reemplazar_script "$tmp" "$SCRIPT_PATH" && chmod +x "$SCRIPT_PATH" 2>/dev/null; then
                echo -e "${GREEN}[ OK ] Kyro actualizado a ${remota}. Se relanzará con la nueva versión.${RESET}"
                registrar_ultima_accion "Actualización de Kyro (${VERSION} → ${remota})"
                eliminar_temporal "$tmp"
                exec bash "$SCRIPT_PATH"
            else
                echo -e "${RED}[ ERROR ] No se pudo reemplazar el script (permisos?).${RESET}"
                echo -e "${DIM}   Intenta manualmente: sudo install -m 755 '$tmp' '$SCRIPT_PATH'${RESET}"
                eliminar_temporal "$tmp"
            fi
        else
            echo -e "${RED}[ ERROR ] Error al descargar la actualización.${RESET}"
            rm -f "$tmp"
        fi
    else
        echo -e "${YELLOW}Quedaste en la versión ${VERSION}. Puedes actualizar después.${RESET}"
    fi
    pause
}

# Resuelve dónde leer/escribir el README. Prioridad:
#   1) README.md del repositorio en HOME (si el script se ejecuta desde ahí).
#   2) README.md junto al script instalado (si existe y es legible).
#   3) Ruta escribible en $HOME (para instalaciones en /usr, etc.).
resolver_readme() {
    if [[ -f "$HOME/Kyro/README.md" ]]; then
        README_PATH="$HOME/Kyro/README.md"
    elif [[ -f "$SCRIPT_DIR/README.md" ]] && [[ -r "$SCRIPT_DIR/README.md" ]]; then
        README_PATH="$SCRIPT_DIR/README.md"
    else
        mkdir -p "$HOME/.local/share/kyro" 2>/dev/null || true
        README_PATH="$HOME/.local/share/kyro/README.md"
    fi
}

# Crea el README.md si no existe (con descripción y créditos).
crear_readme() {
    resolver_readme
    if [[ -f "$README_PATH" ]]; then
        return
    fi
    echo -e "${YELLOW}No se encontró README.md. Creándolo...${RESET}"
    cat > "$README_PATH" <<EOF
# Kyro Optimizer

Optimizador y herramienta de mantenimiento del sistema para Linux.

## Qué hace

- Limpia la caché en un solo toque: gestor oficial, AUR, navegadores, AppImage y sistema.
- Optimiza hardware: CPU, RAM, swap, planificador de E/S y gobernador.
- Optimización rápida persistente: sysctl, gobernador y planificadores en todos los discos.
- Optimización gaming: GPU (AMD/NVIDIA/Intel), vm.max_map_count y CPU sin latencias.
- Optimización de red: TCP BBR, colas fq y buffers (persistente).
- Módulo de sistema de archivos: TRIM (fstrim), btrfs/ext4 y snapshots.
- Análisis del arranque: systemd-analyze y desactivación segura de unidades.
- Seguridad del sistema: puertos, coredumps y endurecimiento reversible.
- Mantenimiento avanzado de paquetes: pacman-key, Flatpak y Snap.
- Mantenimiento de Steam: shader caches y prefijos Proton huérfanos.
- Modo CLI sin interfaz: \`--status\`, \`--health\`, \`--version\`.
- Detecta y diagnostica errores de hardware (SMART, NVMe, ECC/MCE, temperatura).
- Chequeo de salud completo con resumen ok/aviso/crítico.
- Analiza directorios vacíos, integridad de paquetes y archivos grandes.
- Revisa y aplica archivos .pacnew / .pacsave interactivamente (con diff).
- Repara servicios systemd fallidos (incluidos swaps rotos en btrfs).
- Limpieza profunda opcional: coredumps, Snap/Flatpak/Docker/Podman.
- Monitoriza CPU, RAM y temperatura en tiempo real.
- Restaura por completo los ajustes de Kyro (rollback a valores de fábrica).
- Se actualiza automáticamente a sí mismo (¡eso hace este mismo archivo!).

## Instalación

\`\`\`bash
chmod +x Kyro.sh && ./Kyro.sh
\`\`\`

Requiere: **bash >= 4**, **coreutils**, **du**, **numfmt** y sudo.

## Actualizaciones

Kyro comprueba la versión más reciente en el repositorio del proyecto y
te avisa para que la instales manualmente desde el menú.

## Créditos

Kyro fue creado y desarrollado por **comuza**.

Licencia: **GPL-3.0** — usa, modifica y comparte.
EOF
}

# abrir_readme: muestra el README en pantalla.
abrir_readme() {
    crear_readme
    clear
    echo -e "${CYAN}${BOLD}╭─ Kyro Optimizer ─ README ───────────────────────────╮${RESET}"
    echo -e "${CYAN}╰──────────────────────────────────────────────────────────╯${RESET}"
    echo ""
    if command -v less >/dev/null 2>&1; then
        less -R "$README_PATH"
    elif command -v more >/dev/null 2>&1; then
        more "$README_PATH"
    else
        cat "$README_PATH"
    fi
    registrar_ultima_accion "Abrir README"
    pause
}

# ─── 19) Optimización de red (TCP BBR, colas fq y buffers) ─────
optimizar_red() {
    clear
    echo -e "${CYAN}${BOLD}╭─ Optimización de red ──────────────────────────────────────────────╮${RESET}"
    echo -e "${CYAN}│${RESET} TCP BBR, colas fq y buffers más amplios (seguros y reversibles).${CYAN}"
    echo -e "${CYAN}╰──────────────────────────────────────────────────────────────────╯${RESET}"
    echo ""
    if ! confirmar "¿Aplicar la optimización de red ahora?"; then
        echo -e "${YELLOW}Cancelado.${RESET}"
        return
    fi
    if ! check_sudo; then
        pause
        return
    fi
    echo ""
    KYRO_NET=()

    echo -e "${BOLD}▸ Control de congestión (BBR):${RESET}"
    local bbr_ok=0 k v kv
    if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        bbr_ok=1
    elif sudo modprobe tcp_bbr 2>/dev/null; then
        bbr_ok=1
    fi
    if (( bbr_ok == 1 )); then
        for kv in "net.core.default_qdisc=fq" "net.ipv4.tcp_congestion_control=bbr"; do
            k=${kv%%=*}; v=${kv#*=}
            if sudo sysctl -w "$k=$v" >/dev/null 2>&1; then
                echo -e "   ${GREEN}[ OK ]${RESET} $k = $v"
                KYRO_NET+=("$kv")
            else
                echo -e "   ${YELLOW}[ WARN ]${RESET} $k (no aplicable)"
            fi
        done
    else
        echo -e "   ${YELLOW}[ WARN ] BBR no disponible (módulo tcp_bbr). Se aplicarán solo los buffers.${RESET}"
    fi
    echo ""

    echo -e "${BOLD}▸ Buffers, colas y temporizadores:${RESET}"
    local net=(
        "net.core.rmem_max=134217728"
        "net.core.wmem_max=134217728"
        "net.ipv4.tcp_rmem=4096 87380 134217728"
        "net.ipv4.tcp_wmem=4096 65536 134217728"
        "net.ipv4.tcp_fastopen=3"
        "net.core.netdev_max_backlog=16384"
        "net.ipv4.tcp_slow_start_after_idle=0"
        "net.ipv4.tcp_mtu_probing=1"
        "net.core.somaxconn=1024"
        "net.ipv4.tcp_max_syn_backlog=1024"
    )
    for kv in "${net[@]}"; do
        k=${kv%%=*}; v=${kv#*=}
        if sudo sysctl -w "$k=$v" >/dev/null 2>&1; then
            echo -e "   ${GREEN}[ OK ]${RESET} $k = $v"
            KYRO_NET+=("$kv")
        else
            echo -e "   ${YELLOW}[ WARN ]${RESET} $k (no aplicable)"
        fi
    done
    echo ""

    # ── Qdisc avanzado (opcional): CAKE (cable) o fq_codel (Wi-Fi) ──
    # CAKE da una latencia excelente bajo carga, pero conviene indicarle el
    # ancho de banda real. Se detecta desde la velocidad enlazada del puerto;
    # si no se puede medir, se omite el parámetro (máx. sin forma).
    local iface_default="" net_vel=""
    iface_default=$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')
    [[ -z "$iface_default" ]] && iface_default=$(ip -o link show 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}')
    local qdisc_rec="" qdisc_aplicado=0
    if [[ -n "$iface_default" ]] && command -v tc >/dev/null 2>&1; then
        echo -e "${BOLD}▸ Cola de paquetes (qdisc) en ${iface_default}:${RESET}"
        local es_wifi=0
        [[ -d "/sys/class/net/$iface_default/wireless" ]] && es_wifi=1
        if (( es_wifi == 1 )); then
            qdisc_rec="fq_codel"
        else
            qdisc_rec="cake"
        fi
        if confirmar "  → ¿Aplicar qdisc '${qdisc_rec}' a ${iface_default}? (mejora la latencia)"; then
            net_vel=$(cat "/sys/class/net/$iface_default/speed" 2>/dev/null)
            if [[ "$net_vel" =~ ^[0-9]+$ ]] && (( net_vel >= 100 )); then
                if sudo tc qdisc replace dev "$iface_default" root "${qdisc_rec}" bandwidth "${net_vel}Mbit" >/dev/null 2>&1; then
                    echo -e "   ${GREEN}[ OK ] ${qdisc_rec} aplicado (≈${net_vel} Mbit/s)${RESET}"
                    qdisc_aplicado=1
                fi
            elif sudo tc qdisc replace dev "$iface_default" root "${qdisc_rec}" >/dev/null 2>&1; then
                echo -e "   ${GREEN}[ OK ] ${qdisc_rec} aplicado (ancho de banda sin limitar)${RESET}"
                qdisc_aplicado=1
            fi
            if (( qdisc_aplicado == 0 )); then
                echo -e "   ${YELLOW}[ WARN ] No se pudo aplicar el qdisc (¿tc disponible y permisos?).${RESET}"
            fi
        fi
    fi
    echo ""

    echo -e "${BOLD}▸ Persistencia:${RESET}"
    if confirmar "  → ¿Guardar estos ajustes para cada arranque?"; then
        guardar_sysctls "99-kyro-network.conf" "${KYRO_NET[@]}"
    else
        echo -e "   ${DIM}Los cambios durarán hasta el próximo reinicio.${RESET}"
    fi

    # Si se aplicó un qdisc, se persiste con un servicio mínimo (reversible
    # con la opción 30), que reaplica la cola al arrancar la red.
    if (( qdisc_aplicado == 1 )); then
        if confirmar "  → ¿Persistir el qdisc ${qdisc_rec} en cada arranque con un servicio?"; then
            local qb="/usr/local/bin/kyro-net-qdisc.sh"
            local qs="/etc/systemd/system/kyro-net.service"
            local qtmp
            qtmp=$(crear_temporal)
            {
                echo "#!/bin/bash"
                echo "# Generado por Kyro (optimización de red). No editar a mano."
                echo "IFACE=\"$iface_default\""
                if [[ "$net_vel" =~ ^[0-9]+$ ]]; then
                    echo "tc qdisc replace dev \"\$IFACE\" root ${qdisc_rec} bandwidth ${net_vel}Mbit >/dev/null 2>&1 || \\"
                else
                    echo "tc qdisc replace dev \"\$IFACE\" root ${qdisc_rec} >/dev/null 2>&1 || \\"
                fi
                echo "tc qdisc replace dev \"\$IFACE\" root ${qdisc_rec} >/dev/null 2>&1"
                echo "exit 0"
            } > "$qtmp"
            if sudo install -m 755 "$qtmp" "$qb" >/dev/null 2>&1; then
                sudo tee "$qs" >/dev/null <<EOF
[Unit]
Description=Qdisc CAKE/fq_codel de Kyro
After=network.target

[Service]
Type=oneshot
ExecStart=$qb

[Install]
WantedBy=multi-user.target
EOF
                sudo systemctl daemon-reload >/dev/null 2>&1
                if sudo systemctl enable --now kyro-net.service >/dev/null 2>&1; then
                    echo -e "   ${GREEN}[ OK ] qdisc persistente (kyro-net.service)${RESET}"
                else
                    echo -e "   ${YELLOW}[ WARN ] Script guardado, pero no se pudo activar el servicio.${RESET}"
                fi
            else
                echo -e "   ${YELLOW}[ WARN ] No se pudo escribir el script persistente del qdisc.${RESET}"
            fi
            rm -f "$qtmp"
        fi
    fi
    registrar_ultima_accion "Optimización de red (BBR + buffers + qdisc, ${#KYRO_NET[@]} sysctls)"
    echo ""
    echo -e "${GREEN}[ OK ] Optimización de red finalizada${RESET}"
    pause
}

# ─── 28) Chequeo de salud completo ─────────────────────
chequeo_salud() {
    clear
    echo -e "${CYAN}${BOLD}╭─ Chequeo de salud del sistema ──────────────────────────────────────╮${RESET}"
    echo -e "${CYAN}│${RESET} Revisión rápida de los puntos críticos de tu equipo.${CYAN}"
    echo -e "${CYAN}╰──────────────────────────────────────────────────────────────────╯${RESET}"
    echo ""
    local ok=0 warn=0 crit=0 items=()

    # ── Carga y CPU ──
    local load nproc pct
    read -r load _ _ _ _ <<< "$(cat /proc/loadavg 2>/dev/null)"
    load=${load:-0}
    nproc=$(nproc 2>/dev/null || echo 1)
    pct=$(awk -v l="$load" -v n="$nproc" 'BEGIN{printf "%d", (l/n)*100}')
    if (( pct >= 100 )); then items+=("crit|Carga de CPU: $load ($pct% de $nproc núcleo(s))"); crit=$((crit+1))
    elif (( pct > 60 )); then items+=("warn|Carga de CPU: $load ($pct% de $nproc núcleo(s))"); warn=$((warn+1))
    else items+=("ok|Carga de CPU: $load ($pct% de $nproc núcleo(s))"); ok=$((ok+1)); fi

    # ── RAM ──
    local memtot memuse mempct
    memtot=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}'); memuse=$(free -m 2>/dev/null | awk '/^Mem:/{print $3}')
    mempct=$(free -m 2>/dev/null | awk '/^Mem:/{printf "%d", ($3/$2)*100}')
    mempct=${mempct:-0}
    if (( mempct >= 90 )); then items+=("crit|RAM: ${memuse}MB / ${memtot}MB (${mempct}%)"); crit=$((crit+1))
    elif (( mempct >= 70 )); then items+=("warn|RAM: ${memuse}MB / ${memtot}MB (${mempct}%)"); warn=$((warn+1))
    else items+=("ok|RAM: ${memuse}MB / ${memtot}MB (${mempct}%)"); ok=$((ok+1)); fi

    # ── Swap ──
    local swap_total
    read -r swap_total _ _ <<< "$(info_swap)"
    if (( swap_total > 0 )); then items+=("ok|Swap: $swap_total MB"); ok=$((ok+1))
    else items+=("warn|Swap: sin swap (auméntalo con la opción 5)"); warn=$((warn+1)); fi

    # ── Disco ──
    local disk_used disk_total disk_pct
    read -r disk_used disk_total disk_pct < <(df -h "$HOME" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $3, $2, $5}')
    disk_pct=${disk_pct:-0}
    if (( disk_pct >= 90 )); then items+=("crit|Disco ($HOME): ${disk_used}/${disk_total} (${disk_pct}%)"); crit=$((crit+1))
    elif (( disk_pct >= 70 )); then items+=("warn|Disco ($HOME): ${disk_used}/${disk_total} (${disk_pct}%)"); warn=$((warn+1))
    else items+=("ok|Disco ($HOME): ${disk_used}/${disk_total} (${disk_pct}%)"); ok=$((ok+1)); fi

    # ── Temperatura ──
    local tempv=0 tempc
    if command -v sensors >/dev/null 2>&1; then
        tempc=$(sensors 2>/dev/null | grep -m1 -oE '[0-9]+\.[0-9]+°C' | grep -oE '^[0-9]+' | head -1)
        [[ -n "$tempc" ]] && tempv=$tempc
    elif compgen -G "/sys/class/thermal/thermal_zone*/temp" >/dev/null; then
        local tz tv
        for tz in /sys/class/thermal/thermal_zone*/temp; do
            tv=$(cat "$tz" 2>/dev/null)
            (( tv > tempv )) && tempv=$((tv / 1000))
        done
    fi
    if (( tempv >= 85 )); then items+=("crit|Temperatura máx: ${tempv}°C"); crit=$((crit+1))
    elif (( tempv >= 70 )); then items+=("warn|Temperatura máx: ${tempv}°C"); warn=$((warn+1))
    elif (( tempv > 0 )); then items+=("ok|Temperatura máx: ${tempv}°C"); ok=$((ok+1))
    else items+=("ok|Temperatura: sin sensores"); ok=$((ok+1)); fi

    # ── SMART (usa sudo -n: no bloquea el chequeo pidiendo contraseña) ──
    local smart_hay=0 smart_fallos=0 dn smart_out
    if command -v smartctl >/dev/null 2>&1; then
        while IFS= read -r dn; do
            [[ -n "$dn" ]] || continue
            [[ -e "/dev/$dn" ]] || continue
            smart_out=$(sudo -n smartctl -H "/dev/$dn" 2>/dev/null)
            [[ -n "$smart_out" ]] && smart_hay=1
            if echo "$smart_out" | grep -q 'FAILED'; then smart_fallos=$((smart_fallos + 1)); fi
        done < <(lsblk -dno NAME 2>/dev/null | grep -E '^(sd[a-z]|nvme[0-9]n[0-9]+)$')
    fi
    if (( smart_fallos > 0 )); then items+=("crit|S.M.A.R.T.: $smart_fallos disco(s) en FALLO"); crit=$((crit+1))
    elif (( smart_hay == 1 )); then items+=("ok|S.M.A.R.T.: discos sin fallos"); ok=$((ok+1))
    elif command -v smartctl >/dev/null 2>&1; then items+=("warn|S.M.A.R.T.: no verificable sin sudo"); warn=$((warn+1))
    else items+=("warn|S.M.A.R.T.: smartmontools no instalado"); warn=$((warn+1)); fi

    # ── Servicios fallidos ──
    local failed
    failed=$(systemctl --failed --no-legend --plain 2>/dev/null | wc -l)
    if (( failed > 0 )); then items+=("warn|Servicios systemd fallidos: $failed (opción 11)"); warn=$((warn+1))
    else items+=("ok|Servicios systemd: sin fallos"); ok=$((ok+1)); fi

    # ── Kernel errors ──
    local kerr
    kerr=$(journalctl -k -p err --since "-7 days" -o cat 2>/dev/null | grep -icE 'error|fail|critical|panic|oops' || true)
    if (( kerr > 20 )); then items+=("warn|Errores de kernel (7 días): $kerr (opción 7)"); warn=$((warn+1))
    else items+=("ok|Errores de kernel (7 días): $kerr"); ok=$((ok+1)); fi

    # ── .pacnew / huérfanos ──
    local pacnew
    pacnew=$(find /etc -type f \( -name '*.pacnew' -o -name '*.pacsave' \) 2>/dev/null | wc -l)
    if (( pacnew > 0 )); then items+=("warn|Archivos .pacnew/.pacsave: $pacnew (opción 17)"); warn=$((warn+1))
    else items+=("ok|Archivos .pacnew/.pacsave: 0"); ok=$((ok+1)); fi
    local orphans
    orphans=$(pacman -Qtdq 2>/dev/null | wc -l)
    if (( orphans > 0 )); then items+=("warn|Paquetes huérfanos: $orphans (opción 2)"); warn=$((warn+1))
    else items+=("ok|Paquetes huérfanos: 0"); ok=$((ok+1)); fi

    # ── Disco raíz ──
    local rtot rused rpct2
    read -r rtot rused rpct2 < <(df -h / 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $2, $3, $5}')
    rpct2=${rpct2:-0}
    if (( rpct2 >= 90 )); then items+=("crit|Disco raíz (/): ${rused}/${rtot} (${rpct2}%)"); crit=$((crit+1))
    elif (( rpct2 >= 70 )); then items+=("warn|Disco raíz (/): ${rused}/${rtot} (${rpct2}%)"); warn=$((warn+1))
    else items+=("ok|Disco raíz (/): ${rused}/${rtot} (${rpct2}%)"); ok=$((ok+1)); fi

    # ── /boot: si se llena, las actualizaciones de kernel fallan ──
    local btot bused bptc
    read -r btot bused bptc < <(df -h /boot 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $2, $3, $5}')
    if [[ -n "$bptc" ]]; then
        if (( bptc >= 90 )); then items+=("crit|/boot: ${bused}/${btot} (${bptc}%)"); crit=$((crit+1))
        elif (( bptc >= 70 )); then items+=("warn|/boot: ${bused}/${btot} (${bptc}%)"); warn=$((warn+1))
        else items+=("ok|/boot: ${bused}/${btot} (${bptc}%)"); ok=$((ok+1)); fi
    fi

    # ── TRIM automático en SSD ──
    local base_dev rot trim_on
    base_dev=$(detectar_dispositivo_base)
    rot=$(cat "/sys/block/$base_dev/queue/rotational" 2>/dev/null || echo "?")
    if [[ "$base_dev" == nvme* ]] || [[ "$rot" == "0" ]]; then
        if systemctl is-enabled fstrim.timer >/dev/null 2>&1; then
            items+=("ok|TRIM (fstrim.timer): activo"); ok=$((ok+1))
        else
            items+=("warn|TRIM (fstrim.timer) desactivado en SSD"); warn=$((warn+1))
        fi
    fi

    # ── Conectividad de red ──
    if command -v ping >/dev/null 2>&1; then
        if ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
            items+=("ok|Conectividad de red: OK"); ok=$((ok+1))
        else
            items+=("warn|Conectividad: sin acceso a internet"); warn=$((warn+1))
        fi
    fi

    # ── Reloj sincronizado (NTP) ──
    if command -v timedatectl >/dev/null 2>&1; then
        if timedatectl 2>/dev/null | grep -qE 'synchronized: yes'; then
            items+=("ok|Reloj sincronizado (NTP)"); ok=$((ok+1))
        else
            items+=("warn|Reloj sin sincronizar (NTP)"); warn=$((warn+1))
        fi
    fi

    # ── Batería (portátiles) ──
    local bat_pct
    if compgen -G "/sys/class/power_supply/BAT*/capacity" >/dev/null; then
        bat_pct=$(cat /sys/class/power_supply/BAT*/capacity 2>/dev/null | sort -n | head -1)
        if (( bat_pct < 15 )); then items+=("warn|Batería baja: ${bat_pct}%"); warn=$((warn+1))
        else items+=("ok|Batería: ${bat_pct}%"); ok=$((ok+1)); fi
    fi

    # ── Mostrar ──
    echo -e "${BOLD}Resultados:${RESET}"
    local it lvl msg
    for it in "${items[@]}"; do
        lvl=${it%%|*}; msg=${it#*|}
        case "$lvl" in
            ok)   echo -e "   ${GREEN}[ OK ]${RESET} $msg" ;;
            warn) echo -e "   ${YELLOW}[ WARN ]${RESET} $msg" ;;
            crit) echo -e "   ${RED}[ ERROR ]${RESET} $msg" ;;
        esac
    done
    echo ""
    echo -e "${BOLD}Resumen:${RESET} ${GREEN}${ok} ok${RESET} · ${YELLOW}${warn} aviso(s)${RESET} · ${RED}${crit} crítico(s)${RESET}"
    if (( crit > 0 || warn > 0 )); then
        echo -e "${DIM}Resuelve los puntos pendientes con las opciones indicadas del menú.${RESET}"
    else
        echo -e "${GREEN}[ OK ] Sistema en buen estado general.${RESET}"
    fi
    registrar_ultima_accion "Chequeo de salud (${ok} ok, ${warn} avisos, ${crit} críticos)"
    pause
}

# ─── 29) Limpieza profunda (opcional, todo confirmado) ──
limpieza_profunda() {
    clear
    echo -e "${CYAN}${BOLD}╭─ Limpieza profunda (opcional y segura) ────────────────────────────╮${RESET}"
    echo -e "${CYAN}│${RESET} Elementos extra que se eliminan SOLO si confirmas cada uno.${CYAN}"
    echo -e "${CYAN}╰──────────────────────────────────────────────────────────────────╯${RESET}"
    echo ""
    if ! confirmar "¿Comenzar la limpieza profunda?"; then
        echo -e "${YELLOW}Cancelado.${RESET}"
        return
    fi
    if ! check_sudo; then
        pause
        return
    fi
    echo ""

    # ── 1) Coredumps antiguos ──
    if [[ -d /var/lib/systemd/coredump ]] && confirmar "→ ¿Eliminar volcados de memoria (coredumps) de más de 14 días?"; then
        sudo find /var/lib/systemd/coredump -type f -mtime +14 -delete 2>/dev/null
        echo -e "   ${GREEN}[ OK ] Coredumps antiguos eliminados${RESET}"
    fi

    # ── 2) Kernels antiguos (deja el actual + el anterior) ──
    if command -v pacman >/dev/null 2>&1 && confirmar "→ ¿Eliminar kernels antiguos conservando el actual y el anterior?"; then
        local k_actual k_ant activo_pkg
        k_actual=$(uname -r)
        # Paquete que posee el kernel en ejecución (jamás se borra).
        activo_pkg=$(LC_ALL=C pacman -Qo "/usr/lib/modules/$k_actual" 2>/dev/null | head -1 | sed 's/.*is owned by //; s/ [^ ]*$//')
        [[ -z "$activo_pkg" ]] && activo_pkg="desconocido"
        local instalados resto
        instalados=$(pacman -Qq 2>/dev/null | grep -E '^(linux|linux-hardened|linux-lts|linux-zen|linux-cachyos)( |$)' | grep -v 'headers\|docs' | grep -vE -e '-(headers|firmware|api-headers)$' | sort -u)
        if [[ -n "$instalados" ]]; then
            echo -e "   ${DIM}   Kernels instalados:${RESET}"
            echo "$instalados" | sed 's/^/      /'
            echo -e "   ${DIM}   En ejecución: ${k_actual}  →  paquete ${activo_pkg} (protegido)${RESET}"
            # Candidatos = todos menos el activo y los meta.
            resto=$(echo "$instalados" | grep -vx "$activo_pkg" | grep -v '.-meta$' | tr '\n' ' ')
            if [[ -n "$resto" ]] && confirmar "     → ¿Eliminar los kernels no activos: $resto (dejará solo el activo)?"; then
                read -r -a kernel_pkgs <<< "$resto"
                sudo pacman -Rns --noconfirm "${kernel_pkgs[@]}" 2>/dev/null || echo -e "   ${YELLOW}[ WARN ]${RESET} No se pudieron eliminar algunos kernels."
                echo -e "   ${GREEN}[ OK ] Kernels antiguos eliminados: $resto${RESET}"
            fi
        else
            echo -e "   ${YELLOW}[ WARN ] kernel no identificable (¿distro con kernel de paquete distinto?).${RESET}"
        fi
    fi

    # ── 3) Huérfanos generales ──
    if command -v pacman >/dev/null 2>&1 && confirmar "→ ¿Eliminar paquetes huérfanos (dependencias sin uso)?"; then
        local huerc
        huerc=$(pacman -Qtdq 2>/dev/null | wc -l)
        if (( huerc > 0 )); then
            mapfile -t orphan_pkgs < <(pacman -Qtdq 2>/dev/null)
            sudo pacman -Rns --noconfirm "${orphan_pkgs[@]}" 2>/dev/null
            echo -e "   ${GREEN}[ OK ] ${huerc} paquete(s) huérfano(s) eliminados${RESET}"
        else
            echo -e "   ${YELLOW}[ WARN ] No hay huérfanos.${RESET}"
        fi
    fi

    # ── 4) Flatpak ──
    if command -v flatpak >/dev/null 2>&1 && confirmar "→ ¿Eliminar runtimes/paquetes Flatpak sin uso?"; then
        flatpak uninstall --unused --assumeyes 2>/dev/null || true
        spinner "Flatpak: caché" bash -c 'set -f; for d in "$HOME"/.var/app/*/cache; do [[ -d "$d" ]] && rm -rf -- "$d"; done' 
        # también el caché de thumbnailer flatpak
        rm -rf "$HOME/.cache/thumbnails" 2>/dev/null
    fi

    # ── 5) Snap ──
    if command -v snap >/dev/null 2>&1 && confirmar "→ ¿Limpiar revisiones antiguas (disables) de Snap?"; then
        local sname srev
        while read -r sname srev; do
            [[ -n "$sname" && -n "$srev" ]] || continue
            sudo snap remove "$sname" --revision="$srev" 2>/dev/null
        done < <(sudo snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}')
        echo -e "   ${GREEN}[ OK ] Snap: revisiones deshabilitadas eliminadas${RESET}"
    fi

    # ── 6) Docker ──
    if command -v docker >/dev/null 2>&1 && confirmar "→ ¿Podar todo lo no usado de Docker (contenedores parados, redes e imágenes)? [y/N]"; then
        sudo docker system prune -af 2>/dev/null || sudo docker system prune -f 2>/dev/null
        echo -e "   ${GREEN}[ OK ] Docker podado${RESET}"
    fi

    # ── 7) Podman ──
    if command -v podman >/dev/null 2>&1 && confirmar "→ ¿Podar todo lo no usado de Podman?"; then
        sudo podman system prune -af 2>/dev/null || true
        echo -e "   ${GREEN}[ OK ] Podman podado${RESET}"
    fi

    # ── 8) Logs ──
    if command -v journalctl >/dev/null 2>&1 && confirmar "→ ¿Limitar los logs del sistema a 200 MB?"; then
        sudo journalctl --vacuum-size=200M 2>/dev/null
        sudo journalctl --vacuum-time=30d 2>/dev/null
        echo -e "   ${GREEN}[ OK ] Logs limitados a 200 MB / 30 días${RESET}"
    fi

    # ── 9) /var/log accesibles y logs de apps ──
    if confirmar "→ ¿Vaciar logs antiguos de /var/log (apache, nginx, mysql, etc.)?"; then
        sudo find /var/log -type f \( -name '*.gz' -o -name '*.old' -o -name '*.1' -o -name '*.2' -o -name '*.3' -o -name '*.4' \) -delete 2>/dev/null
        echo -e "   ${GREEN}[ OK ] Logs rotados antiguos eliminados${RESET}"
    fi

    # ── 10) Restos de paquetes (#.pacnew / .pacsave) ──
    if confirmar "→ ¿Gestionar archivos .pacnew/.pacsave (reemplazar o borrar)? [y/N]"; then
        local pacf
        pacf=$(find /etc -type f \( -name '*.pacnew' -o -name '*.pacsave' \) 2>/dev/null | wc -l)
        if (( pacf > 0 )); then
            # Aplicar .pacnew sobre su destino, pero preservando primero la
            # versión actual como .pacsave (rollback posible). Los .pacsave
            # existentes NO se borran a ciegas: se mueven a un backup con fecha.
            sudo find /etc -type f -name '*.pacnew' -exec sh -c '
                b="${1%.pacnew}"
                [ -f "$b" ] && cp -a "$b" "${b}.pacsave" 2>/dev/null
                mv "$1" "$b" 2>/dev/null' _ {} \; 2>/dev/null
            sudo find /etc -type f -name '*.pacsave' -exec sh -c '
                mv "$1" "${1}.bak$(date +%Y%m%d%H%M%S)" 2>/dev/null' _ {} \; 2>/dev/null
            echo -e "   ${GREEN}[ OK ] ${pacf} archivo(s) de configuración gestionados${RESET}"
            echo -e "   ${DIM}   Versiones anteriores conservadas como *.pacsave.bak*${RESET}"
        else
            echo -e "   ${YELLOW}[ WARN ] No hay .pacnew/.pacsave.${RESET}"
        fi
    fi

    # ── 11) Cachés de runtime bajo riesgo ──
    local extras liberado_extra
    extras=(
        "$HOME/.cache/electron" "$HOME/.cache/mesa_shader_cache"
        "$HOME/.cache/node-gyp" "$HOME/.cache/ms-playwright" "$HOME/.cache/huggingface"
        "$HOME/.cache/Yarn" "$HOME/.cache/next" "$HOME/.cache/vite"
        "$HOME/.cache/parcel" "$HOME/.cache/webpack" "$HOME/.cache/deno"
        "$HOME/.cache/esbuild" "$HOME/.cache/torch" "$HOME/.cache/paddle"
        "$HOME/.thumbnail_normal"
    )
    liberado_extra=0
    for c in "${extras[@]}"; do
        [[ -e "$c" ]] && liberado_extra=$((liberado_extra + $(eliminar_y_medir "$c" 0)))
    done
    if (( liberado_extra > 0 )) && confirmar "→ ¿Eliminar cachés de runtime en desuso ($(formatear_bytes "$liberado_extra"))?"; then
        for c in "${extras[@]}"; do
            [[ -e "$c" ]] && rm -rf "$c" 2>/dev/null
        done
        echo -e "   ${GREEN}[ OK ] Cachés de runtime eliminados ($(formatear_bytes "$liberado_extra"))${RESET}"
    elif (( liberado_extra > 0 )); then
        echo -e "   ${DIM}   Cachés de runtime conservados.${RESET}"
    fi

    # ── 12) paccache -ruk0 ──
    if command -v pacman >/dev/null 2>&1 && confirmar "→ ¿Limpiar también los paquetes de la caché ya desinstalados (paccache -ruk0)?"; then
        if command -v paccache >/dev/null 2>&1; then
            sudo paccache -ruk0 2>/dev/null
            echo -e "   ${GREEN}[ OK ] Caché de paquetes desinstalados purgada${RESET}"
        else
            echo -e "   ${YELLOW}[ WARN ] paccache no está instalado (pacman-contrib).${RESET}"
        fi
    fi

    echo ""
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${RESET}"
    echo -e "${GREEN}[ OK ]  Limpieza profunda finalizada${RESET}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${RESET}"
    registrar_ultima_accion "Limpieza profunda"
    pause
}

# ─── 20) Optimización gaming (GPU + memoria + CPU) ─────
# Ajustes específicos para jugar: freezes GPU de rendimiento,
# vm.max_map_count alto (Proton/Vulkan), swappiness baja y
# prioridad de tiempo real opcional. Todo reversible con la opción 30.
optimizar_juegos() {
    clear
    echo -e "${CYAN}${BOLD}╭─ Optimización gaming ─────────────────────────────────────────────╮${RESET}"
    echo -e "${CYAN}│${RESET} GPU en modo máximo, memoria para juegos y CPU sin latencias.${CYAN}"
    echo -e "${CYAN}╰──────────────────────────────────────────────────────────────────╯${RESET}"
    echo ""
    echo -e "${DIM}   Se preguntará antes de aplicar cada ajuste. La opción 30 revierte todo.${RESET}"
    echo ""
    if ! confirmar "¿Deseas aplicar los ajustes gaming ahora?"; then
        echo -e "${YELLOW}Cancelado.${RESET}"
        return
    fi
    echo ""
    KYRO_SYSCTL=()

    local vendor modelo
    vendor=$(detectar_gpu_vendor)
    modelo=$(detectar_gpu_modelo)
    echo -e "${BOLD}▸ GPU detectada:${RESET} ${vendor:-desconocida} ${DIM}(${modelo})${RESET}"
    echo ""

    # ── Memoria: juegos (Proton/Vulkan) piden > 1M mapas de memoria ──
    echo -e "${BOLD}▸ Memoria virtual:${RESET}"
    aplicar_sysctl "vm.max_map_count" "2147483642"
    aplicar_sysctl "vm.swappiness" "5"
    aplicar_sysctl "vm.vfs_cache_pressure" "25"
    aplicar_sysctl "vm.compaction_proactiveness" "0"
    echo ""
    guardar_sysctls "99-kyro-gaming.conf" "${KYRO_SYSCTL[@]}"

    # ── GPU en modo rendimiento ──
    echo -e "${BOLD}▸ GPU (modo rendimiento):${RESET}"
    case "$vendor" in
        amd)
            local dpm_levels=0 cfg
            for dpm in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
                [[ -w "$dpm" ]] || continue
                echo "performance" | sudo tee "$dpm" >/dev/null 2>&1 && dpm_levels=1
            done
            (( dpm_levels == 1 )) && echo -e "   ${GREEN}[ OK ] power_dpm_force_performance_level=performance${RESET}" \
                || echo -e "   ${YELLOW}[ WARN ] sin control DPM de AMD accesible${RESET}"
            # Perfiles de potencia de la VRM si el controlador los expone.
            for cfg in /sys/class/drm/card*/device/power_pp_profile_mode; do
                if [[ -w "$cfg" ]]; then
                    echo "1" | sudo tee "$cfg" >/dev/null 2>&1 && echo -e "   ${GREEN}[ OK ] power_pp_profile_mode=1 (máx. rendimiento)${RESET}"
                fi
            done
            ;;
        nvidia)
            if command -v nvidia-smi >/dev/null 2>&1; then
                sudo nvidia-smi -pm 1 >/dev/null 2>&1 && echo -e "   ${GREEN}[ OK ] Persistence Mode activado (-pm 1)${RESET}" \
                    || echo -e "   ${YELLOW}[ WARN ] nvidia-smi no pudo activar persistence${RESET}"
            else
                echo -e "   ${YELLOW}[ WARN ] nvidia-smi no instalado${RESET}"
            fi
            ;;
        intel)
            echo -e "   ${DIM}Intel integrada: sin perfil GPU manual (usa el gobernador de la bisagra).${RESET}"
            ;;
        *)
            echo -e "   ${YELLOW}[ WARN ] GPU no identificada; se omite el perfil de la GPU.${RESET}"
            ;;
    esac

    if command -v gamemoderun >/dev/null 2>&1; then
        echo -e "   ${GREEN}[ OK ] Feral GameMode detectado: usa 'gamemoderun %command%' en Steam.${RESET}"
    fi
    echo ""

    # ── CPU: gobernador de rendimiento ──
    echo -e "${BOLD}▸ CPU:${RESET}"
    local gov="performance" govok=0 avail=""
    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors ]]; then
        avail=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null)
        if ! echo "$avail" | tr ' ' '\n' | grep -qx "$gov"; then
            gov=$(echo "$avail" | awk '{print $1}')
        fi
    fi
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [[ -f "$g" ]] && echo "$gov" | sudo tee "$g" >/dev/null 2>&1 && govok=1
    done
    [[ "$govok" -eq 1 ]] && echo -e "   ${GREEN}[ OK ] Gobernador CPU: ${gov}${RESET}" || echo -e "   ${YELLOW}[ WARN ] sin cpufreq (se omite)${RESET}"

    # kernel.game_mode (parche GameMode de Feral/CachyOS) si está expuesto.
    if [[ -f /proc/sys/kernel/game_mode ]]; then
        aplicar_sysctl "kernel.game_mode" "1"
    fi

    # Prioridad en tiempo real para audio/juegos (opcional y reversible).
    if confirmar "  → ¿Habilitar tiempo real sin límite (kernel.sched_rt_runtime_us=-1)? (mejor latencia, uso experto)"; then
        aplicar_sysctl "kernel.sched_rt_runtime_us" "-1"
        guardar_sysctls "99-kyro-gaming.conf" "${KYRO_SYSCTL[@]}"
    fi
    echo ""

    # ── Planificador de E/S en todos los discos (NVMe→none, SSD→mq-deadline) ──
    echo -e "${BOLD}▸ Planificadores de E/S:${RESET}"
    local q rec sched_ok=0
    rec=$(cat "/sys/block/$(detectar_dispositivo_base)/queue/rotational" 2>/dev/null)
    if [[ "$(detectar_dispositivo_base)" == nvme* ]]; then rec="none"
    elif [[ "$rec" == "0" ]]; then rec="mq-deadline"
    else rec="bfq"; fi
    for q in /sys/block/*/queue/scheduler; do
        [[ -f "$q" ]] || continue
        if echo "$(cat "$q" 2>/dev/null)" | tr ' ' '\n' | sed 's/\[//;s/\]//' | grep -qx "$rec"; then
            echo "$rec" | sudo tee "$q" >/dev/null 2>&1 && sched_ok=1
        fi
    done
    [[ "$sched_ok" -eq 1 ]] && echo -e "   ${GREEN}[ OK ] Scheduler: ${rec} en todos los discos${RESET}" || echo -e "   ${YELLOW}[ WARN ] sin discos ajustables${RESET}"
    echo ""

    # ── Steam: limpieza de shader caches (se regeneran solos) ──
    echo -e "${BOLD}▸ Steam:${RESET}"
    local steam_base="$HOME/.local/share/Steam"
    [[ -d "$HOME/.local/share/steam" ]] && steam_base="$HOME/.local/share/steam"
    if [[ -d "$steam_base/steamapps/shadercache" ]]; then
        local sc_size
        sc_size=$(tamano_de "$steam_base/steamapps/shadercache")
        if (( sc_size > 0 )); then
            echo -e "   ${DIM}Caché de shaders (Vulkan/DX/GL): $(formatear_bytes "$sc_size")${RESET}"
            if confirmar "  → ¿Borrar la caché de shaders? (Steam la recompila según la necesidad)"; then
                eliminar_y_medir "$steam_base/steamapps/shadercache" 1
            fi
        else
            echo -e "   ${DIM}Sin caché de shaders que limpiar.${RESET}"
        fi
    else
        echo -e "   ${DIM}Steam no detectado en la ubicación estándar.${RESET}"
    fi

    # ── Config de GameMode (mejora sencilla y muy segura) ──
    if command -v gamemoderun >/dev/null 2>&1; then
        if [[ ! -f "$HOME/.config/gamemode.ini" ]]; then
            if confirmar "  → ¿Crear ~/.config/gamemode.ini con un perfil de rendimiento?"; then
                mkdir -p "$HOME/.config" 2>/dev/null
                cat > "$HOME/.config/gamemode.ini" <<EOF
[general]
renice=10
wine_fshack=off
softrealtime=auto

[gpu]
apply_gpu_optimisations=accept-responsibility
apply_cpu_optimisations=accept-responsibility

[custom]
start=notify-send "GameMode activado"
end=notify-send "GameMode desactivado"
EOF
                echo -e "   ${GREEN}[ OK ] gamemode.ini creado (usa 'gamemoderun %command%' en Steam)${RESET}"
            fi
        else
            echo -e "   ${DIM}gamemode.ini ya existe; no se modifica nada.${RESET}"
        fi
    fi

    # ── Latencia extra (opcional, reversible) ──
    if confirmar "  → ¿Reducir interrupciones de watchdog (kernel.nmi_watchdog=0) para menos stutter? [y/N]"; then
        aplicar_sysctl "kernel.nmi_watchdog" "0"
        guardar_sysctls "99-kyro-gaming.conf" "${KYRO_SYSCTL[@]}"
    fi
    echo ""

    # ── Persistencia (script + servicio) ──
    if confirmar "  → ¿Guardar GPU/CPU en un servicio para que apliquen en cada arranque?"; then
        persistir_juegos "$gov" "$rec" "$vendor"
    fi

    registrar_ultima_accion "Optimización gaming (GPU=$vendor, gov=$gov)"
    echo ""
    echo -e "${GREEN}[ OK ] Optimización gaming finalizada${RESET}"
    pause
}

# Servicio systemd que reaplica GPU y gobernador en cada arranque (gaming).
persistir_juegos() {
    local gov="$1" sched="$2" vendor="$3"
    local bin="/usr/local/bin/kyro-game-apply.sh"
    local svc="/etc/systemd/system/kyro-game.service"
    local tmpbin
    tmpbin=$(crear_temporal)

    cat > "$tmpbin" <<EOF
#!/bin/bash
# Generado por Kyro (optimización gaming). No editar a mano.
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -w "\$g" ] && echo "$gov" > "\$g" 2>/dev/null
done
for q in /sys/block/*/queue/scheduler; do
    if grep -q "$sched" "\$q" 2>/dev/null; then
        [ -w "\$q" ] && echo "$sched" > "\$q" 2>/dev/null
    fi
done
case "$vendor" in
    amd)
        for d in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
            [ -w "\$d" ] && echo performance > "\$d" 2>/dev/null
        done
        ;;
    nvidia)
        command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -pm 1 >/dev/null 2>&1
        ;;
esac
exit 0
EOF
    if sudo install -m 755 "$tmpbin" "$bin" >/dev/null 2>&1; then
        sudo tee "$svc" >/dev/null <<EOF
[Unit]
Description=Ajustes gaming de Kyro
After=multi-user.target

[Service]
Type=oneshot
ExecStart=$bin

[Install]
WantedBy=multi-user.target
EOF
        sudo systemctl daemon-reload >/dev/null 2>&1
        if sudo systemctl enable --now kyro-game.service >/dev/null 2>&1; then
            echo -e "   ${GREEN}[ OK ] Servicio kyro-game activado (persistente)${RESET}"
        else
            echo -e "   ${YELLOW}[ WARN ] Script guardado, pero no se pudo activar el servicio.${RESET}"
        fi
        rm -f "$tmpbin"
        return 0
    fi
    rm -f "$tmpbin"
    echo -e "   ${RED}[ ERROR ] No se pudo escribir el script persistente (¿sudo?).${RESET}"
    return 1
}

# ─── 21) Mantenimiento de Steam (shaders + compatdata huérfano) ──
# Nunca borra juegos (steamapps/common). Solo cachés regenerables y
# prefijos de compatibilidad (Proton) de juegos que ya no están instalados.
limpiar_steam() {
    clear
    echo -e "${CYAN}${BOLD}╭─ Mantenimiento de Steam ────────────────────────────────────╮${RESET}"
    echo -e "${CYAN}│${RESET} Shader caches y prefijos Proton huérfanos (seguro y reversible).${CYAN}"
    echo -e "${CYAN}╰──────────────────────────────────────────────────────────────────╯${RESET}"
    echo ""

    local steam_base="$HOME/.local/share/Steam"
    [[ -d "$HOME/.local/share/steam" ]] && steam_base="$HOME/.local/share/steam"
    if [[ ! -d "$steam_base" ]]; then
        echo -e "${YELLOW}No se encontró Steam en la ubicación estándar (~/.local/share/Steam).${RESET}"
        echo -e "${DIM}   Si es Flatpak, usa: flatpak run com.valvesoftware.Steam${RESET}"
        pause
        return
    fi

    local liberado=0

    # ── 1) Caché de shaders (Vulkan/DX/GL): Steam la regenera sola ──
    if [[ -d "$steam_base/steamapps/shadercache" ]]; then
        local sc_size
        sc_size=$(tamano_de "$steam_base/steamapps/shadercache")
        if (( sc_size > 0 )); then
            echo -e "${BOLD}▸ Caché de shaders:${RESET} $(formatear_bytes "$sc_size")"
            if confirmar "  → ¿Borrar la caché de shaders? (la primera partida recompilará)"; then
                liberado=$((liberado + $(eliminar_y_medir "$steam_base/steamapps/shadercache" 1)))
            fi
        else
            echo -e "${DIM}▸ Caché de shaders vacía.${RESET}"
        fi
    fi

    # ── 2) Descargas/residuos temporales ──
    if confirmar "  → ¿Limpiar directorios temporales de Steam (downloads/temp/patch)?"; then
        # Vacía el contenido de descargas interrumpidas y temporales (nunca apps).
        for _st in "$steam_base/steamapps/downloading" "$steam_base/steamapps/temp" "$steam_base/steamapps/patch"; do
            [[ -d "$_st" ]] && [[ -n "$(ls -A "$_st" 2>/dev/null)" ]] && liberado=$((liberado + $(eliminar_y_medir "$_st" 1)))
            [[ -d "$_st" ]] && rmdir "$_st" 2>/dev/null
        done
    fi

    # ── 3) Prefijos Proton (compatdata) de juegos ya no instalados ──
    echo -e "${BOLD}▸ Prefijos Proton huérfanos:${RESET}"
    local compat_dirs=() cd_path cd_host
    mapfile -d $'\n' compat_dirs < <(find "$steam_base" -type d -name compatdata 2>/dev/null)
    local huerfanos=0
    for cd_path in "${compat_dirs[@]:-}"; do
        cd_path=$(echo "$cd_path" | tr -d '\n')
        [[ -z "$cd_path" ]] || [[ ! -d "$cd_path" ]] && continue
        local appid archivo
        cd_host=$(dirname "$cd_path")
        for appid in "$cd_path"/*/; do
            [[ -d "$appid" ]] || continue
            appid=$(basename "$appid")
            [[ "$appid" =~ ^[0-9]+$ ]] || continue
            archivo="$cd_host/appmanifest_${appid}.acf"
            if [[ ! -f "$archivo" ]]; then
                local tam
                tam=$(tamano_de "$cd_path/$appid")
                if (( tam > 0 )); then
                    huerfanos=$((huerfanos + 1))
                    echo -e "   ${CYAN}${huerfanos})${RESET} ${DIM}appid ${appid}${RESET}  $(formatear_bytes "$tam")  $(truncate_path "$cd_path/$appid")"
                fi
            fi
        done
    done
    if (( huerfanos == 0 )); then
        echo -e "   ${GREEN}[ OK ] Sin prefijos Proton huérfanos.${RESET}"
    else
        local hsel otro
        echo ""
        read -rp "Prefijos a enviar a la papelera (p.ej. \"1 2\") o Enter para saltar: " hsel || hsel=""
        local hidx=0 app_id
        for cd_path in "${compat_dirs[@]:-}"; do
            cd_path=$(echo "$cd_path" | tr -d '\n')
            [[ -z "$cd_path" ]] && continue
            cd_host=$(dirname "$cd_path")
            for appid in "$cd_path"/*/; do
                [[ -d "$appid" ]] || continue
                appid=$(basename "$appid")
                [[ "$appid" =~ ^[0-9]+$ ]] || continue
                [[ -f "$cd_host/appmanifest_${appid}.acf" ]] && continue
                hidx=$((hidx + 1))
                for otro in $hsel; do
                    if [[ "$otro" == "$hidx" ]]; then
                        if mover_a_papelera "$cd_path/$appid" 2>/dev/null; then
                            echo -e "   ${GREEN}[ OK ] Enviado a la papelera (appid ${appid})${RESET}"
                        elif confirmar "    → No se pudo mover ${appid} a la papelera. ¿Borrar definitivamente?"; then
                            liberado=$((liberado + $(eliminar_y_medir "$cd_path/$appid" 1)))
                        fi
                        break
                    fi
                done
            done
        done
    fi

    echo ""
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${RESET}"
    echo -e "${GREEN}[ OK ]  Mantenimiento de Steam completado${RESET}  ${DIM}($(formatear_bytes "$liberado") liberados)${RESET}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${RESET}"
    registrar_ultima_accion "Mantenimiento de Steam ($(formatear_bytes "$liberado"))"
    pause
}

# ─── 30) Restaurar ajustes de Kyro (rollback) ─────────
restaurar_optimizacion() {
    clear
    echo -e "${CYAN}${BOLD}╭─ Restaurar ajustes de Kyro ──────────────────────────────────────╮${RESET}"
    echo -e "${CYAN}│${RESET} Elimina servicios y sysctl de Kyro y vuelve a los valores de fábrica.${CYAN}"
    echo -e "${CYAN}╰──────────────────────────────────────────────────────────────────╯${RESET}"
    echo ""
    if ! confirmar "¿Deseas restaurar por completo los ajustes de Kyro?"; then
        echo -e "${YELLOW}Cancelado.${RESET}"
        return
    fi
    echo ""

    # 1) Detiene y elimina los servicios de ajustes.
    local svc
    for svc in kyro-perf kyro-quick kyro-game kyro-net; do
        sudo systemctl stop "$svc.service" 2>/dev/null
        sudo systemctl disable "$svc.service" 2>/dev/null
        sudo rm -f "/etc/systemd/system/$svc.service" 2>/dev/null
    done
    sudo systemctl daemon-reload 2>/dev/null
    echo -e "${GREEN}[ OK ] Servicios de Kyro detenidos y eliminados${RESET}"

    # 2) Borra los archivos sysctl y scripts de Kyro.
    sudo rm -f /etc/sysctl.d/99-kyro-optimizer.conf /etc/sysctl.d/99-kyro-network.conf /etc/sysctl.d/99-kyro-gaming.conf 2>/dev/null
    sudo rm -f /usr/local/bin/kyro-perf-apply.sh /usr/local/bin/kyro-quick-apply.sh /usr/local/bin/kyro-game-apply.sh /usr/local/bin/kyro-net-qdisc.sh 2>/dev/null
    echo -e "${GREEN}[ OK ] Configuración sysctl de Kyro eliminada${RESET}"

    # 3) Devuelve los qdisc de red al que eligió el sistema.
    if command -v tc >/dev/null 2>&1; then
        local qi qif
        for qi in /sys/class/net/*; do
            qif=$(basename "$qi")
            [[ "$qif" == "lo" ]] && continue
            sudo tc qdisc del dev "$qif" root 2>/dev/null
        done
        echo -e "${GREEN}[ OK ] Qdisc de red restaurados${RESET}"
    fi

    # 4) Restaura los valores por defecto del kernel (solo si están activos).
    echo -e "${BOLD}▸ Restaurando valores por defecto del kernel:${RESET}"
    local dflt="vm.swappiness=60 vm.vfs_cache_pressure=100 vm.dirty_ratio=20 vm.dirty_background_ratio=10 vm.page-cluster=3 vm.compaction_proactiveness=20 vm.max_map_count=65530"
    local d
    for d in $dflt; do
        if sudo sysctl -w "$d" >/dev/null 2>&1; then
            echo -e "   ${GREEN}[ OK ]${RESET} $d"
        fi
    done

    echo ""
    # 5) Swap creado por Kyro (opcional quitar).
    local sfile=""
    [[ -f /swapfile_kyro ]] && sfile="/swapfile_kyro"
    [[ -f /swap.kyro ]] && sfile="/swap.kyro"
    if [[ -n "$sfile" ]] && confirmar "→ El archivo de swap ${sfile} fue creado por Kyro. ¿Eliminarlo y quitarlo del fstab?"; then
        sudo swapoff "$sfile" 2>/dev/null || true
        sudo sed -i "\|${sfile}|d" /etc/fstab 2>/dev/null
        sudo rm -f "$sfile" 2>/dev/null
        sudo systemctl daemon-reload 2>/dev/null
        echo -e "   ${GREEN}[ OK ] Swap de Kyro eliminado${RESET}"
    fi

    echo ""
    echo -e "${GREEN}[ OK ] Ajustes de Kyro restaurados a los valores de fábrica${RESET}"
    registrar_ultima_accion "Restauración de ajustes de Kyro"
    pause
}

# ═══════════════════════════════════════════════════════
#  ESTABILIDAD DEL SISTEMA
# ═══════════════════════════════════════════════════════

# 26) Estabilizador del sistema: detecta y repara problemas comunes de
# estabilidad sin tocar configuración del usuario. Todo se confirma antes.
estabilizador() {
    clear
    echo -e "${CYAN}${BOLD}╭─ Estabilizador del sistema ──────────────────────────────────╮${RESET}"
    echo -e "${CYAN}│${RESET} Detecta y corrige problemas comunes de estabilidad.${CYAN}"
    echo -e "${CYAN}╰──────────────────────────────────────────────────────────────────╯${RESET}"
    echo ""
    echo -e "${DIM}   Se comprobará cada área y solo se modificará lo que tú confirmes.${RESET}"
    echo ""

    if ! confirmar "¿Comenzar el diagnóstico y reparación?"; then
        echo -e "${YELLOW}Cancelado.${RESET}"
        pause
        return
    fi
    if ! check_sudo; then
        pause
        return
    fi

    local pkg
    pkg=$(detectar_pkg_manager)

    # ── 1) Integridad de la base de datos de paquetes ──
    echo -e "${BOLD}▸ 1) Integridad de paquetes${RESET}"
    case "$pkg" in
        pacman)
            if sudo pacman -Dk 2>/dev/null | grep -iE 'error|unresolvable|missing'; then
                echo -e "   ${YELLOW}[ WARN ] La base de datos tiene inconsistencia.${RESET}"
                if confirmar "  → ¿Reconstruir la base de datos (pacman -Dk / refresh)?"; then
                    sudo pacman -Syy 2>/dev/null
                    echo -e "   ${GREEN}[ OK ] Base de datos refrescada.${RESET}"
                fi
            else
                echo -e "   ${GREEN}[ OK ] Base de datos de paquetes correcta.${RESET}"
            fi
            ;;
        apt)
            if sudo dpkg --audit 2>/dev/null | grep -iE 'error|inconsistent|missing'; then
                echo -e "   ${YELLOW}[ WARN ] dpkg tiene paquetes inconsistentes.${RESET}"
                if confirmar "  → ¿Intentar reparar (dpkg --configure -a)?"; then
                    sudo dpkg --configure -a 2>/dev/null
                    echo -e "   ${GREEN}[ OK ] dpkg reparado.${RESET}"
                fi
            else
                echo -e "   ${GREEN}[ OK ] Base de datos de paquetes correcta.${RESET}"
            fi
            ;;
        *)  echo -e "   ${DIM}   Gestor no soportado, se omite.${RESET}" ;;
    esac

    # ── 2) Journal de systemd (corrupción/reglas de vaciado) ──
    echo -e "${BOLD}▸ 2) Journal de systemd${RESET}"
    if command -v journalctl >/dev/null 2>&1; then
        if sudo journalctl --verify 2>/dev/null | grep -iE 'fail|error' | grep -v 'no errors'; then
            echo -e "   ${YELLOW}[ WARN ] El journal presenta errores.${RESET}"
            if confirmar "  → ¿Rotar y conservar solo 200 MB (descarta corruptos)?"; then
                sudo journalctl --rotate 2>/dev/null
                sudo journalctl --vacuum-size=200M 2>/dev/null
                echo -e "   ${GREEN}[ OK ] Journal rotado y saneado.${RESET}"
            fi
        else
            echo -e "   ${GREEN}[ OK ] Journal íntegro.${RESET}"
        fi
        # Asegura límites de crecimiento del journal (evita llenar disco).
        if ! grep -q 'SystemMaxUse' /etc/systemd/journald.conf 2>/dev/null; then
            if confirmar "  → ¿Limitar el journal a 300 MB (evita discos llenos)?"; then
                echo -e "SystemMaxUse=300M\nSystemKeepFree=100M" | sudo tee -a /etc/systemd/journald.conf >/dev/null 2>&1
                sudo systemctl restart systemd-journald 2>/dev/null || sudo journalctl --flush 2>/dev/null
                echo -e "   ${GREEN}[ OK ] Journal limitado a 300 MB.${RESET}"
            fi
        else
            echo -e "   ${GREEN}[ OK ] Journal ya limitado.${RESET}"
        fi
    else
        echo -e "   ${DIM}   journalctl no disponible.${RESET}"
    fi

    # ── 3) Servicios systemd fallidos ──
    echo -e "${BOLD}▸ 3) Servicios systemd fallidos${RESET}"
    local fallidos
    fallidos=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}')
    if [[ -n "$fallidos" ]]; then
        echo -e "   ${YELLOW}[ WARN ] Servicios fallidos:${RESET}"
        echo "$fallidos" | sed 's/^/      - /'
        if confirmar "  → ¿Intentar reiniciarlos?"; then
            local svc
            for svc in $fallidos; do
                sudo systemctl restart "$svc" 2>/dev/null && echo -e "      ${GREEN}[ OK ] ${svc} reiniciado${RESET}" || echo -e "      ${YELLOW}[ WARN ] ${svc} sigue fallando${RESET}"
            done
        fi
    else
        echo -e "   ${GREEN}[ OK ] Sin servicios fallidos.${RESET}"
    fi

    # ── 4) Sistema de archivos (correcciones menores) ──
    echo -e "${BOLD}▸ 4) Sistema de archivos${RESET}"
    local root_fs
    root_fs=$(findmnt -no FSTYPE / 2>/dev/null)
    case "$root_fs" in
        ext4|ext3)
            echo -e "   ${DIM}   Unidad: /dev/$(detectar_dispositivo_base) (${root_fs}).${RESET}"
            if confirmar "  → ¿Marca la unidad para revisión en el próximo arranque (fsck)? [y/N]"; then
                sudo touch /forcefsck 2>/dev/null && echo -e "   ${GREEN}[ OK ] Revisión programada en el próximo arranque.${RESET}"
            fi
            ;;
        btrfs)
            if confirmar "  → ¿Ejecutar 'scrub' (verifica/regenera redundancia)?"; then
                sudo btrfs scrub start / 2>/dev/null && echo -e "   ${GREEN}[ OK ] Scrub de btrfs iniciado.${RESET}"
            fi
            ;;
        *)  echo -e "   ${DIM}   Sistema '${root_fs:-desconocido}': no se requieren acciones.${RESET}" ;;
    esac

    # ── 5) Particiones montadas correctamente ──
    echo -e "${BOLD}▸ 5) Tabla de particiones / fstab${RESET}"
    if command -v mount >/dev/null 2>&1; then
        local montaje_ok
        montaje_ok=$(sudo findmnt --verify --verbose 2>/dev/null | grep -c 'Successfully verified' || true)
        if (( montaje_ok > 0 )); then
            echo -e "   ${GREEN}[ OK ] /etc/fstab correcto.${RESET}"
        else
            echo -e "   ${YELLOW}[ WARN ] No se pudo verificar completamente; revisa con 'findmnt --verify'.${RESET}"
        fi
    fi

    # ── 6) Archivos .pacnew/.pacsave ──
    echo -e "${BOLD}▸ 6) Configuraciones pendientes (.pacnew/.pacsave)${RESET}"
    local pacn pacs
    pacn=$(find /etc -type f -name '*.pacnew' 2>/dev/null | wc -l)
    pacs=$(find /etc -type f -name '*.pacsave' 2>/dev/null | wc -l)
    echo -e "   ${DIM}   .pacnew: ${pacn} · .pacsave: ${pacs}${RESET}"
    if (( pacn > 0 )) && confirmar "  → ¿Aplicar los .pacnew pendientes (conservando backups .pacsave)?"; then
        # Aplica .pacnew sobre su destino preservando la versión actual
        # como .pacsave (rollback posible); NO borra .pacsave existentes.
        sudo find /etc -type f -name '*.pacnew' -exec sh -c '
            b="${1%.pacnew}"
            [ -f "$b" ] && cp -a "$b" "${b}.pacsave" 2>/dev/null
            mv "$1" "$b" 2>/dev/null' _ {} \; 2>/dev/null
        echo -e "   ${GREEN}[ OK ] Configuraciones actualizadas (backups .pacsave conservados).${RESET}"
    fi

    # ── 7) Variables de entorno del sistema (locale) ──
    echo -e "${BOLD}▸ 7) Locale del sistema${RESET}"
    if locale -a 2>/dev/null | grep -qi "$LANG" 2>/dev/null; then
        echo -e "   ${GREEN}[ OK ] Locale configurado (${LANG:-n/d}).${RESET}"
    else
        echo -e "   ${YELLOW}[ WARN ] El locale ${LANG:-n/d} no está generado.${RESET}"
        if confirmar "  → ¿Generar los locales activos?"; then
            sudo locale-gen 2>/dev/null && echo -e "   ${GREEN}[ OK ] Locales regenerados.${RESET}"
        fi
    fi

    # ── 8) Firewall activo ──
    echo -e "${BOLD}▸ 8) Cortafuegos${RESET}"
    if command -v firewall-cmd >/dev/null 2>&1; then
        if systemctl is-active --quiet firewalld; then
            echo -e "   ${GREEN}[ OK ] firewalld activo.${RESET}"
        else
            echo -e "   ${YELLOW}[ WARN ] firewalld instalado pero inactivo.${RESET}"
            if confirmar "  → ¿Activar firewalld?"; then
                sudo systemctl enable --now firewalld 2>/dev/null && echo -e "   ${GREEN}[ OK ] firewalld activado.${RESET}"
            fi
        fi
    elif command -v ufw >/dev/null 2>&1; then
        if sudo ufw status 2>/dev/null | grep -q 'Status: active'; then
            echo -e "   ${GREEN}[ OK ] ufw activo.${RESET}"
        else
            echo -e "   ${YELLOW}[ WARN ] ufw instalado pero inactivo.${RESET}"
            if confirmar "  → ¿Activar ufw?"; then
                sudo ufw enable 2>/dev/null && echo -e "   ${GREEN}[ OK ] ufw activado.${RESET}"
            fi
        fi
    else
        echo -e "   ${DIM}   Sin cortafuegos detectado (opcional).${RESET}"
    fi

    echo ""
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${RESET}"
    echo -e "${GREEN}[ OK ]  Estabilizador finalizado${RESET}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${RESET}"
    registrar_ultima_accion "Estabilizador del sistema"
    pause
}

# 27) Reparador de paquetes (reinstala archivos perdidos/corruptos).
reparar_paquetes() {
    clear
    echo -e "${CYAN}${BOLD}╭─ Reparador de paquetes ───────────────────────────────────────╮${RESET}"
    echo -e "${CYAN}│${RESET} Reinstala archivos de paquetes faltantes o dañados.${CYAN}"
    echo -e "${CYAN}╰──────────────────────────────────────────────────────────────────╯${RESET}"
    echo ""
    if ! check_sudo; then
        pause
        return
    fi
    local pkg
    pkg=$(detectar_pkg_manager)

    case "$pkg" in
        pacman)
            echo -e "${DIM}   Verificando integridad de todos los paquetes...${RESET}"
            local tmp afuera malos
            tmp=$(crear_temporal)
            # Igual patrón que corrupcion(): busca "N missing files" o
            # "N archivos no encontrados" con N > 0 (pacman -Qk devuelve 1)
            # ante warnings de permisos, así que la salida decide.
            spinner "pacman -Qk (verificación)" bash -c \
                "sudo pacman -Qk 2>/dev/null | grep -E '[1-9][0-9]* (missing files|archivos no encontrados)' > \"$tmp\""
            afuera=$(wc -l < "$tmp" 2>/dev/null || echo 0)
            if (( afuera > 0 )); then
                echo -e "   ${YELLOW}[ WARN ] ${afuera} paquete(s) con problemas detectados.${RESET}"
                sed 's/^/      /' "$tmp" | head -20
                if confirmar "  → ¿Reinstalar esos paquetes?"; then
                    local -a lista=()
                    mapfile -t lista < <(awk -F': ' '{print $1}' "$tmp" | sort -u)
                    if (( ${#lista[@]} > 0 )); then
                        spinner "Reinstalando paquetes dañados" sudo pacman -S --noconfirm "${lista[@]}" || true
                    fi
                fi
            else
                echo -e "   ${GREEN}[ OK ] Ningún paquete con archivos faltantes.${RESET}"
            fi
            rm -f "$tmp"
            ;;
        apt)
            echo -e "${DIM}   Reinstalando paquetes rotos (dpkg)...${RESET}"
            if confirmar "  → ¿Reconfigurar paquetes incompletos (dpkg --configure -a)?"; then
                sudo dpkg --configure -a 2>/dev/null
                spinner "Corrigiendo dependencias (apt -f install)" sudo apt-get -y -f install 2>/dev/null
                echo -e "   ${GREEN}[ OK ] Reparación completada.${RESET}"
            fi
            ;;
        *)
            echo -e "${RED}Reparador no disponible para este gestor.${RESET}"
            ;;
    esac
    registrar_ultima_accion "Reparador de paquetes"
    pause
}

# 28) Diagnóstico completo de estabilidad: lectura de SMART, errores de E/S,
# swap, temperatura y estado de servicios en un solo informe.
diagnostico_estabilidad() {
    clear
    echo -e "${CYAN}${BOLD}╭─ Diagnóstico integral de estabilidad ──────────────────────────╮${RESET}"
    echo -e "${CYAN}│${RESET} S.M.A.R.T. · E/S · swap · temperatura · servicios · updates${CYAN}"
    echo -e "${CYAN}╰──────────────────────────────────────────────────────────────────╯${RESET}"
    echo ""

    echo -e "${BOLD}▸ Discos (S.M.A.R.T.):${RESET}"
    local dn smartl=""
    if command -v smartctl >/dev/null 2>&1; then
        while IFS= read -r dn; do
            [[ -n "$dn" ]] || continue
            [[ -e "/dev/$dn" ]] || continue
            local linea
            linea=$(sudo smartctl -H "/dev/$dn" 2>/dev/null | grep 'SMART overall-health')
            echo -e "   /dev/${dn}: ${linea:-sin datos}"
            smartl="${smartl}${linea} "
        done < <(lsblk -dno NAME 2>/dev/null | grep -E '^(sd[a-z]|nvme[0-9]n[0-9]+|mmcblk[0-9]+)$')
        [[ -z "$smartl" ]] && echo -e "   ${DIM}   smartmontools presente pero sin discos compatibles.${RESET}"
    else
        echo -e "   ${YELLOW}[ WARN ] smartmontools no instalado (sudo pacman -S smartmontools).${RESET}"
    fi

    echo -e "${BOLD}▸ Errores de E/S y kernel (14 días):${RESET}"
    if command -v journalctl >/dev/null 2>&1; then
        local io_err
        io_err=$(journalctl -k --since "-14 days" -o cat 2>/dev/null | grep -icE 'I/O error|blk_update_request|Buffer I/O|READ FPDMA' || true)
        local kern_err
        kern_err=$(journalctl -k -p err --since "-14 days" -o cat 2>/dev/null | wc -l)
        echo -e "   ${DIM}   Errores de E/S de disco: ${io_err} · Errores de kernel (err): ${kern_err}${RESET}"
    else
        echo -e "   ${DIM}   journalctl no disponible.${RESET}"
    fi

    echo -e "${BOLD}▸ Swap:${RESET}"
    local swap_total swap_zram usada swap_pct
    read -r swap_total swap_zram _ <<< "$(info_swap)"
    swap_total=${swap_total:-0}
    usada=$(free -m 2>/dev/null | awk '/^Swap:/{print $3}')
    usada=${usada:-0}
    if (( swap_total > 0 )); then
        swap_pct=$((usada * 100 / swap_total))
    else
        swap_pct=0
    fi
    echo -e "   ${DIM}   Total: ${swap_total} MB · En uso: ${usada} MB (${swap_pct}%) · zram: $([ "${swap_zram:-0}" -eq 1 ] && echo Sí || echo No)${RESET}"

    echo -e "${BOLD}▸ Temperatura:${RESET}"
    local tempv=0 tempc
    if command -v sensors >/dev/null 2>&1; then
        tempc=$(sensors 2>/dev/null | grep -m1 -oE '[0-9]+\.[0-9]+°C' | grep -oE '^[0-9]+' | head -1)
        [[ -n "$tempc" ]] && tempv=$tempc
    elif compgen -G "/sys/class/thermal/thermal_zone*/temp" >/dev/null; then
        local tz tv
        for tz in /sys/class/thermal/thermal_zone*/temp; do
            tv=$(cat "$tz" 2>/dev/null)
            (( tv > tempv )) && tempv=$((tv / 1000))
        done
    fi
    echo -e "   ${DIM}   Máxima registrada: ${tempv:-0}°C${RESET}"

    echo -e "${BOLD}▸ Servicios fallidos:${RESET}"
    local fall
    fall=$(systemctl --failed --no-legend --plain 2>/dev/null | wc -l)
    echo -e "   ${DIM}   ${fall:-0} servicio(s) fallido(s)${RESET}"

    echo -e "${BOLD}▸ Actualizaciones pendientes:${RESET}"
    case "$(detectar_pkg_manager)" in
        pacman) echo -e "   ${DIM}   $(pacman -Qu 2>/dev/null | wc -l) paquete(s) con actualización disponible${RESET}" ;;
        *)      echo -e "   ${DIM}   n/d${RESET}" ;;
    esac

    echo ""
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${RESET}"
    echo -e "${GREEN}[ OK ]  Diagnóstico finalizado${RESET}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${RESET}"
    registrar_ultima_accion "Diagnóstico integral de estabilidad"
    pause
}

# ═══════════════════════════════════════════════════════
#  MÓDULOS NUEVOS: SISTEMA DE ARCHIVOS, ARRANQUE, SEGURIDAD,
#  MANTENIMIENTO AVANZADO DE PAQUETES
# ═══════════════════════════════════════════════════════

# ─── 22) Módulo de sistema de archivos ─────────────────
# fstrim (TRIM) en SSD, estado de btrfs/ext4, snapshots y salud.
modulo_filesystem() {
    clear
    echo -e "${CYAN}${BOLD}╭─ Sistema de archivos ────────────────────────────────────────╮${RESET}"
    echo -e "${CYAN}│${RESET} TRIM, btrfs/ext4, snapshots y salud del almacenamiento.${CYAN}"
    echo -e "${CYAN}╰──────────────────────────────────────────────────────────────────╯${RESET}"
    echo ""

    local root_fs home_fs base_dev rot
    root_fs=$(tipo_fs_de /)
    home_fs=$(tipo_fs_de "$HOME")
    base_dev=$(detectar_dispositivo_base)
    rot=$(cat "/sys/block/$base_dev/queue/rotational" 2>/dev/null || echo "?")

    echo -e "${BOLD}▸ Sistema de archivos:${RESET}"
    echo -e "   ${DIM}Raíz:${RESET} ${root_fs:-?}  ·  HOME: ${home_fs:-?}  ·  Dispositivo: /dev/${base_dev}"
    local tipo="Desconocido"
    [[ "$rot" == "0" ]] && tipo="SSD"
    [[ "$rot" == "1" ]] && tipo="HDD"
    [[ "$base_dev" == nvme* ]] && tipo="SSD (NVMe)"
    echo -e "   ${DIM}Tipo de almacenamiento:${RESET} ${tipo}"

    # ── TRIM (SSD) ──
    if [[ "$base_dev" == nvme* ]] || [[ "$rot" == "0" ]]; then
        echo ""
        echo -e "${BOLD}▸ TRIM (SSD):${RESET}"
        if command -v fstrim >/dev/null 2>&1; then
            if systemctl is-enabled fstrim.timer >/dev/null 2>&1; then
                echo -e "   ${GREEN}[ OK ] fstrim.timer activo (TRIM semanal automático)${RESET}"
            else
                echo -e "   ${YELLOW}[ WARN ] fstrim.timer desactivado.${RESET}"
                if confirmar "  → ¿Activar el TRIM automático semanal (fstrim.timer)?"; then
                    if check_sudo && sudo systemctl enable --now fstrim.timer 2>/dev/null; then
                        echo -e "   ${GREEN}[ OK ] TRIM automático activado${RESET}"
                    else
                        echo -e "   ${YELLOW}[ WARN ] No se pudo activar.${RESET}"
                    fi
                fi
            fi
            if confirmar "  → ¿Ejecutar TRIM manual ahora (fstrim -av)?"; then
                if check_sudo; then
                    spinner "Ejecutando TRIM" sudo fstrim -av
                    echo -e "   ${GREEN}[ OK ] TRIM completado${RESET}"
                fi
            fi
        else
            echo -e "   ${YELLOW}fstrim no está disponible en este sistema.${RESET}"
        fi
    fi

    # ── btrfs ──
    if [[ "$root_fs" == "btrfs" ]] && command -v btrfs >/dev/null 2>&1; then
        echo ""
        echo -e "${BOLD}▸ btrfs:${RESET}"
        local btrfs_uso
        btrfs_uso=$(btrfs filesystem usage -b / 2>/dev/null | grep 'Device size' | head -1 | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/) print $i}')
        [[ -n "$btrfs_uso" ]] && echo -e "   ${DIM}Uso de datos:${RESET} $(formatear_bytes "$btrfs_uso")"
        if confirmar "  → ¿Ver el estado del 'scrub' (verificación de datos)?"; then
            sudo btrfs scrub status / 2>/dev/null || echo -e "   ${DIM}Sin scrub previo.${RESET}"
        fi
        if confirmar "  → ¿Iniciar un 'scrub' ahora? (verifica integridad; leerá todo el disco)"; then
            spinner "Scrub de btrfs (iniciado)" sudo btrfs scrub start /
            echo -e "   ${GREEN}[ OK ] Scrub iniciado; sigue su estado con 'btrfs scrub status /'${RESET}"
        fi
        if confirmar "  → ¿Comprobar si hay un 'balance' en curso?"; then
            sudo btrfs balance status / 2>/dev/null
        fi
    fi

    # ── ext4 ──
    if [[ "$root_fs" == "ext4" ]] && command -v tune2fs >/dev/null 2>&1; then
        echo ""
        echo -e "${BOLD}▸ ext4:${RESET}"
        local dev_fs
        dev_fs=$(findmnt -no SOURCE / 2>/dev/null)
        sudo tune2fs -l "$dev_fs" 2>/dev/null | grep -E 'Filesystem state|Last checked|Mount count|Maximum mount' | sed 's/^/   /' || true
        if confirmar "  → ¿Programar verificación (fsck) en el próximo arranque?"; then
            if check_sudo && sudo touch /forcefsck 2>/dev/null; then
                echo -e "   ${GREEN}[ OK ] fsck programado para el próximo arranque${RESET}"
            fi
        fi
    fi

    # ── Snapshots ──
    echo ""
    echo -e "${BOLD}▸ Snapshots:${RESET}"
    if command -v snapper >/dev/null 2>&1; then
        local snap_total
        snap_total=$(snapper list 2>/dev/null | wc -l)
        if (( snap_total > 1 )); then
            echo -e "   ${DIM}Snapper tiene $((snap_total - 1)) snapshot(s) (consumen espacio).${RESET}"
            if confirmar "  → ¿Mostrar la lista?"; then
                snapper list 2>/dev/null | head -20
            fi
        else
            echo -e "   ${DIM}Snapper sin snapshots.${RESET}"
        fi
    else
        echo -e "   ${DIM}Snapper no instalado (sin snapshots configurados).${RESET}"
    fi
    if [[ -d /run/timeshift ]] || [[ -d /timeshift ]] || command -v timeshift >/dev/null 2>&1; then
        echo -e "   ${DIM}Timeshift detectado: sus snapshots también ocupan espacio en disco.${RESET}"
    fi

    registrar_ultima_accion "Módulo de sistema de archivos (${root_fs})"
    pause
}

# ─── 23) Análisis y optimización del arranque ───────────
# Muestra los tiempos de systemd y ofrece desactivar (reversible) unidades
# opcionales y lentas. Nunca toca unidades críticas del sistema.
analisis_arranque() {
    clear
    echo -e "${CYAN}${BOLD}╭─ Análisis del arranque ──────────────────────────────────────╮${RESET}"
    echo -e "${CYAN}│${RESET} systemd-analyze: tiempos, culpables y unidades lentas.${CYAN}"
    echo -e "${CYAN}╰──────────────────────────────────────────────────────────────────╯${RESET}"
    echo ""

    if ! command -v systemctl >/dev/null 2>&1; then
        echo -e "${YELLOW}systemd no está disponible en este sistema.${RESET}"
        pause
        return
    fi

    echo -e "${BOLD}▸ Tiempo total de arranque:${RESET}"
    systemd-analyze time 2>/dev/null || echo -e "   ${YELLOW}No disponible.${RESET}"
    echo ""

    echo -e "${BOLD}▸ 10 unidades más lentas (blame):${RESET}"
    systemd-analyze blame 2>/dev/null | head -10 || true
    echo ""

    echo -e "${BOLD}▸ Cadena crítica:${RESET}"
    systemd-analyze critical-chain 2>/dev/null | head -15 || true
    echo ""

    echo -e "${BOLD}▸ Puntuación de seguridad (systemd-analyze security):${RESET}"
    local sec_score
    sec_score=$(systemd-analyze security 2>/dev/null | tail -1)
    [[ -n "$sec_score" ]] && echo -e "   ${DIM}${sec_score}${RESET}" || echo -e "   ${DIM}No disponible en esta versión.${RESET}"
    echo ""

    # Desactivar unidades lentas y opcionales (lista blanca, reversible).
    echo -e "${BOLD}▸ Unidades de arranque opcionales y lentas:${RESET}"
    echo -e "${DIM}   Solo se ofrece desactivar servicios opcionales (impresora, bluetooth, avahi...).${RESET}"
    echo -e "${DIM}   Reversible con: sudo systemctl enable <unidad>.${RESET}"
    echo ""
    local lenta unidad desc
    while IFS= read -r lenta; do
        [[ -n "$lenta" ]] || continue
        unidad=$(echo "$lenta" | awk '{print $2}')
        [[ -z "$unidad" ]] && continue
        case "$unidad" in
            cups.service|cups-browsed.service|bluetooth.service|avahi-daemon.service|ModemManager.service|NetworkManager-wait-online.service|systemd-networkd-wait-online.service|man-db.service|man-db.timer|rtkit.service|fstrim.service|apparmor.service)
                desc=$(systemctl show -p Description --value "$unidad" 2>/dev/null)
                echo -e "   ${DIM}${lenta}${RESET}  ${desc}"
                if confirmar "     → ¿Desactivar ${unidad}?"; then
                    sudo systemctl disable --now "$unidad" 2>/dev/null && echo -e "     ${GREEN}[ OK ] ${unidad} desactivado${RESET}" || echo -e "     ${YELLOW}[ WARN ] No se pudo desactivar.${RESET}"
                fi
                ;;
        esac
    done < <(systemd-analyze blame 2>/dev/null | head -15)

    echo ""
    registrar_ultima_accion "Análisis del arranque"
    pause
}

# ─── 24) Seguridad del sistema ─────────────────────────
# Informe de puertos abiertos, intentos de acceso, SUID y endurecimiento
# seguro y reversible del kernel (todo confirmado).
seguridad_sistema() {
    clear
    echo -e "${CYAN}${BOLD}╭─ Seguridad del sistema ──────────────────────────────────────╮${RESET}"
    echo -e "${CYAN}│${RESET} Puertos abiertos, endurecido del kernel y copias de memoria.${CYAN}"
    echo -e "${CYAN}╰──────────────────────────────────────────────────────────────────╯${RESET}"
    echo ""

    # ── Puertos en escucha ──
    echo -e "${BOLD}▸ Puertos en escucha:${RESET}"
    if command -v ss >/dev/null 2>&1; then
        local listening
        listening=$(ss -tulpn 2>/dev/null | grep LISTEN | grep -vE '127\.0\.0\.[0-9]+|::1')
        if [[ -n "$listening" ]]; then
            ss -tulpn 2>/dev/null | grep LISTEN | head -20 | sed 's/^/   /'
            echo -e "   ${YELLOW}[ WARN ] Servicios accesibles desde la red. Revísalos.${RESET}"
        else
            echo -e "   ${GREEN}[ OK ] No hay servicios escuchando en interfaces públicas.${RESET}"
        fi
    else
        echo -e "   ${YELLOW}iproute2 (ss) no instalado.${RESET}"
    fi

    # ── Intentos fallidos de login ──
    echo -e "${BOLD}▸ Intentos de acceso fallidos (últimos 7 días):${RESET}"
    local intentos
    intentos=$(journalctl --since "-7 days" 2>/dev/null | grep -icE 'authentication failure|Failed password for' || true)
    echo -e "   ${DIM}${intentos} intento(s) fallido(s) registrados${RESET}"

    # ── Binarios SUID ──
    echo -e "${BOLD}▸ Binarios con setuid (SUID):${RESET}"
    local suid
    suid=$(find /usr /bin /sbin -type f -perm /4000 2>/dev/null | wc -l)
    echo -e "   ${DIM}${suid} binario(s) SUID (debe ser un número pequeño y conocido)${RESET}"

    # ── Coredumps ──
    echo -e "${BOLD}▸ Copias de memoria (coredump):${RESET}"
    local coredump_storage=""
    [[ -f /etc/systemd/coredump.conf ]] && coredump_storage=$(grep -E '^Storage=' /etc/systemd/coredump.conf 2>/dev/null | head -1)
    echo -e "   ${DIM}Configuración actual: ${coredump_storage:-por defecto}${RESET}"
    if confirmar "  → ¿Limitar los coredumps al journal (Storage=journal)? [y/N]"; then
        if check_sudo; then
            sudo mkdir -p /etc/systemd/coredump.conf.d 2>/dev/null
            echo -e "Storage=journal" | sudo tee /etc/systemd/coredump.conf.d/kyro.conf >/dev/null 2>&1
            sudo systemctl daemon-reload 2>/dev/null
            echo -e "   ${GREEN}[ OK ] Coredumps limitados al journal${RESET}"
        fi
    fi

    # ── Endurecimiento del kernel (sysctls seguros y reversibles) ──
    echo -e "${BOLD}▸ Endurecimiento del kernel:${RESET}"
    if confirmar "  → ¿Aplicar endurecimiento seguro (kptr/dmesg_restrict, redirects, rp_filter, protecciones de links)?"; then
        if check_sudo; then
            KYRO_SYSCTL=()
            aplicar_sysctl "kernel.kptr_restrict" "1"
            aplicar_sysctl "kernel.dmesg_restrict" "1"
            aplicar_sysctl "net.ipv4.conf.all.accept_redirects" "0"
            aplicar_sysctl "net.ipv4.conf.all.send_redirects" "0"
            aplicar_sysctl "net.ipv4.conf.all.rp_filter" "1"
            aplicar_sysctl "net.ipv4.icmp_echo_ignore_broadcasts" "1"
            aplicar_sysctl "net.ipv4.icmp_ignore_bogus_error_responses" "1"
            aplicar_sysctl "fs.protected_hardlinks" "1"
            aplicar_sysctl "fs.protected_symlinks" "1"
            if (( ${#KYRO_SYSCTL[@]} > 0 )); then
                guardar_sysctls "99-kyro-hardening.conf" "${KYRO_SYSCTL[@]}"
            fi
        fi
    fi

    # ── Actualizaciones de seguridad pendientes ──
    echo -e "${BOLD}▸ Actualizaciones pendientes:${RESET}"
    case "$(detectar_pkg_manager)" in
        pacman) echo -e "   ${DIM}$(pacman -Qu 2>/dev/null | wc -l) paquete(s) desactualizado(s). Actualiza con el gestor para cerrar vulnerabilidades.${RESET}" ;;
        apt)    echo -e "   ${DIM}Ejecuta 'sudo apt update && sudo apt upgrade' regularmente.${RESET}" ;;
        *)      echo -e "   ${DIM}n/d${RESET}" ;;
    esac

    echo ""
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${RESET}"
    echo -e "${GREEN}[ OK ]  Módulo de seguridad finalizado${RESET}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${RESET}"
    registrar_ultima_accion "Seguridad del sistema"
    pause
}

# ─── 25) Mantenimiento avanzado de paquetes ─────────────
# Integridad de bases de datos, Flatpak/Snap y claves GPG. Todo confirmado.
mantenimiento_paquetes() {
    clear
    echo -e "${CYAN}${BOLD}╭─ Mantenimiento avanzado de paquetes ───────────────────────╮${RESET}"
    echo -e "${CYAN}│${RESET} Integridad, bases de datos, Flatpak/Snap y claves.${CYAN}"
    echo -e "${CYAN}╰──────────────────────────────────────────────────────────────────╯${RESET}"
    echo ""
    echo -e "${DIM}   Cada paso se confirma antes de ejecutarse. Nada se toca sin tu OK.${RESET}"
    echo ""
    if ! check_sudo; then
        pause
        return
    fi
    local pkg
    pkg=$(detectar_pkg_manager)

    case "$pkg" in
        pacman)
            echo -e "${BOLD}▸ Base de datos de pacman:${RESET}"
            if sudo pacman -Dk 2>/dev/null | grep -iqE 'error|unresolvable'; then
                echo -e "   ${YELLOW}[ WARN ] Inconsistencias detectadas.${RESET}"
                if confirmar "  → ¿Refrescar y reconstruir la base (pacman -Syy + -Dk)?"; then
                    sudo pacman -Syy >/dev/null 2>&1 && echo -e "   ${GREEN}[ OK ] Base de datos refrescada.${RESET}"
                fi
            else
                echo -e "   ${GREEN}[ OK ] Base de datos íntegra.${RESET}"
            fi
            echo -e "${BOLD}▸ Claves GPG (pacman-key):${RESET}"
            if confirmar "  → ¿Refrescar las claves de firma (pacman-key --refresh-keys)? (requiere red y un rato)"; then
                spinner "Refrescando claves GPG" sudo pacman-key --refresh-keys 2>/dev/null
                echo -e "   ${GREEN}[ OK ] Claves refrescadas${RESET}"
            fi
            ;;
        apt)
            echo -e "${BOLD}▸ dpkg:${RESET}"
            if sudo dpkg --audit 2>/dev/null | grep -q .; then
                echo -e "   ${YELLOW}[ WARN ] Paquetes inconsistentes.${RESET}"
                if confirmar "  → ¿Reparar (dpkg --configure -a + apt -f install)?"; then
                    sudo dpkg --configure -a 2>/dev/null
                    sudo apt-get -y -f install 2>/dev/null
                    echo -e "   ${GREEN}[ OK ] dpkg reparado${RESET}"
                fi
            else
                echo -e "   ${GREEN}[ OK ] dpkg sin inconsistencias.${RESET}"
            fi
            ;;
        dnf)
            echo -e "${BOLD}▸ dnf:${RESET}"
            local dnf_extras
            dnf_extras=$(dnf repoquery --extras 2>/dev/null | wc -l)
            echo -e "   ${DIM}${dnf_extras} paquete(s) 'extras' (sin dueño)${RESET}"
            if (( dnf_extras > 0 )) && confirmar "  → ¿Eliminar los extras (dnf autoremove)?"; then
                sudo dnf autoremove -y 2>/dev/null
                echo -e "   ${GREEN}[ OK ] Extras eliminados${RESET}"
            fi
            ;;
        *)  echo -e "${YELLOW}Gestor no soportado para este módulo.${RESET}" ;;
    esac

    echo -e "${BOLD}▸ Flatpak:${RESET}"
    if command -v flatpak >/dev/null 2>&1; then
        if confirmar "  → ¿Reparar el almacén de Flatpak (flatpak repair --user)?"; then
            spinner "Reparando Flatpak" flatpak repair --user
            echo -e "   ${GREEN}[ OK ] Reparación de Flatpak completada${RESET}"
        fi
        if confirmar "  → ¿Eliminar runtimes/paquetes Flatpak sin uso?"; then
            flatpak uninstall --unused --assumeyes 2>/dev/null
            echo -e "   ${GREEN}[ OK ] Flatpak sin uso eliminados${RESET}"
        fi
    else
        echo -e "   ${DIM}Flatpak no instalado.${RESET}"
    fi

    echo -e "${BOLD}▸ Snap:${RESET}"
    if command -v snap >/dev/null 2>&1; then
        local snap_des
        snap_des=$(sudo snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' | wc -l)
        if (( snap_des > 0 )); then
            if confirmar "  → ¿Purgar ${snap_des} revisión(es) deshabilitada(s) de Snap?"; then
                while read -r sname srev; do
                    [[ -n "$sname" && -n "$srev" ]] && sudo snap remove "$sname" --revision="$srev" 2>/dev/null
                done < <(sudo snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}')
                echo -e "   ${GREEN}[ OK ] Snap purgado${RESET}"
            fi
        else
            echo -e "   ${DIM}Snap sin revisiones deshabilitadas.${RESET}"
        fi
    else
        echo -e "   ${DIM}Snap no instalado.${RESET}"
    fi

    echo ""
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${RESET}"
    echo -e "${GREEN}[ OK ]  Mantenimiento de paquetes finalizado${RESET}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${RESET}"
    registrar_ultima_accion "Mantenimiento avanzado de paquetes"
    pause
}

# ═══════════════════════════════════════════════════════
#  MENÚ PRINCIPAL
# ═══════════════════════════════════════════════════════
menu() {
    comprobar_update_fondo &
    KYRO_BG_PIDS+=("$!")
    while true; do
        header

        echo -e "
${CYAN}${BOLD} ──── MANTENIMIENTO ─────────────────────────────────${RESET}
${CYAN} 1)${RESET} Limpiar caché (todo en uno)                        ${CYAN} 2)${RESET} Paquetes huérfanos
${CYAN} 3)${RESET} Limpiar logs del sistema                         ${CYAN} 4)${RESET} Vaciar papelera

${CYAN}${BOLD} ──── OPTIMIZACIÓN ───────────────────────────────────${RESET}
${CYAN} 5)${RESET} Optimizar hardware (CPU/RAM/swap/disco)
${CYAN} 6)${RESET} Optimización rápida (un solo clic)
${CYAN} 7)${RESET} Detectar errores de hardware (SMART + kernel)

${CYAN}${BOLD} ──── ANÁLISIS ───────────────────────────────────────${RESET}"
        echo -e "${CYAN} 8)${RESET} Buscar directorios vacíos                          ${CYAN} 9)${RESET} Verificar corrupción de paquetes"
        echo -e "${CYAN}10)${RESET} Buscar archivos grandes (>1 GB)                   ${CYAN}11)${RESET} Servicios systemd fallidos"

        echo -e "
${CYAN}${BOLD} ──── MONITORIZACIÓN ─────────────────────────────────${RESET}"
        echo -e "${CYAN}12)${RESET} Panel en vivo (CPU/RAM/temp)                       ${CYAN}13)${RESET} Monitor de recursos

${CYAN}${BOLD} ──── EXTRAS ──────────────────────────────────────────${RESET}"
        echo -e "${CYAN}14)${RESET} Cachés de aplicaciones                             ${CYAN}15)${RESET} Refrescar repositorios"
        echo -e "${CYAN}16)${RESET} Limpiar kernels antiguos                           ${CYAN}17)${RESET} Revisar .pacnew/.pacsave"
        echo -e "${CYAN}18)${RESET} Diagnóstico de red y DNS                          ${CYAN}19)${RESET} Optimizar red (BBR)
"
        echo -e "${CYAN}${BOLD} ──── JUEGOS ─────────────────────────────────────────────${RESET}"
        echo -e "${CYAN}20)${RESET} Optimización gaming (GPU/memoria/CPU)              ${CYAN}21)${RESET} Mantenimiento de Steam

${CYAN}${BOLD} ──── SISTEMA ─────────────────────────────────────────${RESET}"
        echo -e "${CYAN}22)${RESET} Sistema de archivos (TRIM/btrfs/ext4)              ${CYAN}23)${RESET} Análisis del arranque"
        echo -e "${CYAN}24)${RESET} Seguridad del sistema                             ${CYAN}25)${RESET} Mant. avanzado de paquetes

${CYAN}${BOLD} ──── KYRO ───────────────────────────────────────────${RESET}"
        echo -e "${CYAN}26)${RESET} Actualizaciones (auto)                             ${CYAN}27)${RESET} Ver README"
        echo -e "${CYAN}28)${RESET} Chequeo de salud completo                          ${CYAN}29)${RESET} Limpieza profunda"
        echo -e "${CYAN}30)${RESET} Restaurar ajustes de Kyro (rollback)               ${CYAN}31)${RESET} Estabilizador"
        echo -e "${CYAN}32)${RESET} Reparador de paquetes                             ${CYAN}33)${RESET} Diag. estabilidad"

        echo -e "${CYAN} ───────────────────────────────────────────────────────────${RESET}"
        echo -e "${CYAN} S)${RESET} Resumen del sistema                    ${RED}0)${RESET} Salir"
        echo -e "${CYAN} ───────────────────────────────────────────────────────────${RESET}"

        read -rp $'\nKyro > ' opcion || opcion="0"

        case "$opcion" in
            1) cache ;;
            2) paquetes_huerfanos ;;
            3) logs ;;
            4) papelera ;;
            5) optimizar_hardware ;;
            6) optimizacion_rapida ;;
            7) errores_hardware ;;
            8) directorios_vacios ;;
            9) corrupcion ;;
            10) archivos_grandes ;;
            11) servicios_fallidos ;;
            12) consumo ;;
            13) monitor ;;
            14) limpiar_caches_apps ;;
            15) refrescar_repos ;;
            16) limpiar_kernels_viejos ;;
            17) revisar_pacnew ;;
            18) diagnostico_red ;;
            19) optimizar_red ;;
            20) optimizar_juegos ;;
            21) limpiar_steam ;;
            22) modulo_filesystem ;;
            23) analisis_arranque ;;
            24) seguridad_sistema ;;
            25) mantenimiento_paquetes ;;
            26) actualizaciones_auto ;;
            27) abrir_readme ;;
            28) chequeo_salud ;;
            29) limpieza_profunda ;;
            30) restaurar_optimizacion ;;
            31) estabilizador ;;
            32) reparar_paquetes ;;
            33) diagnostico_estabilidad ;;
            [Ss]) system_box ;;
            0|q|Q) exit 0 ;;
            *) echo -e "${RED}Opción inválida${RESET}"; sleep 1 ;;
        esac
    done
}

# ─── Modo CLI (headless, solo lectura) ─────────────────
# El modo CLI NUNCA modifica el sistema: es informativo. Para actuar,
# abre el menú interactivo.
mostrar_ayuda() {
    cat <<EOF
Kyro Optimizer v$VERSION

Uso:
  ./Kyro.sh                  Abre el menú interactivo
  ./Kyro.sh --version        Muestra la versión
  ./Kyro.sh --status         Informe rápido del sistema (solo lectura)
  ./Kyro.sh --health         Chequeo de salud breve (solo lectura)
  ./Kyro.sh --update-check   Comprueba si hay una actualización de Kyro
  ./Kyro.sh --yes             Abre el menú con confirmaciones automáticas
  ./Kyro.sh --help           Esta ayuda

Nota: --yes activa confirmaciones automáticas y debe usarse solo cuando
se entiendan las acciones destructivas. Los modos de consulta (--status,
--health y --update-check) son de solo lectura.
EOF
}

estado_cli() {
    local kernel distro ram_total ram_uso ram_pct disk_uso load
    kernel=$(uname -r)
    distro=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
    [[ -z "$distro" ]] && distro="Desconocida"
    ram_total=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    ram_uso=$(free -m 2>/dev/null | awk '/^Mem:/{print $3}')
    ram_pct=$(free -m 2>/dev/null | awk '/^Mem:/{printf "%d", ($3/$2)*100}')
    read -r _ disk_uso _ < <(df -h "$HOME" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $2, $3, $5}')
    read -r load _ < /proc/loadavg 2>/dev/null
    echo -e "${BOLD}Kyro Optimizer v${VERSION}${RESET} — ${distro}"
    echo -e "  Kernel:  ${kernel}   (${HOSTNAME:-?})"
    echo -e "  RAM:     ${ram_uso:-0} / ${ram_total:-0} MB  (${ram_pct:-0}%)"
    echo -e "  Disco:   ${disk_uso:-?} usados en ${HOME}"
    echo -e "  Carga:   ${load:-?}"
    echo ""
    echo -e "${DIM}Modo solo lectura. Usa './Kyro.sh' para el menú interactivo.${RESET}"
}

chequeo_salud_cli() {
    local nproc load mempct diskpct failed kerr
    read -r load _ _ _ _ < /proc/loadavg 2>/dev/null
    nproc=$(nproc 2>/dev/null || echo 1)
    mempct=$(free -m 2>/dev/null | awk '/^Mem:/{printf "%d", ($3/$2)*100}')
    diskpct=$(df -h "$HOME" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')
    failed=$(systemctl --failed --no-legend --plain 2>/dev/null | wc -l)
    kerr=$(journalctl -k -p err --since "-7 days" -o cat 2>/dev/null | wc -l)
    local cpct
    cpct=$(awk -v l="${load:-0}" -v n="$nproc" 'BEGIN{printf "%d", (l/n)*100}')
    echo -e "${BOLD}Chequeo de salud Kyro (solo lectura)${RESET}"
    echo -e "  CPU:      ${cpct}%   (carga ${load:-0} / ${nproc} núcleos)"
    echo -e "  RAM:      ${mempct:-0}%"
    echo -e "  Disco:    ${diskpct:-0}%   (${HOME})"
    echo -e "  Servicios fallidos: ${failed}"
    echo -e "  Errores de kernel (7d): ${kerr}"
    echo -e "${DIM}Para acciones usa el menú interactivo: ./Kyro.sh${RESET}"
}

main() {
    case "${1:-}" in
        --yes|-y) AUTO_SI=1; menu ;;
        -h|--help|help)      mostrar_ayuda ;;
        -v|--version|version) echo "Kyro Optimizer v$VERSION"; exit 0 ;;
        --status|status)     estado_cli ;;
        --health|health)     chequeo_salud_cli ;;
        --update-check|--check-update) comprobar_update; return $? ;;
        "")                  menu ;;
        *) echo -e "${RED}Opción CLI desconocida: $1${RESET}"; mostrar_ayuda; exit 1 ;;
    esac
}

# ─── Punto de entrada ─────────────────────────────────
main "$@"
