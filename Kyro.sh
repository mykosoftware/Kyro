#!/bin/bash

# ═══════════════════════════════════════════════════════
#  Kyro Optimizer – Mantenimiento y diagnóstico del sistema
#  Licencia: GPL-3.0
#  Versión: 2.2
# ═══════════════════════════════════════════════════════

set -uo pipefail
VERSION="2.2"

# ─── Colores ───────────────────────────────────────────
CYAN="\e[36m"
GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
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

registrar_ultima_accion() {
    mkdir -p "$HOME/.cache" 2>/dev/null || true
    echo "$1|$(date '+%Y-%m-%d %H:%M:%S')" > "$STATE_FILE" 2>/dev/null || true
}

# ─── Barra de progreso animada ─────────────────────────
progress_bar() {
    local msg="$1"
    local dur="${2:-2}"
    local ancho=30
    local pasos=30
    local delay
    delay=$(awk -v d="$dur" -v p="$pasos" 'BEGIN{print d/p}')

    for ((i = 1; i <= pasos; i++)); do
        local llenos=$((i * ancho / pasos))
        local vacios=$((ancho - llenos))
        local pct=$((i * 100 / pasos))
        printf "\r${CYAN}%s${RESET} [" "$msg"
        printf "%0.s█" $(seq 1 "$llenos") 2>/dev/null
        printf "%0.s░" $(seq 1 "$vacios") 2>/dev/null
        printf "] ${BOLD}%3d%%${RESET}" "$pct"
        sleep "$delay"
    done
    echo ""
}

# Spinner para comandos de duración desconocida.
spinner() {
    local msg="$1"; shift
    local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local tmp_out
    tmp_out=$(mktemp)

    ("$@" >"$tmp_out" 2>&1; echo $? > "${tmp_out}.rc") &
    local pid=$!

    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        local frame="${frames:i++%${#frames}:1}"
        printf "\r${CYAN}%s${RESET} %s " "$frame" "$msg"
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

# Barra visual simple para porcentajes (usada en resumen del sistema)
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
    printf "${color}"
    printf "%0.s▮" $(seq 1 "$llenos") 2>/dev/null
    printf "${DIM}"
    printf "%0.s▯" $(seq 1 "$vacios") 2>/dev/null
    printf "${RESET} %3d%%" "$pct"
}

# Calcula el % de uso de CPU a partir de dos lecturas de /proc/stat (línea "cpu ")
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
    esac

    local linea1="    kernel       $(printf '%-20s' "$kernel")"
    local linea2="    uptime       $(printf '%-20s' "$uptime")"
    local linea3="    shell        $(printf '%-20s' "$shell")"
    local linea4="    mem          $(printf '%-20s' "${mem_used}MB / ${mem_total}MB")"
    local linea5="    pkgs         $(printf '%-20s' "$pkgs")"
    local linea6="    user         $(printf '%-20s' "$user")"
    local linea7="    hname        $(printf '%-20s' "$hostname")"
    local linea8="  󰻀  distro       $(printf '%-20s' "$distro")"

    echo -e "${CYAN}"
    echo "     ╭───────────────────────────────────╮"
    echo "$linea1"
    echo "$linea2"
    echo "$linea3"
    echo "$linea4"
    echo "$linea5"
    echo "$linea6"
    echo "$linea7"
    echo "$linea8"
    echo "     ╰───────────────────────────────────╯"
    echo -e "${RESET}"

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
                spinner "Purgando caché de pacman" sudo paccache -r || true
            else
                echo -e "${RED}paccache no encontrado. Instala pacman-contrib.${RESET}"
            fi
            ;;
        apt)
            spinner "Limpiando caché de apt" sudo apt clean || true
            ;;
        dnf)
            spinner "Limpiando caché de dnf" sudo dnf clean all || true
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
        spinner "Reduciendo logs a 7 días" sudo journalctl --vacuum-time=7d || true
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

