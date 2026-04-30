#!/usr/bin/env bash
#
# Focus stack processing script using the Zig align_image_stack port.
#
# Aligns and merges a set of focus-bracketed images into a single
# all-in-focus composite using align_image_stack_zig and enfuse.
#
# Usage:
#   ./scripts/stack_zig.sh [--threads N] [--pair-align METHOD] image1.jpg image2.jpg ...
#   ./scripts/stack_zig.sh [--threads N] [--pair-align METHOD] S001_manifest.json
#   ./scripts/stack_zig.sh [--threads N] [--pair-align METHOD] S001_manifest.json S002_manifest.json
#
# Accepts any mix of image files and manifest JSON files.
#
# Output: <output_dir>/<name>_stacked.tif
#         <output_dir>/<name>_stacked.jpg
#
# Dependencies: zig, enfuse, jq
#
# Configuration — override with environment variables if desired.

ALIGN_CONTROL_POINTS="${ALIGN_CONTROL_POINTS:-200}"
ALIGN_GRID_SIZE="${ALIGN_GRID_SIZE:-7}"
ALIGN_ERROR_THRESHOLD="${ALIGN_ERROR_THRESHOLD:-5}"
ALIGN_THREADS="${ALIGN_THREADS:-}"
ALIGN_PAIR_ALIGN_METHOD="${ALIGN_PAIR_ALIGN_METHOD:-hugin-ncc}"

CONTRAST_WINDOW_SIZE="${CONTRAST_WINDOW_SIZE:-5}"
HARD_MASK="${HARD_MASK:-true}"

OUTPUT_DIR="${OUTPUT_DIR:-.}"
JPEG_QUALITY="${JPEG_QUALITY:-98}"
ALIGN_OPTIMIZE_MODE="${ALIGN_OPTIMIZE_MODE:-ReleaseFast}"

set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
aligner_bin="${ALIGNER_BIN:-$repo_root/zig-out/bin/align_image_stack_zig}"

check_deps() {
    command -v zig >/dev/null || die "zig not found"
    command -v enfuse >/dev/null || die "enfuse not found (install enblend-enfuse)"
    command -v jq >/dev/null || die "jq not found"
}

ensure_aligner() {
    if [[ -x "$aligner_bin" ]]; then
        return
    fi

    echo "--- Building align_image_stack_zig ---"
    (
        cd "$repo_root"
        ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build -Doptimize="$ALIGN_OPTIMIZE_MODE"
    )
    [[ -x "$aligner_bin" ]] || die "build completed but aligner binary not found: $aligner_bin"
}

images_from_manifest() {
    local manifest="$1"
    local dir
    dir="$(dirname "$(realpath "$manifest")")"
    jq -r '.images[]' "$manifest" | while read -r img; do
        echo "$dir/$img"
    done
}

derive_name() {
    local first="$1"
    if [[ "$first" == *.json ]]; then
        basename "$first" _manifest.json
    else
        local base
        base="$(basename "$first")"
        echo "${base%.*}"
    fi
}

main() {
    check_deps

    local threads="$ALIGN_THREADS"
    local pair_align_method="$ALIGN_PAIR_ALIGN_METHOD"
    local -a positional=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --threads)
                [[ $# -ge 2 ]] || die "missing value for --threads"
                threads="$2"
                shift 2
                ;;
            --threads=*)
                threads="${1#--threads=}"
                shift
                ;;
            --pair-align)
                [[ $# -ge 2 ]] || die "missing value for --pair-align"
                pair_align_method="$2"
                shift 2
                ;;
            --pair-align=*)
                pair_align_method="${1#--pair-align=}"
                shift
                ;;
            --help|-h)
                cat <<EOF
usage: $0 [--threads N] [--pair-align METHOD] <images or manifests...>

Options:
  --threads N          Limit align_image_stack_zig worker threads
  --pair-align METHOD  Pair alignment method: hugin-ncc, phasecorr-seeded, phasecorr-locked

Environment overrides:
  ALIGN_THREADS
  ALIGN_PAIR_ALIGN_METHOD
  ALIGN_CONTROL_POINTS
  ALIGN_GRID_SIZE
  ALIGN_ERROR_THRESHOLD
  OUTPUT_DIR
  JPEG_QUALITY
  ALIGN_OPTIMIZE_MODE
