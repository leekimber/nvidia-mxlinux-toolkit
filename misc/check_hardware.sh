#!/bin/bash
# check_hardware.sh
# NVIDIA GPU hardware diagnostic for Linux
#
# Checks whether the GPU is properly detected on the PCIe bus, whether the
# link is healthy, and whether the hardware is reporting any problems.
# This is a READ-ONLY diagnostic -- it makes no changes.
#
# Run this FIRST, before installing drivers or debugging software.
# If hardware checks fail, no amount of software configuration will help.
#
# Usage:
#   bash check_hardware.sh
#
# Requires: pciutils (lspci), optional: nvidia-smi (for deeper checks)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

ok()    { echo -e "  ${GREEN}[OK]${NC}    $1"; }
warn()  { echo -e "  ${YELLOW}[WARN]${NC}  $1"; }
fail()  { echo -e "  ${RED}[FAIL]${NC}  $1"; }
note()  { echo -e "  ${BLUE}[INFO]${NC}  $1"; }
header(){ echo -e "\n${BOLD}${BLUE}── $1 ──${NC}"; }

ISSUES=0

# ═══════════════════════════════════════════════════════════════════
header "NVIDIA GPU Hardware Check"
echo ""

# ── 1. PCI Bus Detection ──────────────────────────────────────────────
header "1. PCI Bus Detection"

GPU_PCI=$(lspci -nn 2>/dev/null | grep -i nvidia | grep -i vga) || true
GPU_COUNT=$(echo "$GPU_PCI" | grep -c "." 2>/dev/null) || GPU_COUNT=0

if [ "$GPU_COUNT" -ge 1 ]; then
    ok "NVIDIA GPU detected on PCIe bus ($GPU_COUNT VGA device(s)):"
    echo "$GPU_PCI" | while IFS= read -r line; do note "$line"; done

    # Also check for NVIDIA audio device (HDMI/DP audio)
    GPU_AUDIO=$(lspci -nn 2>/dev/null | grep -i nvidia | grep -i audio) || true
    if [ -n "$GPU_AUDIO" ]; then
        ok "NVIDIA audio device present:"
        echo "$GPU_AUDIO" | while IFS= read -r line; do note "$line"; done
    fi
else
    fail "No NVIDIA GPU found on the PCIe bus"
    echo ""
    echo "  Possible causes:"
    echo "    - GPU not properly seated in the slot"
    echo "    - GPU not receiving power (check power cables)"
    echo "    - BIOS/UEFI has the discrete GPU disabled"
    echo "    - BIOS/UEFI 'Above 4G Decoding' or 'Resizable BAR' misconfigured"
    echo "    - Hardware failure"
    echo ""
    echo "  Try:"
    echo "    sudo lspci -nn | grep -i vga    # check all VGA devices"
    echo "    sudo lspci -nn | grep -i nvidia # check for any NVIDIA device"
    echo ""
    ISSUES=$((ISSUES + 1))
fi

# Exit early if no GPU found
if [ "$GPU_COUNT" -eq 0 ]; then
    header "Summary"
    echo ""
    fail "GPU not detected. Resolve hardware issues before proceeding."
    echo ""
    echo "  Next steps:"
    echo "    1. Reseat the GPU"
    echo "    2. Check power connections"
    echo "    3. Check BIOS/UEFI settings"
    echo "    4. Try a different PCIe slot if available"
    echo ""
    exit 1
fi

# Get the PCI address of the first GPU for deeper checks
GPU_PCI_ADDR=$(echo "$GPU_PCI" | head -1 | awk '{print $1}')
GPU_SYSFS="/sys/bus/pci/devices/0000:${GPU_PCI_ADDR}"

# ── 2. PCIe Link Status ───────────────────────────────────────────────
header "2. PCIe Link Status"

