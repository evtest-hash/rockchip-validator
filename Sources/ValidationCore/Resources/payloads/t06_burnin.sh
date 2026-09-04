#!/bin/bash
# T06 board-side script: fixed-frequency stressapptest, fixed-frequency memtester.
D=/userdata/az0x-ddr/t06_burnin; DUR=${1:-43200}; PH=${2:-ABC}; DMC=/sys/class/devfreq/dmc
log(){ echo "$(date +%s) $*" >> $D/progress.log; }
oomcnt(){ awk '/oom_kill/{print $2}' /proc/vmstat 2>/dev/null || echo 0; }
# Both early exits must put the governor back. The normal end restores it after the phase blocks,
# which an exit never reaches, so without this an aborted or failed run leaves DDR pinned to
# userspace at whatever frequency it stopped at — verified on an AZ04A, and it contaminates every
# later test on that board.
restore(){ echo dmc_ondemand > $DMC/governor 2>/dev/null; }
# The last line this script writes is always a terminal marker, so the host never has to infer an
# ending from silence. ABORTED is the default on purpose: a new exit path whose author forgets to
# classify it lands on 未得结果, never on a false verdict against the material.
die(){ restore; log "OOM end=$(oomcnt)"; log "ABORTED $*"; exit 0; }
# A defect this test itself found. The run reached its own end, so the verdict must judge it.
fail(){ restore; log "OOM end=$(oomcnt)"; log "FAILED $*"; exit 0; }
fix(){ echo userspace > $DMC/governor 2>/dev/null; echo $1 > $DMC/userspace/set_freq 2>/dev/null
       [ "$(cat $DMC/cur_freq)" = "$1" ] || die "FIXFAIL want $1 got $(cat $DMC/cur_freq)"; }
MAXF=$(tr ' ' '\n' < $DMC/available_frequencies | grep -E '^[0-9]+$' | sort -n | tail -1)
SIZE=$(( $(awk '/MemAvailable/{print $2}' /proc/meminfo)/1024/2 - 10 ))
cat /proc/sys/kernel/random/boot_id > $D/boot; sync
log "OOM start=$(oomcnt)"
log "PHASES $PH"
case $PH in *A*)
  fix $MAXF; log "PHASE_A_START freq=$(cat $DMC/cur_freq) size=${SIZE}M"
  stressapptest -s $DUR -i 4 -C 4 -W --stop_on_errors -M $SIZE -l $D/satA.log > $D/satA.out 2>&1 || fail "SATABORT rc=$?"
  grep -q 'Status: FAIL' $D/satA.out $D/satA.log 2>/dev/null && fail "SATABORT status_fail"
  log "PHASE_A_DONE" ;;
esac
case $PH in *B*)
  fix $MAXF; log "PHASE_B_START"
  timeout -s KILL $DUR memtester ${SIZE}M > $D/mtB.log 2>&1; log "PHASE_B_DONE" ;;
esac
# Scaling phase: switch randomly across all operating points while memtester runs.
DWELL=${DWELL:-0.1}
case $PH in *C*)
: > $D/scale_ok; : > $D/scale_prog
( read -a FREQS < $DMC/available_frequencies; NF=${#FREQS[@]}; ok=0
  RANDOM=$$$(date +%s); cur=$(cat $DMC/cur_freq); last=$(date +%s)
  trap 'echo $ok > $D/scale_ok; echo "$(date +%s) $ok $f" >> $D/scale_prog; exit 0' TERM
  while :; do
    # Only points different from the current one are used.
    f=${FREQS[$RANDOM % NF]}
    while [ "$f" = "$cur" ] && [ $NF -gt 1 ]; do f=${FREQS[$RANDOM % NF]}; done
    echo userspace > $DMC/governor 2>/dev/null; echo $f > $DMC/userspace/set_freq 2>/dev/null
    got=$(cat $DMC/cur_freq)
    if [ "$got" = "$f" ]; then ok=$((ok+1)); cur=$f
    else echo "SCALEFAIL want $f got $got" >> $D/scaleC.log; cur=$got; fi
    sleep $DWELL
    # Flushed on time, every 10 s, rather than on a count, which would drift as the dwell changes.
    now=$(date +%s)
    if [ $((now - last)) -ge 10 ]; then last=$now
      echo $ok > $D/scale_ok; echo "$now $ok $f" >> $D/scale_prog; fi
  done ) & FL=$!
log "PHASE_C_START"
timeout -s KILL $DUR memtester ${SIZE}M > $D/mtC.log 2>&1
kill $FL 2>/dev/null; sleep 1; echo dmc_ondemand > $DMC/governor 2>/dev/null
log "PHASE_C_DONE scale_ok=$(cat $D/scale_ok 2>/dev/null || echo 0)" ;;
esac
# The governor must also be restored when the scaling phase did not run.
case $PH in *C*) ;; *) echo dmc_ondemand > $DMC/governor 2>/dev/null ;; esac
log "OOM end=$(oomcnt)"; log "ALLDONE"
