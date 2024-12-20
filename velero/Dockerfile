FROM docker.ellisbs.co.uk:5190/ubuntu:24.04

RUN apt-get update \
 && apt-get install -y wget \
 && wget https://github.com/vmware-tanzu/velero/releases/download/v1.12.0/velero-v1.12.0-linux-amd64.tar.gz \
 && tar -xvf velero-v1.12.0-linux-amd64.tar.gz \
 && mv velero-v1.12.0-linux-amd64/velero /usr/local/bin/

COPY config /root/.aws/config
COPY credentials /root/.aws/credentials

ENTRYPOINT ["/usr/local/bin/velero"]
