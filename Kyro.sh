#!/bin/bash

# ═══════════════════════════════════════════════════════
#  Kyro Optimizer – Mantenimiento y diagnóstico del sistema
#  Licencia: GPL-3.0
#  Versión: 3.1
# ═══════════════════════════════════════════════════════

set -uo pipefail
VERSION="3.1"

# ─── Colores ───────────────────────────────────────────
CYAN="\e[36m"
GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
MAGENTA="\e[35m"
ORANGE="\e[38;5;208m"
BOLD="\e[1m"
DIM="\e[2m"
RESET="\e[0m"

STATE_FILE="$HOME/.cache/kyro_last_run"

# ─── Utilidades ────────────────────────────────────────
pause() {
    read -rp $'\nPresiona ENTER para continuar...' _ || true
}

confirmar() {
    local pregunta="$1"
    local respuesta
    read -rp "$pregunta [y/N] " respuesta || respuesta="n"
    [[ "${respuesta,,}" == "y" ]]
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
    local frames
    case "$style" in
        dots)    frames="⠂⠁⠂⠄ ⠂" ;;
        barra)   frames="▏▎▍▌▋▊▉▊▋▌▍▎" ;;
        puntos)  frames="● ○ ● ○" ;;
        *)       frames="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏" ;;
    esac
    local tmp_out
    tmp_out=$(mktemp)

    ("$@" >"$tmp_out" 2>&1; echo $? > "${tmp_out}.rc") &
    local pid=$!

    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        local frame="${frames:i++%${#frames}:1}"
        printf "\r${MAGENTA}%s${RESET} %s " "$frame" "$msg"
        sleep 0.1
    done
    wait "$pid" 2>/dev/null || true

    local rc=0
    [[ -f "${tmp_out}.rc" ]] && rc=$(cat "${tmp_out}.rc")
    printf "\r"
    if [[ "$rc" -eq 0 ]]; then
        echo -e "${GREEN}✔${RESET} $msg"
    else
        echo -e "${YELLOW}⚠${RESET} $msg ${DIM}(código $rc)${RESET}"
    fi
    cat "$tmp_out"
    rm -f "$tmp_out" "${tmp_out}.rc"
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
    echo -e "${CYAN}
██╗  ██╗██╗   ██╗██████╗  ██████╗
██║ ██╔╝╚██╗ ██╔╝██╔══██╗██╔═══██╗
█████╔╝  ╚████╔╝ ██████╔╝██║   ██║
██╔═██╗   ╚██╔╝  ██╔══██╗██║   ██║
██║  ██╗   ██║   ██║  ██║╚██████╔╝
╚═╝  ╚═╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝
${RESET}${CYAN}
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

# ─── Resumen del sistema (ventanita) ──────────────────
system_box() {
    local kernel uptime shell mem_used mem_total mem_pct disk_used disk_total disk_pct
    kernel=$(uname -r)
    uptime=$(uptime -p 2>/dev/null | sed 's/^up //')
    shell=$(basename "${SHELL:-$0}")
    local pkgs="?"
    local user=${USER:-$(whoami)}
    local hostname=${HOSTNAME:-$(hostname)}
    local distro
    distro=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
    [[ -z "$distro" ]] && distro="Desconocida"

    read -r mem_total mem_used mem_pct < <(free -m | awk '/^Mem:/ {printf "%s %s %d", $2, $3, ($3/$2)*100}')
    read -r disk_total disk_used disk_pct < <(df -h "$HOME" | awk 'NR==2 {gsub("%","",$5); print $2, $3, $5}')

    local pkg_manager
    pkg_manager=$(detectar_pkg_manager)
    case "$pkg_manager" in
        pacman) pkgs=$(pacman -Qq 2>/dev/null | wc -l) ;;
        apt)    pkgs=$(dpkg-query -f '${binary:Package}\n' -W 2>/dev/null | wc -l) ;;
        dnf)    pkgs=$(rpm -qa 2>/dev/null | wc -l) ;;
        zypper) pkgs=$(rpm -qa 2>/dev/null | wc -l) ;;
        apk)    pkgs=$(apk list --installed 2>/dev/null | wc -l) ;;
    esac

    local linea1="    kernel       $(printf '%-20s' "$kernel")"
    local linea2="    distro       $(printf '%-20s' "$distro")"
    local linea3="    shell        $(printf '%-20s' "$shell")"
    local linea4="    mem          $(printf '%-20s' "${mem_used}MB / ${mem_total}MB")"
    local linea5="    pkgs         $(printf '%-20s' "$pkgs")"
    local linea6="    user         $(printf '%-20s' "$user")"
    local linea7="    hname        $(printf '%-20s' "$hostname")"

    echo -e "${CYAN}"
    echo "     ╭───────────────────────────────────╮"
    echo "$linea1"
    echo "$linea2"
    echo "$linea3"
    echo "$linea4"
    echo "$linea5"
    echo "$linea6"
    echo "$linea7"
    echo "     ╰───────────────────────────────────╯"
    echo -e "${RESET}"
    echo -e "${DIM}   uptime: ${uptime}${RESET}"

    echo -e "${BOLD}Uso de RAM:${RESET}   $(barra_pct "${mem_pct:-0}")"
    echo -e "${BOLD}Uso de disco (${HOME}):${RESET} $(barra_pct "${disk_pct:-0}")  (${disk_used} / ${disk_total})"

    pause
}

