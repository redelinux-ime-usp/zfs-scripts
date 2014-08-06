#!/bin/bash

set -e

hostname=''
declare -a hdds
declare -a ssds
zlog_hsize='1024M'
swap_size='1024M'
boot_size='256M'
efi_size='256M'
test_only=1
non_interactive=0
pool_name=''
mount_path=''

print_help()
{
    cat 1>&2 <<EOF
Usage: $0 -h hostname -d hdd-disk-id [-d ...] -s ssd-disk-id [-s ...]
    -m mount-path [-l zlog-size] [-w swap-size] [-p pool-name] [-T]
Options:
    -h hostname       
                      Specify the hostname to use temporarily. Will possibly be
                      used to generate the hostid by ZFS
    -d hdd-disk-id    
                      Specify the ID of a disk to include in the main storage
                      pool. Should be something that exists in /dev/disk/by-id,
                      without the folder name. e.g. wwn-********, scsi-********
                      Repeat for multiple disks. Number of disks must be even.
    -s ssd-disk-id    
                      Specify the ID of a disk to use as utility, ZFS SLOG and
                      cache disks. Should be an SSD. Repeat for multiple disks.
                      Number of disks must be 1 or a multiple of two
    -m mount-path
                      Where to mount the root FS created from the pool after
                      everything is done.
    -e efi-size
                      Size of the EFI partition on the first SSD.
                      Defaults to ${efi_size}. Should be specified in units of
                      'M' for MiB.
    -b boot-size
                      Size of the boot partitions. Will be mirrored on
                      all provided SSDs. Defaults to ${boot_size}.
    -w swap-size      
                      Size of the swap partitions. Will be mirrored on
                      all provided SSDs. Defaults to ${swap_size}.
    -l zlog-size      
                      Size of the ZFS SLOG partitions. Will be mirrored
                      on all provided SSDs. Defaults to ${slogsize}.
    -p pool-name
                      Use an specific pool name instead of defaulting to the
                      host name (without domain)
    -t
                      Actually perform all the actions instead of doing a
                      dry-run as per default. Will ask you to confirm setup
                    before proceding
    -y
                      Answer yes to all prompts by default (be careful!)
EOF
}

cmd()
{
    echo + "$@"
    if (( test_only == 0 )); then
        "$@"
        return $?
    else
        return 0
    fi
}

confirm()
{
    if (( yes == 1 )); then
        return 0
    else
        read -p "$1" -r
        case "$REPLY" in
            [Yy])
                return 0
            ;;
            [Yy][Ee][Ss])
                return 0
        esac

        return 1
    fi
}

rand_uuid()
{
    cat /proc/sys/kernel/random/uuid
}

while getopts "h:d:s:m:e:b:w:l:p:ty" opt; do
    case $opt in
    h)
        hostname=$OPTARG
    ;;
    d)
        hdds+=("$OPTARG")
    ;;
    s)
        ssds+=("$OPTARG")
    ;;
    m)
        mount_path="$OPTARG"
    ;;
    l)
        slog_size="$OPTARG"
    ;;
    w)
        swap_size="$OPTARG"
    ;;
    b)
        boot_size="$OPTARG"
    ;;
    e)
        efi_size="$OPTARG"
    ;;
    p)
        pool_name="$OPTARG"
    ;;
    t)
        test_only=0
    ;;
    y)
        yes=1
    ;;
    \?)
        echo "Invalid option: -$OPTARG" >&2
        exit 1
    ;;
    :)
        echo "Option -$OPTARG requires an argument." >&2
        exit 1
    ;;
    esac
done

if [ -z "$hostname" ] || [ -z "$slog_size" ] || [ -z "$swap_size" ] \
   || [ -z "$boot_size" ] || [ -z "$efi_size" ]
then
    print_help
    exit 1
fi

if [ -z "$pool_name" ]; then
    pool_name="${hostname%%.*}"
fi

hdd_count="${#hdds[@]}" 
ssd_count="${#ssds[@]}"

