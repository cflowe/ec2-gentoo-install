#!/bin/bash
#------------------------------------------------------------------------------
# install - Install Gentoo
#
# usage: install
#
# This script is executed as a part of Gentoo installation process and is not
# meant to be executed directly.  Use the build.sh script.
#------------------------------------------------------------------------------

function main
{
  log 'Beginning Gentoo install'

  env-update
  source /etc/profile

  log 'Updating portage make.conf USE flags'
  use_flags=$(awk -F: '/^flags/{print $2; exit}' /proc/cpuinfo \
      | tr ' ' '\n' \
      | grep -f /tmp/files/portage.use.lis \
      | tr '\n' ' ' \
      )

  if [ -n "$use_flags" ]; then
    sed -ie "s:#@GENTOO_USE@:USE=\"\$USE $use_flags\":" /etc/portage/make.conf
  fi

  cp /usr/share/zoneinfo/GMT /etc/localtime

  locale-gen

  eselect locale set $(eselect locale list \
      | grep -i en_us.utf8 \
      | awk '-F[[\\] ]+' '{print $2; exit}')

  env-update
  source /etc/profile

  log 'Updating packages'
  emerge --sync
  emerge --oneshot portage # just in case
  emerge --update --deep --with-bdeps=y --newuse world

  # This should not be necessary after a stage3 install
  # gcc-config 1
  # gcc-config -l

  log 'Configuring the kernel'
  cd /usr/src/linux
  cp -af /tmp/files/kernel.config ./.config
  yes '' | make oldconfig

  log 'Building the kernel'
  make -j3 && make -j3 modules_install
  cp -L arch/x86_64/boot/bzImage /boot/bzImage

  if ! grep -q '^sudo:' /etc/group; then
    log 'Adding sudo user group'
    groupadd sudo
  fi

  log 'Setting up ec2-user'
  useradd -r -m -s /bin/bash ec2-user

  log 'Setting up service runlevels'
  ln -s /etc/init.d/net.lo /etc/init.d/net.eth0

  rc-update add net.eth0 default
  rc-update add sshd default
  rc-update add syslog-ng default
  rc-update add fcron default
  rc-update add ntpd default
  rc-update add lvm boot
  rc-update add mdraid boot

  sed -ie '/^EMERGE_DEFAULT_OPTS *=/s/^/#/' /etc/portage/make.conf

  log 'Complete'
}

function log
{
  echo "$(date -u +"%Y-%m-%d %H:%M:%S"): $@" >&2
}

main
