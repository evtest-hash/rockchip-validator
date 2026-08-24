#!/bin/sh
# E05 board-side script.
D=/userdata/az0x-emmc/e05_burnin
T=/userdata/az0x-emmc/stress
SRC=$T/src; DEST=$T/dest; MD5=$T/md5
TARGET_N=${1:-20}; DIRNUM=${2:-5}; SETTLE=${3:-1}

mkdir -p $D $SRC $DEST $MD5
log(){ echo "$(date +%s) $*" >> $D/progress.log; }
# The last line this script writes is always a terminal marker. ABORTED is the default: an exit
# path nobody classified lands on 未得结果, never on a false verdict against the material.
die(){ log "ABORTED $*"; exit 0; }
# A defect this test itself found; the run reached its own end, so the verdict judges it.
fail(){ log "FAILED $*"; exit 0; }
cat /proc/sys/kernel/random/boot_id > $D/boot; sync
# The first progress record must come before the source-file generation below, not after it: the
# host gives up if nothing is written within its deploy window, and building ~25 MB of random
# files can outlast that on a slow device. Until the heartbeat was removed, the heartbeat's first
# line was what that check happened to see.
log "START target_n=$TARGET_N dirnum=$DIRNUM settle=$SETTLE"

# 1.
rm -rf $SRC/*
i=0
for base in 512 1024 3456 512 1024 3456; do
  n=0
  while [ $n -lt 5 ]; do
    r=$(( ($(od -An -N2 -tu2 /dev/urandom 2>/dev/null || echo 1024) % base) + 1 ))
    dd if=/dev/urandom of=$SRC/test.$i.$n.bin bs=$r count=1024 2>/dev/null
    n=$((n+1))
  done
  i=$((i+1))
done
SRC_MB=$(( $(du -sk $SRC | awk '{print $1}') / 1024 ))
[ $SRC_MB -lt 1 ] && SRC_MB=1
PER_LOOP=$(( SRC_MB * DIRNUM ))

# Target = N x device capacity.
BLK=$(basename $(ls -d /sys/class/mmc_host/*/mmc*:*/block/* 2>/dev/null | head -1))
DEV_MB=$(( $(blockdev --getsize64 /dev/$BLK 2>/dev/null || echo 0) / 1048576 ))
if [ "$DEV_MB" -lt 1 ]; then
  die "DEVSIZEFAIL 无法读取 eMMC 容量，拒绝用默认值推算写入量"
fi
TARGET_MB=$(( TARGET_N * DEV_MB ))
LOOPS=$(( TARGET_MB / PER_LOOP )); [ $LOOPS -lt 1 ] && LOOPS=1
log "PLAN src=${SRC_MB}MB dirnum=$DIRNUM per_loop=${PER_LOOP}MB dev=${DEV_MB}MB target_n=${TARGET_N} target=${TARGET_MB}MB loops=${LOOPS} settle=${SETTLE}s"

# 2. md5 baseline
cd $SRC && md5sum ./* > $MD5/source.md5; cd /

# 3.
c=0
while [ $c -lt $LOOPS ]; do
  c=$((c+1))
  d=0
  while [ $d -lt $DIRNUM ]; do
    rm -rf $DEST/$d
    if ! cp -rf $SRC $DEST/$d; then
      fail "COPYFAIL loop=$c dir=$d"
    fi
    d=$((d+1))
  done

  # Key vendor step: sync and drop_caches twice.
  sync; echo 3 > /proc/sys/vm/drop_caches; sleep $SETTLE
  sync; echo 3 > /proc/sys/vm/drop_caches; sleep $SETTLE

  d=0
  while [ $d -lt $DIRNUM ]; do
    cd $DEST/$d && md5sum ./* > $MD5/dest$d.md5; cd /
    if diff -q $MD5/source.md5 $MD5/dest$d.md5 >/dev/null 2>&1; then
      rm -f $MD5/dest$d.md5; rm -rf $DEST/$d
    else
      # As in the vendor script: stop on a verification failure and preserve the state.
      cp $MD5/dest$d.md5 $D/failed_dest$d.md5 2>/dev/null
      cp $MD5/source.md5 $D/failed_source.md5 2>/dev/null
      fail "VERIFYFAIL loop=$c dir=$d"
    fi
    d=$((d+1))
  done
  log "LOOP $c written=$(( c * PER_LOOP ))MB"
done

rm -rf $T
log "ALLDONE loops=$c written=$(( c * PER_LOOP ))MB target=${TARGET_MB}MB"
