#!/bin/bash
# nvidia-mxlinux-toolkit.sh
# NVIDIA GPU diagnostic and repair toolkit for MX Linux / Debian 12
#
# Diagnoses and fixes the most common NVIDIA GPU issues on Debian-based
# systems: missing driver, missing libcuda, missing nvidia-smi, broken MLX
# symlinks, CUDA toolkit gaps.
#
# After running this script, CUDA compute should work for: Ollama, LM Studio,
# Docker/Podman with GPU, PyTorch, TensorFlow, and any other CUDA runtime.
#
# Usage:
#   bash nvidia-mxlinux-toolkit.sh           # interactive mode
#   bash nvidia-mxlinux-toolkit.sh --check   # diagnostics only, no changes
#   bash nvidia-mxlinux-toolkit.sh --fix     # fix all issues found
#
# Source: https://github.com/YOURNAME/nvidia-mxlinux-toolkit
# License: MIT

MODE="interactive"
[ "${1:-}" = "--check" ] && MODE="check"
[ "${1:-}" = "--fix" ] && MODE="fix"

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

ISSUES=()
FIXES=()

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

ok()    { echo -e "  ${GREEN}[OK]${NC}    $1"; }
warn()  { echo -e "  ${YELLOW}[WARN]${NC}  $1"; ISSUES+=("$1"); }
fail()  { echo -e "  ${RED}[FAIL]${NC}  $1"; ISSUES+=("$1"); }
note()  { echo -e "  ${BLUE}[INFO]${NC}  $1"; }
header(){ echo -e "\n${BOLD}${BLUE}── $1 ──${NC}"; }

try_fix() {
    local desc="$1"
    local cmd="$2"
    case "$MODE" in
        check)
            FIXES+=("$desc (--check: not applied)")
            ;;
        fix)
            echo -ne "  Applying: $desc ... "
            if eval "$cmd" 2>/dev/null; then
                echo -e "${GREEN}done${NC}"
                FIXES+=("$desc")
            else
                echo -e "${RED}failed${NC}"
            fi
            ;;
        *)
            echo -ne "  ${YELLOW}Fix:${NC} $desc? [y/N] "
            read -r ans
            if [[ "$ans" =~ ^[Yy] ]]; then
                echo -ne "  Applying ... "
                if eval "$cmd" 2>/dev/null; then
                    echo -e "${GREEN}done${NC}"
                    FIXES+=("$desc")
                else
                    echo -e "${RED}failed${NC}"
                fi
            fi
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════
header "NVIDIA MX Linux Toolkit v1.0"
echo ""

# ── 1. Hardware ──────────────────────────────────────────────────────
header "1. GPU Hardware"

GPU_PCI=$(lspci 2>/dev/null | grep -i nvidia | head -3) || true
if [ -n "$GPU_PCI" ]; then
    ok "NVIDIA GPU found:"
    echo "$GPU_PCI" | while IFS= read -r line; do note "$line"; done
else
    fail "No NVIDIA GPU detected via lspci"
    note "Install pciutils: sudo apt install pciutils"
fi

# ── 2. Kernel Module ─────────────────────────────────────────────────
header "2. Kernel Module"

if lsmod 2>/dev/null | grep -q "^nvidia"; then
    DRIVER_VER=$(cat /proc/driver/nvidia/version 2>/dev/null | awk 'NR==1{print $8}') || DRIVER_VER="unknown"
    ok "Kernel module loaded (driver $DRIVER_VER)"
else
    fail "nvidia kernel module NOT loaded"
    echo ""
    echo "  Install the driver, then reboot:"
    echo "    sudo apt update"
    echo "    sudo apt install nvidia-driver firmware-misc-nonfree"
    echo "    sudo reboot"
    echo ""
    try_fix "Install nvidia-driver" \
        "$SUDO apt update && $SUDO apt install -y nvidia-driver firmware-misc-nonfree"
fi

# ── 3. nvidia-smi ────────────────────────────────────────────────────
header "3. nvidia-smi"

if command -v nvidia-smi &>/dev/null; then
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1) || GPU_NAME="unknown"
    GPU_MEM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null | head -1) || GPU_MEM="?"
    CUDA_VER=$(nvidia-smi 2>/dev/null | sed -n 's/.*CUDA Version: \([0-9.]*\).*/\1/p') || CUDA_VER="?"
    DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1) || DRIVER_VER="?"
    ok "nvidia-smi found"
    note "GPU:       $GPU_NAME ($GPU_MEM)"
    note "Driver:    $DRIVER_VER  CUDA: $CUDA_VER"
