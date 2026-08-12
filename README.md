<div align="center">

# ☕ Kyro Optimizer

**Herramienta integral de mantenimiento, diagnóstico y optimización de rendimiento para sistemas Linux.**

![Licencia GPL-3.0](https://img.shields.io/badge/Licencia-GPL--3.0-blue.svg)
![Versión 3.4](https://img.shields.io/badge/Versión-3.4-green.svg)
![Bash 4.0+](https://img.shields.io/badge/Bash-4.0%2B-orange.svg)

</div>

---

## 📌 Descripción

**Kyro Optimizer** es un script interactivo y modular escrito en Bash, diseñado para simplificar el mantenimiento preventivo, la depuración de espacio y el afinamiento (*tweaking*) de rendimiento de hardware en distribuciones Linux como CachyOS y Arch Linux.

Con una interfaz gráfica de terminal muy cuidada (colores ANSI, barras de progreso y arte ASCII), Kyro permite ejecutar limpiezas profundas y optimizaciones del kernel en segundos de forma segura y automatizada.

---

## ✨ Características Principales

### 🧹 1. Limpieza Todo-en-Uno de Caché y Espacio
* **Gestores de Paquetes:** Compatible con `pacman`, `apt`, `dnf`, `zypper` y `apk`.
* **Caché de AUR y Asistentes:** Limpieza en `yay`, `paru`, `pamac`, entre otros.
* **Navegadores Web:** Firefox, Chrome, Chromium, Brave, Edge, Vivaldi, LibreWolf, Zen, Opera, etc.
* **Entornos de Desarrollo y Lenguajes:** Node.js (`npm`, `yarn`, `pnpm`, `bun`), Python (`pip`, `uv`, `pipx`, `poetry`), Rust (`cargo`), Go, PHP (`composer`), Deno, etc.
* **Aplicaciones de Escritorio:** Discord, Telegram, Spotify, VS Code, JetBrains, OBS Studio, Slack, Zoom, etc.
* **Paquetes de Compatibilidad:** Formatos AppImage y cachés independientes de Flatpak (sin alterar configuraciones ni datos personales).
* **Logs y Volcados:** Compactación de journal systemd a 7 días y eliminación de coredumps obsoletos.

### 📦 2. Gestión de Paquetes Huérfanos
* Detección y purga automatizada de dependencias no utilizadas según el gestor instalado (`pacman -Qtdq`, `apt autoremove`, etc.).

### 🗑️ 3. Limpieza de Papelera y Directorios Vacíos
* Vaciado seguro de la papelera del usuario (`~/.local/share/Trash`).
* Depuración de carpetas vacías en `$HOME` protegiendo estrictamente archivos ocultos (`.config`, `.local`), prefijos Wine/Proton (Steam, Lutris, Heroic, Bottles) y rutas críticas.

### ⚙️ 4. Optimización de Hardware Adaptativa
* **Perfiles de Rendimiento:**
  * ⚡ **Máximo rendimiento:** Latencia reducida, retención intensiva en RAM.
  * ⚖️ **Equilibrado (Recomendado):** Balance óptimo entre fluidez y consumo.
  * 🛡️ **Máxima estabilidad:** Ajustes conservadores y menor estrés al hardware.
  * 🎮 **Gaming (Rendimiento Puro):** Ajustes de `vm.max_map_count` para Proton/Vulkan, swap optimizado para cargas pesadas.
* **Ajustes de Memoria Virtual (`sysctl`):** Configuración inteligente de `swappiness`, `vfs_cache_pressure`, `dirty_ratio`, `compaction_proactiveness` y `page-cluster`.
* **Gestión de Gobernador de CPU:** Cambio rápido entre `performance`, `powersave`, `ondemand`, etc.
* **Planificador de E/S (I/O Schedulers):** Detección automática de SSD, NVMe y HDD para asignar `none`, `mq-deadline` o `bfq`.
* **Gestión de Swap:** Creación y gestión inteligente de archivos de Swap compatibles con **Btrfs** (soporte para `NOCOW` y `mkswapfile` de CachyOS) y `ext4`.
* **Persistencia Systemd:** Creación automática de servicios systemd (`kyro-perf.service` / `kyro-quick.service`) para mantener los ajustes tras reiniciar.

### 🩺 5. Diagnóstico de Hardware y Salud del Sistema
* Análisis de logs del kernel (`journalctl` / `dmesg`).
* Lectura del estado **S.M.A.R.T.** de unidades SSD/NVMe/HDD con `smartctl`.
* Monitoreo de eventos **MCE** (Machine Check Exception), errores de memoria ECC y NVMe Error Logs.
* Lectura de temperaturas del sistema (`sensors` y zonas térmicas `/sys/class/thermal`).
* Módulo de **Análisis a Profundidad** para distinguir advertencias menores de fallos reales de hardware.

### 📊 6. Panel de Monitoreo en Vivo
* Métrica en tiempo real de CPU, RAM, uso de disco y temperaturas.

---

## 🚀 Instalación y Uso

### Ejecución Rápida (One-Liner)

Puedes ejecutar Kyro directamente descargándolo vía `curl` o `wget`:

```bash
bash -c "$(curl -fsSL [https://raw.githubusercontent.com/mykosoftware/Kyro/main/Kyro.sh](https://raw.githubusercontent.com/mykosoftware/Kyro/main/Kyro.sh))"