# ═══════════════════════════════════════════════════════
#  FUNCIONES DE LIMPIEZA
# ═══════════════════════════════════════════════════════

cache() {
    echo -e "${YELLOW}Limpiando caché...${RESET}"
    local pkg
    pkg=$(detectar_pkg_manager)
    local antes_cache antes_thumb antes_total
    antes_cache=$(tamano_de "/var/cache")
    antes_thumb=$(tamano_de "$HOME/.cache/thumbnails")
    antes_total=$((antes_cache + antes_thumb))

    case "$pkg" in
        pacman)
            if command -v paccache >/dev/null; then
                spinner "Purgando caché de pacman" sudo paccache -r
            else
                echo -e "${RED}paccache no encontrado. Instala pacman-contrib.${RESET}"
            fi
            ;;
        apt)
            spinner "Limpiando caché de apt" sudo apt clean
            ;;
        dnf)
            spinner "Limpiando caché de dnf" sudo dnf clean all
            ;;
        zypper)
            spinner "Limpiando caché de zypper" sudo zypper clean -a
            ;;
        apk)
            spinner "Limpiando caché de apk" apk cache clean
            ;;
        *)
            echo -e "${RED}Gestor de paquetes no soportado.${RESET}"
            ;;
    esac

    progress_bar "Eliminando miniaturas" 1
    rm -rf "${HOME:?}/.cache/thumbnails/"* 2>/dev/null || true

    local despues_cache despues_thumb despues_total liberado
    despues_cache=$(tamano_de "/var/cache")
    despues_thumb=$(tamano_de "$HOME/.cache/thumbnails")
    despues_total=$((despues_cache + despues_thumb))
    liberado=$((antes_total - despues_total))
    (( liberado < 0 )) && liberado=0

    echo -e "${GREEN}✔ Caché limpiada${RESET}"
    echo -e "${DIM}   Espacio liberado (aprox.): $(formatear_bytes "$liberado")${RESET}"
    registrar_ultima_accion "Limpieza de caché ($(formatear_bytes "$liberado") liberados)"
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
                    sudo pacman -Rns $orphans
                    echo -e "${GREEN}✔ Huérfanos eliminados${RESET}"
                    registrar_ultima_accion "Huérfanos eliminados (pacman)"
                fi
            else
                echo -e "${GREEN}✔ No hay huérfanos${RESET}"
            fi
            ;;
        apt)
            orphans=$(apt-get -s autoremove 2>/dev/null | grep "^Remv" | awk '{print $2}' || true)
            if [[ -n "$orphans" ]]; then
                echo "$orphans"
                echo -e "${DIM}Total: $(echo "$orphans" | wc -l) paquete(s)${RESET}"
                if confirmar "¿Eliminar estos paquetes?"; then
                    sudo apt autoremove --purge -y
                    echo -e "${GREEN}✔ Huérfanos eliminados${RESET}"
                    registrar_ultima_accion "Huérfanos eliminados (apt)"
                fi
            else
                echo -e "${GREEN}✔ No hay huérfanos${RESET}"
            fi
            ;;
        dnf)
            orphans=$(dnf repoquery --extras 2>/dev/null || true)
            if [[ -n "$orphans" ]]; then
                echo "$orphans"
                if confirmar "¿Eliminar estos paquetes?"; then
                    sudo dnf autoremove -y
                    echo -e "${GREEN}✔ Huérfanos eliminados${RESET}"
                    registrar_ultima_accion "Huérfanos eliminados (dnf)"
                fi
            else
                echo -e "${GREEN}✔ No hay huérfanos${RESET}"
            fi
            ;;
        zypper)
            orphans=$(zypper packages --unneeded 2>/dev/null | awk 'NR>4 && /\bi\b/ {for(i=1;i<=NF;i++) if($i ~ /^.../) print $i}' | sort -u | head -80 || true)
            if [[ -n "$orphans" ]]; then
                echo "$orphans"
                echo -e "${DIM}Total: $(echo "$orphans" | wc -l) paquete(s)${RESET}"
                if confirmar "¿Eliminar estos paquetes?"; then
                    sudo zypper rm $(echo "$orphans")
                    echo -e "${GREEN}✔ Huérfanos eliminados${RESET}"
                    registrar_ultima_accion "Huérfanos eliminados (zypper)"
                fi
            else
                echo -e "${GREEN}✔ No hay huérfanos${RESET}"
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
    if command -v journalctl >/dev/null; then
        local antes despues
        antes=$(sudo journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMG]' | head -1 || echo "0")
        spinner "Reduciendo logs a 7 días" sudo journalctl --vacuum-time=7d
        despues=$(sudo journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMG]' | head -1 || echo "0")
        echo -e "${GREEN}✔ Logs del sistema reducidos (7 días)${RESET}"
        echo -e "${DIM}   Uso antes: ${antes}  →  Uso ahora: ${despues}${RESET}"
        registrar_ultima_accion "Logs reducidos a 7 días"
    else
        echo -e "${RED}journalctl no disponible. No se limpiaron logs.${RESET}"
    fi
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
            echo -e "${GREEN}✔ Papelera vaciada${RESET} ${DIM}(${tamano} liberados)${RESET}"
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

