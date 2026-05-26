#!/bin/bash
# start_ollama.sh
# Start Ollama with NVIDIA GPU support on MX Linux / Debian 12
#
# PURPOSE:
#   This script is for NON-SYSTEMD systems (e.g. MX Linux with sysvinit/runit).
#   It sets environment variables that help Ollama's MLX runner find CUDA
#   libraries, then starts the server.
#
# WHY THIS EXISTS:
#   Ollama 0.21.0's MLX runner bundles CUDA libraries with relative symlinks
#   (e.g. -> ../cuda_v13/libcudart.so) that break when the subprocess changes
#   its working directory. The nvidia-mxlinux-toolkit.sh --fix repairs those
#   symlinks system-wide, but Ollama also needs OLLAMA_LIBRARY_PATH and
#   LD_LIBRARY_PATH set so the dynamic linker can find the user-space CUDA
#   library fallback at ~/ollama_cuda_libs/.
#
# FOR SYSTEMD USERS:
#   Do NOT use this script. Instead, add these same variables to your systemd
#   unit's Environment= directive. See the README in this directory for the
#   exact lines to add.
#
# Usage:
#   ~/bin/start_ollama.sh &
#   or copy this script to ~/bin/ and run it from there.

export OLLAMA_KEEP_ALIVE=-1
export OLLAMA_CONTEXT_LENGTH=32768

# User-space CUDA libraries with properly resolved symlinks
# (created by nvidia-mxlinux-toolkit.sh --fix)
OLLAMA_CUDA_LIBS="$HOME/ollama_cuda_libs"
export OLLAMA_LIBRARY_PATH="$OLLAMA_CUDA_LIBS"
export LD_LIBRARY_PATH="$OLLAMA_CUDA_LIBS:${LD_LIBRARY_PATH}"

echo "Starting Ollama with CUDA support..."
echo "  OLLAMA_LIBRARY_PATH=$OLLAMA_LIBRARY_PATH"
echo "  GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || echo 'not detected')"

exec ollama serve
