#!/bin/sh
# INT4 ResNet board test — run ON the board (ssh root@board sh -s < this)
# Verifies: FCLK0 up → level shifters → start → poll done → compare output
# Note: devmem echoes READBACK after write; CTRL (0x40000000) reads back
#       the STATUS word {done,busy}, not the written value (by design).
D=devmem

echo "1. FCLK0 + level shifters"
$D w F8000008 DF0D                       # SLCR unlock
old=$($D r F8000178 | cut -dx -f2)
keep=$(( 0x$old & 0x000F0000 ))          # preserve other FCLK gates
$D w F8000178 $(printf "%X" $(( keep | 1 )))   # stop FCLK0
$D w F8000170 00101400                   # FCLK0 divisors (proven setting)
$D w F8000178 $(printf "%X" $keep)       # restart FCLK0
$D w F8000900 0000000F                   # LVL_SHFTR_EN

echo "2. Status (0x0 fresh bitstream; 0x2 if a previous run left done sticky)"
$D r 40000000

echo "3. Start inference (always 0->1 edge: clears any stale done)"
$D w 40000000 0
$D w 40000000 1
# poll until done (bit1). NOTE: inference takes only 435us; one AXI read
# takes ~8ms, so the busy phase is not observable from PS — expect done=1
# on the first poll already.
i=0
while [ $i -lt 100 ]; do
    s=$($D r 40000000 | cut -dx -f2)
    [ $(( 0x$s & 2 )) -ne 0 ] && break
    i=$(( i + 1 ))
done
echo "   polls=$i status=$s (design: 21762 cycles @ 50MHz = 435us)"

echo "4. Outputs (golden: out=[-2379,6426,8291,3433] → 0x08=191AF6B5 0x0C=0D692063)"
r0=$($D r 40000008 | cut -dx -f2 | tr A-Z a-z)
r1=$($D r 4000000C | cut -dx -f2 | tr A-Z a-z)
echo "   0x08 = $r0"
echo "   0x0C = $r1"

case "$r0/$r1" in
    191af6b5/0d692063) echo "   out MATCH";;
    *)                  echo "   out MISMATCH (want 191af6b5 / 0d692063)";;
esac

echo "5. Repeat inference (0->1 edge again; deterministic → same output)"
$D w 40000000 0
$D w 40000000 1
i=0
while [ $i -lt 100 ]; do
    s=$($D r 40000000 | cut -dx -f2)
    [ $(( 0x$s & 2 )) -ne 0 ] && break
    i=$(( i + 1 ))
done
r0=$($D r 40000008 | cut -dx -f2 | tr A-Z a-z)
r1=$($D r 4000000C | cut -dx -f2 | tr A-Z a-z)
echo "   polls=$i 0x08=$r0 0x0C=$r1"
case "$r0/$r1" in
    191af6b5/0d692063) echo "   run#2 MATCH";;
    *)                  echo "   run#2 MISMATCH";;
esac

echo "6. Final status (done=1 sticky, busy=0)"
$D r 40000000