truncate_path() {
    local path="$1"
    local max_len=34
    if [[ ${#path} -le $max_len ]]; then
        echo "$path"
    else
        echo "${path:0:$((max_len - 3))}..."
    fi
}

directorios_vacios() {
    echo -e "${YELLOW}Analizando directorios vacíos en HOME...${RESET}"

    local tmpfile
    tmpfile=$(mktemp)
    spinner "Buscando directorios vacíos" bash -c "find \"$HOME\" -maxdepth 5 -type d -empty 2>/dev/null > \"$tmpfile\""
    local total
    total=$(wc -l < "$tmpfile")

    if [[ "$total" -eq 0 ]]; then
        echo -e "       ${GREEN}✔ No se encontraron directorios vacíos${RESET}"
    else
        printf "       ${YELLOW}📁 Directorios vacíos: %3d${RESET}\n" "$total"
        printf "       ${YELLOW}   (mostrando primeros 5)${RESET}\n"
        head -5 "$tmpfile" | while IFS= read -r dir; do
            local short="${dir/$HOME/~}"
            short=$(truncate_path "$short")
            printf "       %-34s\n" "$short"
        done
        if [[ "$total" -gt 5 ]]; then
            printf "       ... y %3d más ...\n" $((total - 5))
        fi
    fi

    if [[ "$total" -gt 0 ]]; then
        echo ""
        if confirmar "¿Deseas eliminar todos los directorios vacíos encontrados?"; then
            progress_bar "Eliminando directorios vacíos" 1.5
            local eliminados=0
            while IFS= read -r dir; do
                if rmdir "$dir" 2>/dev/null; then
                    eliminados=$((eliminados + 1))
                fi
            done < "$tmpfile"
            echo -e "${GREEN}✔ Se eliminaron ${eliminados} de ${total} directorios vacíos${RESET}"
            registrar_ultima_accion "Directorios vacíos eliminados (${eliminados})"
        else
            echo -e "${YELLOW}No se eliminó ningún directorio.${RESET}"
        fi
    fi

    rm -f "$tmpfile"
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
        echo -e "${RED}✘ No se pudo crear el archivo de swap en $candidato${RESET}"
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
        echo -e "${GREEN}✔ Swap creado y activado en $candidato (${tamano_mb} MB, $fs)${RESET}"
        registrar_ultima_accion "Swap ampliado +${tamano_mb} MB en $candidato"
        return 0
    else
        echo -e "${RED}✘ swapon falló para $candidato (fs: $fs, compresión/COW activa?)${RESET}"
        return 1
    fi
}

optimizar_hardware() {
    clear
    echo -e "${CYAN}${BOLD}╭─ Optimizador de hardware ─────────────────────────────────────╮${RESET}"
    echo -e "${CYAN}│${RESET} Analizando CPU, RAM, almacenamiento, swap y salud...${CYAN}"
    echo -e "${CYAN}╰──────────────────────────────────────────────────────────────────╯${RESET}"

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
    local swap_rec swappiness_rec governor_rec sched_rec
    if (( ram_mb <= 2048 )); then
        swap_rec=$((ram_mb * 2))
    elif (( ram_mb <= 8192 )); then
        swap_rec=$ram_mb
    elif (( ram_mb <= 16384 )); then
        swap_rec=$((ram_mb / 2))
    else
        swap_rec=4096
    fi
    # Si existe zram, ya hay swap comprimida y rápida.
    if (( swap_zram == 1 )); then
        swap_rec=$((swap_rec / 2))
        (( swap_rec < 512 )) && swap_rec=512
    fi

    if (( ram_mb >= 16384 )); then
        swappiness_rec=5
    elif (( ram_mb >= 8192 )); then
        swappiness_rec=10
    else
        swappiness_rec=30
    fi
    [[ "$tipo_disco" == "HDD" ]] && swappiness_rec=$((swappiness_rec + 20))
    (( swappiness_rec > 60 )) && swappiness_rec=60
    (( swap_zram == 1 )) && swappiness_rec=100

    local governor_rec
    if [[ "$es_laptop" == "Sí" ]]; then
        governor_rec="powersave"
    else
        governor_rec="performance"
    fi
    # Ajusta según disponibilidad real
    if [[ -n "$gobernadores" ]]; then
        if ! echo "$gobernadores" | tr ' ' '\n' | grep -qx "$governor_rec"; then
            governor_rec=$(echo "$gobernadores" | awk '{print $1}')
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
    echo -e "${CYAN}│${RESET} CPU:                        ${cpu_model} (${nucleos} núcleos)"
    echo -e "${CYAN}│${RESET} RAM:                        ${ram_gb} GiB (${ram_mb} MB)"
    echo -e "${CYAN}│${RESET} Disco (/):                  /dev/${base_dev}  ->  ${tipo_disco}"
    echo -e "${CYAN}│${RESET} Portátil (batería):         ${es_laptop}"
    echo -e "${CYAN}│${RESET} Gobernador actual:          ${governor_actual}"
    echo -e "${CYAN}│${RESET} Gobernadores disponibles:   ${gobernadores:-N/D}"
    echo -e "${CYAN}│${RESET} Planificador E/S:           ${sched_actual}"
    echo -e "${CYAN}│${RESET} Swap total:                 ${swap_total} MB"$( \
       (( swap_zram == 1 )) && echo " (zram activo)" )""
    echo -e "${CYAN}╰──────────────────────────────────────────────────────────────────╯${RESET}"

    # ── Detección de errores de hardware ──
    echo ""
    echo -e "${CYAN}${BOLD}╭─ Salud / errores de hardware ──────────────────────────────────╮${RESET}"
    if (( err_total > 0 )); then
        echo -e "${CYAN}│${RESET} ${RED}⚠${RESET} Se detectaron ${BOLD}${err_total}${RESET} evento(s) de error/críticos en el kernel (últ. 7 días)."
        echo -e "${CYAN}│${RESET} Usa la opción 7 del menú para un diagnóstico detallado."
    else
        echo -e "${CYAN}│${RESET} ${GREEN}✔${RESET} Sin errores críticos de hardware detectados recientemente."
    fi
    echo -e "${CYAN}╰──────────────────────────────────────────────────────────────────╯${RESET}"

    echo ""
    echo -e "${CYAN}${BOLD}╭─ Recomendaciones ───────────────────────────────────────────────╮${RESET}"
    echo -e "${CYAN}│${RESET} Swap recomendado:              ${swap_rec} MB  (actual: ${swap_total} MB)"
    echo -e "${CYAN}│${RESET} vm.swappiness recomendado:     ${swappiness_rec}"
    echo -e "${CYAN}│${RESET} Gobernador de CPU recomendado: ${governor_rec}"
    echo -e "${CYAN}│${RESET} Planificador E/S recomendado:  ${sched_rec}"
    echo -e "${CYAN}╰──────────────────────────────────────────────────────────────────╯${RESET}"
    echo ""

    if ! confirmar "¿Deseas aplicar ahora los ajustes recomendados (se te preguntará uno por uno)?"; then
        echo -e "${YELLOW}No se aplicó ningún cambio.${RESET}"
        registrar_ultima_accion "Análisis de hardware (${tipo_disco}, ${ram_gb}GiB RAM)"
        pause
        return
    fi

    # ── Aplicar swappiness ──
    if confirmar "  → ¿Aplicar vm.swappiness=${swappiness_rec}?"; then
        if sudo sysctl -w vm.swappiness="$swappiness_rec" >/dev/null 2>&1; then
            echo "vm.swappiness=${swappiness_rec}" | sudo tee /etc/sysctl.d/99-kyro-optimizer.conf >/dev/null 2>&1 || true
            echo -e "${GREEN}✔ swappiness aplicado y guardado de forma persistente${RESET}"
        else
            echo -e "${RED}✘ No se pudo aplicar swappiness (¿tienes permisos sudo?)${RESET}"
        fi
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
                echo -e "${GREEN}✔ Gobernador aplicado${RESET}"
            else
                echo -e "${YELLOW}⚠ No se pudo aplicar en todos los núcleos${RESET}"
            fi
            if confirmar "    → ¿Persistir tras reiniciar con un servicio systemd?"; then
                persistir_optimizacion "$governor_rec" "$sched_rec" "$swappiness_rec" "$base_dev"
            fi
        fi
    else
        echo -e "${DIM}Este equipo no expone cpufreq; se omite el ajuste de gobernador.${RESET}"
    fi

    # ── Aplicar planificador de E/S ──
    if [[ -f "/sys/block/$base_dev/queue/scheduler" ]]; then
        if confirmar "  → ¿Aplicar planificador de E/S '${sched_rec}' a /dev/${base_dev}?"; then
            if echo "$sched_rec" | sudo tee "/sys/block/$base_dev/queue/scheduler" >/dev/null 2>&1; then
                echo -e "${GREEN}✔ Planificador aplicado${RESET}"
            else
                echo -e "${RED}✘ No se pudo aplicar ('${sched_rec}' puede no estar disponible en este disco)${RESET}"
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
        echo -e "${GREEN}✔ Tu swap actual ya es adecuado para tu RAM${RESET}"
    fi

    registrar_ultima_accion "Optimización de hardware (${tipo_disco}, ${ram_gb} GiB RAM)"
    pause
}

# Persistencia con systemd.
persistir_optimizacion() {
    local gov="$1" sched="$2" swappiness="$3" dev="$4"
    local bin="/usr/local/bin/kyro-perf-apply.sh"
    local svc="/etc/systemd/system/kyro-perf.service"
    echo -e "${DIM}Creando servicio persistente kyro-perf.service...${RESET}"
    if sudo tee "$bin" >/dev/null 2>&1 <<EOF
#!/bin/bash
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -w "\$g" ] && echo "$gov" > "\$g" 2>/dev/null
done
echo "$sched" > /sys/block/$dev/queue/scheduler 2>/dev/null || true
echo "$swappiness" > /proc/sys/vm/swappiness
EOF
        then :; else
        echo -e "${RED}No se pudo escribir el script persistente.${RESET}"
        return
    fi
    sudo chmod +x "$bin"
    sudo tee "$svc" >/dev/null <<EOF
[Unit]
Description=Fikures de rendimiento Kyro
After=multi-user.target

[Service]
Type=oneshot
ExecStart=$bin

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload >/dev/null 2>&1
    sudo systemctl enable --now kyro-perf.service >/dev/null 2>&1 && \
        echo -e "${GREEN}✔ Servicio kyro-perf activado y en boots${RESET}" || \
        echo -e "${YELLOW}⚠ No se pudo activar el servicio (systemd no disponible?)${RESET}"
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

    # 1) Kernel / journalctl
    local kernel_src=""
    if command -v journalctl >/dev/null 2>&1; then
        kernel_src=$(journalctl -k -o cat --no-pager --since "7 days ago" 2>/dev/null | grep -iE 'error|fail|critical|panic|oops|fault|thermal|nvme|pcie' | tail -15 || true)
    elif command -v dmesg >/dev/null 2>&1; then
        kernel_src=$(dmesg 2>/dev/null | tail -200 | grep -iE 'error|fail|critical|panic|oops|fault|thermal|nvme|pcie' | tail -15 || true)
    fi
    echo -e "${BOLD}▸ Errores del kernel (últimos eventos):${RESET}"
    if [[ -n "$kernel_src" ]]; then
        echo "$kernel_src"
    else
        echo -e "   ${GREEN}✔ No se encontraron errores recientes del kernel.${RESET}"
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
                printf "${GREEN}✔ Sano${RESET}"
            elif echo "$h" | grep -qi 'failed'; then
                printf "${RED}✘ FALLO detectado${RESET}"
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

    # 3) Temperatura
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
    local err_n="$kernel_src"
    if [[ -n "$err_n" ]] && echo "$err_n" | grep -qiE 'error|fail|critical|panic|fault|nvme|pcie'; then
        echo -e "   ${RED}⚠ Se observaron errores. Si persisten, revisa RAM (memtest86+)\n      y alimentación; monitorea SMART e temperaturas de disco.${RESET}"
    else
        echo -e "   ${GREEN}✔ Sin señales de fallo de hardware recientes.${RESET}"
    fi
    registrar_ultima_accion "Diagnóstico de errores de hardware"
    pause
}

# ─── Optimización rápida (un solo clic) ─────────────────
optimizacion_rapida() {
    clear
    echo -e "${CYAN}${BOLD}╭─ Optimización rápida ─────────────────────────────────────────────╮${RESET}"
    echo -e "${CYAN}│${RESET} Aplicará los ajustes de rendimiento seguros recomendados.${CYAN}"
    echo -e "${CYAN}╰──────────────────────────────────────────────────────────────────╯${RESET}"
    echo ""
    if ! confirmar "¿Deseas aplicar tweaks seguros ahora?"; then
        echo -e "${YELLOW}Cancelado.${RESET}"
        return
    fi

    local ram_mb sw
    ram_mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    [[ -z "$ram_mb" ]] && ram_mb=0
    if (( ram_mb >= 16384 )); then sw=5; elif (( ram_mb >= 8192 )); then sw=10; else sw=30; fi

    # gobernador
    local gov="performance"
    compgen -G "/sys/class/power_supply/BAT*" >/dev/null 2>&1 && gov="powersave"
    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors ]]; then
        local avail
        avail=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null)
        if ! echo "$avail" | tr ' ' '\n' | grep -qx "$gov"; then
            gov=$(echo "$avail" | awk '{print $1}')
        fi
    fi

    # scheduler
    local dev sched
    dev=$(detectar_dispositivo_base)
    if [[ -f "/sys/block/$dev/queue/scheduler" ]]; then
        sched=$(echo "$(cat /sys/block/$dev/queue/scheduler)" | grep -oP '\[\K[^]]+' 2>/dev/null)
        [[ -z "$sched" ]] && sched=$(echo "$(cat /sys/block/$dev/queue/scheduler)" | awk '{print $1}')
    fi

    echo -e "${BOLD}→ Aplicando vm.swappiness=${sw} ...${RESET}"
    sudo sysctl -w vm.swappiness="$sw" >/dev/null 2>&1 && echo -e "   ${GREEN}✔${RESET}" || echo -e "   ${RED}✘${RESET}"
    echo -e "${BOLD}→ Gobernador CPU: ${gov} ...${RESET}"
    local govok=0
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [[ -f "$g" ]] && echo "$gov" | sudo tee "$g" >/dev/null 2>&1 && govok=1
    done
    [[ "$govok" -eq 1 ]] && echo -e "   ${GREEN}✔${RESET}" || echo -e "   ${YELLOW}⚠ sin cpufreq${RESET}"
    if [[ -n "${sched:-}" && -f "/sys/block/$dev/queue/scheduler" ]]; then
        echo -e "${BOLD}→ Planificador ${sched} en $dev ...${RESET}"
        echo "$sched" | sudo tee "/sys/block/$dev/queue/scheduler" >/dev/null 2>&1 && echo -e "   ${GREEN}✔${RESET}" || echo -e "   ${YELLOW}⚠${RESET}"
    fi
    registrar_ultima_accion "Optimización rápida (gov=$gov, swappiness=$sw)"
    echo ""
    echo -e "${GREEN}✔ Optimización rápida finalizada${RESET}"
    pause
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
    )
    local antes=0 despues=0 d liberado=0
    for d in "${dirs[@]}"; do
        antes=$(( antes + $(tamano_de "$d") ))
    done

    if command -v flatpak >/dev/null 2>&1; then
        if confirmar "¿Eliminar runtimes/paquetes Flatpak no utilizados?"; then
            spinner "Flatpak: limpiando lo no usado" flatpak uninstall --unused --yes
        fi
    fi
    if command -v pip3 >/dev/null 2>&1; then
        spinner "pip: vaciando caché" pip3 cache purge
    fi
    if command -v npm >/dev/null 2>&1; then
        spinner "npm: vaciando caché" npm cache clean --force --loglevel=error
    fi
    if command -v uv >/dev/null 2>&1; then
        spinner "uv: vaciando caché" uv cache clean
    fi
    if command -v cargo >/dev/null 2>&1; then
        spinner "cargo: limpiando caché" cargo cache --autoclean 2>/dev/null || true
        rm -rf "$HOME/.cache/cargo/.fingerprint" 2>/dev/null || true
    fi
    if command -v go >/dev/null 2>&1; then
        spinner "Go: limpiando caché de build" go clean -cache 2>/dev/null || true
    fi

    for d in "${dirs[@]}"; do
        despues=$(( despues + $(tamano_de "$d") ))
    done
    liberado=$(( antes - despues ))
    (( liberado < 0 )) && liberado=0
    echo -e "${GREEN}✔ Cachés de aplicaciones limpias${RESET}  ${DIM}($(formatear_bytes "$liberado") liberados)${RESET}"
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
    echo -e "${GREEN}✔ Repositorios sincronizados${RESET}"
    registrar_ultima_accion "Sincronización de repositorios"
    pause
}

