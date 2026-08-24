#!/bin/sh
# T08 board-side script: installs an init service that reboots the board $1 times.
D=/userdata/az0x-ddr/t08_reboot; TARGET=${1:-3000}; INITD=/etc/init.d/S99-az0x-reboot
mkdir -p $D; echo 0 > $D/cnt; echo $TARGET > $D/target; rm -f $D/stop
cat > $INITD <<'INIT'
#!/bin/sh
[ "$1" = start ] || exit 0
D=/userdata/az0x-ddr/t08_reboot; [ -f $D/target ] || exit 0; [ -f $D/stop ] && exit 0
( TARGET=$(cat $D/target)
  c=$(( $(cat $D/cnt) + 1 )); echo $c > $D/cnt
  # Reaching the target is this test's own end, and the only thing that ends it: the acceptance
  # standard is the count, so nothing here stops for the clock. This is also what keeps the board
  # from rebooting forever — the service disarms itself by writing stop.
  [ $c -gt $TARGET ] && { echo done > $D/stop; echo "$(date +%s) STOP target=$TARGET" >> $D/progress.log; exit 0; }
  P=/sys/fs/pstore/console-ramoops-0
  if [ -e $P ] && [ $c -ge 2 ] && ! grep -q "Restarting system" $P; then
     # An unexplained panic under reboot cycling is the instability T08 screens for, so it is a
     # defect the test found: FAILED, and the verdict names it. PANIC stays in the reason because
     # the pstore check and the anomaly list both match on that word.
     grep -qi panic $P && { echo "$(date +%s) FAILED PANIC" >> $D/progress.log; echo panic > $D/stop; exit 0; }
  fi
  echo "$(date +%s) boot $c" >> $D/progress.log; sync; sleep 8; reboot ) &
exit 0
INIT
chmod +x $INITD; sync
# Installing the service is the only thing this script does. If it did not take — read-only /etc,
# no permission — say so now instead of letting the host wait out the whole budget for reboots that
# will never come. Our side could not run the test, so ABORTED, not a verdict on the material.
[ -x $INITD ] || { echo "$(date +%s) ABORTED INSTALLFAIL 无法安装 $INITD" >> $D/progress.log; exit 0; }
echo "$(date +%s) INSTALLED" >> $D/progress.log
setsid sh $INITD start >/dev/null 2>&1 &
