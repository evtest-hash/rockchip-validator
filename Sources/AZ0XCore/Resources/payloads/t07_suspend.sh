#!/bin/sh
# T07 board-side script: $1 cycles of RTC wake alarm and pm-suspend.
D=/userdata/az0x-ddr/t07_suspend; TARGET=${1:-3000}; DWELL=${2:-10}
# Kernel suspend statistics.
PS=/sys/power/suspend_stats
log(){ echo "$(date +%s) $*" >> $D/progress.log; }
# Our own pid, so the host can ask whether this script is still running instead of guessing
# from how long it has been quiet. Suspending is silent by nature and says nothing about
# health; a pid that no longer exists does.
echo $$ > $D/pid
cat /proc/sys/kernel/random/boot_id > $D/boot; sync
# success is the kernel's count of successful suspends and cannot be forged from user space.
S0=$(cat $PS/success 2>/dev/null || echo 0)
log "SUSPEND_SUCCESS start=$S0"
# Bounded by cycles alone: the acceptance standard is how many the board survives, so nothing here
# stops for the clock. How long the host is willing to wait is the host's business and never a
# verdict — the host bounds its own waiting with Thresholds.maxOfflineSeconds.
n=0
while [ $n -lt $TARGET ]; do
  n=$((n+1))
  f0=$(cat $PS/fail 2>/dev/null || echo 0)
  echo 0 > /sys/class/rtc/rtc0/wakealarm; echo "+$DWELL" > /sys/class/rtc/rtc0/wakealarm
  pm-suspend; rc=$?
  sleep 5
  f1=$(cat $PS/fail 2>/dev/null || echo 0)
  df=$((f1-f0))
  log "cycle $n rc=$rc fail=$df"
  # Early stop on the first failing cycle rather than running the full 12 hours. This reached its
  # own end — the criterion is already disproved — so it is FAILED, not ABORTED, and the verdict
  # judges it. The terminal marker is the last line written.
  if [ "$rc" -ne 0 ] || [ "$df" -ne 0 ]; then
    log "SUSPEND_SUCCESS end=$(cat $PS/success 2>/dev/null || echo 0)"
    log "FAILED SUSPENDFAIL cycle=$n rc=$rc fail=$df"
    exit 0
  fi
done
log "SUSPEND_SUCCESS end=$(cat $PS/success 2>/dev/null || echo 0)"
log "ALLDONE $n"
