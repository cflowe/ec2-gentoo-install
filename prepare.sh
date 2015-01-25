#!/bin/bash
#------------------------------------------------------------------------------
# prepare.sh - Prepare the gentoo install volume and install gentoo
#
# usage: prepare.sh <gentoo-stage3-path>
#
# This script is executed as a part of Gentoo installation process and is not
# meant to be executed directly.  Use the build.sh script.
#------------------------------------------------------------------------------

set -eu

function main
{
  if [ $# -eq 0 ]; then
    cat >&2 <<EOF
No Gentoo stage3 path given

usage: $(basename $0) <gentoo-stage3-path>

EOF
    exit 1
  fi

  declare stage3=$1

  mkdir -p /mnt/gentoo

  if [ ! -b /dev/xvdf ]; then
    cat >&2 <<EOF
Block device /dev/xvdf is not available on instance
$(curl --silent http://169.254.169.254/latest/meta-data/instance-id)

/dev/xvdf is used to as 
EOF
    exit 1
  fi

  if grep -P -q '^/dev/xvdf\b' /proc/mounts; then
    declare mount_dir=$(awk '$1 == "/dev/xvdf" {print $2}' /proc/mounts)

    if [ "$mount_dir" != "/mnt/gentoo" ]; then
      log "/dev/xvdf is mounted to the wrong place ($mount_dir) - unmounting"
      umount /dev/xvdf
    fi
  else
    if grep -q '\bext4'\b <(sudo -i file -s /dev/xvdf); then
      log 'An ext4 filesystem already exists on /dev/xvdf'
    else
      log 'Creating ext4 filesystem on /dev/xvdf'
      mkfs -t ext4 /dev/xvdf
    fi
  fi

  if ! grep -q '^/dev/xvdf\b' /proc/mounts; then
    log 'Mounting /dev/xvdf on /mnt/gentoo'
    mount /dev/xvdf /mnt/gentoo
  fi

  cd /tmp

  log 'Downloading stage3'
  #curl -O \
  #    "http://gentoo.mirrors.pair.com/releases/amd64/autobuilds/${stage}3"

  #curl -O \
  #    "http://gentoo.mirrors.pair.com/releases/amd64/autobuilds/${stage3}.CONTENTS"

  curl -O \
      "http://gentoo.mirrors.pair.com/releases/amd64/autobuilds/${stage3}.DIGESTS"

  declare basename=$(basename "${stage3}")

  log 'Verifying the sha512 checkums of the stage3 files'
  sha512sum -c <(grep -iA1 sha512 "$basename.DIGESTS" | grep -v -- '^--$')

  log 'Unpacking stage3'
  case "$stage3" in
  *bz2) tar --totals -C /mnt/gentoo -xjpf "/tmp/$basename";;
  *xz) tar --totals -C /mnt/gentoo -xJpf "/tmp/$basename";;
  *) tar --totals -C /mnt/gentoo -xjpf "/tmp/$basename";;
  esac

  log 'Downloading portage'
  curl -O \
      http://gentoo.mirrors.pair.com/snapshots/portage-latest.tar.xz

  curl -O \
      http://gentoo.mirrors.pair.com/snapshots/portage-latest.tar.xz.md5sum

  log 'Verifying the md5 checkum of the portage file'
  md5sum -c portage-latest.tar.xz.md5sum

  log 'Unpacking portage'
  tar --totals -C /mnt/gentoo/usr -xJpf /tmp/portage-latest.tar.xz

  log 'Setting-up files'
  tar --totals -C /mnt/gentoo -xjpf /tmp/build-root.tar.bz2

  mount -t proc proc /mnt/gentoo/proc
  mount --rbind /sys /mnt/gentoo/sys
  mount --make-rslave /mnt/gentoo/sys
  mount --rbind /dev /mnt/gentoo/dev
  mount --make-rslave /mnt/gentoo/dev

  #if [ -l /dev/shm ]; then
  #  mount -t tmps -o nosuid,nodev,noexec shm /mnt/gentoo/dev/shm
  #fi

  cp -L /etc/resolv.conf /mnt/gentoo/etc

  log 'Installing Gentoo'
  chroot /mnt/gentoo /tmp/files/install.sh

  log 'Cleaning up'
  #if [ -l /dev/shm ]; then
  #  umount /mnt/gentoo/dev/shm
  #fi

  umount -l /mnt/gentoo/dev
  umount /mnt/gentoo{/sys,/proc}

  rm -rf /mnt/gentoo/tmp/*
  rm -rf /mnt/gentoo/var/tmp/*
  rm -rf /mnt/gentoo/usr/portage/distfiles/*

  #> /mnt/gentoo/var/log/emerge-fetch.log
  #> /mnt/gentoo/var/log/emerge.log
  #> /mnt/gentoo/var/log/portage/elog/summary.log

  umount /mnt/gentoo
}

function log
{
  echo "$(date -u +"%Y-%m-%d %H:%M:%S"): $@"
}

main "$@"
