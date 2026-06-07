#!/usr/bin/env bash
# ------------------------------------------------------------
#  transcribe_local.sh – local video/audio → transcript
#
#  Usage:
#    ./transcribe_local.sh <file1> [<file2> ...]
#
#  Configuration: edit the variables below.
#
#  Notes:
#    • small model requires fp16=False on GTX 1650 (NaN with fp16)
#    • medium model needs >4GB VRAM
#    • tiny model works with fp16 but lower quality
# ------------------------------------------------------------

set -euo pipefail

######################
# Configuration      #
######################

# Whisper model: tiny, base, small, medium, large, turbo
MODEL="small"

# Device: cpu or cuda
DEVICE="cuda"

# Output format: srt, vtt, txt, tsv, json, all
OUTPUT_FORMAT="srt"

# Language: leave empty for auto-detect, or set e.g. "en"
LANGUAGE=""

# fp16: True for faster inference, False if GPU produces NaN (GTX 1650)
FP16="False"

######################
# Argument check     #
######################

if [[ $# -eq 0 ]]; then
    echo "Error: No input files supplied."
    echo "Usage: $0 <file> [<file> ...]"
    exit 1
fi

######################
# Process each file  #
######################

for input in "$@"; do
    if [[ ! -f "$input" ]]; then
        echo "Warning: File not found: $input" >&2
        continue
    fi

    dir="$(cd "$(dirname "$input")" && pwd)"
    base="$(basename "$input")"
    base_noext="${base%.*}"
    out_file="${dir}/${base_noext}.${OUTPUT_FORMAT}"

    if [[ -f "$out_file" ]]; then
        echo "Skipping (exists): $out_file"
        continue
    fi

    echo "========================================="
    echo "Processing: $input"
    echo "  Model   : $MODEL"
    echo "  Device  : $DEVICE"
    echo "  FP16    : $FP16"
    echo "  Format  : $OUTPUT_FORMAT"
    echo "  Output  : $out_file"
    echo ""

    lang_flag=""
    if [[ -n "$LANGUAGE" ]]; then
        lang_flag="--language $LANGUAGE"
    fi

    whisper "$input" \
        --model "$MODEL" \
        --device "$DEVICE" \
        --output_format "$OUTPUT_FORMAT" \
        --output_dir "$dir" \
        --fp16 "$FP16" \
        $lang_flag

    echo "Done: $out_file"
    echo ""
done

echo "All done."
