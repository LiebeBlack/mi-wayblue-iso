# =============================================================================
# Fedora 44 Minimal + Labwc (Wayland) — ISO live con Secure Boot
# =============================================================================
# Construida con livemedia-creator (lorax) desde el workflow de GitHub Actions:
#   .github/workflows/build-fedora-iso.yml
#
# Diseño (espejo del stack Debian/Labwc del repo, pero con RPM/DNF):
#   * Base @core mínima (sin Xorg, sin GNOME/KDE) + compositor Wayland labwc
#   * Barra sfwbar, lanzador fuzzel, terminal foot, notificaciones mako
#   * Fondo swaybg (color sólido), bloqueo swaylock
#   * Gestor de sesión ligero: greetd + tuigreet (sin GDM/SDDM/LightDM)
#   * Agente polkit mínimo: lxpolkit (PolicyKit-authentication-agent)
#   * Arranque UEFI Secure Boot nativo: shim-x64 y grub2-efi-x64 firmados por
#     Fedora/Microsoft. Los binarios firmados del árbol ISO (BOOTX64.EFI,
#     grubx64.efi) los genera lorax a partir de estos paquetes; NUNCA se
#     re-firman a mano.
#   * Instalador live (anaconda-live / liveinst) que replica este sistema
# =============================================================================

lang es_ES.UTF-8
keyboard es
timezone Europe/Madrid

# -----------------------------------------------------------------------------
# Red y repos. En livemedia-creator solo se permite un "url"; el resto son
# "repo" y NINGUNO puede llamarse "updates" (nombre reservado de Anaconda).
# -----------------------------------------------------------------------------
network --bootproto=dhcp --activate

url --url="https://download.fedoraproject.org/pub/fedora/linux/releases/44/Everything/x86_64/os/"
repo --name="fedora-updates" --baseurl="https://mirrors.kernel.org/fedora/updates/44/Everything/x86_64/"

# =============================================================================
# PARTICIONADO
# =============================================================================
bootloader --location=none
zerombr
clearpart --all

# reqpart crea las particiones obligatorias del firmware (ESP efi + biosboot)
reqpart
part / --fstype="ext4" --size=8192

# =============================================================================
# PAQUETES
# =============================================================================
%packages --exclude-weakdeps
@core

# --- Stack de arranque / live (requisitos de livemedia-creator) ---------------
# dracut-config-generic + dracut-live: initramfs generico y arranque live.
# shim-x64 + grub2-efi-x64 + grub2-efi-x64-cdboot: binarios EFI FIRMADOS por
#   Fedora/Microsoft. Lorax los usa en la fase de ISO (x86.tmpl) para poblar
#   EFI/BOOT/BOOTX64.EFI (shim) y EFI/BOOT/grubx64.efi (GRUB firmado). Con
#   Secure Boot ON, el firmware valida la cadena completa sin ningun error.
shim-x64
grub2-efi-x64
grub2-efi-x64-cdboot
grub2-tools
grub2-tools-extra
efibootmgr
mokutil
dracut
dracut-config-generic
dracut-live
dracut-network
-dracut-config-rescue
syslinux-nonlinux
kernel
kernel-modules
kernel-modules-extra

# --- Instalador live ----------------------------------------------------------
anaconda-live
anaconda-dracut

# --- Gráficos / Mesa ----------------------------------------------------------
mesa-dri-drivers
mesa-libEGL
mesa-libGL
mesa-libgbm
mesa-vulkan-drivers
vulkan-loader

# --- Firmware / microcode (hardware objetivo: Intel iGPU + Wi-Fi Intel) -------
intel-microcode
alsa-sof-firmware
iwlwifi-mvm-firmware
iwlwifi-dvm-firmware
iwlegacy-firmware
intel-gpu-firmware

# --- Compositor Wayland (labwc lo arrastra: wlroots0.19, libinput, etc.) ------
labwc
sfwbar
foot
fuzzel
mako
swaybg
swaylock
brightnessctl

# --- Sesión / gestor de login ligero ------------------------------------------
greetd
tuigreet
polkit
lxpolkit

