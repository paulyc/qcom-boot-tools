#!/bin/sh
set -e

# check that we are not root!
if [ "$(whoami)" != "root" ]; then
    echo "ERROR: Please run as root. Exiting..."
    exit 1
fi

trap cleanup_exit INT TERM EXIT

cleanup_exit() {
    [ -n "$partitions" ] && rm -f $partitions
}

usage() {
    cat <<EOF 
Usage: `basename $0` [OPTIONS]

Utility to create SD card

 -d         enable debug traces
 -o <file>  output file (will be destroyed if exists)
 -p <file>  partition description file
 -i <path>  additional include paths to use when looking for files
 -s <size>  set output image size
 -g         create partitions but do not write files
 -n         print partition scheme and exit, before creating image file
 -x         enable shell debug mode
 -h         display help
EOF
    exit 1;
}

PRINTONLY=0
PARTONLY=0
while getopts "o:p:i:s:xng" o; do
    case "${o}" in
    x|d)
        set -x
        ;;
    n)
        PRINTONLY=1
        ;;
    g)
        PARTONLY=1
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
gpt=`mktemp`
grep -v '^[[:space:]]*#' $PARTITIONS > $partitions

# let's compute the size of the SD card, by looking
# at all partitions, but let's make sure the SD card
# is at least 16MB 
SIZE_MIN=16384
# padding
SIZE=1024
sector=0
part=1
while IFS=, read name size align type file; do
    if [ -z "$size" ] ; then continue; fi
    echo "=== Entry: name: $name, size: $size, align: $align, type: $type, file: $file"

    # align partition start
    if [ -n "$align" ]; then
        align=$(( $align * 2))
        sector=$(( (($sector+$align-1) / $align) * $align ))
    fi
    start=$sector
    sector=$(($sector + $size*2))

    if [ -z "$name" ] ; then continue; fi

    # make sure we don't overlap with GPT primary header
    if [ $start -lt 34 ]; then
        start=34
        sector=$(($sector+$start))
    fi

    echo "$part,$start,$(($sector-1)),$name,$size,$align,$type,$file" >> $gpt
    part=$(($part+1))

    # size=0 is valid for the last partition only (grow)
    if [ "$size" = 0 ]; then break; fi

done < $partitions

SIZE=$(($sector/2 + $SIZE))
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

if [ "$PRINTONLY" = "1" ] ;then
    cat $gpt
    exit
fi

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
while IFS=, read part start end name size align type file; do
    echo "=== Create part: name:$name, size:$size, type:$type align:$align"
    # grow last partition until end of disk
    # but do no overlap with GPT secondary header
    if [ "$size" = 0 ]; then end=$(($SIZE*2-32)); fi
    sgdisk -a 1 -n $part:$start:$end $IMG
    sgdisk -c $part:$name $IMG
    if [ -n "$type" ]; then
        sgdisk -t $part:$type $IMG
    fi
done < $gpt

[ "$PARTONLY" = "1" ] && exit

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
while IFS=, read part start end name size align type file; do
    if [ -z "$file" ] ; then continue; fi
    # default to look for file in current folder
    for i in ${INC}; do
        if [ -e "$i/$file" ]; then
            file="$i/$file"
            break
        fi
    done

    case "$DEV" in
        /dev/mapper/loop*) DPATH=${DEV}p${part};;
        /dev/mmcblk*) DPATH=${DEV}p${part};;
        *)            DPATH=${DEV}${part};;
    esac

    echo "=== Writing $file to $name: ${DPATH} ... "
    dd if=$file of=${DPATH}
done < $gpt

# cleanup in case we used kpartx
if [ ! -b "$IMG" ]; then
    kpartx -d $IMG
fi

rm -f $partitions
rm -f $gpt