if [ -d "$GPU_SYSFS" ]; then
    CURRENT_SPEED=$(cat "$GPU_SYSFS/current_link_speed" 2>/dev/null || echo "unknown")
    MAX_SPEED=$(cat "$GPU_SYSFS/max_link_speed" 2>/dev/null || echo "unknown")
    CURRENT_WIDTH=$(cat "$GPU_SYSFS/current_link_width" 2>/dev/null || echo "unknown")
    MAX_WIDTH=$(cat "$GPU_SYSFS/max_link_width" 2>/dev/null || echo "unknown")

    note "Link speed: $CURRENT_SPEED (max: $MAX_SPEED)"
    note "Link width: $CURRENT_WIDTH lanes (max: $MAX_WIDTH lanes)"

    # Check if link is running below max speed
    # Extract numeric generation (e.g. "2.5 GT/s" -> 1, "5.0 GT/s" -> 2, "8.0 GT/s" -> 3)
    CURR_GEN=$(echo "$CURRENT_SPEED" | grep -oP '[\d.]+' | head -1)
    MAX_GEN=$(echo "$MAX_SPEED" | grep -oP '[\d.]+' | head -1)

    if [ "$CURRENT_WIDTH" != "$MAX_WIDTH" ]; then
        warn "Link width reduced: running at x$CURRENT_WIDTH, hardware supports x$MAX_WIDTH"
        echo "  This can indicate a seating issue or BIOS configuration problem."
        ISSUES=$((ISSUES + 1))
    else
        ok "Link width: x$CURRENT_WIDTH (maximum)"
    fi

    # Speed comparison (handle floating point)
    SPEED_OK=$(python3 -c "
cur = float('${CURR_GEN}')
mx  = float('${MAX_GEN}')
# Allow some tolerance (e.g. 8.0 vs 8.0 is fine, 2.5 vs 8.0 is not)
print('ok' if cur >= mx * 0.9 else 'slow')
" 2>/dev/null || echo "unknown")

    if [ "$SPEED_OK" = "slow" ]; then
        warn "Link speed reduced: running at $CURRENT_SPEED, hardware supports $MAX_SPEED"
        echo "  Common causes:"
        echo "    - BIOS/UEFI PCIe link speed set to Gen1/Gen2 instead of Auto/Gen3"
        echo "    - Power management forcing lower link speed"
        echo "    - Motherboard slot wired for fewer lanes"
        echo "  This reduces bandwidth but the GPU should still function."
        ISSUES=$((ISSUES + 1))
    elif [ "$SPEED_OK" = "ok" ]; then
        ok "Link speed: $CURRENT_SPEED (maximum)"
    else
        note "Link speed: $CURRENT_SPEED (could not compare with max $MAX_SPEED)"
    fi

    # Power state
    POWER_STATE=$(cat "$GPU_SYSFS/power_state" 2>/dev/null || echo "unknown")
    note "Power state: $POWER_STATE"
    if [ "$POWER_STATE" != "D0" ] && [ "$POWER_STATE" != "unknown" ]; then
        warn "GPU not in D0 (fully on) state: $POWER_STATE"
        ISSUES=$((ISSUES + 1))
    fi

    # Boot VGA
    BOOT_VGA=$(cat "$GPU_SYSFS/boot_vga" 2>/dev/null || echo "?")
    if [ "$BOOT_VGA" = "1" ]; then
        ok "GPU is the boot VGA device"
    else
        note "GPU is NOT the boot VGA device (may be normal on laptops with Optimus)"
    fi
else
    warn "Cannot read GPU sysfs data at $GPU_SYSFS"
    ISSUES=$((ISSUES + 1))
fi

# ── 3. PCIe Errors (AER) ──────────────────────────────────────────────
header "3. PCIe Error Counters (AER)"

if [ -f "$GPU_SYSFS/aer_dev_correctable" ]; then
    CORR_TOTAL=$(grep "TOTAL_ERR_COR" "$GPU_SYSFS/aer_dev_correctable" 2>/dev/null | awk '{print $NF}')
    FATAL_TOTAL=$(grep "TOTAL_ERR_FATAL" "$GPU_SYSFS/aer_dev_fatal" 2>/dev/null | awk '{print $NF}')
    NONFATAL_TOTAL=$(grep "TOTAL_ERR_NONFATAL" "$GPU_SYSFS/aer_dev_nonfatal" 2>/dev/null | awk '{print $NF}')

    note "Correctable errors:   ${CORR_TOTAL:-0}"
    note "Fatal errors:         ${FATAL_TOTAL:-0}"
    note "Non-fatal errors:    ${NONFATAL_TOTAL:-0}"

    if [ "${CORR_TOTAL:-0}" -gt 0 ]; then
        warn "Correctable PCIe errors detected (${CORR_TOTAL})"
        echo "  These are usually harmless but a high count can indicate:"
        echo "    - Poor physical connection (reseating may help)"
        echo "    - Electrical interference"
        echo "    - Overclocking instability"
        echo ""
        echo "  Full correctable error breakdown:"
        cat "$GPU_SYSFS/aer_dev_correctable" 2>/dev/null | while IFS= read -r line; do
            val=$(echo "$line" | awk '{print $NF}')
            [ "$val" -gt 0 ] 2>/dev/null && echo "    ! $line"
        done
        ISSUES=$((ISSUES + 1))
    else
        ok "No correctable PCIe errors"
    fi

    if [ "${FATAL_TOTAL:-0}" -gt 0 ]; then
        fail "FATAL PCIe errors detected (${FATAL_TOTAL})"
        echo "  This indicates serious hardware or configuration problems."
        echo "  Check physical connections and BIOS settings."
        echo ""
        echo "  Full fatal error breakdown:"
        cat "$GPU_SYSFS/aer_dev_fatal" 2>/dev/null | while IFS= read -r line; do
            val=$(echo "$line" | awk '{print $NF}')
            [ "$val" -gt 0 ] 2>/dev/null && echo "    ! $line"
        done
        ISSUES=$((ISSUES + 1))
    else
        ok "No fatal PCIe errors"
    fi

    if [ "${NONFATAL_TOTAL:-0}" -gt 0 ]; then
        warn "Non-fatal PCIe errors detected (${NONFATAL_TOTAL})"
        ISSUES=$((ISSUES + 1))
    else
        ok "No non-fatal PCIe errors"
    fi
else
    note "AER not available (may require root or kernel CONFIG_PCIEAER=y)"
fi

# Also check dmesg for PCIe errors
PCIE_ERRORS=$(dmesg 2>/dev/null | grep -iE "pcie.*error|AER.*error|bandwidth.*degraded|link.*down" | tail -10) || true
if [ -n "$PCIE_ERRORS" ]; then
    warn "PCIe errors found in kernel log:"
    echo "$PCIE_ERRORS" | while IFS= read -r line; do echo "    ! $line"; done
    ISSUES=$((ISSUES + 1))
else
    ok "No PCIe errors in kernel log"
fi

# ── 4. Kernel Driver Binding ──────────────────────────────────────────
header "4. Kernel Driver"

DRIVER=$(lspci -k 2>/dev/null | grep -A3 "$GPU_PCI_ADDR" | grep "Kernel driver in use:" | sed 's/.*: //') || DRIVER=""
MODULES=$(lspci -k 2>/dev/null | grep -A3 "$GPU_PCI_ADDR" | grep "Kernel modules:" | sed 's/.*: //') || MODULES=""

if [ -n "$DRIVER" ]; then
    ok "Kernel driver loaded: $DRIVER"
else
    note "No kernel driver currently bound to the GPU"
    echo "  Available modules: ${MODULES:-unknown}"
    echo "  This is normal if the NVIDIA driver has not been installed yet."
fi

# ── 5. Kernel Messages ────────────────────────────────────────────────
header "5. Kernel Messages"

GPU_DMESG=$(dmesg 2>/dev/null | grep -iE "nvidia|nouveau" | grep -iE "error|fail|warn|bug|fault" | tail -10) || true
if [ -n "$GPU_DMESG" ]; then
    warn "GPU-related kernel errors:"
    echo "$GPU_DMESG" | while IFS= read -r line; do echo "    ! $line"; done
    ISSUES=$((ISSUES + 1))
else
    ok "No GPU-related kernel errors"
fi

# ── 6. GPU Health (requires nvidia-smi) ───────────────────────────────
header "6. GPU Health (nvidia-smi)"

if command -v nvidia-smi &>/dev/null; then
    TEMP=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null | head -1)
    POWER=$(nvidia-smi --query-gpu=power.draw --format=csv,noheader 2>/dev/null | head -1)
    GPU_CLOCK=$(nvidia-smi --query-gpu=clocks.current.graphics --format=csv,noheader 2>/dev/null | head -1)
    MEM_CLOCK=$(nvidia-smi --query-gpu=clocks.current.memory --format=csv,noheader 2>/dev/null | head -1)
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null | head -1)

    note "GPU: $GPU_NAME"
    note "VRAM: $VRAM"
    note "Temperature: ${TEMP}°C"
    note "Power draw: ${POWER}"
    note "GPU clock: $GPU_CLOCK  Memory clock: $MEM_CLOCK"

    # Temperature check
    TEMP_NUM=$(echo "$TEMP" | grep -oP '\d+')
    if [ "${TEMP_NUM:-0}" -gt 90 ]; then
        warn "GPU temperature very high: ${TEMP}°C (throttling likely)"
        ISSUES=$((ISSUES + 1))
    elif [ "${TEMP_NUM:-0}" -gt 80 ]; then
        warn "GPU temperature elevated: ${TEMP}°C"
    else
        ok "GPU temperature normal: ${TEMP}°C"
    fi

    # Throttle check -- ignore benign "gpu idle" flag (bit 0)
    THROTTLE=$(nvidia-smi --query-gpu=clocks_throttle_reasons.active --format=csv,noheader 2>/dev/null | head -1)
    THROTTLE_DEC=$(printf "%d" "$THROTTLE" 2>/dev/null || echo 0)
    THROTTLE_REAL=$((THROTTLE_DEC & ~1))  # strip idle bit

    if [ "$THROTTLE_REAL" -eq 0 ]; then
        ok "No active clock throttling (GPU idle is normal)"
    else
        warn "Clock throttling active: $THROTTLE"
        echo "  Active throttle reasons:"
        for reason in hw_thermal_slowdown sw_thermal_slowdown hw_power_brake_slowdown sw_power_cap sync_boost applications_clocks_setting; do
            val=$(nvidia-smi --query-gpu="clocks_throttle_reasons.${reason}" --format=csv,noheader 2>/dev/null | head -1)
            [ "$val" = "Active" ] && echo "    ! $reason"
        done
        ISSUES=$((ISSUES + 1))
    fi

    # ECC errors (mostly relevant for datacenter GPUs)
    ECC_CORR=$(nvidia-smi --query-gpu=ecc.errors.corrected.volatile.total --format=csv,noheader 2>/dev/null | head -1)
    ECC_UNCORR=$(nvidia-smi --query-gpu=ecc.errors.uncorrected.volatile.total --format=csv,noheader 2>/dev/null | head -1)
    if [ -n "$ECC_CORR" ] && [ "$ECC_CORR" != "[N/A]" ]; then
        note "ECC corrected errors:   $ECC_CORR"
        note "ECC uncorrected errors: $ECC_UNCORR"
        if [ "${ECC_UNCORR:-0}" -gt 0 ] 2>/dev/null; then
            fail "Uncorrected ECC errors detected -- possible hardware failure"
            ISSUES=$((ISSUES + 1))
        fi
    fi
