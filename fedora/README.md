# Fedora 44 Minimal + Labwc — ISO con Secure Boot

ISO live de **Fedora 44** ultraligera con compositor Wayland **Labwc** (estilo
Openbox), gestor de sesión **greetd + tuigreet** y arranque UEFI **Secure
Boot** nativo (shim + GRUB firmados por Fedora/Microsoft, sin errores en
hardware real).

100 % gestionada con DNF: cero Flatpak, cero inmutabilidad. Construida con
`livemedia-creator` (lorax) dentro de un contenedor oficial `fedora:44`.

## Qué contiene la ISO

| Área | Componentes |
|---|---|
| Compositor | `labwc` (window-stacking, estilo Openbox) |
| Shell | `sfwbar` (barra), `fuzzel` (lanzador), `mako` (notificaciones), `foot` (terminal) |
| Fondo | `swaybg` con color sólido (cero coste de imagen) |
| Sesión | `greetd` + `tuigreet` (VT1, sin GDM/SDDM/LightDM) |
| Polkit | `lxpolkit` (agente de autenticación mínimo) |
| Gráfica | Mesa + `intel-gpu-firmware` + `intel-microcode` (UHD 600 / Gen9+) |
| Wi-Fi | `NetworkManager-wifi` + `iwd`/`wpa_supplicant`, firmware `iwlwifi-*` |
| Audio | `pipewire` + `wireplumber` |
| Instalador | `anaconda-live` (liveinst): replica este sistema ya optimizado al disco |
| Secure Boot | `shim-x64` + `grub2-efi-x64` + `grub2-efi-x64-cdboot` firmados |

## Por qué Secure Boot funciona sin errores

La estrategia es **no re-firmar nada**:

1. Los paquetes `shim-x64`, `grub2-efi-x64` y `grub2-efi-x64-cdboot` llevan
   binarios EFI firmados por Microsoft UEFI CA 2011 (shim) y Fedora Secure
   Boot CA (GRUB).
2. Lorax coloca esos binarios firmados en el árbol ISO: `EFI/BOOT/BOOTX64.EFI`
   (shim) y `EFI/BOOT/grubx64.efi` (GRUB).
3. El kickstart nunca toca `/boot/efi` ni ejecuta `sbsign`: cualquier
   re-firmado rompería la cadena de confianza y forzaría a enrolar MOKs.
4. El workflow ejecuta `fedora/verify-secure-boot.sh` como **gate del CI**:
   extrae el árbol EFI de la ISO con `xorriso` y valida con `sbverify` que
   las firmas embebidas provienen de las CAs correctas. Si algo no cuadra,
   el build falla antes de publicar la ISO.

## Estructura de la carpeta

```
fedora/
├── kickstarts/
│   └── fedora-labwc-minimal.ks     Fuente de verdad: paquetes + %post
├── verify-secure-boot.sh           Gate del CI: firmas shim/grubx64 de la ISO
└── README.md                       Este archivo
```

## Atajos de teclado (labwc)

| Combinación | Acción |
|---|---|
| `Super + Enter` | Terminal `foot` |
| `Super + d` | Lanzador `fuzzel` |
| `Alt + F4` | Cerrar ventana |
| `Alt + Tab` | Cambiar ventana |
| `Ctrl + Alt + ←/→` | Cambiar escritorio virtual |
| `Super + l` | Bloquear pantalla (`swaylock`) |
| Clic derecho | Menú raíz (incluye `liveinst` para instalar al disco) |

## Compilar localmente (Docker/Podman)

```sh
podman run --rm --privileged -v "$PWD:/build:z" -w /build fedora:44 bash -c '
  dnf install -y git-core lorax xorriso sbsigntools pesign e2fsprogs dosfstools &&
  setenforce 0 2>/dev/null; livemedia-creator --make-iso --no-virt \
    --ks fedora/kickstarts/fedora-labwc-minimal.ks \
    --resultdir /tmp/out --tmp /tmp/lmc \
    --releasever 44 --nomacboot --iso-only --iso-name fedora44-labwc-minimal.iso'
```

> Nota: `--no-virt` usa Anaconda directamente en el contenedor (más rápido y
> sin necesidad de KVM en el runner). El contenedor debe ser `--privileged`
> por los loop devices/montajes, igual que el workflow Debian de este repo.

## Compilar con GitHub Actions

- **Push a `main`** (cuando cambian `fedora/**` o el workflow): compila la ISO
  y la sube como *artifact* descargable.
- **Pestaña Actions → Build Fedora 44 Labwc ISO → Run workflow**: además
  publica la ISO en las *Releases* con su `sha256`.
- El paso **Verify Secure Boot signatures** es un gate: si shim o grubx64 no
  tienen firma válida, el build falla y no se publica nada.

## Usuario del live

- Usuario `live` (grupo `wheel`) sin contraseña en el entorno live
  (`sudo` sin contraseña, patrón de las spins oficiales de Fedora).
- `tuigreet` autologin silencioso: recuerda usuario y sesión
  (`--remember --remember-user-session --cmd labwc`).
- Tras instalar al disco, la misma configuración funciona; solo habría que
  dar contraseña al usuario.
