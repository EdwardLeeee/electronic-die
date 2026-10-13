#!/usr/bin/env bash
# Compile Quartus variants with Quartus II 9.0 SP2.
#   tools/run_quartus.sh [variant ...]      default: every variant from tools/quartus.py
# Windows:   QUARTUS_BIN="C:/altera/90sp2/quartus/bin" (run from Git Bash), no Wine needed.
# Linux:     QUARTUS_BIN=<dir with quartus_sh.exe>, run through Wine (WINEPREFIX optional).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
: "${QUARTUS_BIN:?set QUARTUS_BIN to the directory that contains quartus_sh(.exe)}"
if [ "$(uname -s)" = Linux ]; then
    export WINEDEBUG="${WINEDEBUG:--all}"
    qsh=(wine "$QUARTUS_BIN/quartus_sh.exe")
else
    qsh=("$QUARTUS_BIN/quartus_sh")
fi
python3 -I "$here/tools/quartus.py" generate
variants=("$@")
[ ${#variants[@]} -gt 0 ] || read -r -a variants <<< "$(python3 -I "$here/tools/quartus.py" list)"
for v in "${variants[@]}"; do
    d="$here/electronic-die/synth/quartus/variants/$v"
    echo "== $v"
    start=$SECONDS
    stamp="$d/.compile-start"; touch "$stamp"
    ( cd "$d" && "${qsh[@]}" --flow compile "$v" > "$v.compile.log" 2>&1 ) || {
        echo "   FAILED, see $d/$v.compile.log"; grep -m5 -i "error" "$d/$v.compile.log" || true; exit 1; }
    [ "$d/$v.tan.summary" -nt "$stamp" ] || { echo "   FAILED: no new $v.tan.summary"; exit 1; }
    rm -f "$stamp"
    echo "   ok in $((SECONDS - start)) s: $(grep 'Actual Time' "$d/$v.tan.summary" | sed -n '4p' | tr -d '\r' | sed 's/.*: //')"
done
python3 -I "$here/tools/quartus.py" generate > /dev/null   # Quartus rewrites the .qsf with CRLF
python3 -I "$here/tools/quartus.py" collect > /dev/null
echo "docs/results.md updated"