EOF
                return 0
                ;;
            --)
                shift
                while [[ $# -gt 0 ]]; do
                    positional+=("$1")
                    shift
                done
                break
                ;;
            -*)
                die "unknown option: $1"
                ;;
            *)
                positional+=("$1")
                shift
                ;;
        esac
    done

    if [[ -n "$threads" ]]; then
        [[ "$threads" =~ ^[1-9][0-9]*$ ]] || die "--threads must be a positive integer"
    fi
    [[ "$pair_align_method" =~ ^(hugin-ncc|phasecorr-seeded|phasecorr-locked)$ ]] || \
        die "--pair-align must be one of: hugin-ncc, phasecorr-seeded, phasecorr-locked"

    [[ ${#positional[@]} -gt 0 ]] || die "usage: $0 [--threads N] [--pair-align METHOD] <images or manifests...>"

    local name
    name="$(derive_name "${positional[0]}")"

    local -a images=()
    for arg in "${positional[@]}"; do
        if [[ "$arg" == *.json ]]; then
            [[ -f "$arg" ]] || die "manifest not found: $arg"
            while IFS= read -r img; do
                [[ -f "$img" ]] || die "image not found: $img (from manifest $arg)"
                images+=("$img")
            done < <(images_from_manifest "$arg")
        else
            [[ -f "$arg" ]] || die "image not found: $arg"
            images+=("$arg")
        fi
    done

    local count=${#images[@]}
    [[ $count -ge 2 ]] || die "need at least 2 images, got $count"

    if [[ ${#positional[@]} -gt 1 && "${positional[0]}" == *.json ]]; then
        local last_index=$(( ${#positional[@]} - 1 ))
        local last_name
        last_name="$(derive_name "${positional[$last_index]}")"
        name="${name}-${last_name}"
    fi

    ensure_aligner

    echo "=== Focus Stack (Zig): $name ==="
    echo "  Images: $count"
    echo "  Aligner: $aligner_bin"
    if [[ -n "$threads" ]]; then
        echo "  Threads: $threads"
    else
        echo "  Threads: auto"
    fi
    echo "  Pair align: $pair_align_method"
    echo "  Output: $OUTPUT_DIR/${name}_stacked.tif"
    echo ""

    local workdir
    workdir="$(mktemp -d -t focus-stack-zig-XXXXXX)"
    trap 'rm -rf "${workdir:-}"' EXIT
    echo "  Working directory: $workdir"
    echo ""

    echo "--- Aligning $count images ---"
    echo "  Optimizing: magnification (-m), center shift (-i), radial distortion (-d), auto-crop (-C)"
    echo "  Control points: ${ALIGN_CONTROL_POINTS} per cell, ${ALIGN_GRID_SIZE}x${ALIGN_GRID_SIZE} grid"
    echo ""

    local -a aligner_opts=()
    if [[ -n "$threads" ]]; then
        aligner_opts+=(--threads "$threads")
    fi
    aligner_opts+=(--pair-align "$pair_align_method")

    "$aligner_bin" \
        "${aligner_opts[@]}" \
        -m \
        -i \
        -d \
        -C \
        -c "$ALIGN_CONTROL_POINTS" \
        -g "$ALIGN_GRID_SIZE" \
        -t "$ALIGN_ERROR_THRESHOLD" \
        --use-given-order \
        -v \
        -a "$workdir/aligned_" \
        "${images[@]}"

    local aligned_count
    aligned_count=$(find "$workdir" -maxdepth 1 -name 'aligned_*.tif' | wc -l)
    [[ $aligned_count -gt 0 ]] || die "alignment produced no output files"
    echo ""
    echo "  Aligned $aligned_count images"
    echo ""

    echo "--- Merging with enfuse ---"

    local -a enfuse_opts=(
        --exposure-weight=0
        --saturation-weight=0
        --contrast-weight=1
        --contrast-window-size="$CONTRAST_WINDOW_SIZE"
    )
    if [[ "$HARD_MASK" == true ]]; then
        enfuse_opts+=(--hard-mask)
    fi

    mkdir -p "$OUTPUT_DIR"

    enfuse \
        "${enfuse_opts[@]}" \
        --output="$OUTPUT_DIR/${name}_stacked.tif" \
        "$workdir"/aligned_*.tif

    echo ""
    echo "  Output: $OUTPUT_DIR/${name}_stacked.tif"

    if command -v convert >/dev/null 2>&1; then
        convert "$OUTPUT_DIR/${name}_stacked.tif" \
            -quality "$JPEG_QUALITY" \
            "$OUTPUT_DIR/${name}_stacked.jpg"
        echo "  Preview: $OUTPUT_DIR/${name}_stacked.jpg"
    elif command -v magick >/dev/null 2>&1; then
        magick "$OUTPUT_DIR/${name}_stacked.tif" \
            -quality "$JPEG_QUALITY" \
            "$OUTPUT_DIR/${name}_stacked.jpg"
        echo "  Preview: $OUTPUT_DIR/${name}_stacked.jpg"
    else
        echo "  (install imagemagick for JPEG preview)"
    fi

    echo ""
    local tif_size
    tif_size="$(du -h "$OUTPUT_DIR/${name}_stacked.tif" | cut -f1)"
    echo "=== Done: ${name}_stacked.tif ($tif_size) ==="
}

main "$@"