else
    fail "nvidia-smi not found (separate package from the driver)"
    try_fix "Install nvidia-smi" \
        "$SUDO apt update && $SUDO apt install -y nvidia-smi"
fi

# ── 4. libcuda.so ────────────────────────────────────────────────────
header "4. libcuda.so (CUDA driver library)"

LIBCUDA=""
for p in \
    /usr/lib/x86_64-linux-gnu/nvidia/current/libcuda.so.1 \
    /lib/x86_64-linux-gnu/libcuda.so.1 \
    /usr/lib/x86_64-linux-gnu/libcuda.so.1; do
    [ -f "$p" ] && LIBCUDA="$p" && break
done

if [ -n "$LIBCUDA" ]; then
    ok "libcuda.so.1 found: $LIBCUDA"
else
    fail "libcuda.so.1 NOT found"
    echo ""
    echo "  libcuda1 is a SEPARATE package. Without it, NO CUDA compute works."
    echo "  Games and display may work, but Ollama, PyTorch, Docker, etc."
    echo "  will all silently fall back to CPU."
    try_fix "Install libcuda1" \
        "$SUDO apt update && $SUDO apt install -y libcuda1"
fi

# ── 5. CUDA Function Test ────────────────────────────────────────────
header "5. CUDA Functional Test"

