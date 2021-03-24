#!/bin/bash
# Copyright (c) 2018 EveryWare AG
# francois.scheurer@everyware.ch
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
#
# Links:
#   cf. http://heiterbiswolkig.blogs.nde.ag/2018/04/08/migrating-bluestores-block-db/
#   (this guide is not 100% compatible with SES5.5, but it was good for the broad lines)
#   Patch for ceph-bluestore-tool on Luminous: https://github.com/ceph/ceph/pull/24352
#   pointed by Igor (ifedotov@suse.de) on the ceph maillist: https://www.spinics.net/lists/ceph-users/msg49528.html
#   This would allow us to expand the RocksDB and WAL without needing to wipe all OSD's.

if [ $# -ne 3 ] ; then
    echo -e "\n\n=== usage help ==="
    cat <<EOF
Usage: $0 <OSD> <NVME> <DIR>

This script does export the bluestore rocksdb (db + wal) of an osd
from a disk partitions to files with dd .

Arguments:
  OSD:  osd number; must be local to the host
  NVME: nvme device, eg. /dev/nvme0n1
  DIR:  path to where 'dd' will export the files

Notes:
  - copy the db and wal partitions of <OSD> from <NVME> to <DIR> .
  - the osd will be stopped and masked automatically - the mask is because 
    many disk commands (eg. partprobe) will auto trigger a restart of the osd.
  - the original partitions on <NVME> must be deleted manually after the script
    execution and before the import.
EOF
    echo -e "\nOSD list on this node:"
    for i in /var/lib/ceph/osd/ceph-*/block.{wal,db}; do echo "$i is on "$(realpath $i); done | sort -k4 | column -t
    exit 0
fi

echo -e "\n\n=== check osd $OSD ==="
OSD="$1"
if [ -z "$OSD" ] || [ -z "${OSD##*[!0-9]*}" ] || ! grep -q " /var/lib/ceph/osd/ceph-$OSD " /proc/mounts; then
    echo "Error: please enter a valid osd number as param."
    exit 1
fi
echo "Done"

echo -e "\n\n=== check nvme $NVME ==="
NVME="${2%/}"
if [ -z "$NVME" ] || [ -n "${NVME##/dev/nvme[0-9]n[0-9]}" ]; then
    echo "Error: please enter a valid source nvme device as param."
    exit 1
fi
if realpath /var/lib/ceph/osd/ceph-$OSD/block.{wal,db} | grep -qv $NVME; then
    for i in /var/lib/ceph/osd/ceph-$OSD/block.{wal,db}; do echo "$i is on "$(realpath $i); done | sort -k4 | column -t
    echo "Error: OSD $OSD not on $NVME."
    exit 1
fi
echo "Done"

echo -e "\n\n=== check export path ==="
DIR="${3%/}"
if [ -z "$DIR" ] || ! [ -d "${DIR}" ]; then
    echo "Error: please enter a valid destination directory as param."
    exit 1
fi
echo "Done"

echo -e "\n\n=== check /var/lib/ceph/osd/ceph-$OSD/block.{wal,db}_uuid ==="
if [ "$(blkid -s PARTUUID -o value /var/lib/ceph/osd/ceph-$OSD/block.wal)" != "$(cat /var/lib/ceph/osd/ceph-$OSD/block.wal_uuid)" ]; then
    echo "Error: the original partition ($(realpath /var/lib/ceph/osd/ceph-$OSD/block.wal)) does not match /var/lib/ceph/osd/ceph-$OSD/block.wal_uuid)."
    echo "You can use this command to fix it: blkid -s PARTUUID -o value /var/lib/ceph/osd/ceph-$OSD/block.wal >/var/lib/ceph/osd/ceph-$OSD/block.wal_uuid"
    exit 1
fi
if [ "$(blkid -s PARTUUID -o value /var/lib/ceph/osd/ceph-$OSD/block.db)" != "$(cat /var/lib/ceph/osd/ceph-$OSD/block.db_uuid)" ]; then
    echo "Error: the original partition ($(realpath /var/lib/ceph/osd/ceph-$OSD/block.db)) does not match /var/lib/ceph/osd/ceph-$OSD/block.db_uuid)."
    echo "You can use this command to fix it: blkid -s PARTUUID -o value /var/lib/ceph/osd/ceph-$OSD/block.db >/var/lib/ceph/osd/ceph-$OSD/block.db_uuid"
    exit 1
fi
echo "Done"




echo -e "\n\n=== disable ceph rebuild ==="
ceph osd set noout #disable rebuild
echo "Done"

echo -e "\n\n=== wait on osd $OSD to stop and mask service ==="
while pgrep -laf "/usr/bin/ceph-osd -f --cluster ceph --id $OSD\>"; do
    systemctl stop ceph-osd@$OSD
    echo -n .
    sleep 5
done
echo "Done"
systemctl mask ceph-osd@$OSD

echo -e "\n\n=== show current partitions on $NVME ==="
partprobe $NVME
lsblk -ao NAME,MAJ:MIN,RM,SIZE,RO,TYPE,OWNER,GROUP,MODE,DISC-ZERO,FSTYPE,MOUNTPOINT,LABEL,UUID $NVME
sgdisk -p $NVME
echo "Done"

echo -e "\n\n=== copy original partitions from $NVME to files in $DIR ==="
dd if=/var/lib/ceph/osd/ceph-$OSD/block.wal of=$DIR/wal-osd-$OSD.dd bs=1M conv=fsync || exit 1
dd if=/var/lib/ceph/osd/ceph-$OSD/block.db of=$DIR/db-osd-$OSD.dd bs=1M conv=fsync || exit 1
echo "Done"




echo -e "\n\n=== export completed ==="
echo "These original partitions:"
realpath /var/lib/ceph/osd/ceph-$OSD/block.{wal,db}
echo "were exported to these files:"
ls -lah $DIR/{wal,db}-osd-$OSD.dd
echo "Now you must delete the original partitions before importing the files,"
echo "or if you want to abort you can just delete the files, then unmask and start the osd-$OSD."
exit $?