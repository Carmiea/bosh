#!/usr/bin/env bash

set -eux

VERSIONED_FILENAME=$1
DESTINATION_PATH=$2
ARCHIVE_SHA=$3
BUCKET_FOLDER=$4

ARCHIVE_URL=https://s3.amazonaws.com/${BUCKET_FOLDER}/${VERSIONED_FILENAME}

wget -q $ARCHIVE_URL -O $DESTINATION_PATH
echo "${ARCHIVE_SHA}  ${DESTINATION_PATH}" | shasum -a 256 -c -
