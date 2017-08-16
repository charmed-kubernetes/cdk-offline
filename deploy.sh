#!/bin/bash
set -eux

VPC_CIDR=172.32.0.0/16
PRIVATE_SUBNET_CIDR=172.32.0.0/24
PUBLIC_SUBNET_CIDR=172.32.1.0/24

alias aws="aws --output text"

function clean {
  NAME=cleanup-$VPC_ID.sh
  if [ ! -f $NAME ]; then
    touch $NAME
    chmod +x $NAME
  fi
  echo -e "$1\n$(cat $NAME)" > $NAME
}

VPC_ID=$(aws ec2 create-vpc --cidr $VPC_CIDR | awk '{print $7}')
clean "aws ec2 delete-vpc --vpc-id $VPC_ID"

aws ec2 modify-vpc-attribute --vpc-id=$VPC_ID --enable-dns-support
aws ec2 modify-vpc-attribute --vpc-id=$VPC_ID --enable-dns-hostnames

PRIVATE_SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $PRIVATE_SUBNET_CIDR | awk '{print $9}')
clean "aws ec2 delete-subnet --subnet-id $PRIVATE_SUBNET_ID"
PUBLIC_SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $PUBLIC_SUBNET_CIDR | awk '{print $9}')
clean "aws ec2 delete-subnet --subnet-id $PUBLIC_SUBNET_ID"
aws ec2 modify-subnet-attribute --subnet-id $PRIVATE_SUBNET_ID --map-public-ip-on-launch
aws ec2 modify-subnet-attribute --subnet-id $PUBLIC_SUBNET_ID --map-public-ip-on-launch

GATEWAY_ID=$(aws ec2 create-internet-gateway | cut -f 2)
clean "aws ec2 delete-internet-gateway --internet-gateway-id $GATEWAY_ID"
aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway $GATEWAY_ID
clean "aws ec2 detach-internet-gateway --internet-gateway-id $GATEWAY_ID --vpc-id $VPC_ID"
DEFAULT_ROUTE_TABLE_ID=$(aws --output text ec2 describe-route-tables | grep $VPC_ID | cut -f 2)
aws ec2 create-route --route-table-id $DEFAULT_ROUTE_TABLE_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $GATEWAY_ID

SECURITY_GROUP_ID=$(aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC_ID | awk '{print $6}')
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol tcp --port 22 --cidr 0.0.0.0/0

if [ ! -f cdk-offline.pem ]; then
    aws ec2 create-key-pair --key-name cdk-offline > cdk-offline.pem
fi

SQUID_INSTANCE_ID=$(aws ec2 run-instances --output json --count 1 --image-id ami-bb1901d8 --instance-type t2.micro --key-name cdk-offline --subnet-id $PUBLIC_SUBNET_ID | jq -r '.Instances[].InstanceId')
clean "until aws ec2 describe-instances --instance-ids $SQUID_INSTANCE_ID --output json | jq -r '.Reservations[].Instances[].State.Name' | grep terminated; do sleep 1; echo 'wating for instance termination'; done"
clean "aws ec2 terminate-instances --instance-ids $SQUID_INSTANCE_ID"

until aws ec2 describe-instances --instance-ids $SQUID_INSTANCE_ID --output json | jq -r '.Reservations[].Instances[].State.Name' | grep running; do sleep 1; echo 'waiting for squid instance'; done
aws ec2 modify-instance-attribute --instance-id $SQUID_INSTANCE_ID --source-dest-check '{"Value": false}'

SQUID_INSTANCE_IP=$(aws ec2 describe-instances --instance-ids $SQUID_INSTANCE_ID --output json | jq -r '.Reservations[].Instances[].PublicIpAddress')

SQUID_ROUTE_TABLE_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --output json| jq -r '.RouteTable.RouteTableId')
aws ec2 create-route --route-table-id $SQUID_ROUTE_TABLE_ID --destination-cidr-block 0.0.0.0/0 --instance-id $SQUID_INSTANCE_ID
clean "aws ec2 delete-route-table --route-table-id $SQUID_ROUTE_TABLE_ID"

SQUID_ROUTE_TABLE_ASSOCIATION_ID=$(aws ec2 associate-route-table --route-table-id $SQUID_ROUTE_TABLE_ID --subnet-id $PRIVATE_SUBNET_ID)

TEST_INSTANCE_ID=$(aws ec2 run-instances --output json --count 1 --image-id ami-bb1901d8 --instance-type t2.micro --key-name cdk-offline --subnet-id $PRIVATE_SUBNET_ID | jq -r '.Instances[].InstanceId')
clean "until aws ec2 describe-instances --instance-ids $TEST_INSTANCE_ID --output json | jq -r '.Reservations[].Instances[].State.Name' | grep terminated; do sleep 1; echo 'wating for instance termination'; done"
clean "aws ec2 terminate-instances --instance-ids $TEST_INSTANCE_ID"

# Wait for the squid instance to respond to ssh
until ssh -i cdk-offline.pem ubuntu@$SQUID_INSTANCE_IP echo waiting; do sleep 1; done

# Install squid on the squid instance
scp -i cdk-offline.pem ./install-squid.sh ubuntu@$SQUID_INSTANCE_IP:.
ssh -i cdk-offline.pem ubuntu@$SQUID_INSTANCE_IP ./install-squid.sh



# cat > cleanup-$VPC_ID.sh << EOF
# set -ux
# aws ec2 detach-internet-gateway --internet-gateway-id $GATEWAY_ID --vpc-id $VPC_ID
# aws ec2 delete-internet-gateway --internet-gateway-id $GATEWAY_ID
# aws ec2 delete-subnet --subnet-id $PRIVATE_SUBNET_ID
# aws ec2 delete-vpc --vpc-id $VPC_ID
# EOF
# chmod +x cleanup-$VPC_ID.sh


# ACL_ID=$(aws ec2 describe-network-acls --filters Name=vpc-id,Values=$VPC_ID --output json | jq -r '.NetworkAcls[0].NetworkAclId')
#
# MY_IP=$(dig +short myip.opendns.com @resolver1.opendns.com)
# aws ec2 replace-network-acl-entry --network-acl-id $ACL_ID --egress --rule-number 100 --protocol all --rule-action allow --cidr-block $MY_IP/32
#
# function acl_dn {
#   RULE=$1
#   DN=$2
#   dig +short $DN | grep -E '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | while read ip
#     do aws ec2 create-network-acl-entry --network-acl-id $ACL_ID --egress --rule-number $RULE --protocol all --rule-action allow --cidr-block $ip/32
#     RULE=$((RULE + 1))
#   done
# }
#
# acl_dn 200 ap-southeast-2.ec2.archive.ubuntu.com
# acl_dn 300 security.ubuntu.com
# acl_dn 400 juju-dist.s3.amazonaws.com
#
# # Bootstrap juju controller
# juju bootstrap aws/ap-southeast-2 aws-$VPC_ID --config vpc-id=$VPC_ID --config test-mode=true