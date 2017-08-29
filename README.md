Offline environment tool for CDK testing

This is still a WIP.

### How-to

1. Clone this repo.
2. Run `deploy-squid.sh`.
3. Get the IP of the squid machine from stdout.
4. Take a look in cleanup-blah.sh to get the VPC-ID, or scroll through the deploy script output to find it.
5. `ssh` into the squid machine using the generated `cdk-offline.pem` private key file. This will be your juju client box.
6. `sudo snap install juju --classic`
7. `juju add-credential aws`
8.  `juju bootstrap aws/ap-southeast-2 --config vpc-id=<VPC-ID> --config vpc-id-force=true  --config test-mode=true --to subnet=172.32.0.0/24` (note use of VPC-ID from step 4 and the aws region - see notes on that below)

### Notes

* Step 8 is gonna fail, this is as far as I've gotten.
* You'll need to use `ap-southeast-2` as your aws region or edit the scripts (including the hardcoded ami id's) to match your region.
* The generated topology is: One vpc, one private subnet, one public subnet, one machine on the public subnet running squid, private subnet traffic sent through the squid machine. See `deploy-squid.sh` for details.
