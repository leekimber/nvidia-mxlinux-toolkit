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

```bash
# Download
curl -O https://raw.githubusercontent.com/YOURNAME/nvidia-mxlinux-toolkit/main/nvidia-mxlinux-toolkit.sh
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
| Other Runtimes | Docker, LM Studio, Conda, PyTorch | Install missing packages |

## After Running

Start Ollama with GPU support:

```bash
export OLLAMA_LIBRARY_PATH=$HOME/ollama_cuda_libs
export LD_LIBRARY_PATH=$HOME/ollama_cuda_libs:$LD_LIBRARY_PATH
ollama serve &
```

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
