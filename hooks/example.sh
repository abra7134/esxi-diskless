#!/usr/bin/env bash

# An example hook script to view all environment variables from master script

for i in \
  ESXI_NAME \
  ESXI_HOSTNAME \
  STATUS \
  STATUS_DESCRIPTION \
  TYPE \
  VM_IPV4_ADDRESS \
  VM_SSH_PASSWORD \
  VM_SSH_PORT \
  VM_SSH_USERNAME \
  VM_NAME
do
  eval echo "\${i}=\\\"\${${i}}\\\""
done

exit 0
