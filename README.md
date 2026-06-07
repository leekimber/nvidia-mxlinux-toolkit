# NVIDIA MX Linux Toolkit

Diagnose and fix NVIDIA GPU issues on MX Linux and Debian 12 (Bookworm).

## The Problem

NVIDIA driver installation on Debian-based systems has several gotchas that
cause GPU compute to silently fail:

1. **`nvidia-smi` is a separate package** -- installing `nvidia-driver` does NOT
   include it. Without it, you can't query GPU status.

2. **`libcuda1` is a separate package** -- without it, no CUDA compute works at
   all. Games and display may work fine, but Ollama, PyTorch, Docker, etc. will
   all silently fall back to CPU.

3. **Ollama's MLX runner has broken CUDA symlinks** -- Ollama 0.21.0 bundles
   CUDA libraries with relative symlinks (`../cuda_v13/libcudart.so`) that break
   when the runner subprocess starts. Ollama silently falls back to CPU.

4. **`ldconfig` is not in the default PATH** on MX Linux (it's at
   `/sbin/ldconfig`).

## Quick Start

### Step 1: Check Your Hardware

Before troubleshooting software, verify the GPU is physically working:

```bash
bash misc/check_hardware.sh
```

This checks PCIe bus detection, link health, error counters, and GPU hardware
status. If hardware checks fail, no amount of software configuration will help.

### Step 2: Diagnose and Fix Software

```bash
# Download
curl -O https://raw.githubusercontent.com/leekimber/nvidia-mxlinux-toolkit/main/nvidia-mxlinux-toolkit.sh
chmod +x nvidia-mxlinux-toolkit.sh

# Diagnose (no changes)
bash nvidia-mxlinux-toolkit.sh --check

# Fix all issues (interactive, asks before each fix)
bash nvidia-mxlinux-toolkit.sh

# Fix all issues (non-interactive)
bash nvidia-mxlinux-toolkit.sh --fix
```

## What It Does

| Check | What It Tests | Fix Applied |
|-------|--------------|-------------|
| GPU Hardware | `lspci` detects NVIDIA GPU | -- |
| Kernel Module | `nvidia` module loaded | Install `nvidia-driver` |
| nvidia-smi | Management tool available | Install `nvidia-smi` package |
| libcuda.so | CUDA driver library present | Install `libcuda1` package |
| CUDA Test | `cuInit()` + device query via Python | -- |
| MLX Symlinks | Ollama's `mlx_cuda_v13/` relative links | Replace with absolute symlinks |
| User-space CUDA | Fallback library directory | Copy libs to `~/ollama_cuda_libs/` |
| PyTorch CUDA | PyTorch version vs driver compatibility | Install matching PyTorch build (cu126, cu124, etc.) |
| Other Runtimes | Docker, LM Studio, Conda, PyTorch | Install missing packages |

## After Running

### Non-systemd systems (MX Linux sysvinit/runit)

Copy the helper script from `misc/` and start Ollama:

```bash
cp misc/start_ollama.sh ~/bin/
chmod +x ~/bin/start_ollama.sh
~/bin/start_ollama.sh &
```

The script sets `OLLAMA_LIBRARY_PATH` and `LD_LIBRARY_PATH` so Ollama's MLX
runner can find the CUDA libraries in `~/ollama_cuda_libs/`. See
[misc/README.md](misc/README.md) for details.

### Systemd systems

Add the environment variables to your Ollama systemd unit. Edit
`/etc/systemd/system/ollama.service` and add `Environment=` lines in the
`[Service]` section:

**Before:**
```
[Service]
ExecStart=/usr/local/bin/ollama serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="PATH=/usr/local/bin:/usr/bin:/bin"

[Install]
WantedBy=multi-user.target
```

**After:**
```
[Service]
ExecStart=/usr/local/bin/ollama serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
Environment="OLLAMA_LIBRARY_PATH=/home/YOURUSER/ollama_cuda_libs"
Environment="LD_LIBRARY_PATH=/home/YOURUSER/ollama_cuda_libs"
Environment="OLLAMA_KEEP_ALIVE=-1"
Environment="OLLAMA_CONTEXT_LENGTH=32768"

[Install]
WantedBy=multi-user.target
```

Replace `YOURUSER` with your actual username. Multiple `Environment=` directives
are valid in systemd -- each one sets or appends variables independently.

Then reload and restart:

```bash
sudo systemctl daemon-reload
sudo systemctl restart ollama
```

Verify GPU is being used:

```bash
ollama logs 2>&1 | grep -i gpu
```

## Miscellaneous Tools

The `misc/` directory contains helper scripts for specific setups:

- **[check_hardware.sh](misc/check_hardware.sh)** -- Hardware diagnostic. Checks PCIe
  bus detection, link speed/width, AER errors, kernel driver binding, GPU health
  (temperature, power, throttling), IOMMU group, and BIOS/UEFI configuration hints.
  Run this FIRST, before any software troubleshooting.
- **[start_ollama.sh](misc/start_ollama.sh)** -- Launch script for non-systemd
  users. Sets `OLLAMA_LIBRARY_PATH` and `LD_LIBRARY_PATH` for the MLX runner.
- **[fix_pytorch_cuda.sh](misc/fix_pytorch_cuda.sh)** -- Fixes PyTorch/CUDA version
  mismatch. PyTorch bundles its own CUDA runtime; if it's newer than your driver
  supports, `torch.cuda.is_available()` returns `False`. This script installs a
  matching PyTorch build. Run when the main toolkit reports a PyTorch CUDA issue.
- **[test_whisper.sh](misc/test_whisper.sh)** -- Tests openai-whisper transcription
  on CUDA. Checks model loading, transcription output, SRT format, and provides
  model/VRAM recommendations. Run after fixing CUDA to verify whisper works.
- **[transcribe_local.sh](misc/transcribe_local.sh)** -- Batch video/audio to
  transcript. Configurable model, device, format, and language via variables at
  the top of the script. SRT output by default.
- **[misc/README.md](misc/README.md)** -- Detailed documentation for each tool,
  including systemd configuration instructions.

## Requirements

- MX Linux or Debian 12 (Bookworm)
- NVIDIA GPU
- `sudo` access (for installing packages and fixing system library symlinks)
- `python3` (optional, for CUDA functional test)

## Tested On

- MX Linux 23 (Debian 12 Bookworm)
- NVIDIA GeForce GTX 1650 Mobile / Max-Q (TU117M)
- Driver 535.261.03
- Ollama 0.21.0

## License

MIT
