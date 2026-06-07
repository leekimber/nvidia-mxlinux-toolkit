#!/usr/bin/env bash
# ------------------------------------------------------------
#  fix_pytorch_cuda.sh — fix PyTorch/CUDA mismatch on
#  MX Linux / Debian 12
#
#  Problem:
#    PyTorch bundles its own CUDA runtime. If the bundled
#    CUDA is newer than what the NVIDIA driver supports,
#    torch.cuda.is_available() returns False even though
#    the driver and GPU are fine.
#
#    Example: PyTorch 2.11.0+cu130 on driver 535
#    Driver 535 supports up to CUDA 12.6, not 13.0.
#
#  Solution:
#    Install a PyTorch build compiled for a CUDA version
#    the driver actually supports.
#
#  Usage:
#    ./fix_pytorch_cuda.sh
#
#  What it does:
#    1. Detects driver version
#    2. Determines the best CUDA variant (cu126, cu124, etc.)
#    3. Checks if the correct PyTorch is already installed
#    4. If not, downloads and installs the matching wheel
#       into the openai-whisper pipx venv
#    5. Verifies the fix
#
#  Requirements:
#    • pipx with openai-whisper already installed
#    • Internet access (downloads ~2-3 GB)
#    • nvidia-smi working
# ------------------------------------------------------------

set -euo pipefail

WHISPER_VENV="$HOME/.local/pipx/venvs/openai-whisper"
TORCH_WHEEL_DIR="$HOME/downloads"
PYTORCH_CUDA_MAJOR=12

echo "============================================="
echo "  Fix PyTorch/CUDA Mismatch — MX Linux"
echo "============================================="
echo ""

# ── 1. Check prerequisites ───────────────────────
echo "── Checking prerequisites ──"

if ! command -v nvidia-smi &>/dev/null; then
    echo "  [FAIL] nvidia-smi not found. Install the NVIDIA driver first."
    exit 1
fi

DRIVER_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
DRIVER_MAJOR=$(echo "$DRIVER_VERSION" | cut -d. -f1)
echo "  Driver: $DRIVER_VERSION (major: $DRIVER_MAJOR)"

if [[ ! -d "$WHISPER_VENV" ]]; then
    echo "  [FAIL] openai-whisper venv not found at $WHISPER_VENV"
    echo "  Install first: pipx install openai-whisper"
    exit 1
fi
echo "  Venv: $WHISPER_VENV"

PYTHON="$WHISPER_VENV/bin/python3"
PIP="$PYTHON -m pip"
echo ""

# ── 2. Determine best CUDA variant ────────────────
echo "── Determining best CUDA variant ──"

# Driver → max supported CUDA toolkit version
# 560+ → CUDA 12.6+
# 550+ → CUDA 12.4+
# 535+ → CUDA 12.2+
# 525+ → CUDA 12.0+
# 450+ → CUDA 11.8

if [[ "$DRIVER_MAJOR" -ge 560 ]]; then
    CUDA_VARIANT="cu126"
    CUDA_FULL="12.6"
elif [[ "$DRIVER_MAJOR" -ge 550 ]]; then
    CUDA_VARIANT="cu124"
    CUDA_FULL="12.4"
elif [[ "$DRIVER_MAJOR" -ge 535 ]]; then
    CUDA_VARIANT="cu126"
    CUDA_FULL="12.6"
elif [[ "$DRIVER_MAJOR" -ge 525 ]]; then
    CUDA_VARIANT="cu120"
    CUDA_FULL="12.0"
elif [[ "$DRIVER_MAJOR" -ge 450 ]]; then
    CUDA_VARIANT="cu118"
    CUDA_FULL="11.8"
else
    echo "  [FAIL] Driver $DRIVER_VERSION is too old (need >= 450)"
    echo "  Update your NVIDIA driver."
    exit 1
fi

echo "  Recommended: PyTorch with $CUDA_VARIANT (CUDA $CUDA_FULL)"
echo ""

# ── 3. Check current PyTorch ──────────────────────
echo "── Checking current PyTorch ──"