# 16) Limpiar kernels antiguos (mantiene el actual protegido)
limpiar_kernels_viejos() {
    echo -e "${YELLOW}Analizando kernels instalados...${RESET}"
    local kpkg okg activo
    kpkg=$(pacman -Qq 2>/dev/null | grep -E '^(linux)' | grep -Ev 'firmware|api-headers' | sort)
    if [[ -z "$kpkg" ]]; then
        echo -e "${GREEN}✔ No se detectaron paquetes de kernel.${RESET}"
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
        echo -e "${GREEN}✔ Kernels eliminados. El cargador se regenera solo en el arranque.${RESET}"
        registrar_ultima_accion "Limpieza de kernels viejos (${#quitar[@]})"
    fi
    pause
}

# 17) Revisar archivos .pacnew / .pacsave en /etc
revisar_pacnew() {
    echo -e "${YELLOW}Buscando archivos .pacnew / .pacsave en /etc...${RESET}"
    local tmpfile
    tmpfile=$(mktemp)
    find /etc -type f \( -name '*.pacnew' -o -name '*.pacsave' \) 2>/dev/null | sort > "$tmpfile"
    local total
    total=$(wc -l < "$tmpfile" 2>/dev/null || echo 0)
    if [[ "$total" -eq 0 ]]; then
        echo -e "${GREEN}✔ No hay archivos .pacnew ni .pacsave${RESET}"
    else
        echo -e "${YELLOW}⚠ ${total} archivo(s) pendientes de revisar:${RESET}"
        sed 's/^/   - /' "$tmpfile"
        local f b
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            if [[ "$f" == *.pacnew ]]; then
                b=${f%.pacnew}
                if confirmar "¿Aplicar ${f}? (backup de '${b}' se guarda como .pacsave)"; then
                    sudo cp -a "$b" "$b.pacsave" 2>/dev/null || true
                    sudo cp -a "$f" "$b" 2>/dev/null
                    echo -e "${GREEN}✔ ${b} actualizado${RESET}"
                fi
            elif confirmar "¿Mover ${f} a $HOME/backups-pacnew?"; then
                mkdir -p "$HOME/backups-pacnew"
                sudo mv "$f" "$HOME/backups-pacnew/" 2>/dev/null
                echo -e "${GREEN}✔ Archivo movido a backups-pacnew${RESET}"
            fi
        done < "$tmpfile"
    fi
    rm -f "$tmpfile"
    registrar_ultima_accion "Revisión de .pacnew/.pacsave (${total})"
    pause
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
            echo -e "${GREEN}✔ Caché DNS vaciada${RESET}"
        fi
    fi
    if command -v nmcli >/dev/null 2>&1; then
        if nmcli -t -f RUNNING general 2>/dev/null | grep -q running; then
            echo -e "${GREEN}✔ NetworkManager ejecutándose${RESET}"
        else
            echo -e "${YELLOW}NetworkManager no se está ejecutando.${RESET}"
        fi
        if confirmar "¿Reiniciar NetworkManager?"; then
            sudo systemctl restart NetworkManager
            echo -e "${GREEN}✔ NetworkManager reiniciado${RESET}"
        fi
    fi
    if command -v ping >/dev/null 2>&1; then
        echo -e "${BOLD}▸ Conectividad (ping 1.1.1.1):${RESET}"
        ping -c 3 -W 2 1.1.1.1 2>&1 | tail -3 || true
    fi
    registrar_ultima_accion "Diagnóstico de red/DNS"
    pause
}

