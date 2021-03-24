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
#
# For example, to create temporary fs on sdX to store dd images:
#   #show available disks:
#     DEV=<sdX>
#     lsblk -ao NAME,MAJ:MIN,RM,SIZE,RO,TYPE,OWNER,GROUP,MODE,DISC-ZERO,FSTYPE,MOUNTPOINT,LABEL,UUID /dev/$DEV
#   #create new temporary partition and ext4 fs:
#     sgdisk -n 1:0:+500g -t 1:0FC63DAF-8483-4772-8E79-3D69D8477DE4 /dev/$DEV
#     lsblk -ao NAME,MAJ:MIN,RM,SIZE,RO,TYPE,OWNER,GROUP,MODE,DISC-ZERO,FSTYPE,MOUNTPOINT,LABEL,UUID /dev/$DEV
#     mkfs.ext4 /dev/${DEV}1
#     mkdir -vpm000 /mnt/${DEV}1
#     mount -v /dev/${DEV}1 /mnt/${DEV}1
#     sgdisk -p /dev/nvme0n1
#  #export rocksdb (wal+db) to files:
#     cd ceph-bluestore-tool.patched/
#     ./export-rocksdb-to-file.sh -h
#     OSD=<Y>
#     ./export-rocksdb-to-file.sh $OSD /dev/nvme0n1 /mnt/${DEV}1/
#  #delete original nvme wal+db partitions:
#     for i in <Z> <Z+1>; do sgdisk -d $i /dev/nvme0n1; done
#     sgdisk -p /dev/nvme0n1
#  #re-import and expand on bigger nvme wal+db partitions:
#     ./import-rocksdb-from-file.sh $OSD /mnt/${DEV}1 /dev/nvme0n1 2 80
#     ceph osd unset noout #enable rebuild
#  #remove temporary partitions with ext4 fs:
#     umount -v /mnt/${DEV}1
#     sgdisk -d 1 /dev/$DEV
#     partprobe /dev/$DEV
#
# Example to create a dummy (padding) partition:
#     sgdisk -n 21:140167168:171968511 -t 21:45B0969E-9B03-4F30-B4C6-B4B80CEFF106 $NVME

SECTOR_SIZE=512
START_SECTOR=0 #to create new partitions after the last partition (default)
#START_SECTOR=2048 #to create new partitions at the beginning of the disk

