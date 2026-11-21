#!/bin/sh
# INT4 ResNet board test — run ON the board (ssh root@board sh -s < this)
# Verifies: FCLK0 up → level shifters → start → poll done → compare output
D=devmem

echo "1. FCLK0 + level shifters"
$D w F8000008 DF0D                       # SLCR unlock
old=$($D r F8000178 | cut -dx -f2)
keep=$(( 0x$old & 0x000F0000 ))          # preserve other FCLK gates
$D w F8000178 $(printf "%X" $(( keep | 1 )))   # stop FCLK0
$D w F8000170 00101400                   # FCLK0 divisors (proven setting)
$D w F8000178 $(printf "%X" $keep)       # restart FCLK0
$D w F8000900 0000000F                   # LVL_SHFTR_EN

echo "2. Status before start (expect 0)"
$D r 40000000

echo "3. Start inference"
t0=$(date +%s%N)
$D w 40000000 1
# poll until done (bit1) with timeout
i=0
while [ $i -lt 100 ]; do
    s=$($D r 40000000 | cut -dx -f2)
    [ $(( 0x$s & 2 )) -ne 0 ] && break
    i=$(( i + 1 ))
done
t1=$(date +%s%N)
echo "   polls=$i  wall=$(( (t1 - t0) / 1000 ))us (design: 21762 cycles @ 50MHz ≈ 435us)"

echo "4. Outputs (golden: out=[-2379,6426,8291,3433] → 0x08=191AF6B5 0x0C=0D692063)"
r0=$($D r 40000008 | cut -dx -f2)
r1=$($D r 4000000C | cut -dx -f2)
echo "   0x08 = $r0"
echo "   0x0C = $r1"

case "$(echo $r0 | tr A-Z a-z)" in
    191af6b5) echo "   out[0:1] MATCH";;
    *)        echo "   out[0:1] MISMATCH (want 191af6b5)";;
esac
case "$(echo $r1 | tr A-Z a-z)" in
    0d692063) echo "   out[2:3] MATCH";;
    *)        echo "   out[2:3] MISMATCH (want 0d692063)";;
esac

echo "5. Status after (done bit sticks until next start; busy=0)"
$D r 40000000
