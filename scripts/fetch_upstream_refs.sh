#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lockfile="$repo_root/third_party/upstream-snapshots.lock"
upstream_root="$repo_root/upstream"

die() { echo "error: $*" >&2; exit 1; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

tree_hash() {
    local dir="$1"
    (
        cd "$dir"
        find . \
            -type f \
            ! -path './.git/*' \
            ! -path './.hg/*' \
            ! -name '*.tar.gz' \
            ! -name '*.tar.bz2' \
            ! -name '*.tar.xz' \
            ! -name '*.zip' \
            -print \
        | LC_ALL=C sort \
        | while IFS= read -r f; do
            sha256sum "$f"
        done \
        | sha256sum \
        | awk '{print $1}'
    )
}

fetch_archive() {
    local target_dir="$1"
    local url="$2"
    local _selector="$3"
    local expected_hash="$4"
    local mode="$5"

    local tmp_archive
    tmp_archive="$(mktemp)"
    trap 'rm -f "$tmp_archive"' RETURN

    curl -L --fail --retry 3 --output "$tmp_archive" "$url"

    case "$mode" in
        archive)
            tar -xf "$tmp_archive" -C "$upstream_root"
            ;;
        archive-into)
            mkdir -p "$target_dir"
            tar -xf "$tmp_archive" -C "$target_dir"
            ;;
        *)
            die "unknown archive mode: $mode"
            ;;
    esac

    [[ -d "$target_dir" ]] || die "expected extracted directory not found: $target_dir"

    local actual_hash
    actual_hash="$(tree_hash "$target_dir")"
    [[ "$actual_hash" == "$expected_hash" ]] || die "tree hash mismatch for $target_dir: expected $expected_hash, got $actual_hash"

    rm -f "$tmp_archive"
    trap - RETURN
}

fetch_hg() {
    local target_dir="$1"
    local url="$2"
    local selector="$3"
    local expected_hash="$4"

    need_cmd hg

    local tmp_clone
    tmp_clone="$(mktemp -d)"
    trap 'rm -rf "$tmp_clone"' RETURN

    hg clone "$url" "$tmp_clone/repo"
    (
        cd "$tmp_clone/repo"
        hg update -r "$selector"
        rm -rf .hg
    )
    mv "$tmp_clone/repo" "$target_dir"

    local actual_hash
    actual_hash="$(tree_hash "$target_dir")"
    [[ "$actual_hash" == "$expected_hash" ]] || die "tree hash mismatch for $target_dir: expected $expected_hash, got $actual_hash"

    rm -rf "$tmp_clone"
    trap - RETURN
}

main() {
    need_cmd curl
    need_cmd tar
    need_cmd sha256sum

    mkdir -p "$upstream_root"

    while IFS='|' read -r name kind target_dir source selector expected_hash; do
        [[ -n "$name" ]] || continue
        [[ "$name" == \#* ]] && continue

        local_target="$repo_root/$target_dir"
        rm -rf "$local_target"

        echo "--- fetching $name -> $target_dir"
        case "$kind" in
            archive)
                fetch_archive "$local_target" "$source" "$selector" "$expected_hash" "$kind"
                ;;
            archive-into)
                fetch_archive "$local_target" "$source" "$selector" "$expected_hash" "$kind"
                ;;
            hg)
                fetch_hg "$local_target" "$source" "$selector" "$expected_hash"
                ;;
            *)
                die "unknown snapshot kind: $kind"
                ;;
        esac
    done < "$lockfile"
}

main "$@"
