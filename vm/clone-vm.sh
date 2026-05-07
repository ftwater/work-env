#!/bin/bash
set -euo pipefail

SEED_VM="ubuntu-seed"
NEW_VM="${1:-}"

die() { echo "ERROR: $*" >&2; exit 1; }

missing() { for pkg in "$@"; do command -v "$pkg" >/dev/null 2>&1 || echo "$pkg"; done; }
NEED=$(missing virt-clone virsh)
if [ -n "$NEED" ]; then
    echo "Missing packages for: $NEED"
    read -r -p "Install now? [Y/n] " ans
    [[ "${ans,,}" != "n" ]] && sudo apt install -y virtinst libvirt-clients libvirt-daemon-system
    NEED=$(missing virt-clone virsh)
    [ -n "$NEED" ] && die "Required tools still missing: $NEED"
fi

if ! virsh connect qemu:///system &>/dev/null; then
    if ! groups | grep -q '\blibvirt\b'; then
        echo "Adding ${USER} to libvirt group..."
        sudo usermod -aG libvirt "${USER}"
        echo "Group added. Refresh group with:  su - ${USER}"
        exit 1
    fi
    if ! systemctl is-active --quiet libvirtd 2>/dev/null; then
        echo "libvirtd not running. Starting..."
        sudo systemctl start libvirtd
        sudo systemctl enable libvirtd
    fi
    virsh connect qemu:///system &>/dev/null || die "Cannot connect to libvirtd"
fi

[ -z "${NEW_VM}" ] && die "Usage: $0 <new-vm-name>"
virsh domstate "${SEED_VM}" &>/dev/null || die "Seed VM '${SEED_VM}' not found. Run create-seed-vm.sh first."
virsh domstate "${SEED_VM}" | grep -q "shut off" || die "Seed VM '${SEED_VM}' must be shut off before cloning."

virsh domstate "${NEW_VM}" &>/dev/null && die "VM '${NEW_VM}' already exists."

echo "Cloning '${SEED_VM}' → '${NEW_VM}'..."
virt-clone \
    --original "${SEED_VM}" \
    --name "${NEW_VM}" \
    --file "./${NEW_VM}.qcow2"

echo ""
echo "VM '${NEW_VM}' ready."
echo "Start:  virsh start ${NEW_VM}"
echo "Connect:  virt-viewer ${NEW_VM}"
