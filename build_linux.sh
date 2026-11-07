#!/bin/sh
# build_linux.sh - assemble and link the Linux server, and compile the test tools.
#
# Needs UASM (https://github.com/Terraspace/UASM), GNU ld and gcc. Point UASM_BIN at the assembler
# if it isn't on your PATH. Don't use a variable called UASM: the assembler reads that for options. Sources are shared with Windows; Windows-only unwind directives are
# removed first, as ELF has no use for them.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
out="$root/build"
gen="$out/linux"
UASM_BIN=${UASM_BIN:-uasm}
mkdir -p "$gen"

for name in util os_linux input sim tier net_linux main; do
    sed -E -e 's/\bPROC FRAME\b/PROC/' \
           -e '/^[[:space:]]*\.(pushreg|allocstack|setframe|endprolog)\b/d' \
           "$root/src/$name.asm" > "$gen/$name.asm"
    "$UASM_BIN" -nologo -q -elf64 -DLINUX "-I$root/src" "-Fo$gen/$name.o" "$gen/$name.asm"
done

# No C runtime: a static executable with its own _start.
ld -o "$out/mmoserver" -z noexecstack -z max-page-size=4096 \
    "$gen/util.o" "$gen/os_linux.o" "$gen/input.o" "$gen/sim.o" "$gen/tier.o" \
    "$gen/net_linux.o" "$gen/main.o"

# Test tools only: these are C and are not part of the server.
gcc -O2 -no-pie -z noexecstack -o "$out/test_sim" "$root/tests/test_sim.c" "$gen/sim.o"
gcc -O2 -pthread -o "$out/loadgen" "$root/tools/loadgen.c"

echo "build ok: $out/mmoserver ($(wc -c < "$out/mmoserver") bytes)"
