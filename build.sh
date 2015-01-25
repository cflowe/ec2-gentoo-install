#!/bin/bash
#-------------------------------------------------------------------------------
# build.sh - Build a Gentoo ec2 root volume
#
# usage: build.sh [aws-cli-profile-name]
#
# [aws-cli-profile-name] defaults to the 'default' profile.
#-------------------------------------------------------------------------------

set -eu

function main()
{
  PROFILE=${1:-default}

  log "Using profile '$PROFILE'"

  declare region=$(aws configure get --profile "$PROFILE" region)

  if [ -z "$region" ]; then
    cat >&2 <<EOF
No AWS region assigned to profile '$PROFILE'.
Set your region using:

aws configure set --profile '$PROFILE' region <aws-region-name>

EOF
    exit 1
  fi

  declare private_keyfile=$(aws configure get --profile "$PROFILE" \
      gentoo-build-private-keyfile)

  if [ -z "$private_keyfile" ]; then
    cat >&2 <<EOF
No AWS private_keyfile assigned to profile '$PROFILE'.
Set your private keyfile using:

aws configure set --profile '$PROFILE' gentoo-build-private-keyfile <local-filename>

EOF
    exit 1
  fi

  declare key_name=$(aws configure get --profile "$PROFILE" \
      gentoo-build-key-name)

  if [ -z "$key_name" ]; then
    cat >&2 <<EOF
No AWS key name assigned to profile '$PROFILE'.
Set your key name using:

aws configure set --profile '$PROFILE' gentoo-build-key-name <key-name>

EOF
    exit 1
  fi

  declare sec_group_name=$(aws configure get --profile "$PROFILE" \
      gentoo-build-security-group)

  if [ -z "$sec_group_name" ]; then
    sec_group_name='gentoo-build'

    log "Setting the default security group to $sec_group_name"

    aws configure set --profile "$PROFILE" \
      gentoo-build-security-group "$sec_group_name"
  fi

  setup_security_group "$sec_group_name"

  declare instance_id volume_id
  declare existing_instance_id=$(aws configure get --profile "$PROFILE" \
      gentoo-build-use-instance)

  if [ -n "$existing_instance_id" ]; then
    log "Using running existing instance: $existing_instance_id"
    instance_id="$existing_instance_id"

    declare instance_state="$(instance_status "$instance_id")"

    if [ "$instance_state" != 'running' ]; then
      log "Instance $instance_id is not running. It's state is '$instance_state'"
      return 1
    fi

    volume_id=$(aws_ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query '*[*].Instances[*].BlockDeviceMappings[?DeviceName == `/dev/sdf`].[Ebs.VolumeId]' --output text)

    if [ -z "$volume_id" ]; then
      cat >&2 <<EOF
Block device /dev/xvdf (/dev/sdf) was not found on instance '$instance_id'.

Attach at least a 10G volume to $instance_id as /dev/xvdf to continue.

EOF
      exit 1
    fi
  else
    log 'Creating a new instance'
echo 'XXX oops'; exit 1
    declare instance_type=$(aws configure get --profile "$PROFILE" \
        gentoo-build-instance-type)

    if [ -z "$instance_type" ]; then
      cat >&2 <<EOF
No AWS instance-type assigned to profile '$PROFILE'.
Set your instance type using:

aws configure set --profile '$PROFILE' gentoo-build-instance-type <ec2-instance-type>

EOF
      exit 1
    fi

    declare public_keyfile=$(aws configure get --profile "$PROFILE" \
        gentoo-build-public-keyfile)

    if [ -z "$public_keyfile" ]; then
      cat >&2 <<EOF
No public keyfile assigned to profile '$PROFILE'.
Set your public keyfile using:

aws configure set --profile '$PROFILE' gentoo-build-public-keyfile <local-filename>

EOF
      exit 1
    fi

    setup_keypair "$key_name" "$public_keyfile"

    instance_id=$(start_instance $region "$key_name" "$sec_group_name")

    log "Waiting for instance '$instance_id' to start"
    while [ "$(instance_status "$instance_id")" != 'running' ]
    do
      # Think about limiting the time in this loop
      echo -n .
      sleep 10
    done
    echo

    # Assumes the xvdf volume attached to the new instance is ready
    # when the instance is running. May need to add a check here.
    log "Created instance '$instance_id'"
  fi

  declare ipaddr=$(aws_ec2 describe-instances \
      --instance-ids "$instance_id" \
      --query '*[0].Instances[0].PublicIpAddress' --output text)

  if [ -z "$ipaddr" ]; then
    cat >&2 <<EOF
No ip address found for instance $instance_id.

Ensure that the instance is running.
EOF
  fi

  log "Instance '$instance_id' is running and using ip address '$ipaddr'" \
      'waiting for sshd to start'

  declare subject="$(md5sum <<<"$RANDOM $(date -Ins)" | cut -f1 -d' ')"

  while [ "$(ssh_host $private_keyfile ec2-user@$ipaddr echo "$subject" 2>/dev/null)" != "$subject" ]
  do
    # Think about limiting the time spent spent in this loop
    echo -n .
    sleep 10
  done
  echo

  if [ ! -f build-root.tar.bz2 ]; then
    log 'Building / directory layout'
    sudo -i make -C $PWD install
  fi

  log "Copying files to $ipaddr"
  rsync -aP \
      -e  \
      "ssh -o Compression=no -o StrictHostKeyChecking=no -i $private_keyfile" \
      build-root.tar.bz2 \
      prepare.sh \
      ec2-user@$ipaddr:/tmp

  declare stage3=$(curl --silent http://gentoo.mirrors.pair.com/releases/amd64/autobuilds/latest-stage3-amd64.txt | grep stage3-amd64)

  log "Installing Gentoo on $ipaddr using stage3 install $stage3"
  ssh_host $private_keyfile -xt ec2-user@$ipaddr \
      sudo -i /tmp/prepare.sh "$stage3"

  volume_id=$(aws_ec2 describe-instances \
      --instance-ids "$instance_id" \
      --query '*[*].Instances[*].BlockDeviceMappings[?DeviceName == `/dev/sdf`].[Ebs.VolumeId]' --output text)

  if [ -z "$volume_id" ]; then
    cat >&2 <<EOF
Unable to find the Gentoo EBS volume on instance '$instance_id'

EOF
    return 1
  fi

  if [ -z "$existing_instance_id" ]; then
    # optionally wait for shutdown
    #
    # Since un-mounting the partition is the only req before snapshotting
    # the volume, waiting for shutdown may not be necessary.
    :
  fi

  log "Creating snapshot of EBS volume $volume_id"

  snapshot_id=$(aws_ec2 create-snapshot \
      --volume-id "$volume_id" \
      --description \
      "Gentoo Root Volume built from $stage3 on $(date -u) ($(date +%s))" \
      --query 'SnapshotId' \
      --output text)

  log "Created Gentoo root volume snapshot $snapshot_id"
  log "Waiting for snapshot $snapshot_id to compete"
  log 'Snapshoting a 10G volume may take 15 minutes'
  log 'The Gentoo install is complete and'

  declare -l status='' progress

  while [ "$status" != 'complete' ]
  do
    # Executing describe-snapshots will take some time as well
    read progress status <<<"$(aws_ec2 describe-snapshots \
        --snapshot-ids "$snapshot_id" \
        --query 'Snapshots[*].[Progress,State]' \
        --output text)"

    echo -ne "${progress}% Complete \r"

    if [ "$progress" == '100' ]; then
      break
    fi

    sleep 5
  done

  log 'Complete'
}

function ssh_host
{
  declare private_keyfile=$1; shift

  ssh \
      -o StrictHostKeyChecking=no  \
      -i "${private_keyfile:?No private key file given}" \
      "$@"
}

function instance_status
{
  declare instance_id=$1

  aws_ec2 describe-instances \
      --instance-ids "$instance_id" \
      --query '*[0].Instances[0].State.Name'  \
      --output text
}

function start_instance
{
  declare region=$1; shift
  declare key_name=$1; shift
  declare sec_group_name=$1; shift

  declare kernel_id=$(aws_ec2 describe-images \
      --owners amazon --filters \
      'Name=image-type,Values=kernel' \
      'Name=virtualization-type,Values=paravirtual' \
      'Name=hypervisor,Values=xen' \
      'Name=architecture,Values=x86_64' \
      'Name=state,Values=available' \
      --query 'Images[*].[ImageLocation, ImageId]' \
      --output text \
      | grep hd0_1 \
      | sed -e 's@.*/pv-grub[0-9]*-hd0[^0-9]*@@' \
      | sort \
      | tail -n1 \
      | awk '{print $2}')

  log "Using kernel_id $kernel_id"

  declare image_id=$(aws_ec2 describe-images \
      --owners amazon --filters \
      'Name=image-type,Values=machine' \
      'Name=root-device-type,Values=ebs' \
      'Name=virtualization-type,Values=paravirtual' \
      'Name=hypervisor,Values=xen' \
      'Name=architecture,Values=x86_64' \
      'Name=state,Values=available' \
      "Name=kernel-id,Values=$kernel_id" \
      --query 'Images[-1].ImageId' \
      --output text)

  log "Using image_id $image_id"

  log 'Starting an instance'
  aws_ec2 run-instances \
      --region "$region" \
      --key-name "$key_name" \
      --kernel-id "$kernel_id" \
      --image-id "$image_id" \
      --security-groups "$sec_group_name" \
      --block-device-mappings \
          '[{"DeviceName": "/dev/sdf","Ebs":{"VolumeSize":10}}]' \
      --query ImageId \
      --output text
}

function setup_keypair
{
  declare key_name=$1; shift
  declare public_keyfile=$1

  if ! grep -q "^$key_name$" <(aws_ec2 describe-key-pairs | awk '-F[":]+' '/KeyName/{print $4}'); then
    aws_ec2 import-key-pair \
        --key-name "$key_name" \
        --public-key-material "$(base64 $public_keyfile)"
  fi
}

function setup_security_group()
{
  declare sec_group_name=$1

  declare default_vpc_id=$(aws_ec2 describe-vpcs \
      --filters \
      'Name=isDefault,Values=true' \
      --query 'Vpcs[*].VpcId' \
      --output text)

  if [ -z "$default_vpc_id" ]; then
    log 'No default vpc found.'
    return 1
  fi

  declare group_id=$(aws_ec2 describe-security-groups \
      --filters \
      "Name=vpc-id,Values=$default_vpc_id" \
      "Name=group-name,Values=$sec_group_name" \
      --query 'SecurityGroups[*].GroupId' \
      --output text)

  if [ -n "$group_id" ]; then
    log "Found security group '$sec_group_name'"
    return
  fi

  log "Creating security group '$sec_group_name'"
  aws_ec2 create_security_group \
      --group-name "$sec_group_name" \
      --description 'Gentoo install' \
      > /dev/null
}

function aws_ec2
{
  aws ec2 --profile "$PROFILE" "$@"
}

function log
{
  echo "$(date -u +"%Y-%m-%d %H:%M:%S"): $@" >&2
}

main "$@"
