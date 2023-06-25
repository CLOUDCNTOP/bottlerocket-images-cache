#!/bin/bash
set -e

function print_help {
    echo "usage: $0 [options] <comma seperated container images>"
    echo "Build EBS snapshot for Bottlerocket data volume with cached container images"
    echo "Options:"
    echo "-h,--help print this help"
    echo "-r,--region Set AWS region to build the EBS snapshot, (default: use environment variable of AWS_DEFAULT_REGION)"
    echo "-a,--ami Set SSM Parameter path for Bottlerocket ID, (default: /aws/service/bottlerocket/aws-k8s-1.21/x86_64/latest/image_id)"
    echo "-i,--instance-type Set EC2 instance type to build this snapshot, (default: t2.small)"
    echo "-s,--subnet Set where to host EC2 instance"
    echo "-c,--clean Set whether to clean existing images"
}

while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -h|--help)
            print_help
            exit 1
            ;;
        -r|--region)
            AWS_DEFAULT_REGION=$2
            shift
            shift
            ;;
        -a|--ami)
            AMI_ID=$2
            shift
            shift
            ;;
        -i|--instance-type)
            INSTANCE_TYPE=$2
            shift
            shift
            ;;
        -s|--subnet)
            SUBNET_ID=$2
            shift
            shift
            ;;
        -c|--clean)
            IS_CLEAN=$2
            shift
            shift
            ;;                        
        *)    # unknown option
            POSITIONAL+=("$1") # save it in an array for later
            shift # past argument
            ;;
    esac
done

set +u
set -- "${POSITIONAL[@]}" # restore positional parameters
IMAGES="$1"
set -u

AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-}
AMI_ID=${AMI_ID:-/aws/service/bottlerocket/aws-k8s-1.25/x86_64/latest/image_id}
INSTANCE_TYPE=${INSTANCE_TYPE:-t2.small}
<<<<<<< HEAD:r_snapshot.sh
SUBNET_ID=${SUBNET_ID}
IS_CLEAN=${IS_CLEAN:-false}
=======
CTR_CMD="apiclient exec admin sheltie ctr -a /run/containerd/containerd.sock -n k8s.io"
>>>>>>> 1ade8a5f40a23806d71a5eb8b44d3e0168d747cd:snapshot.sh

if [ -z "${AWS_DEFAULT_REGION}" ]; then
    echo "Please set AWS region"
    exit 1
fi

if [ -z "${IMAGES}" ]; then
    echo "Please set images list"
    exit 1
fi

if [ -z "${SUBNET_ID}" ]; then
    echo "Please set subnet"
    exit 1
fi

IMAGES_LIST=(`echo $IMAGES | sed 's/,/\n/g'`)
export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION}

##############################################################################################
export AWS_PAGER=""

# launch EC2
echo "[1/8] Deploying EC2 CFN stack ..."
CFN_STACK_NAME="Bottlerocket-ebs-snapshot"
aws cloudformation deploy --stack-name $CFN_STACK_NAME --template-file ebs-snapshot-instance.yaml --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides SubnetID=$SUBNET_ID AmiID=$AMI_ID InstanceType=$INSTANCE_TYPE
INSTANCE_ID=$(aws cloudformation describe-stacks --stack-name $CFN_STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text)

