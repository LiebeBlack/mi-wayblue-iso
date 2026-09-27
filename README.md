# Debian 14 "forky" (beta) + Labwc para Lenovo 300e (Celeron N4120)

ISO híbrida de Debian 14 **ultraligera**, con compositor Wayland **Labwc**
**sin panel** (escritorio desnudo: todo se lanza con `fuzzel`), firmware Intel
non-free y arranque nativo con **UEFI Secure Boot** (shim + GRUB firmados por
Debian/Microsoft, verificados en CI antes de publicar). 100 % gestionada con
APT: cero Flatpak, cero inmutabilidad.

## Cómo se instala y credenciales

1. **Arranca la ISO** en modo UEFI: el firmware valida `shim` → `grubx64.efi`
   (firmados por Microsoft/Debian) sin errores ni enrolado de MOK. Aparece el
   login **greetd + tuigreet**, que **siempre pide usuario y contraseña**.
2. **Sesión live**: usuario `live`, contraseña `live`, con `sudo` sin
   contraseña. Entras al escritorio Labwc (sin panel: `Super+d` abre fuzzel,
   `Super+Enter` abre el terminal `foot`).
3. **Instalar en el disco**: clic derecho en el escritorio → **"Instalar
   Debian en el disco"**. El instalador te pide idioma/teclado, **crea TU
   usuario y TU contraseña**, hace el particionado guiado y copia el sistema
   live ya optimizado al disco.
4. **Tras instalar**: reinicia y entra con **el usuario que creaste en el
   instalador**. La cuenta root está bloqueada; la administración se hace con
   `sudo`. No hay autologin en ningún caso (así el sistema instalado no
   hereda credenciales del live).

## Qué contiene la ISO

| Área | Componentes |
|---|---|
| Compositor | `labwc` (estilo Openbox), **sin panel** — escritorio desnudo |
| Lanzador | `fuzzel` (`Super+d`), terminal `foot`, fondo `swaybg`, notificaciones `mako` |
| Sesión | **greetd + tuigreet** en tty1 (sin GDM/SDDM/LightDM); `getty@tty1` desactivado para que no pelee |
| PolicyKit | `polkitd` + agente `lxpolkit` (discos/red/instalador en GUI) |
| Gráfica | `libgl1-mesa-dri` + `firmware-intel-graphics` (i915 / UHD 600) + `intel-microcode` |
| Wi-Fi | `firmware-iwlwifi` + `iwd` como backend de `network-manager` |
| Audio | `pipewire` + `wireplumber` (teclas de volumen vía `wpctl`) |
| Térmico | `thermald` (el 300e es fanless: gestiona las zonas ACPI) |
| Brillo/pantalla | `brightnessctl` (`XF86MonBrightness*`), bloqueo con `swaylock` (`Super+l`) |
| Instalador | `debian-installer-launcher` en modo *live*: copia este sistema ya optimizado al disco |
| Secure Boot | `--uefi-secure-boot enable` → `shim-signed` + `grub-efi-amd64-signed` en el ESP |

## Atajos de teclado (labwc)

| Combinación | Acción |
|---|---|
| `Super + Enter` | Terminal `foot` |
| `Super + d` | Lanzador `fuzzel` |
| `Alt + F4` | Cerrar ventana |
| `Alt + Tab` | Cambiar de ventana |
| `Super + l` | Bloquear pantalla (`swaylock`) |
| `Ctrl + Alt + ←/→` | Cambiar de escritorio virtual |
| Teclas de volumen/brillo | `wpctl` / `brightnessctl` (fn keys del 300e) |

## Estructura del repositorio

```
auto/config                          Fuente de verdad: regenera config/ en cada build
config/archives/debian.list.chroot   Repos forky + non-free + non-free-firmware
config/package-lists/*.list.chroot   Lista de paquetes
config/includes.chroot/...           Config de labwc, fuzzel, foot, greetd, sesión
config/hooks/live/*.hook.chroot      Ajustes del chroot (servicios, sudoers, TZ, locales)
verify-debian-iso.sh                 Gate: integridad ISO + firmas Secure Boot
.github/workflows/build-iso.yml      CI: compila, verifica y publica la ISO
```

## Compilar localmente (Docker)

```sh
docker run --rm --privileged -v "$PWD:/build" -w /build debian:forky sh -c '
  export DEBIAN_FRONTEND=noninteractive &&
  apt-get update &&
  apt-get install -y \
    live-build squashfs-tools xorriso dosfstools e2fsprogs mtools binutils \
    curl ca-certificates sbsigntool pesign &&
  ./auto/config && lb build'
```

El resultado es `live-image-amd64.hybrid.iso`.

## Compilar con GitHub Actions

- **Push a `main`** (cuando cambian `auto/**`, `config/**`, el gate o el workflow):
  compila la ISO, **verifica firmas e integridad** y la sube como *artifact*.
- **Pestaña Actions → Build Custom Debian 14 Labwc ISO → Run workflow**: además
  publica la ISO en las *Releases* del repositorio con su `sha256`.

## Robustez del build (nada de errores)

- **Recomendaciones de APT activadas** (`--apt-recommends true`): nunca se usa
  `--no-install-recommends`; se instala todo lo Recomendado para que no falte nada.
- **Pre-flight en CI**: espacio en disco (≥12 GB), existencia real de los suites
  `forky`/`forky-updates`/`forky-security` (si Debian renombra el suite, el build
  muere en segundos con diagnóstico, no a mitad) y `debian-archive-keyring`
  reinstalado para llaves GPG siempre frescas.
- **Reintentos**: `apt-get update` (3 en CI, 5 vía `Acquire::Retries`) y timeouts
  de 30 s ante espejos lentos.
- **Gate post-build**: `verify-debian-iso.sh` valida `filesystem.squashfs`,
  `grub.cfg`, árbol EFI completo y las firmas Authenticode de shim
  (Microsoft UEFI CA 2011) y `grubx64.efi` (Debian Secure Boot CA).

## Notas de hardware (Lenovo 300e, Celeron N4120)

- **Gráfica UHD 600**: accel 2D/3D por Mesa; el firmware lo aporta
  `firmware-intel-graphics` (non-free-firmware).
- **Wi-Fi Intel**: `iwd` + `wifi.backend=iwd` en NetworkManager
  (`/etc/NetworkManager/conf.d/90-iwd-backend.conf`).
- **Bajo consumo / fanless**: `apt-daily` desactivado; `thermald` gestionando
  las zonas térmicas ACPI; sesión Wayland pura sin Xorg.