# ─── Verificación de integridad de paquetes ─────────────
# Detecta archivos corruptos/faltantes y ofrece reparación automática.
corrupcion() {
    echo -e "${YELLOW}Revisando integridad de paquetes...${RESET}"
    local pkg tmpfile disponible rc_verif
    pkg=$(detectar_pkg_manager)
    tmpfile=$(mktemp)
    disponible=1
    rc_verif=0

    case "$pkg" in
        pacman)
            # Compatible con locales EN/ES: busca "N missing files" o
            # "N archivos no encontrados" con N > 0 y omite los "0".
            spinner "Verificando integridad con pacman" bash -c \
                "sudo pacman -Qk 2>/dev/null | grep -E '[1-9][0-9]* (missing files|archivos no encontrados)' > '$tmpfile'"
            rc_verif=$?
            ;;
        apt)
            if command -v debsums >/dev/null; then
                spinner "Verificando integridad con debsums" bash -c \
                    "sudo debsums -c 2>/dev/null > '$tmpfile'"
                rc_verif=$?
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
        total=$(wc -l < "$tmpfile" 2>/dev/null || echo 0)

        if [[ "$total" -eq 0 ]]; then
            echo -e "${GREEN}✔ No se encontraron paquetes ni archivos corruptos${RESET}"
        else
            echo -e "${YELLOW}⚠ Se encontraron ${total} paquete(s)/archivo(s) con problemas de integridad${RESET}"
            if confirmar "¿Ver el detalle?"; then
                echo ""
                cat "$tmpfile"
                echo ""
            fi
            reparar_paquetes_danados "$pkg" "$tmpfile"
        fi
        registrar_ultima_accion "Verificación de integridad (${total} problema(s))"
    elif (( rc_verif != 0 )); then
        echo -e "${YELLOW}⚠ No se pudo completar la verificación (faltan permisos sudo o el gestor falla).${RESET}"
    fi

    rm -f "$tmpfile"
    pause
}

