ARG BASE_IMAGE=ubuntu

FROM $BASE_IMAGE

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get -y install curl jq

# Download the archive.
RUN curl -LO https://github.com/tidbyt/pixlet/releases/download/v0.22.4/pixlet_0.22.4_linux_amd64.tar.gz

# Unpack the archive.
RUN tar -xvf pixlet_0.22.4_linux_amd64.tar.gz

# Ensure the binary is executable.
RUN chmod +x ./pixlet

# Move the binary into your path.
RUN mv pixlet /usr/local/bin/pixlet
WORKDIR /workspace
COPY . .
ENTRYPOINT /workspace/daemonize-push.sh