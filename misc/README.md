# Miscellaneous Tools

Helper scripts for specific setups that the main toolkit does not cover.

## start_ollama.sh

Starts Ollama with NVIDIA GPU support on **non-systemd** systems (e.g. MX Linux
with sysvinit or runit).

### Why it exists

Ollama 0.21.0's MLX runner bundles CUDA libraries with relative symlinks that
break when the subprocess changes working directory. The main toolkit (`--fix`)
repairs those symlinks system-wide, but Ollama also needs two environment
variables set at runtime so the dynamic linker can find the user-space CUDA
library fallback at `~/ollama_cuda_libs/`:

- `OLLAMA_LIBRARY_PATH` -- tells the MLX runner where to find CUDA libs
- `LD_LIBRARY_PATH` -- fallback for the dynamic linker

This script sets those variables and launches `ollama serve`.

### For non-systemd users

Copy to `~/bin/` and run:

```bash
cp start_ollama.sh ~/bin/
chmod +x ~/bin/start_ollama.sh
~/bin/start_ollama.sh &
```

### For systemd users

Do NOT use this script. Instead, edit your Ollama systemd unit (usually
`/etc/systemd/system/ollama.service`) and add the environment variables to the
`Environment=` line in the `[Service]` section:

**Before:**
```
[Service]
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
```

**After:**
```
[Service]
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
Environment="OLLAMA_LIBRARY_PATH=/home/YOURUSER/ollama_cuda_libs"
Environment="LD_LIBRARY_PATH=/home/YOURUSER/ollama_cuda_libs"
```

Replace `YOURUSER` with your actual username. If the unit already has an
`Environment=` line, you can either add a second one (systemd allows multiple)
or append to the existing one:

```
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
Environment="OLLAMA_LIBRARY_PATH=/home/YOURUSER/ollama_cuda_libs"
Environment="OLLAMA_KEEP_ALIVE=-1"
Environment="OLLAMA_CONTEXT_LENGTH=32768"
```

Then reload and restart:

```bash
sudo systemctl daemon-reload
sudo systemctl restart ollama
```

### Prerequisites

Run `nvidia-mxlinux-toolkit.sh --fix` first to create `~/ollama_cuda_libs/`
and repair the MLX symlinks. Without that directory, the environment variables
point to nothing and Ollama will silently fall back to CPU.