# --- Integración de escritorio Wayland ----------------------------------------
xdg-user-dirs
adwaita-icon-theme
xdg-desktop-portal
xdg-desktop-portal-wlr
libnotify
gsettings-desktop-schemas
dbus-tools
dbus-daemon

# --- Tipografías mínimas ------------------------------------------------------
google-noto-sans-vf-fonts
google-noto-sans-mono-vf-fonts
dejavu-sans-fonts
dejavu-sans-mono-fonts

# --- Audio --------------------------------------------------------------------
pipewire
pipewire-alsa
pipewire-pulseaudio
wireplumber

# --- Red ----------------------------------------------------------------------
NetworkManager-wifi
wpa_supplicant
iwd
NetworkManager-openvpn
dnsmasq
iw
wget2
curl
git-core
chrony

# --- Utilidades mínimas -------------------------------------------------------
nano
zstd
xz
file
less
nvme-cli
dmidecode
usbutils
pciutils
lm_sensors
gnome-keyring
gnome-keyring-pam

# --- Excluir peso innecesario de @core ----------------------------------------
-firewalld
-sssd
-sssd-common
-sssd-client
-sssd-ad
-sssd-krb5
-abrt
-abrt-cli
-abrt-desktop
-kexec-tools
-kernel-debug
-kernel-debug-core
-kernel-debug-devel
-kernel-debug-modules
-kernel-debug-modules-extra
-kernel-rt
-kernel-rt-core
-kernel-rt-devel
-kernel-doc
-perf
-bpftrace
-bcc
-sysstat
-iotop
-tcpdump
-wireshark-cli
-nmap-ncat
-alsa-utils
-alsa-plugins-pulseaudio
-pulseaudio
-bash-completion
-glibc-minimal-langpack
-coreutils-single
%end

# =============================================================================
# CONTRASEÑAS Y USUARIO
# =============================================================================
rootpw --lock
user --name=live --gecos="Live System User" --groups=wheel

# =============================================================================
# SERVICIOS
# =============================================================================
services --enabled=NetworkManager,greetd,chronyd

# =============================================================================
# POST-CONFIGURACIÓN
# =============================================================================
%post --erroronfail
set -eu

LIVE_USER="live"

date "+%Y%m%d_%H%M" > /etc/build-date

# -----------------------------------------------------------------------------
# 1) Servicios del live
# -----------------------------------------------------------------------------
systemctl enable NetworkManager.service >/dev/null 2>&1 || true
systemctl enable greetd.service        >/dev/null 2>&1 || true
systemctl enable chronyd.service       >/dev/null 2>&1 || true
systemctl disable sshd.service         >/dev/null 2>&1 || true
# getty no debe pelear por la VT1 que usara greetd
systemctl disable getty@tty1.service   >/dev/null 2>&1 || true

# -----------------------------------------------------------------------------
# 2) sudo sin contraseña para el usuario del live (patron de las spins Fedora)
# -----------------------------------------------------------------------------
echo "${LIVE_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${LIVE_USER}-live"
chmod 0440 "/etc/sudoers.d/90-${LIVE_USER}-live"

# -----------------------------------------------------------------------------
# 3) Config de labwc/sfwbar/foot en /etc/skel (y en el home del live)
# -----------------------------------------------------------------------------
mkdir -p /etc/skel/.config/labwc
cp /usr/share/doc/labwc-0*/rc.xml /etc/skel/.config/labwc/rc.xml 2>/dev/null || \
  cp /usr/share/doc/labwc/rc.xml /etc/skel/.config/labwc/rc.xml 2>/dev/null || true
cp /usr/share/doc/labwc-0*/menu.xml /etc/skel/.config/labwc/menu.xml 2>/dev/null || \
  cp /usr/share/doc/labwc/menu.xml /etc/skel/.config/labwc/menu.xml 2>/dev/null || true

# environment: teclado español + autostart de la sesión completa
cat > /etc/skel/.config/labwc/environment <<'EOF'
XKB_DEFAULT_LAYOUT=es
XKB_DEFAULT_MODEL=pc105
EOF

cat > /etc/skel/.config/labwc/autostart <<'EOF'
swaybg -c '#20242c' &
sfwbar &
mako &
lxpolkit &
EOF

