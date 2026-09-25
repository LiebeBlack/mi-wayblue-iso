# Arranca labwc automaticamente en tty1 (sistema instalado).
if [ "$(tty)" = "/dev/tty1" ] && [ -z "$WAYLAND_DISPLAY" ] && [ -z "$LABWC_STARTED" ]; then
    export LABWC_STARTED=1
    # Teclado espanol: quita/ajusta si lo necesitas
    export XKB_DEFAULT_LAYOUT=es
    exec labwc
fi