if (( hdd_count < 2 )) || (( hdd_count % 2 != 0 )); then
    echo "Invalid HDD count ${hdd_count}: must be multiple of 2, non-zero"
    exit 1
fi

if (( ssd_count < 1 )) || (( ssd_count == 1 || ssd_count % 2 != 0 )); then
    echo "Invalid SSD count ${ssd_count}: must be 1 or a multiple of 2"
    exit 1
fi

echo "Using hostname '${hostname}'"
old_hostname=$(hostname)
trap "hostname '${old_hostname}'" EXIT 
hostname "$hostname"

echo "Using pool name '${pool_name}'"

check_disks()
{
    dest_var=$1
    shift

    local -a disks
    disks=("$@")

    local -A disk_devs
    for disk in "${disks[@]}"; do
        echo -n "- $disk => "
        if ! [ -e "/dev/disk/by-id/${disk}" ]; then
            echo "NOT FOUND"
            exit 1
        fi

        dev=$(readlink -f "/dev/disk/by-id/${disk}")
        echo "$dev"

        eval "${dest_var}[$disk]=\"$dev\""
    done
}

echo "Using ${hdd_count} HDDs: "
declare -A hdd_devs
check_disks "hdd_devs" "${hdds[@]}"
echo

echo "Using ${ssd_count} SSDs: "
declare -A ssd_devs
check_disks "ssd_devs" "${ssds[@]}"

if (( ssd_count == 1 )); then
    echo "Only one SSD selected. Your boot, swap and SLOG will not be mirrored."
    if ! confirm "Disk failures will cause data and availability loss. Proceed? [y/n]"; then
        exit 1
    fi
fi

if (( test_only == 0 )); then
    if ! confirm "Verify all information for correctness. Proceed? [y/n]"; then
        exit 1
    fi

    if ! confirm "Destructive actions will be performed. Are you sure? [y/n]"; then
        exit 1
    fi
fi

if (( test_only == 0 )) && zpool status "$pool_name"; then
    if ! confirm "A zpool named ${pool_name} already exists. Destroy it and proceed? [y/n]"; then
        exit 1
    fi

    echo; echo "* Destroying existing pool"
    cmd zpool destroy "$pool_name" 
fi

echo; echo "* Formatting SSDs"

SGDISK="sgdisk -a 2048"

efi_uuid=''
declare -a boot_uuids swap_uuids slog_uuids l2arc_uuids

for ssd in "${ssds[@]}"; do
    echo; echo "** Formatting ${ssd}"

    SGDISK_SSD="${SGDISK} /dev/disk/by-id/${ssd}"

    cmd zpool labelclear -f "/dev/disk/by-id/${ssd}"
    cmd hdparm -z "/dev/disk/by-id/${ssd}"
    cmd $SGDISK_SSD --clear

    if [ -z "$efi_uuid" ]; then
        efi_uuid=$(rand_uuid)
        echo; echo "** Creating EFI partition (${efi_uuid})"
            
        cmd $SGDISK_SSD --new="0:0:+${efi_size}" \
          -c "0:EFI System Partition" \
          -t 0:ef00 \
          -u "0:${efi_uuid}"

        cmd zpool labelclear -f "/dev/disk/by-partuuid/${efi_uuid}"
    fi

    boot_uuid=$(rand_uuid)
    boot_uuids+="$boot_uuid"

    echo; echo "** Creating boot partition (${boot_uuid})"
    
    cmd $SGDISK_SSD --new="0:0:+${boot_size}" \
     -c 0:/boot \
     -t 0:8300 \
     -u "0:${boot_uuid}"
    cmd zpool labelclear -f "/dev/disk/by-partuuid/${boot_uuid}"

    swap_uuid=$(rand_uuid)
    swap_uuids+="$swap_uuid"

    echo; echo "** Creating swap partition (${swap_uuid})"
    
    cmd $SGDISK_SSD --new="0:0:+${swap_size}" \
     -c "0:Linux Swap" \
     -t 0:8200 \
     -u "0:${swap_uuid}"
    cmd zpool labelclear -f "/dev/disk/by-partuuid/${swap_uuid}"

    slog_uuid=$(rand_uuid)
    slog_uuids+="$slog_uuid"

    echo; echo "** Creating SLOG partition (${slog_uuid})"

    cmd $SGDISK_SSD --new="0:0:+${slog_size}" \
     -c "0:ZFS SLOG" \
     -t 0:bf01 \
     -u "0:${slog_uuid}"
    cmd zpool labelclear -f "/dev/disk/by-partuuid/${slog_uuid}"

    l2arc_uuid=$(rand_uuid)
    l2arc_uuids+="$l2arc_uuid"

    echo; echo "** Creating L2ARC partition in rem. space (${l2arc_uuid})"

    cmd $SGDISK_SSD --largest-new=0 \
     -c:"0:ZFS L2ARC" \
     -t 0:bf01 \
     -u "0:${l2arc_uuid}"
    cmd zpool labelclear -f "/dev/disk/by-partuuid/${l2arc_uuid}"
