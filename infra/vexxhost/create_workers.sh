#!/bin/bash -eE
set -o pipefail

[ "${DEBUG,,}" == "true" ] && set -x

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source "$my_dir/definitions"
source "$my_dir/functions.sh"
source "$WORKSPACE/global.env"

# parameters for workers
VM_TYPE=${VM_TYPE:-'medium'}
NODES_COUNT=${NODES_COUNT:-1}

ENV_FILE="$WORKSPACE/stackrc.$JOB_NAME.env"
touch "$ENV_FILE"
echo "export OS_REGION_NAME=${OS_REGION_NAME}" > "$ENV_FILE"
echo "export ENVIRONMENT_OS=${ENVIRONMENT_OS}" >> "$ENV_FILE"

IMAGE_TEMPLATE_NAME="${OS_IMAGES["${ENVIRONMENT_OS^^}"]}"
for (( i=1; i<=5 ; ++i )) ; do
  if IMAGE_NAME=$(openstack image list --status active -c Name -f value | grep "${IMAGE_TEMPLATE_NAME}" | sort -nr | head -n 1) ; then
    if IMAGE=$(openstack image show -c id -f value "$IMAGE_NAME") ; then
      break
    fi
  fi
  sleep 15
done
if [[ -z "$IMAGE" ]]; then
  echo "ERROR: can't retrieve image details to boot VM"
  exit 1
fi
echo "export IMAGE=$IMAGE" >> "$ENV_FILE"

IMAGE_SSH_USER=${OS_IMAGE_USERS["${ENVIRONMENT_OS^^}"]}
echo "export IMAGE_SSH_USER=$IMAGE_SSH_USER" >> "$ENV_FILE"

INSTANCE_TYPE=${VM_TYPES[$VM_TYPE]}
if [[ -z "$INSTANCE_TYPE" ]]; then
  echo "ERROR: invalid VM_TYPE=$VM_TYPE"
  exit 1
fi
echo "INFO: VM_TYPE=$VM_TYPE  INSTANCE_TYPE=$INSTANCE_TYPE"

function cleanup () {
  local cleanup_tag=$1
  local termination_list="$(list_instances ${cleanup_tag})"
  if [[ -n "${termination_list}" ]] ; then
    echo "INFO: Instances to terminate: $termination_list"
    for instance_id in $termination_list ; do
      if nova show "$instance_id" | grep 'locked' | grep 'False'; then
        down_instances $instance_id || true
        nova delete "$instance_id"
      fi
    done
  fi
}

function wait_for_instance_availability () {
  local instance_ip=$1
  local res=0
  timeout 300 bash -c "\
  while /bin/true ; do \
    ssh -i $WORKER_SSH_KEY $SSH_OPTIONS $IMAGE_SSH_USER@$instance_ip 'uname -a' && break ; \
    sleep 10 ; \
  done" || res=1
  if [[ $res != 0 ]] ; then
    echo "ERROR: VM  with ip $instance_ip is unreachable. Exit "
    return 1
  fi
  export instance_ip
  image_up_script=${OS_IMAGES_UP["${ENVIRONMENT_OS^^}"]}
  if [[ -n "$image_up_script" && -e ${my_dir}/../hooks/${image_up_script}/up.sh ]] ; then
    ${my_dir}/../hooks/${image_up_script}/up.sh
  fi
 }

if [[ -n $WORKER_NAME_PREFIX ]] ; then
  PREFIX="${WORKER_NAME_PREFIX}_"
else
  PREFIX=''
fi
instance_name="${PREFIX}${BUILD_TAG}"
job_tag="JobTag=${BUILD_TAG}"
group_tag="GroupTag=${PREFIX}${BUILD_TAG}"

for (( i=1; i<=5 ; ++i )) ; do
  if instance_vcpu=$(openstack flavor show $INSTANCE_TYPE | awk '/vcpus/{print $4}') ; then
    break
  fi
  sleep 10
done
if [[ -z "$instance_vcpu" ]]; then
  echo "ERROR: can't retrieve flavor details to boot VM"
  exit 1
fi
total_vcpu=$(( instance_vcpu * $NODES_COUNT ))

for (( i=1; i<=$VM_RETRIES ; ++i )) ; do
  ready_nodes=0
  INSTANCE_IDS=""
  INSTANCE_IPS=""
  while true; do
    [[ "$(($(nova list --tags "SLAVE=$SLAVE"  --field status | grep -c 'ID\|ACTIVE') + NODES_COUNT ))" -lt "$MAX_COUNT_VM" ]] && break
    echo "INFO: waiting for free worker"
    sleep 60
  done

  while true; do
    [[ "$(($(nova quota-show --detail | grep cores | sed 's/}.*/}/'| tr -d "}" | awk '{print $NF}') + total_vcpu ))" -lt "$MAX_COUNT_VCPU" ]] && break
    echo "INFO: waiting for CPU resources"
    sleep 60
  done

  res=0
  nova boot --flavor ${INSTANCE_TYPE} \
            --security-groups ${OS_SG} \
            --key-name=worker \
            --min-count ${NODES_COUNT} \
            --tags "PipelineBuildTag=${PIPELINE_BUILD_TAG},${job_tag},${group_tag},SLAVE=${SLAVE},DOWN=${OS_IMAGES_DOWN["${ENVIRONMENT_OS^^}"]}" \
            --nic net-name=${OS_NETWORK} \
            --block-device source=image,id=$IMAGE,dest=volume,shutdown=remove,size=120,bootindex=0 \
            --poll \
            ${instance_name} || res=1

  if [[ $res == 1 ]]; then
    echo "ERROR: Instances creation is failed on nova boot. Retry"
    cleanup ${group_tag}
    sleep 60
    continue
  fi
  INSTANCE_IDS="$( list_instances ${group_tag} )"

  for instance_id in $INSTANCE_IDS ; do
    instance_ip=$(get_instance_ip $instance_id)
    if ! wait_for_instance_availability $instance_ip ; then
      echo "ERROR: Node with $instance_ip is not available. Clean up"
      cleanup ${group_tag}
      break
    fi
    ready_nodes=$(( ready_nodes + 1 ))
    INSTANCE_IPS+="$instance_ip,"
  done

  if (( ready_nodes == NODES_COUNT )) ; then
    if [[ -n "$INSTANCE_IPS" ]] ; then
      INSTANCE_IDS="$(echo "$INSTANCE_IDS" | sed 's/ /,/g')"
      echo "export INSTANCE_IDS=$INSTANCE_IDS" >> "$ENV_FILE"
      echo "export INSTANCE_IPS=$INSTANCE_IPS" >> "$ENV_FILE"
      instance_ip=`echo $INSTANCE_IPS | cut -d',' -f1`
      echo "export instance_ip=$instance_ip" >> "$ENV_FILE"
    fi
    exit 0
  fi
done

echo "INFO: Nodes are not created."
touch "$ENV_FILE"
exit 1
