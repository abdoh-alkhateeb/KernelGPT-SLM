#!/usr/bin/env bash
# One-shot setup for KernelGPT-SLM on Ubuntu x86_64 with an NVIDIA GPU.
# Every phase is skipped when its result already exists, so re-running is safe.
# The first run installs packages and the GPU driver and then asks for a
# reboot; run it again afterwards to finish (the long kernel build and analysis).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
JOBS=${JOBS:-$(( $(nproc) < 128 ? $(nproc) : 128 ))}
STAMPS="$ROOT/.setup"
PY="$ROOT/.venv/bin/python"
ANALYZER_IMAGE=kernelgpt-analyzer
BASE_MODEL=Qwen/Qwen2.5-Coder-7B-Instruct
mkdir -p "$STAMPS"

log() { printf '\n==> %s\n' "$*"; }
done_stamp() { [[ -f "$STAMPS/$1" ]]; }
stamp() { touch "$STAMPS/$1"; }

# Run a command in the clang-14 container with the repo mounted at the same
# absolute path, so the generated compile_commands.json is valid on the host too.
in_analyzer() {
    local workdir=$1
    shift
    docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
        -v "$ROOT:$ROOT" -w "$workdir" "$ANALYZER_IMAGE" "$@"
}

# The analyzer writes its *.jsonl next to whichever directory clang's tooling
# changed into, while process_output.py expects some in linux/ and some in the
# analyzer directory. Make every file visible from both places.
link_jsonl() {
    local f d
    for f in "$ROOT"/linux/*.jsonl "$ROOT"/spec-gen/analyzer/*.jsonl; do
        [[ -e "$f" ]] || continue
        for d in "$ROOT/linux" "$ROOT/spec-gen/analyzer"; do
            [[ -e "$d/$(basename "$f")" ]] || ln -s "$f" "$d/$(basename "$f")"
        done
    done
}

# ------------------------------------------------------------ 1. host packages
log "Installing system packages"
sudo apt-get update
sudo apt-get install -y build-essential gcc-14 g++-14 make flex bison bc \
    libelf-dev libssl-dev dwarves zstd cpio rsync kmod git python3 \
    python3-venv python3-pip golang-go docker.io qemu-system-x86 qemu-utils \
    debootstrap ubuntu-drivers-common wget curl
sudo systemctl enable --now docker
sudo usermod -aG docker,kvm "$USER"

if ! nvidia-smi >/dev/null 2>&1; then
    log "Installing the NVIDIA driver"
    sudo ubuntu-drivers install
    echo "Driver installed. Reboot, then run ./setup.sh again."
    exit 0
fi
if ! docker info >/dev/null 2>&1 || [[ ! -w /dev/kvm ]]; then
    echo "Docker/KVM group membership is not active in this session yet."
    echo "Reboot (or log out and back in), then run ./setup.sh again."
    exit 0
fi

free_gb=$(df -BG --output=avail "$ROOT" | tail -1 | tr -dc 0-9)
if (( free_gb < 120 )); then
    echo "Warning: ${free_gb}G free; the allyesconfig kernel build needs ~100G."
fi

# ------------------------------------------------------------ 2. python
log "Creating the Python environment"
[[ -d "$ROOT/.venv" ]] || python3 -m venv "$ROOT/.venv"
"$ROOT/.venv/bin/pip" install -q --upgrade pip
"$ROOT/.venv/bin/pip" install -q -r "$ROOT/requirements.txt"

# ------------------------------------------------------------ 3. sources
log "Fetching the Linux and Syzkaller submodules"
git -C "$ROOT" submodule update --init --depth 1
if ! git -C "$ROOT/linux" apply --reverse --check \
        "$ROOT/spec-eval/linux-d2f51b35.patch" >/dev/null 2>&1; then
    git -C "$ROOT/linux" apply "$ROOT/spec-eval/linux-d2f51b35.patch"
fi

# ------------------------------------------------------------ 4. kernel analysis
log "Building the clang-14 analysis container"
docker build -q -t "$ANALYZER_IMAGE" "$ROOT/spec-gen/analyzer" >/dev/null

if ! done_stamp kernel-analysis-build; then
    log "Building Linux (allyesconfig, clang-14) under bear; this takes hours"
    cp "$ROOT/kernel-configs/allyesconfig-clang.config" "$ROOT/linux/.config"
    in_analyzer "$ROOT/linux" make CC=clang HOSTCC=clang olddefconfig
    in_analyzer "$ROOT/linux" bear --append -- make CC=clang HOSTCC=clang -j"$JOBS"
    stamp kernel-analysis-build
fi

if ! done_stamp kernel-analysis-run; then
    log "Building and running the kernel analyzer"
    in_analyzer "$ROOT/spec-gen/analyzer" make all
    test -x "$ROOT/spec-gen/analyzer/analyze" -a -x "$ROOT/spec-gen/analyzer/usage"
    in_analyzer "$ROOT/spec-gen/analyzer" ./analyze -p "$ROOT/linux/compile_commands.json"
    link_jsonl
    (cd "$ROOT/spec-gen/analyzer" && "$PY" process_output.py --linux-path "$ROOT/linux")
    in_analyzer "$ROOT/spec-gen/analyzer" ./usage -p "$ROOT/linux/compile_commands.json"
    link_jsonl
    (cd "$ROOT/spec-gen/analyzer" && "$PY" process_output.py --linux-path "$ROOT/linux" --usage)
    stamp kernel-analysis-run
fi

# ------------------------------------------------------------ 5. syzkaller + model
if [[ ! -f "$ROOT/image/bullseye.img" ]]; then
    log "Creating the Debian VM image for Syzkaller (asks for sudo)"
    (cd "$ROOT/image" && ./create-image.sh)
fi

log "Pulling the Syzkaller build image"
docker pull -q gcr.io/syzkaller/env >/dev/null

log "Downloading $BASE_MODEL"
"$PY" -c "from huggingface_hub import snapshot_download; snapshot_download('$BASE_MODEL')"

log "Setup complete. Generate and validate specs with: ./run.sh [NUM_SPECS]"