# Reinstala los paquetes con archivos faltantes/corruptos y re-verifica.
reparar_paquetes_danados() {
    local pkg="$1" tmp="$2" lista=""
    case "$pkg" in
        pacman)
            lista=$(cut -d: -f1 "$tmp" | sort -u)
            ;;
        apt)
            # debsums -c devuelve rutas; se mapean a su paquete con dpkg -S.
            lista=$(while IFS= read -r f; do
                        [[ -z "$f" ]] && continue
                        [[ "$f" != /* ]] && f="/$f"
                        dpkg -S "$f" 2>/dev/null | cut -d: -f1
                    done < "$tmp" | sort -u)
            ;;
    esac

    if [[ -z "$lista" ]]; then
        echo -e "${YELLOW}No se pudieron identificar los paquetes; reinstálalos manualmente.${RESET}"
        return 0
    fi

    echo ""
    echo -e "${YELLOW}Paquetes a reparar:${RESET}"
    echo "$lista" | sed 's/^/   - /'
    if confirmar "¿Reinstalar automáticamente estos paquetes para repararlos?"; then
        local ok=1
        case "$pkg" in
            pacman)
                spinner "Reinstalando paquetes (pacman)" bash -c \
                    "sudo pacman -S --noconfirm $lista" || ok=0
                ;;
            apt)
                spinner "Reinstalando paquetes (apt)" bash -c \
                    "sudo apt-get -y install --reinstall $lista" || ok=0
                ;;
        esac
        if [[ "$ok" -eq 1 ]]; then
            echo -e "${GREEN}✔ Reparación completada${RESET}"
        else
            echo -e "${RED}✘ La reparación terminó con errores; revisa los mensajes de arriba.${RESET}"
        fi

        # Re-verificación después de reparar.
        local tmp2 restantes
        tmp2=$(mktemp)
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
            echo -e "${YELLOW}⚠ Quedan ${restantes} problema(s) sin resolver.${RESET}"
        else
            echo -e "${GREEN}✔ Re-verificación sin errores. Todo correcto.${RESET}"
        fi
        rm -f "$tmp2"
    fi
}

# ─── Buscar archivos grandes (> 1 GB) ──────────────────
archivos_grandes() {
    echo -e "${YELLOW}Archivos mayores a 1 GB en tu HOME:${RESET}"
    local tmpfile
    tmpfile=$(mktemp)
    spinner "Buscando archivos grandes" bash -c \
        "find \"$HOME\" -maxdepth 6 -type f -size +1G -exec du -h {} \; 2>/dev/null | sort -rh > \"$tmpfile\""
    if [[ -s "$tmpfile" ]]; then
        head -20 "$tmpfile"
        local total
        total=$(wc -l < "$tmpfile")
        echo -e "${DIM}Mostrando hasta 20 de ${total} archivo(s) encontrados.${RESET}"
        registrar_ultima_accion "Búsqueda de archivos grandes (${total} encontrados)"
    else
        echo -e "${GREEN}✔ No se encontraron archivos mayores a 1 GB${RESET}"
    fi
    rm -f "$tmpfile"
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
    tmpfile=$(mktemp)
    systemctl --failed --no-legend --plain > "$tmpfile" 2>/dev/null

    local total
    total=$(wc -l < "$tmpfile")

    if [[ "$total" -eq 0 ]]; then
        echo -e "${GREEN}✔ No hay servicios fallidos${RESET}"
    else
        echo -e "${YELLOW}⚠ ${total} servicio(s) con fallos:${RESET}"
        awk '{print "   - " $1}' "$tmpfile"
        if confirmar "¿Intentar reiniciar estos servicios?"; then
            local ok=0 fail=0 reparados=0
            while read -r linea; do
                local unidad
                unidad=$(echo "$linea" | awk '{print $1}')
                [[ -z "$unidad" ]] && continue
                if sudo systemctl restart "$unidad" 2>/dev/null; then
                    echo -e "${GREEN}✔ ${unidad} reiniciado${RESET}"
                    ok=$((ok + 1))
                else
                    # Reparación automática de swaps rotos (típico en btrfs).
                    if [[ "$unidad" == *.swap ]]; then
                        local src sz mb reparado=0
                        src=$(systemctl show -p What --value "$unidad" 2>/dev/null)
                        if [[ -n "$src" ]] && [[ -f "$src" ]]; then
                            sz=$(stat -c %s "$src" 2>/dev/null || echo 0)
                            mb=$(( sz / 1048576 ))
                            (( mb < 64 )) && mb=4096
                            if confirmar "  → El swap '$src' está roto. ¿Reconstruirlo automáticamente (~${mb} MB)?"; then
                                if crear_archivo_swap "$mb" "$src"; then
                                    sudo systemctl reset-failed "$unidad" 2>/dev/null
                                    if sudo systemctl restart "$unidad" 2>/dev/null; then
                                        echo -e "${GREEN}✔ ${unidad} reparado y en marcha${RESET}"
                                        ok=$((ok + 1))
                                        reparados=$((reparados + 1))
                                        reparado=1
                                    fi
                                fi
                            fi
                        fi
                        if [[ "$reparado" -eq 0 ]]; then
                            echo -e "${RED}✘ No se pudo recuperar ${unidad}${RESET}"
                            fail=$((fail + 1))
                        fi
                    else
                        echo -e "${RED}✘ Falló el reinicio de ${unidad}${RESET}"
                        echo -e "${DIM}   Diagnóstico: journalctl -u ${unidad} --no-pager | tail -20${RESET}"
                        fail=$((fail + 1))
                    fi
                fi
            done < "$tmpfile"
            if (( reparados > 0 )); then
                echo -e "${GREEN}✔ ${reparados} unit(s) de swap reconstruidos correctamente${RESET}"
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
#  MENÚ PRINCIPAL
# ═══════════════════════════════════════════════════════
menu() {
    while true; do
        header

        echo -e "
${CYAN}${BOLD} ──── MANTENIMIENTO ─────────────────────────────────${RESET}
${CYAN} 1)${RESET} Limpiar caché                                    ${CYAN} 2)${RESET} Paquetes huérfanos
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
        echo -e "${CYAN}18)${RESET} Diagnóstico de red y DNS
"
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
            [Ss]) system_box ;;
            0|q|Q) exit 0 ;;
            *) echo -e "${RED}Opción inválida${RESET}"; sleep 1 ;;
        esac
    done
}

# ─── Punto de entrada ─────────────────────────────────
menu
