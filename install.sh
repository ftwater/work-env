#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FONT_DIR="${HOME}/.local/share/fonts"

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "This script is intended for Ubuntu/Linux systems." >&2
    exit 1
fi

echo "Installing fonts to ${FONT_DIR} ..."
mkdir -p "${FONT_DIR}"

find "${SCRIPT_DIR}" -maxdepth 2 \( -name "*.ttf" -o -name "*.otf" \) | while read -r font; do
    dest="${FONT_DIR}/$(basename "${font}")"
    cp "${font}" "${dest}"
    echo "  Installed: $(basename "${font}")"
done

fc-cache -fv "${FONT_DIR}" > /dev/null
echo "Font cache refreshed."
echo "Done."
