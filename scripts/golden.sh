#!/bin/zsh
# The plugin against in-process MLXServeEngine: seeded sounds made on the signed bundle the way Gaea calls it
# (gaea-plugin-check: launch under the launch requirement, configure, prepare, run) and through moss-sfx-inproc with the
# lane configuration, requests and cut the worker uses. Each pair must be byte for byte the same WAV, and each sound
# round(duration_s × 48 000) frames long.
#
#   scripts/golden.sh <out-dir>     (after scripts/build-plugin.sh)
#
# Cases (bf16): rain at 1.5 s (draft), a door at 2.3 s (standard: the package's crop is a frame short there), two barks
# (count 2, seeds 7 and 8), a street without horns (a negative prompt), glass at 1.0 s (best), and a Chinese prompt.
set -uo pipefail
ROOT=${0:A:h:h}
cd $ROOT
OUT=${1:?out dir}; mkdir -p $OUT
B=$ROOT/dist/moss-soundeffect.gaeaplugin
MODELS=${CHECK_MODELS_ROOT:-$HOME/Library/Application Support/MLXEngine/Models}
SWIFTPM=(-c release --build-system swiftbuild)
xcrun swift build $SWIFTPM --product moss-sfx-inproc > /dev/null && xcrun swift build -c release --product gaea-plugin-check > /dev/null
INPROC=$(xcrun swift build $SWIFTPM --show-bin-path)/moss-sfx-inproc; CHECK=$(xcrun swift build -c release --show-bin-path)/gaea-plugin-check
LOG=$OUT/golden.log; : > $LOG
pass=0; fail=0
say() { print -r -- "$*" | tee -a $LOG }
say "# MOSS-SoundEffect golden check $(date -u +%FT%TZ): $(python3 -c "import json; m=json.load(open('$B/Contents/Resources/manifest.json')); print(m['id'], m['version'])")"
same() { # name, gpp wav, inproc wav, frames
  local a=$(shasum -a 256 $2 2>/dev/null | cut -c1-16) b=$(shasum -a 256 $3 2>/dev/null | cut -c1-16)
  local n=$(python3 -c "import wave,sys; print(wave.open(sys.argv[1]).getnframes())" $2 2>/dev/null)
  if [[ -n $a && $a == $b && $n == $4 ]]; then pass=$((pass+1)); say "PASS  $1: byte-identical, $n frames, sha256 $a…"
  else fail=$((fail+1)); say "FAIL  $1: $a… / $b…, $n frames (want $4)"; fi
}
outputs() { grep -o '"path":"[^"]*"' $1 | sed 's/"path":"//; s/"$//; s/\\\//\//g' | awk '!seen[$0]++' }

# sound <name> <seed> <params json> <prompt> <frames> [inproc args…]
sound() {
  local name=$1 seed=$2 params=$3 prompt=$4 frames=$5; shift 5
  $CHECK $B --operation audio.generate --model moss-soundeffect --lane bf16 --params $params --seed $seed --text "prompt=$prompt" \
    --models-root "$MODELS" --budget 64000000000 --timeout 1800 --session $OUT/$name.gpp > $OUT/$name-gpp.log 2>&1
  local i=0; for f in $(outputs $OUT/$name-gpp.log); do [[ -f $f ]] && cp $f $OUT/$name-gpp-$i.wav; i=$((i+1)); done
  $INPROC --prompt "$prompt" --seed $seed --models-root "$MODELS" --out-dir $OUT/$name-inproc "$@" 2>> $LOG | tail -1 > $OUT/$name-inproc.json
  say "      $name: over GPP $(grep -o 'ran in [0-9.]* s' $OUT/$name-gpp.log | head -1); in-process $(cat $OUT/$name-inproc.json)"
  i=0; for f in $OUT/$name-inproc/sounds-*.wav; do same "$name sound $i (seed $((seed+i)))" $OUT/$name-gpp-$i.wav $f $frames; i=$((i+1)); done
}

sound rain 11 '{"duration_s":1.5,"quality":"draft"}' 'Rain on a tin roof, steady, with distant thunder.' 72000 --duration 1.5 --quality draft
sound door 3 '{"duration_s":2.3,"quality":"standard"}' 'A heavy wooden door creaks open slowly.' 110400 --duration 2.3 --quality standard
sound barks 7 '{"duration_s":1.2,"quality":"draft","count":2}' 'A dog barks twice in the distance.' 57600 --duration 1.2 --quality draft --count 2
sound street 5 '{"duration_s":2.0,"quality":"draft","negative_prompt":"car horns"}' 'Busy city street ambience.' 96000 --duration 2.0 --quality draft --negative 'car horns'
sound glass 9 '{"duration_s":1.0,"quality":"best"}' 'Glass shatters on a stone floor.' 48000 --duration 1.0 --quality best
sound thunder 2 '{"duration_s":1.55,"quality":"draft"}' '远处的雷声，低沉而缓慢。' 74400 --duration 1.55 --quality draft

for s in $OUT/*.gpp; do
  if python3 ${GAEA_SPEC_ROOT:-$ROOT/../gaea-mes-media-server}/tools/validate.py --transcript $s >> $LOG 2>&1; then pass=$((pass+1)); say "PASS  ${s:t} passes validate.py"
  else fail=$((fail+1)); say "FAIL  ${s:t} fails validate.py"; fi
done
say "== $pass passed, $fail failed"
exit $(( fail > 0 ))
