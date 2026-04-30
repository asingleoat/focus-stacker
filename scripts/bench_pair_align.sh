#!/usr/bin/env bash
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
aligner_bin="${ALIGNER_BIN:-$repo_root/zig-out/bin/align_image_stack_zig}"
threads="${ALIGN_THREADS:-32}"
control_points="${ALIGN_CONTROL_POINTS:-24}"
grid_size="${ALIGN_GRID_SIZE:-4}"
error_threshold="${ALIGN_ERROR_THRESHOLD:-5}"

usage() {
    cat <<EOF
usage: $0 [images...]

Runs all current pair-alignment methods against the same image sequence and
prints a compact comparison table.

Environment overrides:
  ALIGNER_BIN
  ALIGN_THREADS
  ALIGN_CONTROL_POINTS
  ALIGN_GRID_SIZE
  ALIGN_ERROR_THRESHOLD
EOF
}

[[ $# -ge 2 ]] || { usage; exit 1; }
[[ -x "$aligner_bin" ]] || die "aligner binary not found: $aligner_bin"

methods=(
  hugin-ncc
  phasecorr-seeded
  phasecorr-locked
)

printf "%-20s %-10s %-10s %-10s %-10s\n" "method" "real_s" "cp_after" "rms_px" "max_px"

for method in "${methods[@]}"; do
    log="$(mktemp /tmp/focus-stack-bench.${method}.XXXXXX.log)"
    pto="$(mktemp /tmp/focus-stack-bench.${method}.XXXXXX.pto)"
    time_file="$(mktemp /tmp/focus-stack-bench.${method}.XXXXXX.time)"

    TIMEFORMAT="%R"
    {
        time "$aligner_bin" \
            --pair-align "$method" \
            --threads "$threads" \
            -m -i -d -C \
            -c "$control_points" \
            -g "$grid_size" \
            -t "$error_threshold" \
            --use-given-order \
            -p "$pto" \
            "$@" >"$log" 2>&1
    } 2>"$time_file"

    real_s="$(cat "$time_file")"
    cp_after="$(awk '
        /optimization summary \(before pruning\):/ { stage="before"; next }
        /optimization summary \(after pruning\):/ { stage="after"; next }
        stage != "" && /control points:/ { cp[stage]=$3 }
        END {
            if (cp["after"] != "") print cp["after"];
            else if (cp["before"] != "") print cp["before"];
        }
    ' "$log")"
    rms_px="$(awk '
        /optimization summary \(before pruning\):/ { stage="before"; next }
        /optimization summary \(after pruning\):/ { stage="after"; next }
        stage != "" && /RMS residual:/ { rms[stage]=$3 }
        END {
            if (rms["after"] != "") print rms["after"];
            else if (rms["before"] != "") print rms["before"];
        }
    ' "$log")"
    max_px="$(awk '
        /optimization summary \(before pruning\):/ { stage="before"; next }
        /optimization summary \(after pruning\):/ { stage="after"; next }
        stage != "" && /max residual:/ { mx[stage]=$3 }
        END {
            if (mx["after"] != "") print mx["after"];
            else if (mx["before"] != "") print mx["before"];
        }
    ' "$log")"

    printf "%-20s %-10s %-10s %-10s %-10s\n" "$method" "$real_s" "${cp_after:-?}" "${rms_px:-?}" "${max_px:-?}"
done
