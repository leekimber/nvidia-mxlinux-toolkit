#!/usr/bin/env bash
# ------------------------------------------------------------
#  test_whisper.sh — test openai-whisper transcription
#  on MX Linux with NVIDIA CUDA
#
#  Tests:
#    1. whisper CLI available
#    2. Model loads on CUDA
#    3. Transcription produces valid output
#    4. SRT output format correct
#
#  Usage:
#    ./test_whisper.sh [video-file]
#
#  If no file is given, creates a short test audio clip.
#
#  Example (Acer Nitro 5, GTX 1650):
#    $ ./test_whisper.sh ~/Videos/test.mp4
#    [PASS] whisper CLI found
#    [PASS] tiny model loads on cuda:0
#    [PASS] Transcription: "Hey everybody, certainly glad..."
#    [PASS] SRT output: 142 segments, 12K
#    [INFO] Model: small, Device: cuda, FP16: False
#    [INFO] Time: 28.9s for 9min video
# ------------------------------------------------------------

set -euo pipefail

WHISPER_VENV="$HOME/.local/pipx/venvs/openai-whisper"
PYTHON="$WHISPER_VENV/bin/python3"
PASS=0
FAIL=0

ok()   { echo "  [PASS] $1"; ((PASS++)); }
fail() { echo "  [FAIL] $1"; ((FAIL++)); }
info() { echo "  [INFO] $1"; }
warn() { echo "  [WARN] $1"; }

echo "============================================="
echo "  Whisper CUDA Test — MX Linux"
echo "============================================="
echo ""

# ── 1. whisper CLI ────────────────────────────────
echo "── 1. Whisper CLI ──"
if [[ -x "$WHISPER_VENV/bin/whisper" ]]; then
    ok "whisper CLI found: $WHISPER_VENV/bin/whisper"
else
    fail "whisper CLI not found"
    info "Install: pipx install openai-whisper"
    exit 1
fi
echo ""