if command -v python3 &>/dev/null; then
    CUDA_TEST=$(python3 -c "
import ctypes
try:
    lib = ctypes.CDLL('libcuda.so.1')
    ret = lib.cuInit(0)
    if ret != 0: exit(1)
    dev = ctypes.c_int()
    lib.cuDeviceGet(ctypes.byref(dev), 0)
    buf = ctypes.create_string_buffer(256)
    lib.cuDeviceGetName(buf, 256, dev)
    mem = ctypes.c_size_t()
    lib.cuDeviceTotalMem_v2(ctypes.byref(mem), dev)
    print('GPU=' + buf.value.decode() + ' VRAM=' + str(mem.value // 1048576) + 'MB')
except Exception as e:
    print('ERROR:' + str(e), file=__import__('sys').stderr)
    exit(99)
" 2>/dev/null) || CUDA_TEST=""

    if [[ "$CUDA_TEST" == GPU=* ]]; then
        ok "CUDA functional: ${CUDA_TEST#GPU=}"
    else
        warn "CUDA function test failed: ${CUDA_TEST:-Python error}"
        note "Reboot may be needed if driver was just installed"
    fi
else
    warn "python3 not available for CUDA test"
fi

# ── 6. CUDA Runtime & MLX Symlinks ───────────────────────────────────
header "6. CUDA Runtime Libraries"

# System CUDA toolkit (optional)
if dpkg -l 2>/dev/null | grep -q "nvidia-cuda-toolkit"; then
    ok "nvidia-cuda-toolkit installed"
else
    note "nvidia-cuda-toolkit not installed (optional; for compiling CUDA code)"
fi

# Ollama checks
OLLAMA_BIN="/usr/local/bin/ollama"
OLLAMA_LIB_DIR="/usr/local/lib/ollama"

if [ -f "$OLLAMA_BIN" ]; then
    OLLAMA_VER=$(ollama --version 2>/dev/null || echo "?")
    ok "Ollama installed ($OLLAMA_VER)"

    MODEL_COUNT=$(ollama list 2>/dev/null | tail -n +2 | wc -l) || MODEL_COUNT=0
    note "Models: $MODEL_COUNT installed"

    # -- MLX symlink check --
    MLX_DIR="$OLLAMA_LIB_DIR/mlx_cuda_v13"
    CUDA13_DIR="$OLLAMA_LIB_DIR/cuda_v13"

    if [ -d "$MLX_DIR" ] && [ -d "$CUDA13_DIR" ]; then
        BROKEN_MLX=false
        for f in "$MLX_DIR"/libcudart.so.13.0.96 \
                 "$MLX_DIR"/libcublas.so.13.1.1.3 \
                 "$MLX_DIR"/libcublasLt.so.13.1.1.3; do
            [ -e "$f" ] || continue
            tgt=$(readlink "$f" 2>/dev/null) || continue
            [[ "$tgt" == ../* ]] && BROKEN_MLX=true && break
        done

        if $BROKEN_MLX; then
            warn "Ollama MLX CUDA symlinks are broken (relative ../ paths)"
            echo ""
            echo "  Ollama's MLX runner bundles CUDA libs with relative symlinks"
            echo "  (e.g. -> ../cuda_v13/libcudart.so.13.0.96). These break when"
            echo "  the subprocess starts because the working directory changes."
            echo "  Result: Ollama silently falls back to CPU inference."
            echo ""

            MLX_FIX="cd '$MLX_DIR' && rm -f libcudart.so libcudart.so.13 libcudart.so.13.0.96 libcublas.so libcublas.so.13 libcublas.so.13.1.1.3 libcublasLt.so libcublasLt.so.13 libcublasLt.so.13.1.1.3 && ln -sf '$CUDA13_DIR/libcudart.so.13' libcudart.so.13 && ln -sf libcudart.so.13 libcudart.so && ln -sf '$CUDA13_DIR/libcublas.so.13.1.1.3' libcublas.so.13.1.1.3 && ln -sf libcublas.so.13.1.1.3 libcublas.so.13 && ln -sf libcublas.so.13 libcublas.so && ln -sf '$CUDA13_DIR/libcublasLt.so.13.1.1.3' libcublasLt.so.13.1.1.3 && ln -sf libcublasLt.so.13.1.1.3 libcublasLt.so.13 && ln -sf libcublasLt.so.13 libcublasLt.so"

            try_fix "Fix MLX CUDA symlinks (requires root)" "$SUDO bash -c \"$MLX_FIX\""

            # User-space fallback
            USER_CUDA="$HOME/ollama_cuda_libs"
            try_fix "Create user-space CUDA fallback" "
                mkdir -p '$USER_CUDA'
                for src in '$CUDA13_DIR' '$MLX_DIR'; do
                    for f in \"\$src\"/lib*.so \"\$src\"/lib*.so.[0-9]*; do
                        [ -f \"\$f\" ] && [ ! -L \"\$f\" ] && cp -af \"\$f\" '$USER_CUDA/' 2>/dev/null
                    done
                done
                for f in /usr/local/lib/ollama/libggml-base.so*; do
                    [ -f \"\$f\" ] && [ ! -L \"\$f\" ] && cp -af \"\$f\" '$USER_CUDA/' 2>/dev/null
                done
                libcuda=\$(readlink -f /usr/lib/x86_64-linux-gnu/nvidia/current/libcuda.so.1 2>/dev/null || readlink -f /lib/x86_64-linux-gnu/libcuda.so.1 2>/dev/null)
                [ -n \"\$libcuda\" ] && cp -af \"\$libcuda\" '$USER_CUDA/libcuda.so.1'
            "

            # Create local symlinks in user-space dir
            if [ -d "$USER_CUDA" ]; then
                cd "$USER_CUDA"
                ln -sf libcudart.so.13.0.96 libcudart.so.13 2>/dev/null
                ln -sf libcudart.so.13 libcudart.so 2>/dev/null
                ln -sf libcublas.so.13.1.1.3 libcublas.so.13 2>/dev/null
                ln -sf libcublas.so.13 libcublas.so 2>/dev/null
                ln -sf libcublasLt.so.13.1.1.3 libcublasLt.so.13 2>/dev/null
                ln -sf libcublasLt.so.13 libcublasLt.so 2>/dev/null
                ln -sf libggml-base.so.0.0.0 libggml-base.so.0 2>/dev/null
                ln -sf libggml-base.so.0 libggml-base.so 2>/dev/null
                ln -sf libopenblas-r0.3.15.so libopenblas.so.0 2>/dev/null
                ln -sf libnccl.so.2.29.7 libnccl.so.2 2>/dev/null
                ln -sf libcufft.so.12.0.0.61 libcufft.so.12 2>/dev/null
                ln -sf libnvrtc.so.13.0.88 libnvrtc.so.13 2>/dev/null
                ln -sf libcudnn.so.9.21.0 libcudnn.so.9 2>/dev/null
                ln -sf libcudnn_graph.so.9.21.0 libcudnn_graph.so.9 2>/dev/null
                ln -sf libcudnn_engines_runtime_compiled.so.9.21.0 libcudnn_engines_runtime_compiled.so.9 2>/dev/null
                ln -sf libcudnn_ops.so.9.21.0 libcudnn_ops.so.9 2>/dev/null
                ln -sf libcudnn_cnn.so.9.21.0 libcudnn_cnn.so.9 2>/dev/null
                ln -sf libcudnn_adv.so.9.21.0 libcudnn_adv.so.9 2>/dev/null
                ln -sf libcudnn_engines_precompiled.so.9.21.0 libcudnn_engines_precompiled.so.9 2>/dev/null
                ln -sf libcudnn_heuristic.so.9.21.0 libcudnn_heuristic.so.9 2>/dev/null
                note "User-space CUDA libs: $USER_CUDA ($(du -sh "$USER_CUDA" 2>/dev/null | cut -f1))"
            fi
        else
            ok "Ollama MLX CUDA symlinks are correct"
        fi
    fi
else
    note "Ollama not installed (https://ollama.com)"
fi

# ── 7. Other AI/ML Runtimes ──────────────────────────────────────────
header "7. Other AI / ML Runtimes"

# LM Studio
if [ -f "$HOME/.lmstudio/bin/lmstudio" ] || [ -f "/opt/lmstudio/LM Studio" ]; then
    ok "LM Studio detected"
else
    note "LM Studio not detected (https://lmstudio.ai)"
fi

# Docker + nvidia-container-toolkit
if command -v docker &>/dev/null; then
    if dpkg -l 2>/dev/null | grep -q nvidia-container-toolkit; then
        ok "Docker + nvidia-container-toolkit"
    else
        note "Docker installed; nvidia-container-toolkit not found"
        try_fix "Install nvidia-container-toolkit" \
            "$SUDO apt update && $SUDO apt install -y nvidia-container-toolkit"
    fi
fi

# Conda
if command -v conda &>/dev/null; then
    ok "Conda: $(conda --version 2>/dev/null)"
fi

# Python ML libraries
if command -v python3 &>/dev/null; then
    for pkg in torch tensorflow; do
        if python3 -c "import $pkg" 2>/dev/null; then
            VER=$(python3 -c "import $pkg; print($pkg.__version__)" 2>/dev/null || echo "installed")
            note "Python $pkg: $VER"
        fi
    done
fi

# ── 8. Summary ───────────────────────────────────────────────────────
header "Summary"

echo ""
if [ ${#ISSUES[@]} -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}All checks passed! NVIDIA GPU should be fully functional.${NC}"
else
    echo -e "  ${YELLOW}Found ${#ISSUES[@]} issue(s):${NC}"
    for i in "${ISSUES[@]}"; do
        echo -e "    ${RED}!${NC} $i"
    done
    echo ""
    if [ ${#FIXES[@]} -gt 0 ]; then
        echo -e "  ${GREEN}Applied ${#FIXES[@]} fix(es).${NC}"
    fi
    echo ""
    echo "  Re-run with --fix to apply all fixes without prompting:"
    echo "    bash nvidia-mxlinux-toolkit.sh --fix"
fi

echo ""
echo "  Quick start for Ollama:"
echo ""
echo "  Non-systemd (MX Linux sysvinit/runit):"
echo "    cp misc/start_ollama.sh ~/bin/"
echo "    ~/bin/start_ollama.sh &"
echo ""
echo "  Systemd:"
echo "    Add to /etc/systemd/system/ollama.service [Service] section:"
echo "      Environment=\"OLLAMA_LIBRARY_PATH=/home/\$USER/ollama_cuda_libs\""
echo "      Environment=\"LD_LIBRARY_PATH=/home/\$USER/ollama_cuda_libs\""
echo "    Then: sudo systemctl daemon-reload && sudo systemctl restart ollama"
echo ""
echo "  See README.md and misc/README.md for full instructions."
echo ""

# Save report
REPORT="/tmp/nvidia-toolkit-report.txt"
{
    echo "NVIDIA MX Linux Toolkit Report"
    echo "Date: $(date)"
    echo "Kernel: $(uname -r)"
    echo "Mode: $MODE"
    echo ""
    echo "=== nvidia-smi ==="
    nvidia-smi 2>/dev/null || echo "nvidia-smi not available"
    echo ""
    echo "=== Issues (${#ISSUES[@]}) ==="
    for i in "${ISSUES[@]}"; do echo "  ! $i"; done
    echo ""
    echo "=== Fixes (${#FIXES[@]}) ==="
    for f in "${FIXES[@]}"; do echo "  + $f"; done
} > "$REPORT" 2>/dev/null || true

note "Report saved: $REPORT"