optimizar_hardware() {
    clear
    echo -e "${CYAN}${BOLD}╭─ Analizador de hardware ────────────────────────────────────────╮${RESET}"
    echo -e "${CYAN}│${RESET} Analizando CPU, RAM y almacenamiento, un momento...${CYAN}"
    echo -e "${CYAN}╰──────────────────────────────────────────────────────────────────╯${RESET}"

    # ── Detección de disco (SSD/HDD/NVMe) ──
    local root_dev base_dev rotational tipo_disco es_nvme=0
    root_dev=$(df --output=source / 2>/dev/null | tail -1)
    if command -v lsblk >/dev/null; then
        base_dev=$(lsblk -no pkname "$root_dev" 2>/dev/null | head -1)
    fi
    [[ -z "$base_dev" ]] && base_dev=$(basename "${root_dev:-}" 2>/dev/null | sed -E 's/p?[0-9]+$//')
    [[ "$base_dev" == nvme* ]] && es_nvme=1

    rotational="?"
    [[ -f "/sys/block/$base_dev/queue/rotational" ]] && rotational=$(cat "/sys/block/$base_dev/queue/rotational" 2>/dev/null)

    case "$rotational" in
        0) tipo_disco="SSD" ;;
        1) tipo_disco="HDD" ;;
        *) tipo_disco="Desconocido" ;;
    esac
    (( es_nvme == 1 )) && tipo_disco="SSD (NVMe)"

    # ── Detección de RAM ──
    local ram_mb ram_gb
    ram_mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    [[ -z "$ram_mb" ]] && ram_mb=0
    ram_gb=$(awk -v m="$ram_mb" 'BEGIN{printf "%.1f", m/1024}')

    # ── Detección de CPU ──
    local cpu_model nucleos
    cpu_model=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ *//')
    [[ -z "$cpu_model" ]] && cpu_model="Desconocido"
    nucleos=$(nproc 2>/dev/null || echo "?")

    local es_laptop="No"
    compgen -G "/sys/class/power_supply/BAT*" >/dev/null 2>&1 && es_laptop="Sí"

    local governor_actual="N/D"
    [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]] && \
        governor_actual=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)

    local sched_actual="N/D"
    if [[ -f "/sys/block/$base_dev/queue/scheduler" ]]; then
        sched_actual=$(grep -oP '\[\K[^\]]+' "/sys/block/$base_dev/queue/scheduler" 2>/dev/null)
        [[ -z "$sched_actual" ]] && sched_actual=$(cat "/sys/block/$base_dev/queue/scheduler" 2>/dev/null)
    fi

    local swappiness_actual
    swappiness_actual=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "60")

    local swap_actual_mb
    swap_actual_mb=$(free -m 2>/dev/null | awk '/^Swap:/{print $2}')
    [[ -z "$swap_actual_mb" ]] && swap_actual_mb=0

    # ── Cálculo de recomendaciones según el hardware ──
    local swap_rec
    if (( ram_mb <= 2048 )); then
        swap_rec=$((ram_mb * 2))
    elif (( ram_mb <= 8192 )); then
        swap_rec=$ram_mb
    elif (( ram_mb <= 16384 )); then
        swap_rec=$((ram_mb / 2))
    else
        swap_rec=4096
    fi

    local swappiness_rec
    if (( ram_mb >= 16384 )); then
        swappiness_rec=5
    elif (( ram_mb >= 8192 )); then
        swappiness_rec=10
    else
        swappiness_rec=30
    fi
    [[ "$tipo_disco" == "HDD" ]] && swappiness_rec=$((swappiness_rec + 20))
    (( swappiness_rec > 60 )) && swappiness_rec=60

    local governor_rec
    if [[ "$es_laptop" == "Sí" ]]; then
        governor_rec="powersave"
    else
        governor_rec="performance"
    fi

    local sched_rec
    if (( es_nvme == 1 )); then
        sched_rec="none"
    elif [[ "$tipo_disco" == SSD* ]]; then
        sched_rec="mq-deadline"
    else
        sched_rec="bfq"
    fi

    # ── Mostrar hardware detectado ──
    echo ""
    echo -e "${CYAN}${BOLD}╭─ Hardware detectado ────────────────────────────────────────────╮${RESET}"
    echo -e "${CYAN}│${RESET} CPU:                        ${cpu_model} (${nucleos} núcleos)"
    echo -e "${CYAN}│${RESET} RAM:                        ${ram_gb} GiB (${ram_mb} MB)"
    echo -e "${CYAN}│${RESET} Disco (/):                  /dev/${base_dev:-?}  →  ${tipo_disco}"
    echo -e "${CYAN}│${RESET} Portátil (batería):         ${es_laptop}"
    echo -e "${CYAN}│${RESET} Gobernador de CPU actual:   ${governor_actual}"
    echo -e "${CYAN}│${RESET} Planificador E/S actual:    ${sched_actual}"
    echo -e "${CYAN}│${RESET} Swap actual:                ${swap_actual_mb} MB  (swappiness: ${swappiness_actual})"
    echo -e "${CYAN}╰──────────────────────────────────────────────────────────────────╯${RESET}"

    echo ""
    echo -e "${CYAN}${BOLD}╭─ Recomendaciones para tu equipo ───────────────────────────────╮${RESET}"
    echo -e "${CYAN}│${RESET} Swap recomendado:              ${swap_rec} MB"
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
                echo -e "${GREEN}✔ Gobernador aplicado (no persiste tras reiniciar sin un servicio)${RESET}"
            else
                echo -e "${YELLOW}⚠ No se pudo aplicar en todos los núcleos${RESET}"
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
    if (( swap_actual_mb < swap_rec - 256 )); then
        echo ""
        echo -e "${YELLOW}Tu swap actual (${swap_actual_mb} MB) es menor al recomendado (${swap_rec} MB).${RESET}"
        if confirmar "  → ¿Crear un archivo de swap adicional de $((swap_rec - swap_actual_mb)) MB en /swapfile_kyro?"; then
            local extra=$((swap_rec - swap_actual_mb))
            progress_bar "Creando archivo de swap" 2
            if sudo fallocate -l "${extra}M" /swapfile_kyro 2>/dev/null || sudo dd if=/dev/zero of=/swapfile_kyro bs=1M count="$extra" status=none 2>/dev/null; then
                sudo chmod 600 /swapfile_kyro 2>/dev/null
                sudo mkswap /swapfile_kyro >/dev/null 2>&1
                sudo swapon /swapfile_kyro 2>/dev/null
                if ! grep -q "/swapfile_kyro" /etc/fstab 2>/dev/null; then
                    echo "/swapfile_kyro none swap sw 0 0" | sudo tee -a /etc/fstab >/dev/null 2>&1 || true
                fi
                echo -e "${GREEN}✔ Swap adicional creado y activado${RESET}"
                registrar_ultima_accion "Swap ampliado (+${extra}MB) según hardware detectado"
            else
                echo -e "${RED}✘ No se pudo crear el archivo de swap${RESET}"
            fi
        fi
    else
        echo -e "${GREEN}✔ Tu swap actual ya es adecuado para tu RAM${RESET}"
        registrar_ultima_accion "Análisis de hardware (${tipo_disco}, ${ram_gb}GiB RAM)"
    fi

    pause
}
corrupcion() {
    echo -e "${YELLOW}Revisando integridad de paquetes...${RESET}"
    local pkg
    pkg=$(detectar_pkg_manager)
    local tmpfile
    tmpfile=$(mktemp)
    local disponible=1

    case "$pkg" in
        pacman)
            spinner "Verificando integridad con pacman" bash -c \
                "sudo pacman -Qk 2>/dev/null | grep -v '0 missing files' > '$tmpfile'"
            ;;
        apt)
            if command -v debsums >/dev/null; then
                spinner "Verificando integridad con debsums" bash -c \
                    "sudo debsums -c 2>/dev/null > '$tmpfile'"
            else
                echo -e "${RED}Instala 'debsums' para esta verificación.${RESET}"
                disponible=0
            fi
            ;;
        dnf|*)
            echo -e "${RED}Verificación no disponible para este gestor.${RESET}"
            disponible=0
            ;;
    esac

    if [[ "$disponible" -eq 1 ]]; then
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
        fi
        registrar_ultima_accion "Verificación de integridad (${total} problema(s))"
    fi

    rm -f "$tmpfile"
    pause
}

