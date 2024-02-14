#!/usr/bin/env bash

# Required Environment Variables
if [ -z "$REDIS_IP" ]
then
  echo "Environment variable REDIS_IP has to be provided"
  exit 1
fi

if [ -z "$REDIS_PASSWORD" ]
then
  echo "Environment variable REDIS_PASSWORD has to be provided"
  exit 1
fi

python3 -m venv ~/.py3redis
. ~/.py3redis/bin/activate
pip install --upgrade pip setuptools redis
python3 <<EOF
import redis, os
def hdelall(redis_conn, hash_name):
    # Get all keys and fields from the hash
    hash_data = redis_conn.hgetall(hash_name)

    # Iterate through each key-value pair
    for key, value in hash_data.items():
        # Delete the field for each key
        redis_conn.hdel(hash_name, key)

    # Optionally, you can return the number of deleted fields
    return len(hash_data)
r = redis.Redis(host='$REDIS_IP', port=6379, password='$REDIS_PASSWORD', decode_responses=True)
hdelall(r, 'cluster')
EOF
