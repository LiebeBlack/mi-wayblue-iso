#!/usr/bin/env bash
# =============================================================================
# Verificación OFFLINE de la ISO Debian 14 (gate del CI)
# =============================================================================
# 1) Integridad del sistema de ficheros de la ISO:
#      árbol EFI (bootx64.efi/shimx64.efi, grubx64.efi, mmx64.efi — live-build
#      escribe EFI/boot en minúsculas; se busca case-insensitive),
#      /live/filesystem.squashfs y grub.cfg (/boot/grub o /EFI/boot).
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
#    NOTA: live-build escribe el árbol EFI en MINÚSCULAS
#    (EFI/boot/bootx64.efi, EFI/boot/grubx64.efi). El firmware UEFI no
#    distingue mayúsculas al leer la ISO, pero las pruebas -f de este
#    script sí: buscamos SIEMPRE case-insensitive con find -iname.
# ---------------------------------------------------------------------------
echo "==> Integridad del sistema de ficheros de la ISO:"
check_file "live/filesystem.squashfs" "squashfs del sistema live"

GRUB_CFG="$(find "${EXTRACT_DIR}/iso" -type f -iname 'grub.cfg' -not -path '*/x86_64-efi/*' -print -quit 2>/dev/null || true)"
if [ -n "${GRUB_CFG}" ]; then
    echo "    OK    grub.cfg: /${GRUB_CFG#${EXTRACT_DIR}/iso/}"
else
    echo "    FALTA grub.cfg" >&2
    fail=1
fi

SHIM="$(find "${EXTRACT_DIR}/iso" -type f \( -iname 'bootx64.efi' -o -iname 'shimx64.efi' \) -print -quit 2>/dev/null || true)"
GRUB="$(find "${EXTRACT_DIR}/iso" -type f -iname 'grubx64.efi' -print -quit 2>/dev/null || true)"
MMX="$(find "${EXTRACT_DIR}/iso" -type f -iname 'mmx64.efi' -print -quit 2>/dev/null || true)"

if [ -n "${SHIM}" ]; then
    echo "    OK    shim: /${SHIM#${EXTRACT_DIR}/iso/}"
else
    echo "    FALTA bootx64.efi/shimx64.efi (falta shim-signed)" >&2
    fail=1
fi
if [ -n "${GRUB}" ]; then
    echo "    OK    grubx64.efi (GRUB EFI firmado por Debian): /${GRUB#${EXTRACT_DIR}/iso/}"
else
    echo "    FALTA grubx64.efi (falta grub-efi-amd64-signed)" >&2
    fail=1
fi
if [ -n "${MMX}" ]; then
    echo "    OK    mmx64.efi (MokManager, enrolar MOK si algún día hiciera falta)"
fi

if [ "${fail}" -ne 0 ]; then
    echo "==> Diagnóstico: raíz de la ISO y árbol EFI:" >&2
    find "${EXTRACT_DIR}/iso" -maxdepth 1 2>/dev/null | sed 's/^/    /' >&2
    find "${EXTRACT_DIR}/iso/EFI" 2>/dev/null | sed 's/^/    /' >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 3) Integridad del shim: si existen bootx64.efi y shimx64.efi por separado,
#    deben ser el MISMO binario (el fallback de arranque es el shim).
# ---------------------------------------------------------------------------
echo "==> Verificando integridad del shim de Debian:"
SHIM_BOOT="$(find "${EXTRACT_DIR}/iso/EFI" -type f -iname 'bootx64.efi' -print -quit 2>/dev/null || true)"
SHIM_REAL="$(find "${EXTRACT_DIR}/iso/EFI" -type f -iname 'shimx64.efi' -print -quit 2>/dev/null || true)"
if [ -n "${SHIM_BOOT}" ] && [ -n "${SHIM_REAL}" ]; then
    if cmp -s "${SHIM_BOOT}" "${SHIM_REAL}"; then
        echo "    OK    bootx64.efi == shimx64.efi (shim intacto)"
    else
        echo "ERROR: bootx64.efi difiere de shimx64.efi (no debe reemplazarse el shim)" >&2
        fail=1
    fi
else
    echo "    info: hay un único binario shim en la ISO (bootx64.efi = shim firmado)"
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