else
    note "nvidia-smi not available -- skipping GPU health checks"
    echo "  Install the NVIDIA driver for temperature, power, and ECC monitoring."
fi

# ── 7. IOMMU Group ────────────────────────────────────────────────────
header "7. IOMMU Group"

if [ -d "$GPU_SYSFS/iommu_group" ]; then
    IOMMU_GROUP=$(readlink "$GPU_SYSFS/iommu_group" 2>/dev/null | xargs basename) || IOMMU_GROUP="unknown"
    note "IOMMU group: $IOMMU_GROUP"

    # List other devices in the same group
    GROUP_DEVICES=$(ls /sys/kernel/iommu_groups/"$IOMMU_GROUP"/devices/ 2>/dev/null | wc -l)
    if [ "$GROUP_DEVICES" -gt 1 ]; then
        note "Group contains $GROUP_DEVICES devices:"
        for dev in /sys/kernel/iommu_groups/"$IOMMU_GROUP"/devices/*; do
            dev_addr=$(basename "$dev")
            dev_desc=$(lspci -nn 2>/dev/null | grep "^${dev_addr:5}" | sed 's/^.*: //') || dev_desc="unknown"
            echo "    $dev_addr: $dev_desc"
        done
    else
        ok "GPU is in its own IOMMU group (ideal for PCI passthrough)"
    fi
else
    note "IOMMU not enabled or not available"
fi

# ── 8. BIOS/UEFI Hints ────────────────────────────────────────────────
header "8. BIOS/UEFI Configuration Hints"

echo ""
echo "  If you are having problems, check these BIOS/UEFI settings:"
echo ""
echo "  - 'Above 4G Decoding' or 'Above 4G MMIO': Enable"
echo "    Required for GPUs with large VRAM BARs. Without it, the GPU"
echo "    may not be detected or may have reduced performance."
echo ""
echo "  - 'Resizable BAR' / 'Smart Access Memory': Enable (optional)"
echo "    Can improve performance. If causing instability, try disabling."
echo ""
echo "  - 'PCIe Link Speed': Set to 'Auto' or the highest generation"
echo "    supported by your hardware (e.g. Gen3). If set to Gen1/Gen2,"
echo "    bandwidth will be severely limited."
echo ""
echo "  - 'Primary Display' / 'Init Display First': Set to 'PEG' or"
echo "    'PCIe' (not 'IGD' or 'Auto') if you want the NVIDIA GPU as"
echo "    the primary display adapter."
echo ""
echo "  - 'Secure Boot': May need to be disabled for proprietary NVIDIA"
echo "    drivers to load (driver signing issues)."
echo ""

# ═══════════════════════════════════════════════════════════════════
header "Summary"
echo ""

if [ "$ISSUES" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}All hardware checks passed!${NC}"
    echo ""
    echo "  Your GPU hardware appears healthy. If you are having problems,"
    echo "  they are likely software-related. Run the main toolkit next:"
    echo ""
    echo "    bash nvidia-mxlinux-toolkit.sh --check"
    echo ""
else
    echo -e "  ${YELLOW}${BOLD}Found $ISSUES hardware issue(s).${NC}"
    echo ""
    echo "  Resolve the issues above before proceeding with software"
    echo "  configuration. Hardware problems cannot be fixed by drivers."
    echo ""
fi
