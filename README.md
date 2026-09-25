# Debian 13 + Labwc para Lenovo 300e (Celeron N4120)

ISO híbrida de Debian 13 "trixie" **ultraligera**, con compositor Wayland **Labwc**,
firmware Intel non-free y arranque nativo con **UEFI Secure Boot** (shim + GRUB firmados).
100 % gestionada con APT: cero Flatpak, cero inmutabilidad.

## Qué contiene la ISO

| Área | Componentes |
|---|---|
| Compositor | `labwc` (estilo Openbox) |
| Shell | `wf-shell` (panel + fondo), `fuzzel` (lanzador), `mako` (notificaciones), `foot` (terminal) |
| Fondo | `swaybg` con color sólido (cero coste de imagen) |
| Gráfica | `libgl1-mesa-dri` + `firmware-intel-graphics` (i915 / UHD 600) + `intel-microcode` |
| Wi-Fi | `firmware-iwlwifi` + `iwd` como backend de `network-manager` |
| Audio | `pipewire` + `wireplumber` |
| Sesión | Sin display manager: `.profile` ejecuta labwc en tty1 |
| Instalador | debian-installer en modo *live*: copia este sistema ya optimizado al disco |
| Secure Boot | `--uefi-secure-boot enable` → `shim-signed` + `grub-efi-amd64-signed` en el ESP |

## Atajos de teclado (labwc)

| Combinación | Acción |
|---|---|
| `Super + Enter` | Terminal `foot` |
| `Super + d` | Lanzador `fuzzel` |
| `Alt + F4` | Cerrar ventana |

## Estructura del repositorio

```
auto/config                          Fuente de verdad: regenera config/ en cada build
config/archives/debian.list.chroot   Repos trixie + non-free + non-free-firmware
config/package-lists/*.list.chroot   Mini-lista de paquetes
config/includes.chroot/...           Config de labwc, wf-shell, sesión, NetworkManager
config/hooks/live/*.hook.chroot      Ajustes del chroot (servicios, apt-daily)
.github/workflows/build-iso.yml      CI: compila y publica la ISO
```

## Compilar localmente (Docker)

```sh
docker run --rm --privileged -v "$PWD:/build" -w /build debian:trixie sh -c '
  apt-get update &&
  apt-get install -y --no-install-recommends \
    live-build squashfs-tools xorriso dosfstools e2fsprogs mtools binutils curl ca-certificates &&
  ./auto/config && lb build'
```

El resultado es `live-image-amd64.hybrid.iso`.

## Compilar con GitHub Actions

- **Push a `main`** (cuando cambian `auto/**`, `config/**` o el workflow): compila la ISO
  y la sube como *artifact* descargable.
- **Pestaña Actions → Build Custom Debian 13 Labwc ISO → Run workflow**: además publica
  la ISO en las *Releases* del repositorio con su `sha256`.

## Notas de hardware (Lenovo 300e, Celeron N4120)

- **Gráfica UHD 600**: accel 2D/3D por Mesa; el firmware lo aporta `firmware-intel-graphics`.
- **Wi-Fi AX201**: `iwd` + `wifi.backend=iwd` en NetworkManager (necesario porque se
  compila con `--apt-recommends false` y sin wpa_supplicant).
- **Bajo consumo**: `apt-daily` desactivado en la imagen; sesión Wayland sin Xorg.

## Correcciones aplicadas respecto a la propuesta original

| Original | Corregido |
|---|---|
| `firmware-graphics-cuda` (no existe) | `firmware-intel-graphics` |
| `i9565-microcode` (no existe) | `intel-microcode` |
| Base bookworm (sin `labwc`) | Debian 13 **trixie** (estable, lo incluye) |
| `keybind name="W-Return"` (sintaxis Openbox) | `keybind key="W-Return"` (sintaxis labwc) |
| Tema `Flat-Dark` (no existe) | tema por defecto |
| `lb config` en `auto/config` → recursión infinita | `lb config noauto` |
| Sin `--archive-areas` non-free-firmware | añadido en `auto/config` |
| `sudo lb config` en CI pisa la config del repo | CI ejecuta `./auto/config` |
| live-build viejo del runner Ubuntu | job en contenedor `debian:trixie` |
| runit como PID 1 (rompe live-boot/d-i) | systemd puro |
