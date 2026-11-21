#!/bin/sh
# INT4 ResNet board test — run ON the board (ssh root@board sh -s < this)
#
# Status word @ 0x40000000: {26'0, run_cnt[3:0], done, busy}
#   bit0=busy bit1=done bits[5:2]=run_cnt (+1 per accepted start)
# Exits nonzero on ANY failure. run_cnt assertions prove each inference
# really ran (stale done/outputs can no longer fake a PASS).
#
# NOTE: FCLK0 divisor 0x00101400 assumes IO PLL = 1000 MHz (our boot
# config). A different PLL rate changes FCLK0 and the timing margin.
D=devmem
FAILS=0
fail() { echo "   FAIL: $1"; FAILS=$((FAILS + 1)); }

get_status() { $D r 40000000 | cut -dx -f2; }

echo "1. FCLK0 + level shifters (assumes IO PLL 1000MHz)"
$D w F8000008 DF0D                       # SLCR unlock
old=$($D r F8000178 | cut -dx -f2)
keep=$(( 0x$old & 0x000F0000 ))          # preserve other FCLK gates
$D w F8000178 $(printf "%X" $(( keep | 1 )))   # stop FCLK0
$D w F8000170 00101400                   # FCLK0 divisors
$D w F8000178 $(printf "%X" $keep)       # restart FCLK0
$D w F8000900 0000000F                   # LVL_SHFTR_EN

st=$(get_status)
echo "2. Baseline status: $st (busy must be 0)"
[ $(( 0x$st & 1 )) -eq 0 ] || fail "core busy at baseline (stuck?)"
base_cnt=$(( ( 0x$st >> 2 ) & 0xF ))
echo "   run_cnt=$base_cnt done=$(( 0x$st & 2 ? 1 : 0 ))"

echo "3. Negative tests (run_cnt must NOT advance)"
$D w 40000008 00000001 2>/dev/null       # RO register write
$D w 40000010 00000001 2>/dev/null       # outside aperture (SLVERR → Bus error is EXPECTED)
st=$(get_status)
c=$(( ( 0x$st >> 2 ) & 0xF ))
[ "$c" = "$base_cnt" ] || fail "run_cnt advanced $base_cnt→$c (write alias!)"
[ $(( 0x$st & 1 )) -eq 0 ] || fail "busy set by stray write"
echo "   PASS: run_cnt still $c, no spurious run (0x08 RO ignored, 0x10 SLVERR)"

run_case() {
    n=$1
    c0=$(( ( 0x$(get_status) >> 2 ) & 0xF ))
    $D w 40000000 0
    $D w 40000000 1
    i=0; dn=0
    while [ $i -lt 100 ]; do
        s=$(get_status)
        [ $(( 0x$s & 2 )) -ne 0 ] && { dn=1; break; }
        i=$(( i + 1 ))
    done
    [ $dn -eq 1 ] || fail "run#$n: done not observed within deadline"
    c1=$(( ( 0x$(get_status) >> 2 ) & 0xF ))
    [ "$c1" = $(( (c0 + 1) & 0xF )) ] || fail "run#$n: run_cnt $c0→$c1 (did a new inference actually run?)"
    r0=$($D r 40000008 | cut -dx -f2 | tr A-Z a-z)
    r1=$($D r 4000000C | cut -dx -f2 | tr A-Z a-z)
    echo "   run#$n: run_cnt $c0→$c1 done @poll=$i  0x08=$r0 0x0C=$r1"
    case "$r0/$r1" in
        191af6b5/0d692063) ;;
        *) fail "run#$n: outputs MISMATCH (want 191af6b5/0d692063)";;
    esac
}

echo "4. Inference run #1 (design: 21762 cycles @ 50MHz = 435us)"
run_case 1
echo "5. Inference run #2 (0->1 edge; deterministic → same output)"
run_case 2

if [ $FAILS -eq 0 ]; then
    echo "=== ALL BOARD TESTS PASS ==="
    exit 0
else
    echo "=== $FAILS FAILURE(S) ==="
    exit 1
fi