consumo() {
    clear
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
        elif [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
            temp_str="$(awk '{printf "%.1f°C", $1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null)"
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

# 10) Buscar archivos grandes (>1 GB)
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

# 11) Servicios systemd fallidos
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
            local ok=0 fail=0
            while read -r linea; do
                local unidad
                unidad=$(echo "$linea" | awk '{print $1}')
                [[ -z "$unidad" ]] && continue
                if sudo systemctl restart "$unidad" 2>/dev/null; then
                    echo -e "${GREEN}✔ ${unidad} reiniciado${RESET}"
                    ok=$((ok + 1))
                else
                    echo -e "${RED}✘ Falló el reinicio de ${unidad}${RESET}"
                    fail=$((fail + 1))
                fi
            done < "$tmpfile"
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
${CYAN}1)${RESET} Limpiar caché
${CYAN}2)${RESET} Paquetes huérfanos
${CYAN}3)${RESET} Limpiar logs del sistema
${CYAN}4)${RESET} Optimizar hardware (CPU/RAM/swap/disco)
${CYAN}5)${RESET} Buscar directorios vacíos
${CYAN}6)${RESET} Vaciar papelera
${CYAN}7)${RESET} Verificar corrupción de paquetes
${CYAN}8)${RESET} Panel en vivo (CPU/RAM/temp)
${CYAN}9)${RESET} Monitor de recursos (btop/htop/top)
${CYAN}10)${RESET} Buscar archivos grandes (>1 GB)
${CYAN}11)${RESET} Servicios systemd fallidos
${CYAN}S)${RESET} Mostrar resumen del sistema
${RED}0)${RESET} Salir
"
        read -rp "Kyro > " opcion || opcion="0"

        case "$opcion" in
            1) cache ;;
            2) paquetes_huerfanos ;;
            3) logs ;;
            4) optimizar_hardware ;;
            5) directorios_vacios ;;
            6) papelera ;;
            7) corrupcion ;;
            8) consumo ;;
            9) monitor ;;
            10) archivos_grandes ;;
            11) servicios_fallidos ;;
            [Ss]) system_box ;;
            0) exit 0 ;;
            *) echo -e "${RED}Opción inválida${RESET}"; sleep 1 ;;
        esac
    done
}

# ─── Punto de entrada ─────────────────────────────────
menu
