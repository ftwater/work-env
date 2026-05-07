#!/bin/bash
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

VM_NAME="${1:-}"

if [ -z "${VM_NAME}" ]; then
    # List all VMs
    mapfile -t VMS < <(virsh list --all --name 2>/dev/null | sed '/^$/d')
    if [ ${#VMS[@]} -eq 0 ]; then
        echo "No VMs found."
        exit 0
    fi

    echo "Available VMs:"
    for i in "${!VMS[@]}"; do
        STATE=$(virsh domstate "${VMS[$i]}" 2>/dev/null)
        printf "  %d) %s  [%s]\n" "$((i+1))" "${VMS[$i]}" "${STATE}"
    done
    echo "  q) quit"

    read -r -p "Select VM to destroy: " choice
    [[ "${choice}" == "q" ]] && exit 0
    [[ "${choice}" =~ ^[0-9]+$ ]] || die "Invalid choice"
    idx=$((choice - 1))
    [ "${idx}" -ge 0 ] && [ "${idx}" -lt "${#VMS[@]}" ] || die "Invalid selection"
    VM_NAME="${VMS[$idx]}"
    echo ""
fi

if ! virsh domstate "${VM_NAME}" &>/dev/null; then
    echo "VM '${VM_NAME}' not found in libvirt."
    rm -f "./${VM_NAME}.qcow2"
    exit 0
fi

read -r -p "Destroy '${VM_NAME}'? This deletes the VM and its disk. [y/N] " confirm
[[ "${confirm,,}" != "y" ]] && { echo "Aborted."; exit 0; }

echo "Destroying VM '${VM_NAME}'..."
virsh destroy "${VM_NAME}" 2>/dev/null || true
virsh undefine "${VM_NAME}" --remove-all-storage 2>/dev/null || true
rm -f "./${VM_NAME}.qcow2"
echo "Done."
