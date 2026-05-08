#!/bin/bash
#
# Sync staged trees from a working area (expected: /flash on uan06) to
# /appl/lumi/ on lustrep[1-4].
#
# Usage:
#     sync_to_appl_lumi.sh [staging-root]
#
# With no argument, the staging root is derived as the parent of the repo
# this script lives in, and is required to start with /flash/. Pass an
# explicit path to override (e.g. for testing against a fake staging tree).
#
# Auto-discovers under the staging root:
#     lumi-spack-settings/   ->  <dest>/spack/
#     spack-[0-9]*/          ->  <dest>/<same-name>/   (e.g. spack-1.1)
# Anything else is ignored (and listed in the prompt for visibility).
# spack-buildcache is intentionally out of scope — different source and
# different semantics; sync it with a separate command.

set -euo pipefail
umask 002

if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [staging-root]" >&2
    exit 2
fi

if [[ $# -eq 1 ]]; then
    staging_root="${1%/}"
else
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    staging_root="$(cd "$script_dir/../.." && pwd)"
    if [[ "$staging_root" != /flash/* ]]; then
        cat >&2 <<EOF
Script is at $script_dir/$(basename "${BASH_SOURCE[0]}").
Refusing to auto-derive staging from a non-/flash location ($staging_root).
Pass an explicit staging root if you really mean it.
EOF
        exit 2
    fi
fi

[[ -d "$staging_root" ]] || { echo "Not a directory: $staging_root" >&2; exit 2; }

destinations=(
    /pfs/lustrep1/appl/lumi
    /pfs/lustrep2/appl/lumi
    /pfs/lustrep3/appl/lumi
    /pfs/lustrep4/appl/lumi
)
preview_dest="${destinations[0]}"
preview_short="${preview_dest#/pfs/}"; preview_short="${preview_short%%/*}"

logdir="$HOME/appl_sync_logs"
mkdir -p "$logdir"
ts="$(date --iso-8601=seconds)"

excludes=(
    --exclude=.DS_Store
    --exclude='*.swp' --exclude='*.swo' --exclude='*.swn'
    --exclude='*~'
)

# ---------- discovery ---------------------------------------------------------

shopt -s nullglob
settings_src=""
spack_srcs=()
ignored=()
for entry in "$staging_root"/*/; do
    entry="${entry%/}"
    name="$(basename "$entry")"
    case "$name" in
        lumi-spack-settings) settings_src="$entry" ;;
        spack-[0-9]*)        spack_srcs+=("$entry") ;;
        *)                   ignored+=("$name") ;;
    esac
done
shopt -u nullglob

if [[ -z "$settings_src" && ${#spack_srcs[@]} -eq 0 ]]; then
    echo "No lumi-spack-settings or spack-<ver> dirs under $staging_root" >&2
    exit 2
fi

# ---------- preview -----------------------------------------------------------

echo
echo "Staging root: $staging_root"
echo "Destinations: ${destinations[*]}"
echo "Plan:"

if [[ -n "$settings_src" ]]; then
    echo "  $settings_src/  ->  <dest>/spack/"
    dst="$preview_dest/spack"
    if [[ -d "$dst" ]]; then
        out=$(rsync --archive --dry-run --itemize-changes --delete \
                    "${excludes[@]}" --exclude='.git' \
                    "$settings_src/" "$dst/" 2>&1) || {
            echo "    preview failed:"
            printf '%s\n' "$out" | sed 's/^/      /'
            exit 1
        }
        new=$(printf '%s\n' "$out" | grep -c '^>f+++++++++' || true)
        all_f=$(printf '%s\n' "$out" | grep -Ec '^>f' || true)
        mod=$(( all_f - new ))
        del=$(printf '%s\n' "$out" | grep -c '^\*deleting' || true)
        printf '    preview vs %s (.git excluded): %d new, %d modified, %d deleted\n' \
               "$preview_short" "$new" "$mod" "$del"
        if (( del > 0 )); then
            printf '%s\n' "$out" | grep '^\*deleting' | sed 's/^\*deleting */      D /'
        fi
    else
        echo "    (no existing $dst — full initial sync)"
    fi
fi

for s in "${spack_srcs[@]}"; do
    echo "  $s/  ->  <dest>/$(basename "$s")/"
done

if [[ ${#ignored[@]} -gt 0 ]]; then
    echo
    echo "Siblings under staging root that will NOT be synced:"
    for n in "${ignored[@]}"; do echo "  - $n"; done
fi

echo
read -rp "Proceed? [y/N] " ans
[[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ---------- sync --------------------------------------------------------------

run_one_tree() {
    local src="$1" target_name="$2"
    local pids=() pid_logs=() pid_short=()
    local dest short log
    for dest in "${destinations[@]}"; do
        short="${dest#/pfs/}"; short="${short%%/*}"
        log="$logdir/${short}_${target_name}_${ts}.log"
        mkdir -p "$dest/$target_name"
        rsync --archive --delete --human-readable --info=stats2 \
              "${excludes[@]}" \
              "$src/" "$dest/$target_name/" >"$log" 2>&1 &
        pids+=("$!"); pid_logs+=("$log"); pid_short+=("$short")
    done
    local i fail=0
    for i in "${!pids[@]}"; do
        if wait "${pids[$i]}"; then
            echo "  ok:   ${pid_short[$i]} ($target_name)"
        else
            echo "  FAIL: ${pid_short[$i]} ($target_name)  see ${pid_logs[$i]}" >&2
            fail=1
        fi
    done
    return "$fail"
}

overall_fail=0

if [[ -n "$settings_src" ]]; then
    echo
    echo "=== Syncing lumi-spack-settings -> spack/ ==="
    run_one_tree "$settings_src" spack || overall_fail=1
fi

for s in "${spack_srcs[@]}"; do
    n="$(basename "$s")"
    echo
    echo "=== Syncing $n ==="
    run_one_tree "$s" "$n" || overall_fail=1
done

# ---------- post-sync symlink check on lustrep1 -------------------------------

echo
echo "=== Checking symlinks on $preview_short ==="
subs=()
[[ -n "$settings_src" ]] && subs+=(spack)
for s in "${spack_srcs[@]}"; do subs+=("$(basename "$s")"); done

broken=()
for sub in "${subs[@]}"; do
    path="$preview_dest/$sub"
    [[ -d "$path" ]] || continue
    while IFS= read -r line; do
        broken+=("$line")
    done < <(find -L "$path" -xtype l 2>/dev/null)
done

if [[ ${#broken[@]} -gt 0 ]]; then
    echo "Broken symlinks (target does not resolve):"
    for b in "${broken[@]}"; do echo "  $b"; done
    overall_fail=1
else
    echo "All symlinks resolve."
fi

echo
if (( overall_fail )); then
    echo "Sync completed with errors. See logs in $logdir." >&2
    exit 1
fi
echo "Sync complete. Logs in $logdir."