# wait for SSM ready
echo -n "[2/8] Launching SSM ."
while [[ $(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$INSTANCE_ID" --query "InstanceInformationList[0].PingStatus" --output text) != "Online" ]]
do
   echo -n "."
   sleep 5
done
echo " done!"

<<<<<<< HEAD:r_snapshot.sh
# clean & pull images
if [ ${IS_CLEAN} ]; then
    echo "Clean existing images:"
    CMD_CLEAN_ID=$(aws ssm send-command --instance-ids $INSTANCE_ID \
            --document-name "AWS-RunShellScript" --comment "Clean Existing Images" \
            --parameters commands="apiclient exec admin sheltie ctr -n k8s.io images rm \$(apiclient exec admin sheltie ctr -n k8s.io images ls -q)" \
            --cloud-watch-output-config "CloudWatchOutputEnabled=true" \
            --query "Command.CommandId" --output text)
    aws ssm wait command-executed --command-id "$CMD_CLEAN_ID" --instance-id $INSTANCE_ID > /dev/null && echo "clean done"
fi

echo "[3/6] Pulling ECR images:"
=======
# stop kubelet.service
echo -n "[3/8] Stopping kubelet.service .."
CMDID=$(aws ssm send-command --instance-ids $INSTANCE_ID \
    --document-name "AWS-RunShellScript" --comment "Stop kubelet" \
    --parameters commands="apiclient exec admin sheltie systemctl stop kubelet" \
    --query "Command.CommandId" --output text)
aws ssm wait command-executed --command-id "$CMDID" --instance-id $INSTANCE_ID > /dev/null
echo " done!"

# cleanup existing images
echo -n "[4/8] Cleanup existing images .."
CMDID=$(aws ssm send-command --instance-ids $INSTANCE_ID \
    --document-name "AWS-RunShellScript" --comment "Cleanup existing images" \
    --parameters commands="$CTR_CMD images rm \$($CTR_CMD images ls -q)" \
    --query "Command.CommandId" --output text)
aws ssm wait command-executed --command-id "$CMDID" --instance-id $INSTANCE_ID > /dev/null
echo " done!"

# pull images
echo "[5/8] Pulling ECR images:"
>>>>>>> 1ade8a5f40a23806d71a5eb8b44d3e0168d747cd:snapshot.sh
for IMG in "${IMAGES_LIST[@]}"
do
    ECR_REGION=$(echo $IMG | sed -n "s/^[0-9]*\.dkr\.ecr\.\([a-z1-9-]*\)\.amazonaws\.com.*$/\1/p")
    [ ! -z "$ECR_REGION" ] && ECRPWD="--u AWS:"$(aws ecr get-login-password --region $ECR_REGION) || ECRPWD=""
    for PLATFORM in amd64 arm64
    do
        echo -n "  $IMG - $PLATFORM ... "
        CMDID=$(aws ssm send-command --instance-ids $INSTANCE_ID \
            --document-name "AWS-RunShellScript" --comment "Pull Images" \
            --parameters commands="$CTR_CMD images pull --platform $PLATFORM $IMG $ECRPWD" \
            --query "Command.CommandId" --output text)
        aws ssm wait command-executed --command-id "$CMDID" --instance-id $INSTANCE_ID > /dev/null && echo "pull done"
    done
done
echo " done!"

# stop EC2
echo -n "[6/8] Stopping instance ... "
aws ec2 stop-instances --instance-ids $INSTANCE_ID --output text > /dev/null
aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID" > /dev/null && echo "done!"

# create EBS snapshot
echo -n "[7/8] Creating snapshot ... "
DATA_VOLUME_ID=$(aws ec2 describe-instances  --instance-id $INSTANCE_ID --query "Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName=='/dev/xvdb'].Ebs.VolumeId" --output text)
SNAPSHOT_ID=$(aws ec2 create-snapshot --volume-id $DATA_VOLUME_ID --description "Bottlerocket Data Volume snapshot" --query "SnapshotId" --output text)
aws ec2 wait snapshot-completed --snapshot-ids "$SNAPSHOT_ID" > /dev/null && echo "done!"

# aws ec2 enable-fast-snapshot-restores \
#     --availability-zones ${AWS_DEFAULT_REGION}a ${AWS_DEFAULT_REGION}b ${AWS_DEFAULT_REGION}c \
#     --source-snapshot-ids $SNAPSHOT_ID

# destroy temporary instance
echo "[8/8] Cleanup."
aws cloudformation delete-stack --stack-name "Bottlerocket-ebs-snapshot"

# done!
echo "--------------------------------------------------"
export EBS_SNAPSHOT_ID=$SNAPSHOT_ID
echo "All done! Created snapshot in $AWS_DEFAULT_REGION: $EBS_SNAPSHOT_ID"
