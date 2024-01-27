#!/usr/bin/env bash

if [ $# -ne 1 ]
then
  echo "Have to supply a verb"
  exit 1
fi

./Vagrant_Kubernetes_Setup.sh $1 2>&1 > ./vagrant_kubernetes.log &