# rc.xml: atajos mínimos (mismo esquema que la ISO Debian del repo)
cat > /etc/skel/.config/labwc/rc.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<labwc_config>
  <theme>
    <name></name>
    <cornerRadius>6</cornerRadius>
  </theme>
  <keyboard>
    <default />
    <keybind key="W-Return"><action name="Execute" command="foot" /></keybind>
    <keybind key="W-d"><action name="Execute" command="fuzzel" /></keybind>
    <keybind key="A-Tab"><action name="NextWindow" /></keybind>
    <keybind key="A-F4"><action name="Close" /></keybind>
    <keybind key="W-l"><action name="Execute" command="swaylock" /></keybind>
    <keybind key="C-A-Left"><action name="GoToDesktop" to="left" wrap="yes" /></keybind>
    <keybind key="C-A-Right"><action name="GoToDesktop" to="right" wrap="yes" /></keybind>
  </keyboard>
  <mouse>
    <default />
  </mouse>
</labwc_config>
EOF

# menu.xml: menú de aplicación con root-click
cat > /etc/skel/.config/labwc/menu.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu>
  <menu id="root-menu" label="Applications">
    <item label="Terminal (foot)"><action name="Execute" command="foot" /></item>
    <item label="Lanzador (fuzzel)"><action name="Execute" command="fuzzel" /></item>
    <item label="Live Installer"><action name="Execute" command="liveinst" /></item>
    <item label="Bloquear pantalla"><action name="Execute" command="swaylock" /></item>
  </menu>
</openbox_menu>
EOF

# sfwbar: panel mínimo (reloj, batería, red, volume)
cat > /etc/skel/.config/sfwbar/config <<'EOF'
layout {
  * { size = 0 }
  widget = clock { interval = 1, format = "%d/%m %H:%M" }
  widget = battery {}
  widget = network {}
  widget = volume {}
}
EOF

# foot: terminal minimal
mkdir -p /etc/skel/.config/foot
cat > /etc/skel/.config/foot/foot.ini <<'EOF'
[main]
font=monospace:size=11
shell=/bin/bash
EOF

# greetd + tuigreet: autologin silencioso del live (usuario live sin password).
# La misma config vale tras instalar; solo habria que dar password al usuario.
cat > /etc/greetd/config.toml <<'EOF'
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --remember --remember-user-session --asterisks --cmd labwc"
user = "greeter"
EOF
chmod 0644 /etc/greetd/config.toml

# Aplicar la config al usuario del live ya creado por el kickstart
for f in .config/labwc/rc.xml .config/labwc/menu.xml .config/labwc/environment .config/labwc/autostart .config/sfwbar/config .config/foot/foot.ini; do
    if [ -f "/etc/skel/${f}" ]; then
        install -D -m 0644 "/etc/skel/${f}" "/home/${LIVE_USER}/${f}" 2>/dev/null || true
    fi
done
chown -R "${LIVE_USER}:${LIVE_USER}" "/home/${LIVE_USER}/.config" 2>/dev/null || true

# -----------------------------------------------------------------------------
# 4) fstab vacio: dracut monta el rootfs del live (recomendacion oficial lmc)
# -----------------------------------------------------------------------------
> /etc/fstab

# -----------------------------------------------------------------------------
# 5) Limpieza y estado reproducible
# -----------------------------------------------------------------------------
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true
dnf -y clean all >/dev/null 2>&1 || true
rm -rf /var/cache/libdnf5 /var/cache/dnf 2>/dev/null || true

%end

# =============================================================================
# NOTA SOBRE SECURE BOOT
# =============================================================================
# El %post no toca ningun binario EFI. Lorax copia, ya dentro de la ISO:
#   * EFI/BOOT/BOOTX64.EFI  <- shim firmado por Microsoft (paquete shim-x64)
#   * EFI/BOOT/grubx64.efi  <- GRUB firmado por Fedora (grub2-efi-x64-cdboot)
# Por eso Secure Boot arranca sin errores: no hay firmas regeneradas ni MOK
# que enrolar. La verificacion post-build esta en fedora/verify-secure-boot.sh
# y se ejecuta automaticamente en el workflow.
