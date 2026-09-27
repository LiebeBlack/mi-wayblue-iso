#!/usr/bin/env bash
# =============================================================================
# Verificación OFFLINE de la ISO Debian 14 (gate del CI)
# =============================================================================
# 1) Integridad del sistema de ficheros de la ISO:
#      EFI/BOOT/{BOOTX64.EFI,grubx64.efi,mmx64.efi}, /live/filesystem.squashfs
#      y grub.cfg (en /boot/grub o /EFI/BOOT).
# 2) Secure Boot: shim y grubx64 con firmas Authenticode de las CAs que el
#    firmware valida. No descarga nada ni re-firma: los binarios firmados
#    provienen de los paquetes shim-signed / grub-efi-amd64-signed que
#    live-build coloca en la ISO (--uefi-secure-boot enable).
# =============================================================================
set -euo pipefail

ISO_FILE="${1:?Uso: $0 <ruta-a-la-iso>}"

for tool in xorriso sbverify; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "ERROR: falta la herramienta '${tool}' en el contenedor de build" >&2
        exit 1
    fi
done

if [ ! -f "${ISO_FILE}" ]; then
    echo "ERROR: no existe la ISO ${ISO_FILE}" >&2
    exit 1
fi

echo "==> ISO: ${ISO_FILE}"

EXTRACT_DIR="$(mktemp -d)"
cleanup() { rm -rf "${EXTRACT_DIR}"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1) Extraer el árbol de la ISO (osirrox lee la ISO9660 en modo usuario:
#    sin montajes, ideal para el runner del CI)
# ---------------------------------------------------------------------------
if ! osirrox -indev "${ISO_FILE}" -extract / "${EXTRACT_DIR}/iso" >/dev/null 2>&1; then
    echo "ERROR: no se pudo extraer el árbol de la ISO" >&2
    exit 1
fi

fail=0

check_file() {
    local path="$1" label="$2"
    if [ -f "${EXTRACT_DIR}/iso/${path}" ]; then
        echo "    OK    ${label}: /${path}"
    else
        echo "    FALTA ${label}: /${path}" >&2
        fail=1
    fi
}

# ---------------------------------------------------------------------------
# 2) Estructura crítica: squashfs del live, GRUB y árbol EFI
# ---------------------------------------------------------------------------
echo "==> Integridad del sistema de ficheros de la ISO:"
check_file "live/filesystem.squashfs" "squashfs del sistema live"

# grub.cfg: live-build lo puede poner en /boot/grub (BIOS+UEFI) o en /EFI/BOOT
if [ -f "${EXTRACT_DIR}/iso/boot/grub/grub.cfg" ]; then
    echo "    OK    grub.cfg: /boot/grub/grub.cfg"
elif [ -f "${EXTRACT_DIR}/iso/EFI/BOOT/grub.cfg" ]; then
    echo "    OK    grub.cfg: /EFI/BOOT/grub.cfg"
else
    echo "    FALTA grub.cfg (buscado en /boot/grub y /EFI/BOOT)" >&2
    fail=1
fi

SHIM="${EXTRACT_DIR}/iso/EFI/BOOT/BOOTX64.EFI"
GRUB="${EXTRACT_DIR}/iso/EFI/BOOT/grubx64.efi"
MMX="${EXTRACT_DIR}/iso/EFI/BOOT/mmx64.efi"

check_file "EFI/BOOT/BOOTX64.EFI" "shim como BOOTX64.EFI"
if [ -f "${GRUB}" ]; then
    echo "    OK    grubx64.efi (GRUB EFI firmado por Debian)"
else
    echo "    FALTA grubx64.efi (falta grub-efi-amd64-signed)" >&2
    fail=1
fi
if [ -f "${MMX}" ]; then
    echo "    OK    mmx64.efi (MokManager, enrolar MOK si algún día hiciera falta)"
fi

if [ "${fail}" -ne 0 ]; then
    echo "==> Árbol raíz de la ISO (diagnóstico):" >&2
    find "${EXTRACT_DIR}/iso" -maxdepth 3 | sed 's/^/    /' >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 3) Integridad del shim: BOOTX64.EFI debe SER shimx64.efi
# ---------------------------------------------------------------------------
echo "==> Verificando que BOOTX64.EFI es el shim de Debian:"
SHIM_ALT="$(find "${EXTRACT_DIR}/iso/EFI" -iname 'shimx64.efi' -print -quit 2>/dev/null || true)"
if [ -n "${SHIM_ALT}" ]; then
    if cmp -s "${SHIM}" "${SHIM_ALT}"; then
        echo "    OK    BOOTX64.EFI == shimx64.efi (shim intacto)"
    else
        echo "ERROR: BOOTX64.EFI difiere de shimx64.efi (no debe reemplazarse el shim)" >&2
        fail=1
    fi
fi

# ---------------------------------------------------------------------------
# 4) Firmas Authenticode embebidas. Formato REAL de "sbverify --list":
#      image signature certificates:
#       - subject: /C=US/.../CN=Microsoft Corporation UEFI CA 2011
#         issuer:  /CN=...
#    Extraemos subject/issuer (DN formato slash) contra la lista blanca.
# ---------------------------------------------------------------------------
check_signer() {
    local efi_file="$1"
    local label="$2"
    shift 2
    local allowed=("$@")
    local signers
    signers="$(sbverify --list "${efi_file}" 2>/dev/null \
        | sed -n -e 's/.*subject: //p' -e 's/.*issuer: //p' | sort -u || true)"

    if [ -z "${signers}" ]; then
        echo "ERROR: ${label} NO contiene ninguna firma Authenticode" >&2
        echo "==> Salida completa de sbverify --list (${label}) para diagnóstico:" >&2
        sbverify --list "${efi_file}" 2>&1 | sed 's/^/    /' >&2 || true
        return 1
    fi

    local ok=0
    while IFS= read -r dn; do
        [ -z "${dn}" ] && continue
        echo "    ${label}: firmado por \"${dn}\""
        for allowed_dn in "${allowed[@]}"; do
            if [[ "${dn}" == *"${allowed_dn}"* ]]; then
                ok=1
            fi
        done
    done <<< "${signers}"

    if [ "${ok}" -ne 1 ]; then
        echo "ERROR: ${label} no está firmado por ninguna CA permitida: ${allowed[*]}" >&2
        return 1
    fi
}

echo "==> Verificando firmantes de las firmas embebidas:"
# shim lo firma Microsoft UEFI CA 2011 (está en el DB de todo el hardware x86_64)
check_signer "${SHIM}" "shim" "Microsoft Corporation UEFI CA 2011" || fail=1
# grubx64.efi de la ISO lo firma la CA de Debian (shim confía en ella vía vendor DB)
check_signer "${GRUB}" "grubx64.efi" "Debian Secure Boot CA" || fail=1

# ---------------------------------------------------------------------------
# 5) Resultado
# ---------------------------------------------------------------------------
if [ "${fail}" -ne 0 ]; then
    echo
    echo "=== FALLO: la ISO contiene binarios de arranque sin firma válida ===" >&2
    exit 1
fi

echo
echo "=== OK: shim y grubx64 firmados correctamente; Secure Boot arrancará sin errores ==="