if [ $# -ne 5 ] ; then
    echo -e "\n\n=== usage help ==="
    cat <<EOF
Usage: $0 <OSD> <DIR> <NVME> <WALSIZE> <DBSIZE>

This script does import the bluestore rocksdb (db + wal) of an osd
from files to disk partitions with dd and expand them with a patched ceph-bluestore-tool.

Arguments:
  OSD:     osd number; must be local to the host
  DIR:     path from where 'dd' will import the files
  NVME:    nvme device, eg. /dev/nvme0n1
  WALSIZE: size in GiB for wal (1-2 GiB recommended)
  DBSIZE:  size in GiB for db (1% of bluestore disk size recommended)

Notes: 
  - copy the db and wal partitions of <OSD> from <DIR> to <NVME> .
  - the new partitions on <NVME> will be created automatically.
  - the osd will be unmasked and started at the end of the script.
  - you can edit the script and set START_SECTOR to control where to add partitions.

To check used bluestore sizes in osd logs:
  for i in /var/log/ceph/ceph-osd.*.log; do egrep "block\.(db|wal) size" \$i | tail -2; done
EOF
  exit 1
fi

echo -e "\n\n=== check ceph version ==="
if [ "$(ceph --version | awk '{print $3}')" != "12.2.8-467-g080f2248ff" ]; then
    echo "Error: ceph version missmatch."
    exit 1
fi
echo "Done"
    
echo -e "\n\n=== check ceph-bluestore-tool is patched ==="
if ! [ -x ./ceph-bluestore-tool ] || ! [ -f ./ceph-bluestore-tool.md5 ] || ! md5sum ceph-bluestore-tool.md5; then
    echo "Error: ./ceph-bluestore-tool not found or signature missmatch."
    exit 1
fi
echo "Done"

echo -e "\n\n=== check osd $OSD ==="
OSD="$1"
if [ -z "$OSD" ] || [ -z "${OSD##*[!0-9]*}" ] || ! grep -q " /var/lib/ceph/osd/ceph-$OSD " /proc/mounts; then
    echo "Error: please enter a valid osd number as param."
    exit 1
fi
echo "Done"

echo -e "\n\n=== check import path ==="
DIR="${2%/}"
if [ -z "$DIR" ] || ! [ -d "${DIR}" ]; then
    echo "Error: please enter a valid source directory as param."
    exit 1
fi
echo "Done"

echo -e "\n\n=== check nvme $NVME ==="
NVME="${3%/}"
if [ -z "$NVME" ] || [ -n "${NVME##/dev/nvme[0-9]n[0-9]}" ]; then
    echo "Error: please enter a valid destination nvme device as param."
    exit 1
fi
echo "Done"

echo -e "\n\n=== check wal and db size ==="
if ! [ -s $DIR/wal-osd-$OSD.dd ]; then
    echo "Error: source file $DIR/wal-osd-$OSD.dd not found or empty."
    exit 1
fi
WALSIZE="$4"
if [ -z "${WALSIZE##*[!0-9]*}" ] || [ $(($WALSIZE * 1024**3)) -lt $(wc -c <$DIR/wal-osd-$OSD.dd) ]; then
    echo "Error: please enter a valid wal size in GiB as param."
    exit 1
fi
if ! [ -s $DIR/db-osd-$OSD.dd ]; then
    echo "Error: source file $DIR/db-osd-$OSD.dd not found or empty."
    exit 1
fi
DBSIZE="$5"
if [ -z "${DBSIZE##*[!0-9]*}" ] || [ $(($DBSIZE * 1024**3)) -lt $(wc -c <$DIR/db-osd-$OSD.dd) ]; then
    echo "Error: please enter a valid db size in GiB as param."
    exit 1
fi
echo "Done"

echo -e "\n\n=== check that osd $OSD is stopped and masked ==="
if pgrep -laf "/usr/bin/ceph-osd -f --cluster ceph --id $OSD\>"; then
    echo "Error: please check why osd $OSD is still running."
    echo "(something went wrong and you probably need to re-export)"
    exit 1  
fi
systemctl mask ceph-osd@$OSD
echo "Done"

echo -e "\n\n=== check that original partitions on $NVME were deleted ==="
if [ "$(blkid -s PARTUUID -o value /var/lib/ceph/osd/ceph-$OSD/block.wal)" == "$(cat /var/lib/ceph/osd/ceph-$OSD/block.wal_uuid)" ]; then
    echo -e "Error: the original partition ($(realpath /var/lib/ceph/osd/ceph-$OSD/block.wal)) still exists."
    exit 1
fi
if [ "$(blkid -s PARTUUID -o value /var/lib/ceph/osd/ceph-$OSD/block.db)" == "$(cat /var/lib/ceph/osd/ceph-$OSD/block.db_uuid)" ]; then
    echo -e "Error: the original partition ($(realpath /var/lib/ceph/osd/ceph-$OSD/block.db)) still exists."
    exit 1
fi
echo "Done"




#create partitions on nvme
PTYPE_WAL='5CE17FCE-4087-4169-B7FF-056CC58473F9'
PTYPE_DB='30CD0809-C2B2-499C-8879-2D6B78529876'
LAST_P=$(sgdisk -p $NVME | awk 'END{print $1}')
if [ "$LAST_P" = "Number" ]; then
    LAST_P=0
fi

echo -e "\n\n=== create new WAL partition on $NVME ==="
sgdisk -n $(($LAST_P+1)):$START_SECTOR:+${WALSIZE}g -t $(($LAST_P+1)):$PTYPE_WAL $NVME || exit 1
partprobe $NVME
echo "Done"

echo -e "\n\n=== create new DB partition on $NVME ==="
if [ "$START_SECTOR" -eq 0 ]; then
    START_SECTOR_DB = 0
else
    START_SECTOR_DB=$(($START_SECTOR + $WALSIZE * 1024**3 / $SECTOR_SIZE))
fi
sgdisk -n $(($LAST_P+2)):$START_SECTOR_DB:+${DBSIZE}g -t $(($LAST_P+2)):$PTYPE_DB $NVME || exit 1
partprobe $NVME
echo "Done"

echo -e "\n\n=== show current partitions on $NVME ==="
lsblk -ao NAME,MAJ:MIN,RM,SIZE,RO,TYPE,OWNER,GROUP,MODE,DISC-ZERO,FSTYPE,MOUNTPOINT,LABEL,UUID $NVME
sgdisk -p $NVME
echo "Done"

echo -e "\n\n=== copy files from $DIR to new partitions on $NVME ==="
echo dd if=$DIR/wal-osd-$OSD.dd of=${NVME}p$(($LAST_P+1)) bs=1M conv=fsync 
read -p "press enter to continue"
dd if=$DIR/wal-osd-$OSD.dd of=${NVME}p$(($LAST_P+1)) bs=1M conv=fsync || exit 1
echo dd if=$DIR/db-osd-$OSD.dd of=${NVME}p$(($LAST_P+2)) bs=1M conv=fsync
read -p "press enter to continue"
dd if=$DIR/db-osd-$OSD.dd of=${NVME}p$(($LAST_P+2)) bs=1M conv=fsync || exit 1
echo "Done"

echo -e "\n\n=== replace symlinks ==="
WAL_PARTUUID=/dev/disk/by-partuuid/$(blkid -s PARTUUID -o value ${NVME}p$(($LAST_P+1)))
DB_PARTUUID=/dev/disk/by-partuuid/$(blkid -s PARTUUID -o value ${NVME}p$(($LAST_P+2)))
[ -h $WAL_PARTUUID ] || ln -vs ../../nvme0n1p$(($LAST_P+1)) $WAL_PARTUUID
[ -h $DB_PARTUUID ] || ln -vs ../../nvme0n1p$(($LAST_P+2)) $DB_PARTUUID
mv -v /var/lib/ceph/osd/ceph-$OSD/block.wal{,.old} || exit 1
mv -v /var/lib/ceph/osd/ceph-$OSD/block.db{,.old} || exit 1
ln -vs $WAL_PARTUUID /var/lib/ceph/osd/ceph-$OSD/block.wal || exit 1
ln -vs $DB_PARTUUID /var/lib/ceph/osd/ceph-$OSD/block.db || exit 1
echo "Done"

echo -e "\n\n=== update /var/lib/ceph/osd/ceph-$OSD/block.{wal,db}_uuid ==="
echo ${WAL_PARTUUID##*/} >/var/lib/ceph/osd/ceph-$OSD/block.wal_uuid
echo ${DB_PARTUUID##*/} >/var/lib/ceph/osd/ceph-$OSD/block.db_uuid
echo "Done"

echo -e "\n\n=== update ownership to ceph:ceph ==="
chown -c ceph:ceph $(realpath $WAL_PARTUUID) || exit 1
chown -c ceph:ceph $(realpath $DB_PARTUUID) || exit 1
chown -ch ceph:ceph /var/lib/ceph/osd/ceph-$OSD/block.wal || exit 1
chown -ch ceph:ceph /var/lib/ceph/osd/ceph-$OSD/block.db || exit 1
echo "Done"

echo -e "\n\n=== resize (expand) bluefs ==="
./ceph-bluestore-tool bluefs-bdev-expand --path /var/lib/ceph/osd/ceph-$OSD || exit 1
echo "Done"

echo -e "\n\n=== show bluefs details ==="
ls -la /var/lib/ceph/osd/ceph-$OSD/
for i in /var/lib/ceph/osd/ceph-$OSD/block.{wal,db}; do
    echo "$i => $(readlink $i) => $(realpath $i)"
done
./ceph-bluestore-tool bluefs-bdev-sizes --path /var/lib/ceph/osd/ceph-$OSD
echo "Done"




echo -e "\n\n=== import completed ==="
echo "These files:"
ls -lah $DIR/{wal,db}-osd-$OSD.dd
echo "were imported to these new partitions:"
realpath /var/lib/ceph/osd/ceph-$OSD/block.{wal,db}

echo -e "\n\n=== unmask and start osd $OSD ==="
echo "You should now follow the osd log in another terminal with this command: tail -f /var/log/ceph/ceph-osd.$OSD.log"
echo "You can also check the used bluestore sizes with this command: for i in /var/log/ceph/ceph-osd.*.log; do egrep \"block\\.(db|wal) size\" \$i | tail -2; done"
read -p "Do you want to start the osd $OSD now?: [y/n] " ANSW
if [ "$ANSW" != "y" ]; then
    echo "Abort"
    exit 1
fi
systemctl unmask ceph-osd@$OSD
systemctl start ceph-osd@$OSD
echo "Done"
echo "Do not forget to enable ceph rebuild with this command: ceph osd unset noout #enable rebuild"
exit $?