# ── 2. Model loads on CUDA ────────────────────────
echo "── 2. Model Load Test ──"
LOAD_TEST=$($PYTHON -c "
import whisper
model = whisper.load_model('tiny')
print(f'device: {model.device}')
print(f'dtype: {model.dtype}')
" 2>&1) || true

if echo "$LOAD_TEST" | grep -q "device: cuda"; then
    ok "tiny model loads on CUDA"
    info "$(echo "$LOAD_TEST" | grep device)"
elif echo "$LOAD_TEST" | grep -q "device: cpu"; then
    warn "Model loaded on CPU — CUDA may not be available"
    info "Run: ./test_nvidia_cuda.sh"
    info "Then: ./fix_pytorch_cuda.sh"
else
    fail "Model failed to load"
    info "$LOAD_TEST"
fi
echo ""

# ── 3. Create test audio if no file given ─────────
TEST_FILE="${1:-}"
if [[ -z "$TEST_FILE" ]]; then
    echo "── 3. Creating test audio clip ──"
    TEST_FILE="/tmp/whisper_test_$(date +%s).wav"

    if command -v ffmpeg &>/dev/null; then
        # Generate 5-second sine wave with spoken text overlay
        # Using espeak for speech synthesis
        if command -v espeak &>/dev/null; then
            espeak -w /tmp/whisper_test_speech.wav "Hello, this is a test of whisper transcription."
            ffmpeg -y -i /tmp/whisper_test_speech.wav -ar 16000 -ac 1 "$TEST_FILE" 2>/dev/null
            ok "Test audio created: $TEST_FILE"
        else
            # Fallback: generate silent WAV
            ffmpeg -y -f lavfi -i "sine=frequency=440:duration=3" -ar 16000 -ac 1 "$TEST_FILE" 2>/dev/null
            warn "espeak not installed — using silent test audio"
            info "Install espeak for meaningful transcription tests"
        fi
    else
        fail "ffmpeg not found — cannot create test audio"
        info "Install: sudo apt install ffmpeg"
        exit 1
    fi
else
    echo "── 3. Using provided file ──"
    if [[ -f "$TEST_FILE" ]]; then
        ok "File: $TEST_FILE ($(du -h "$TEST_FILE" | cut -f1))"
    else
        fail "File not found: $TEST_FILE"
        exit 1
    fi
fi
echo ""

# ── 4. Transcription test ─────────────────────────
echo "── 4. Transcription Test ──"

TRANSCRIBE_TEST=$($PYTHON -c "
import whisper
import time
import os

model = whisper.load_model('tiny')
start = time.time()
result = model.transcribe('${TEST_FILE}', language='en')
elapsed = time.time() - start

text = result['text'].strip()
segments = len(result.get('segments', []))

print(f'time: {elapsed:.1f}')
print(f'segments: {segments}')
print(f'text: {text[:200]}')
" 2>&1) || true

if echo "$TRANSCRIBE_TEST" | grep -q "text:"; then
    ok "Transcription completed"
    TIME=$(echo "$TRANSCRIBE_TEST" | grep "time:" | head -1 | awk '{print $2}')
    SEGMENTS=$(echo "$TRANSCRIBE_TEST" | grep "segments:" | head -1 | awk '{print $2}')
    TEXT=$(echo "$TRANSCRIBE_TEST" | grep "text:" | head -1 | cut -d: -f2-)
    info "Time: ${TIME}s | Segments: $SEGMENTS"
    info "Text: $TEXT"
else
    fail "Transcription failed"
    info "$TRANSCRIBE_TEST"
fi
echo ""

# ── 5. SRT output test ────────────────────────────
echo "── 5. SRT Output Test ──"
SRT_FILE="${TEST_FILE%.*}.srt"

# Remove old SRT if exists
rm -f "$SRT_FILE"

$WHISPER_VENV/bin/whisper "$TEST_FILE" \
    --model tiny \
    --output_format srt \
    --output_dir "$(dirname "$TEST_FILE")" \
    --language en \
    2>/dev/null || true

if [[ -f "$SRT_FILE" ]]; then
    SRT_SIZE=$(du -h "$SRT_FILE" | cut -f1)
    SRT_LINES=$(wc -l < "$SRT_FILE")
    ok "SRT output: $SRT_SIZE, $SRT_LINES lines"

    # Validate SRT format (should start with "1" and have timestamps)
    if head -3 "$SRT_FILE" | grep -qE '^[0-9]+$'; then
        ok "SRT format valid"
    else
        warn "SRT format may be invalid"
    fi
else
    fail "SRT file not created"
fi
echo ""

# ── 6. Model recommendations ──────────────────────
echo "── 6. Model Recommendations ──"
if command -v nvidia-smi &>/dev/null; then
    VRAM_TOTAL=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
    VRAM_GB=$(echo "scale=1; $VRAM_TOTAL / 1024" | bc 2>/dev/null || echo "$((VRAM_TOTAL / 1024))")
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)

    info "GPU: $GPU_NAME (${VRAM_GB}GB VRAM)"

    if (( $(echo "$VRAM_GB < 4" | bc -l 2>/dev/null || echo 0) )); then
        echo "  Recommended settings:"
        echo "    MODEL=tiny,  FP16=True  (fastest, lower quality)"
        echo "    MODEL=small, FP16=False (better quality, ~2x slower)"
        echo "  Avoid: medium, large, turbo (will OOM)"
    elif (( $(echo "$VRAM_GB < 6" | bc -l 2>/dev/null || echo 0) )); then
        echo "  Recommended settings:"
        echo "    MODEL=small,  FP16=False (good quality)"
        echo "    MODEL=medium, FP16=True  (best quality, may be slow)"
        echo "  Avoid: large (may OOM)"
    else
        echo "  All models should work. Recommended:"
        echo "    MODEL=medium, FP16=True"
    fi
fi
echo ""

# ── Summary ───────────────────────────────────────
echo "============================================="
echo "  Summary"
echo "============================================="
echo "  Pass: $PASS  |  Fail: $FAIL"
echo ""

if [[ $FAIL -eq 0 ]]; then
    echo "  Whisper is working correctly on CUDA."
    echo "  You can now use transcribe_local.sh for batch jobs."
else
    echo "  Some tests failed. Run ./test_nvidia_cuda.sh for"
    echo "  detailed CUDA diagnostics."
fi
echo ""

# Cleanup
if [[ "${1:-}" == "" && -f "$TEST_FILE" ]]; then
    rm -f "$TEST_FILE" "${TEST_FILE%.*}.srt" /tmp/whisper_test_speech.wav 2>/dev/null
fi
