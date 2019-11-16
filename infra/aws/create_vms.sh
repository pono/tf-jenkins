#!/bin/bash -e

[ "${DEBUG,,}" == "true" ] && set -x

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source "$my_dir/definitions"

ENV_FILE="$WORKSPACE/stackrc"
touch "$ENV_FILE"
echo "ENV_BUILD_ID=${BUILD_ID}" > "$ENV_FILE"
echo "AWS_REGION='${AWS_REGION}'" >> "$ENV_FILE"

# Spin VM
iname=$BUIDL_TAG
bdm='{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":60,"DeleteOnTermination":true}}'
instance_id=$(aws ec2 run-instances \
    --region $AWS_REGION \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$iname}]" \
    --block-device-mappings "[${bdm}]" \
    --image-id $IMAGE_CENTOS7 \
    --count 1 \
    --instance-type t2.xlarge \
    --key-name worker \
    --security-group-ids $AWS_SG \
    --subnet-id $AWS_SUBNET | \
    jq -r '.Instances[].InstanceId')
echo "instance_id=$instance_id" >> "$ENV_FILE"
aws ec2 wait instance-running --region $AWS_REGION \
    --instance-ids $InstanceId
instance_ip=$(aws ec2 describe-instances \
    --region $AWS_REGION \
    --filters \
    "Name=instance-state-name,Values=running" \
    "Name=instance-id,Values=$InstanceId" \
    --query 'Reservations[*].Instances[*].[PrivateIpAddress]' \
    --output text)
echo "instance_ip=$instance_ip" >> "$ENV_FILE"
