#!/usr/bin/env bash
set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-minecraft-on-demand}"
export AWS_REGION="${AWS_REGION:-us-west-2}"

STACK="${STACK:-minecraft-server-stack}"
CLUSTER="${CLUSTER:-minecraft}"
SERVICE="${SERVICE:-minecraft-server}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.nano}"
ROLE_NAME="${ROLE_NAME:-MinecraftHelperSsmRole}"
PROFILE_NAME="${PROFILE_NAME:-MinecraftHelperSsmProfile}"
NAME_TAG="${NAME_TAG:-minecraft-efs-helper}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/minecraft}"

INSTANCE_ID=""
CLEANED_UP=0

cleanup() {
  local exit_code=$?

  if [[ "$CLEANED_UP" == "1" ]]; then
    exit "$exit_code"
  fi
  CLEANED_UP=1

  if [[ -z "${INSTANCE_ID:-}" || "$INSTANCE_ID" == "None" ]]; then
    exit "$exit_code"
  fi

  printf '
==> Cleaning up helper instance %s
' "$INSTANCE_ID" >&2

  local state
  state=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null || true)

  if [[ "$state" == "running" ]]; then
    printf '==> Attempting EFS unmount via SSM
' >&2

    local command_id
    command_id=$(aws ssm send-command \
      --instance-ids "$INSTANCE_ID" \
      --document-name "AWS-RunShellScript" \
      --comment "Unmount Minecraft EFS before terminating helper" \
      --parameters "commands=[\"set -euxo pipefail\",\"if mountpoint -q '$MOUNT_POINT'; then sudo umount '$MOUNT_POINT'; fi\"]" \
      --query 'Command.CommandId' \
      --output text 2>/dev/null || true)

    if [[ -n "$command_id" && "$command_id" != "None" ]]; then
      aws ssm wait command-executed \
        --command-id "$command_id" \
        --instance-id "$INSTANCE_ID" \
        >/dev/null 2>&1 || true
    fi
  fi

  printf '==> Terminating helper instance %s
' "$INSTANCE_ID" >&2
  aws ec2 terminate-instances \
    --instance-ids "$INSTANCE_ID" \
    >/dev/null 2>&1 || true

  exit "$exit_code"
}

trap cleanup EXIT INT TERM

log() {
  printf '\n==> %s\n' "$*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd aws
require_cmd jq

log "Using profile=$AWS_PROFILE region=$AWS_REGION"

log "Finding EFS file system and access point from CloudFormation stack: $STACK"
EFS_ID=$(aws cloudformation list-stack-resources \
  --stack-name "$STACK" \
  --query 'StackResourceSummaries[?ResourceType==`AWS::EFS::FileSystem`].PhysicalResourceId | [0]' \
  --output text)

ACCESS_POINT_ID=$(aws cloudformation list-stack-resources \
  --stack-name "$STACK" \
  --query 'StackResourceSummaries[?ResourceType==`AWS::EFS::AccessPoint`].PhysicalResourceId | [0]' \
  --output text)

if [[ -z "$EFS_ID" || "$EFS_ID" == "None" || -z "$ACCESS_POINT_ID" || "$ACCESS_POINT_ID" == "None" ]]; then
  echo "Could not discover EFS_ID or ACCESS_POINT_ID from stack $STACK" >&2
  exit 1
fi

log "EFS_ID=$EFS_ID ACCESS_POINT_ID=$ACCESS_POINT_ID"

log "Finding ECS service network config"
NETWORK_JSON=$(aws ecs describe-services \
  --cluster "$CLUSTER" \
  --services "$SERVICE" \
  --query 'services[0].networkConfiguration.awsvpcConfiguration' \
  --output json)

SUBNET_ID=$(printf '%s' "$NETWORK_JSON" | jq -r '.subnets[0]')
SG_ID=$(printf '%s' "$NETWORK_JSON" | jq -r '.securityGroups[0]')
ASSIGN_PUBLIC_IP=$(printf '%s' "$NETWORK_JSON" | jq -r '.assignPublicIp // "DISABLED"')

if [[ -z "$SUBNET_ID" || "$SUBNET_ID" == "null" || -z "$SG_ID" || "$SG_ID" == "null" ]]; then
  echo "Could not discover subnet/security group from ECS service $CLUSTER/$SERVICE" >&2
  exit 1
fi

log "SUBNET_ID=$SUBNET_ID SG_ID=$SG_ID assignPublicIp=$ASSIGN_PUBLIC_IP"

log "Ensuring SSM IAM role/profile exists"
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    >/dev/null
fi

aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore \
  >/dev/null || true

if ! aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null
fi

if ! aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" \
  --query "InstanceProfile.Roles[?RoleName=='$ROLE_NAME'].RoleName" \
  --output text | grep -q "$ROLE_NAME"; then
  aws iam add-role-to-instance-profile \
    --instance-profile-name "$PROFILE_NAME" \
    --role-name "$ROLE_NAME" \
    >/dev/null
  log "Waiting for IAM instance profile propagation"
  sleep 20
fi

log "Resolving latest Amazon Linux 2023 AMI"
AMI_ID=$(aws ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameter.Value' \
  --output text)

log "Launching helper EC2 instance"
NETWORK_IFACE="DeviceIndex=0,SubnetId=$SUBNET_ID,Groups=$SG_ID"
if [[ "$ASSIGN_PUBLIC_IP" == "ENABLED" ]]; then
  NETWORK_IFACE="$NETWORK_IFACE,AssociatePublicIpAddress=true"
fi

INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --network-interfaces "$NETWORK_IFACE" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME_TAG}]" \
  --query 'Instances[0].InstanceId' \
  --output text)

log "INSTANCE_ID=$INSTANCE_ID"
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

log "Waiting for SSM agent to come online"
PING=""
for _ in {1..40}; do
  PING=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query 'InstanceInformationList[0].PingStatus' \
    --output text 2>/dev/null || true)

  if [[ "$PING" == "Online" ]]; then
    break
  fi

  printf '.'
  sleep 5
done
printf '\n'

if [[ "$PING" != "Online" ]]; then
  echo "SSM did not come online. Check subnet internet/NAT/VPC endpoints and security group egress." >&2
  echo "Instance left running: $INSTANCE_ID" >&2
  exit 1
fi

log "Sending mount command via SSM"
COMMANDS_JSON=$(jq -cn \
  --arg mount_point "$MOUNT_POINT" \
  --arg access_point_id "$ACCESS_POINT_ID" \
  --arg efs_id "$EFS_ID" \
  '{
    commands: [
      "set -euxo pipefail",
      "sudo dnf install -y amazon-efs-utils || sudo yum install -y amazon-efs-utils",
      "sudo mkdir -p \($mount_point)",
      "if ! mountpoint -q \($mount_point); then sudo mount -t efs -o tls,accesspoint=\($access_point_id) \($efs_id):/ \($mount_point); fi",
      "mount | grep \($mount_point)",
      "sudo ls -la \($mount_point)"
    ]
  }')

COMMAND_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --comment "Mount Minecraft EFS" \
  --parameters "$COMMANDS_JSON" \
  --query 'Command.CommandId' \
  --output text)

log "Waiting for mount command: $COMMAND_ID"
aws ssm wait command-executed \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID"

log "Mount command output"
aws ssm get-command-invocation \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" \
  --query '{Status:Status,Stdout:StandardOutputContent,Stderr:StandardErrorContent}' \
  --output json

cat <<EOF

Helper is ready.

  cd $MOUNT_POINT
  ls -la

Log out to delete the instance.

EOF

log "Opening SSM session"
aws ssm start-session --target "$INSTANCE_ID"
