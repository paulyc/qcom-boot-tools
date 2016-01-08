#!/bin/sh
set -e

# check that we are not root!
if [ "$(whoami)" != "root" ]; then
    echo -e "\nERROR: Please run as root. Exiting..."
    exit 1
fi

usage() {
    cat <<EOF 
Usage: `basename $0` [OPTIONS]

Utility to create SD card

 -d         enable debug traces
 -o <file>  output file (will be destroyed if exists)
 -p <file>  partition description file
 -i <path>  additional include paths to use when looking for files
 -x         enable shell debug mode
 -h         display help
EOF
    exit 1;
}

while getopts "o:p:i:xn" o; do
    case "${o}" in
    x|d)
        set -x
        ;;
    o)
        IMG=${OPTARG}
        ;;
    i)
        INC="${INC} ${OPTARG}"
        ;;
    p)
        PARTITIONS=${OPTARG}
        ;;
    *)
        usage
        ;;
    esac
done
shift $((OPTIND-1))

if [ -z "$PARTITIONS" ]; then
    echo "Please specify a partition description file"
    echo ""
    usage
    exit 1
fi

if [ ! -e "$PARTITIONS" ]; then
    echo "Cannot find partition description file: $PARTITIONS"
    echo ""
    usage
    exit 1
fi

if [ -z "$IMG" ]; then
    echo "Please specify an output file"
    echo ""
    usage
    exit 1
fi

# let's compute the size of the SD card, by looking
# at all partitions, but let's make sure the SD card
# is at least 16MB 
SIZE_MAX=16384
SIZE=0
while IFS=, read name size type file; do
    if [ -z "$name" ] || [ -z "$size" ] ||
           [ -z "$type" ]; then continue; fi
    echo "=== Entry: name: $name, size: $size, type: $type, file: $file"
    SIZE=$(($SIZE + $size))
done < $PARTITIONS

if [ $SIZE -gt $SIZE_MAX ]; then
    SIZE_MAX=$(($SIZE + 1024))
fi

echo "=== Create file with size: $SIZE_MAX"
rm -f $IMG
dd if=/dev/zero of=$IMG bs=1024 count=1 seek=$SIZE_MAX

# create partition table
while IFS=, read name size type file; do
    if [ -z "$name" ] || [ -z "$size" ] ||
           [ -z "$type" ]; then continue; fi
    echo "=== Create partition: name: $name, size: $size, type: $type"
    sgdisk -a 1 -n 0:0:+$(($size*2)) $IMG
    PNUM="$(sgdisk -p $IMG |tail -1|sed 's/^[ \t]*//'|cut -d ' ' -f1)"
    sgdisk -c $PNUM:$name $IMG
    sgdisk -t $PNUM:$type $IMG
done < $PARTITIONS

DEV="$(kpartx -av $IMG | tail -1 | \
    sed 's/^.*\/dev\///;s/ .*$//')"
if [ -e "/dev/$DEV" ] ; then
    echo "loop created: /dev/$DEV"
else
    echo "Cannot create loop: /dev/$DEV"
    exit 1
fi

sleep 2

# push the blobs to their respective
# partitions
while IFS=, read name size type file; do
    if [ -z "$file" ] ; then continue; fi
    # default to look for file in current folder
    for i in ${INC}; do
        if [ -e "$i/$file" ]; then
            file="$i/$file"
            break
        fi
    done
    # tries to match the output of sgdisk with "Number/start/end sectors"
    COUNTER=$(sgdisk -p $IMG |grep -E "^(\s+[0-9]+){3}.*\b$name\b"|
                     sed 's/^[ \t]*//'|cut -d ' ' -f1 )
    DPATH=/dev/mapper/${DEV}p${COUNTER}
    echo "=== Writing $file to $name: ${DPATH} ... "
    dd if=$file of=${DPATH}
done < $PARTITIONS

kpartx -d $IMG
