#!/bin/sh
set -e

# check that we are not root!
if [ "$(whoami)" != "root" ]; then
    echo "ERROR: Please run as root. Exiting..."
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
 -s <size>  set output image size
 -n         print partition scheme and exit, before creating image file
 -x         enable shell debug mode
 -h         display help
EOF
    exit 1;
}

PRINTONLY=0
while getopts "o:p:i:s:xn" o; do
    case "${o}" in
    x|d)
        set -x
        ;;
    n)
        PRINTONLY=1
        ;;
    o)
        IMG=${OPTARG}
        ;;
    s)
        SIZE_IMG=${OPTARG}
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

if [ -z "$IMG" ] && [ "$PRINTONLY" = "0" ] ; then
    echo "Please specify an output file"
    echo ""
    usage
    exit 1
fi

# remove comments
partitions=`mktemp`
grep -v '^[[:space:]]*#' $PARTITIONS > $partitions

# let's compute the size of the SD card, by looking
# at all partitions, but let's make sure the SD card
# is at least 16MB 
SIZE_MIN=16384
# padding
SIZE=1024
while IFS=, read name size type file; do
    if [ -z "$name" ] || [ -z "$size" ] ; then continue; fi
    echo "=== Entry: name: $name, size: $size, type: $type, file: $file"
    SIZE=$(($SIZE + $size))
done < $partitions

if [ $SIZE -lt $SIZE_MIN ]; then
    SIZE=$SIZE_MIN
fi

if [ -n "$SIZE_IMG" ] ; then
    if [ $SIZE -lt $SIZE_IMG ]; then
        SIZE=$SIZE_IMG
    elif [ $SIZE -gt $SIZE_IMG ]; then
        echo "Error: cannot create partition table using $PARTITIONS"
        echo "Expected size is $SIZE, however image size is set to $SIZE_IMG"
        exit
    fi
fi

echo "=== Create file with size: $SIZE"

[ "$PRINTONLY" = "1" ] && exit

# the output can be:
#  * a file in which case we need to create an image
#  * a block device in which case we directly work on the physical device
#    and it's safer to zap all GPT data first
if [ -b "$IMG" ]; then
    echo "=== Destroy GPT data on block device: $IMG"
    sgdisk -Z $IMG
else
    echo "=== Create image file: $IMG"
    rm -f $IMG
    dd if=/dev/zero of=$IMG bs=1024 count=1 seek=$SIZE
fi

# create partition table
while IFS=, read name size type file; do
    if [ -z "$name" ] || [ -z "$size" ]; then continue; fi
    echo "=== Create partition: name: $name, size: $size, type: $type"
    sgdisk -a 1 -n 0:0:+$(($size*2)) $IMG
    PNUM="$(sgdisk -p $IMG |tail -1|sed 's/^[ \t]*//'|cut -d ' ' -f1)"
    sgdisk -c $PNUM:$name $IMG
    if [ -n "$type" ]; then
        sgdisk -t $PNUM:$type $IMG
    fi
done < $partitions

# when dealing with image , we use kpartx to loop mount the right partition
# otherwise with block device we directly work on it
DEV=$IMG
if [ ! -b "$IMG" ]; then
    DEV="$(kpartx -av $IMG | tail -1 | \
    sed 's/^.*\/dev\///;s/ .*$//')"
    if [ -e "/dev/$DEV" ] ; then
        echo "loop created: /dev/$DEV"
        DEV=/dev/mapper/${DEV}
    else
        echo "Cannot create loop: /dev/$DEV"
        kpartx -d $IMG
        exit 1
    fi
    sleep 2
fi

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
    id=$(sgdisk -p $IMG |grep -E "^(\s+[0-9]+){3}.*\b$name\b"|
                sed 's/^[ \t]*//'|cut -d ' ' -f1 )

    case "$DEV" in
        /dev/mmcblk*) DPATH=${DEV}p${id};;
        *)            DPATH=${DEV}${id};;
    esac

    echo "=== Writing $file to $name: ${DPATH} ... "
    dd if=$file of=${DPATH}
done < $partitions

# cleanup in case we used kpartx
if [ ! -b "$IMG" ]; then
    kpartx -d $IMG
fi

rm -f $partitions