done

dev_refs()
{
    local var="${1}[@]"
    local devs=("${!var}") prefix="$2" mirror
    [ "$3" != "mirror" ] || mirror=1

    
    for (( i = 0; i < ${#devs[@]}; ++i )); do
        if (( mirror && i % 2 == 0 )); then
            echo -n "mirror "
        fi
        
        echo -n "${prefix}${devs[i]} "  
    done
}

if (( ssd_count > 1 )); then
    echo; echo "* Creating MDADM devices"

    boot_dev=/dev/md/boot
    cmd mdadm --create --verbose "$boot_dev" --level=mirror --raid-devices="${ssd_count}" \
     $(dev_refs boot_uuids /dev/disk/by-partuuid/)

    swap_dev=/dev/md/swap
    cmd mdadm --create --verbose "$swap_dev" --level=mirror --raid-devices="${ssd_count}" \
     $(dev_refs swap_uuids /dev/disk/by-partuuid/)
else
    boot_dev="/dev/disk/by-partuuid/${boot_uuids[0]}"
    swap_dev="/dev/disk/by-partuuid/${swap_uuids[0]}"
fi

echo; echo "* Formatting EFI partition"

efi_dev="/dev/disk/by-partuuid/${efi_uuid}"
cmd mkfs.vfat -n "EFI System Partition" "$efi_dev"

echo; echo "* Formatting boot partition"

cmd mkfs.ext2 -L "/boot" "$boot_dev"

echo; echo "* Formatting swap partition"

cmd mkswap "$swap_dev"

echo; echo "* Clearing HDDs"

for hdd in "${hdds[@]}"; do
    echo; echo "** Clearing ${hdd}"
    
    cmd zpool labelclear -f "/dev/disk/by-id/${hdd}"
    cmd hdparm -z "/dev/disk/by-id/${ssd}"
    cmd $SGDISK "/dev/disk/by-id/${hdd}" --clear
done

echo; echo "* Creating pool"

cmd zpool create -m none -R "$mount_path" -o ashift=12 "$pool_name" \
 $(dev_refs hdds /dev/disk/by-id/ mirror)

echo; echo "* Adding SLOG to pool"

cmd zpool add "$pool_name" log \
 $(dev_refs slog_uuids /dev/disk/by-partuuid/ mirror)

echo; echo "* Adding caches to pool"

cmd zpool add "$pool_name" cache \
 $(dev_refs l2arc_uuids /dev/disk/by-partuuid/)

echo; echo "* Creating ZFS filesystems"

cmd zfs create "${pool_name}/root" -o mountpoint=none
cmd zfs create "${pool_name}/root/debian" -o mountpoint=/

echo; echo "* Setting ZFS pool options"

cmd zpool set bootfs="${pool_name}/root/debian" "$pool_name"
cmd zpool set cachefile="${mount_path}/etc/zfs/zpool.cache" "$pool_name"
