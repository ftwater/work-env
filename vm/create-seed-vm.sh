#!/bin/bash
set -euo pipefail

# ── Config ────────────────────────────────────────────
VM_NAME="ubuntu-seed"
VCPUS=4
MEMORY=8192            # MB
DISK_SIZE=60           # GB
ISO_PATH="${ISO_PATH:-}"   # env override or set below
ISO_URL="${ISO_URL:-https://releases.ubuntu.com/26.04/ubuntu-26.04-desktop-amd64.iso}"
NETWORK="default"          # libvirt NAT network
GRAPHICS="spice,listen=none"
VIDEO="qxl"
OS_VARIANT="linux2022"     # generic; use osinfo-query os to find exact
# ──────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

# ── Prereqs ───────────────────────────────────────────
missing() { for pkg in "$@"; do command -v "$pkg" >/dev/null 2>&1 || echo "$pkg"; done; }
NEED=$(missing virt-install virsh)
if [ -n "$NEED" ]; then
    echo "Missing packages for: $NEED"
    read -r -p "Install now? [Y/n] " ans
    [[ "${ans,,}" != "n" ]] && sudo apt install -y virtinst libvirt-clients libvirt-daemon-system virt-viewer qemu-system-x86 qemu-utils
    NEED=$(missing virt-install virsh)
    [ -n "$NEED" ] && die "Required tools still missing: $NEED"
fi

# ── Libvirtd ───────────────────────────────────────────
if ! virsh connect qemu:///system &>/dev/null; then
    # Check group
    if ! groups | grep -q '\blibvirt\b'; then
        echo "Adding ${USER} to libvirt group..."
        sudo usermod -aG libvirt "${USER}"
        echo "Group added. Refresh group with:  su - ${USER}"
        exit 1
    fi
    # Check daemon
    if ! systemctl is-active --quiet libvirtd 2>/dev/null; then
        echo "libvirtd not running. Starting..."
        sudo systemctl start libvirtd
        sudo systemctl enable libvirtd
    fi
    virsh connect qemu:///system &>/dev/null || die "Cannot connect to libvirtd"
fi

# ── Storage permissions ────────────────────────────────
check_storage() {
    sudo -u libvirt-qemu test -r "$1" -a -w "$1" -a -x "$1" 2>/dev/null
}
if ! check_storage "$(pwd)"; then
    echo "Granting libvirt-qemu access to this directory..."
    # Grant x on each parent dir leading to pwd
    DIR="$(pwd)"
    while [ "$DIR" != "/" ]; do
        sudo chmod o+x "$DIR" 2>/dev/null || true
        DIR="$(dirname "$DIR")"
    done
    sudo chmod o+rwx "$(pwd)"
    check_storage "$(pwd)" || die "Cannot grant access to $(pwd). Try a different directory."
fi

# ── ISO ───────────────────────────────────────────────
# Priority: command-line arg > env var > default download
if [ -n "${1:-}" ]; then
    ISO_PATH="$1"
fi
if [ -z "${ISO_PATH}" ]; then
    ISO_PATH="/tmp/ubuntu-26.04-desktop-amd64.iso"
fi
if [ ! -f "${ISO_PATH}" ]; then
    echo "ISO not found: ${ISO_PATH}"
    read -r -p "Download from ${ISO_URL}? [Y/n] " ans
    [[ "${ans,,}" == "n" ]] && die "ISO required. Set ISO_PATH or download manually."
    mkdir -p "$(dirname "${ISO_PATH}")"
    if command -v curl >/dev/null 2>&1; then
        curl -L --progress-bar -o "${ISO_PATH}" "${ISO_URL}"
    elif command -v wget >/dev/null 2>&1; then
        wget --show-progress -O "${ISO_PATH}" "${ISO_URL}"
    else
        die "Need curl or wget to download. Install one or download ISO manually."
    fi
    [ -f "${ISO_PATH}" ] || die "Download failed. Check URL: ${ISO_URL}"
    echo "Downloaded: ${ISO_PATH}"
fi

# ── Destroy old seed if present ──────────────────────
if virsh domstate "${VM_NAME}" &>/dev/null; then
    echo "Destroying existing VM '${VM_NAME}'..."
    virsh destroy "${VM_NAME}" 2>/dev/null || true
    virsh undefine "${VM_NAME}" --remove-all-storage 2>/dev/null || true
    rm -f "./${VM_NAME}.qcow2"
fi

# ── Create ────────────────────────────────────────────
echo "Creating seed VM '${VM_NAME}'..."
virt-install \
    --name "${VM_NAME}" \
    --vcpus "${VCPUS}" \
    --memory "${MEMORY}" \
    --disk "path=./${VM_NAME}.qcow2,size=${DISK_SIZE},format=qcow2,bus=virtio,cache=writeback" \
    --cdrom "${ISO_PATH}" \
    --graphics "${GRAPHICS}" \
    --video "${VIDEO}" \
    --network "network=${NETWORK},model=virtio" \
    --os-variant "${OS_VARIANT}" \
    --noautoconsole

echo ""
echo "Seed VM '${VM_NAME}' is installing."
echo "Connect:  virt-viewer ${VM_NAME}"
echo "Check progress:  virsh domstate ${VM_NAME}"
