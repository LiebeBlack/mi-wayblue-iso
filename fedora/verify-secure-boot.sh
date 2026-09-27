#!/usr/bin/env bash
# =============================================================================
# Verificación de firmas de arranque en la ISO (gate del CI)
# =============================================================================
# Comprueba que el árbol de arranque de la ISO contiene los binarios EFI
# firmados por Fedora/Microsoft y que las firmas Authenticode embebidas de
# shim y GRUB provienen de las CAs que el firmware valida en el DB de
# Secure Boot:
#
#   * shimx64.efi / BOOTX64.EFI -> "Microsoft Corporation UEFI CA 2011"
#   * grubx64.efi               -> "Fedora Secure Boot CA" (firmante de Fedora)
#
# Verificación 100 % OFFLINE: no descarga certificados ni re-firma nada.
# La estrategia del proyecto es usar los binarios firmados de los paquetes
# shim-x64 / grub2-efi-x64-cdboot tal cual los coloca lorax en la ISO.
# =============================================================================
set -euo pipefail

ISO_FILE="${1:?Uso: $0 <ruta-a-la-iso>}"

# ---------------------------------------------------------------------------
# 0) Dependencias
# ---------------------------------------------------------------------------
for tool in xorriso sbverify pesign; do
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

# ---------------------------------------------------------------------------
# 1) Extraer el árbol de arranque EFI de la ISO (xorriso lee la ISO9660 en
#    modo usuario: no hace falta montar, ideal para el runner del CI)
#
#    En una ISO de lorax/lmc el árbol EFI está en la RAÍZ: /EFI/BOOT/.
#    (En un sistema instalado sería /boot/efi/EFI; probamos ambas por si
#    algún día se apunta el gate a un árbol montado en vez de a la ISO.)
# ---------------------------------------------------------------------------
EXTRACT_DIR="$(mktemp -d)"
cleanup() { rm -rf "${EXTRACT_DIR}"; }
trap cleanup EXIT

EFI_SRC=""
for candidate in /EFI /boot/efi/EFI; do
    rm -rf "${EXTRACT_DIR}/EFI"
    if osirrox -indev "${ISO_FILE}" -extract "${candidate}" "${EXTRACT_DIR}/EFI" >/dev/null 2>&1 \
        && [ -n "$(find "${EXTRACT_DIR}/EFI" -type f -name '*.efi' -print -quit 2>/dev/null)" ]; then
        EFI_SRC="${candidate}"
        break
    fi
done

if [ -z "${EFI_SRC}" ]; then
    echo "ERROR: la ISO no contiene un árbol EFI con binarios .efi (probados /EFI y /boot/efi/EFI)" >&2
    echo "==> Árbol raíz de la ISO (diagnóstico):" >&2
    osirrox -indev "${ISO_FILE}" -ls / 2>/dev/null | sed 's/^/    /' || true
    exit 1
fi
echo "==> Árbol EFI extraído de ${EFI_SRC}"

echo "==> Binarios EFI presentes en la ISO:"
find "${EXTRACT_DIR}/EFI" -type f -iname '*.efi' -printf '    %P\n' | sort

# ---------------------------------------------------------------------------
# 2) Localizar shim y GRUB
# ---------------------------------------------------------------------------
SHIM="$(find "${EXTRACT_DIR}/EFI" \( -iname 'shimx64.efi' -o -iname 'bootx64.efi' \) -print -quit)"
GRUB="$(find "${EXTRACT_DIR}/EFI" -iname 'grubx64.efi' -print -quit)"

fail=0

if [ -z "${SHIM}" ]; then
    echo "ERROR: no se encontró shimx64.efi/BOOTX64.EFI (falta el paquete shim-x64)" >&2
    fail=1
fi
if [ -z "${GRUB}" ]; then
    echo "ERROR: no se encontró grubx64.efi (falta grub2-efi-x64-cdboot)" >&2
    fail=1
fi
[ "${fail}" -ne 0 ] && exit 1

# ---------------------------------------------------------------------------
# 3) Integridad de shim como fallback: BOOTX64.EFI debe SER shimx64.efi
#    (el firmware arranca siempre por EFI/BOOT/BOOTX64.EFI en medios extraíbles)
# ---------------------------------------------------------------------------
SHIM_REAL="$(find "${EXTRACT_DIR}/EFI" -iname 'shimx64.efi' -print -quit || true)"
if [ -n "${SHIM_REAL}" ]; then
    BOOTX64="$(find "${EXTRACT_DIR}/EFI" -iname 'bootx64.efi' -print -quit || true)"
    if [ -n "${BOOTX64}" ] && ! cmp -s "${BOOTX64}" "${SHIM_REAL}"; then
        echo "ERROR: BOOTX64.EFI difiere de shimx64.efi (no debe reemplazarse el shim)" >&2
        fail=1
    fi
fi

# ---------------------------------------------------------------------------
# 4) Firmas Authenticode embebidas. Formato REAL de "sbverify --list":
#      image signature issuers:
#       - /CN=...
#      image signature certificates:
#       - subject: /C=US/.../CN=Microsoft Corporation UEFI CA 2011
#         issuer:  /CN=...
#    Extraemos las líneas "subject:" e "issuer:" (DN completo formato slash)
#    y las comparamos contra la lista blanca de CAs del DB de Secure Boot.
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
    while IFS= read -r cn; do
        [ -z "${cn}" ] && continue
        echo "    ${label}: firmado por \"${cn}\""
        for allowed_cn in "${allowed[@]}"; do
            if [[ "${cn}" == *"${allowed_cn}"* ]]; then
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
# grubx64.efi de la ISO lo firma Fedora Secure Boot CA (confía shim vía vendor DB)
check_signer "${GRUB}" "grubx64.efi" "Fedora Secure Boot CA" "Fedora Secure Boot Signer" || fail=1

# Detalle de firmas y resumen de hash en el log del CI (informativo)
echo "==> Detalle de firmas (pesign):"
pesign --show-signatures -i "${SHIM}" 2>&1 | sed 's/^/    /' || true
pesign --show-signatures -i "${GRUB}" 2>&1 | sed 's/^/    /' || true

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