CURRENT_TORCH=$($PYTHON -c "import torch; print(torch.__version__)" 2>/dev/null) || true
if [[ -n "$CURRENT_TORCH" ]]; then
    echo "  Current: $CURRENT_TORCH"
    CURRENT_CUDA=$(echo "$CURRENT_TORCH" | grep -oP 'cu\K[0-9]+' || echo "none")

    if [[ "$CURRENT_CUDA" == "$CUDA_VARIANT" ]]; then
        echo "  [OK] PyTorch already uses $CUDA_VARIANT. No fix needed."
        echo ""
        echo "  If CUDA still doesn't work, the issue may be:"
        echo "  - Broken driver installation (try reinstalling)"
        echo "  - Kernel module not loaded (try: sudo modprobe nvidia)"
        echo "  - Secure Boot blocking the driver"
        exit 0
    else
        echo "  Current CUDA variant: $CURRENT_CUDA → needs $CUDA_VARIANT"
    fi
else
    echo "  PyTorch not installed in venv"
fi
echo ""

# ── 4. Find the right wheel ───────────────────────
echo "── Finding PyTorch wheel ──"

# Get Python version from the venv
PY_VERSION=$($PYTHON -c "import sys; print(f'cp{sys.version_info.major}{sys.version_info.minor}')")
echo "  Python: $PY_VERSION"

# Construct wheel URL
# Format: torch-2.12.0+cu126-cp311-cp311-manylinux_2_28_x86_64.whl
TORCH_VER="2.12.0"
WHEEL_NAME="torch-${TORCH_VER}+${CUDA_VARIANT}-${PY_VERSION}-${PY_VERSION}-manylinux_2_28_x86_64.whl"
WHEEL_URL="https://download.pytorch.org/whl/${CUDA_VARIANT}/${WHEEL_NAME}"
WHEEL_PATH="${TORCH_WHEEL_DIR}/${WHEEL_NAME}"

echo "  Wheel: $WHEEL_NAME"
echo "  URL: $WHEEL_URL"
echo ""

# ── 5. Download if needed ─────────────────────────
mkdir -p "$TORCH_WHEEL_DIR"

if [[ -f "$WHEEL_PATH" ]]; then
    echo "  Wheel already downloaded: $WHEEL_PATH"
    echo "  Size: $(du -h "$WHEEL_PATH" | cut -f1)"
else
    echo "  Downloading (~2 GB)..."
    echo "  This will take a few minutes."
    echo ""
    curl -L -o "$WHEEL_PATH" "$WHEEL_URL" 2>&1
    echo ""
    echo "  Downloaded: $(du -h "$WHEEL_PATH" | cut -f1)"
fi
echo ""

# ── 6. Backup current torch ───────────────────────
echo "── Backing up current torch ──"
BACKUP_DIR="${TORCH_WHEEL_DIR}/torch-backup-$(date +%Y%m%d-%H%M%S)"
SITE_PACKAGES="$($PYTHON -c "import site; print(site.getsitepackages()[0])" 2>/dev/null)"
if [[ -d "$SITE_PACKAGES/torch" ]]; then
    cp -a "$SITE_PACKAGES/torch" "$BACKUP_DIR"
    echo "  Backed up to: $BACKUP_DIR"
else
    echo "  No existing torch package to back up"
fi
echo ""

# ── 7. Install ────────────────────────────────────
echo "── Installing PyTorch ${TORCH_VER}+${CUDA_VARIANT} ──"
echo "  This will take several minutes (downloads ~2 GB of CUDA deps)."
echo ""

# Ensure pip is available
$PYTHON -m ensurepip --quiet 2>/dev/null || true

$PIP install --force-reinstall "$WHEEL_PATH" 2>&1
echo ""

# ── 8. Verify ─────────────────────────────────────
echo "── Verifying ──"
VERIFY=$($PYTHON -c "
import torch
print(f'Version: {torch.__version__}')
print(f'CUDA available: {torch.cuda.is_available()}')
if torch.cuda.is_available():
    print(f'Device: {torch.cuda.get_device_name(0)}')
" 2>&1) || true

echo "$VERIFY"
echo ""

if echo "$VERIFY" | grep -q "CUDA available: True"; then
    echo "============================================="
    echo "  [SUCCESS] CUDA is now working!"
    echo "============================================="
    echo ""
    echo "  Run ./test_nvidia_cuda.sh for full diagnostics."
else
    echo "============================================="
    echo "  [FAILED] CUDA still not available."
    echo "============================================="
    echo ""
    echo "  Possible causes:"
    echo "  1. Driver installation is broken — try reinstalling"
    echo "  2. Secure Boot is blocking the NVIDIA module"
    echo "  3. The GPU is not supported by this CUDA version"
    echo ""
    echo "  To restore the previous PyTorch:"
    echo "  $PIP install --force-reinstall ${BACKUP_DIR}"
fi
