#!/bin/bash

export COUNTER=0
export MAXCURL=22

export clusterIP=$1

while [ $COUNTER -lt $MAXCURL ]; do

OUTPUT="$(curl http:/${clusterIP}:8001/testwebapp/)"

if [ "$OUTPUT" != "404 page not found" ]; then

echo $OUTPUT

let COUNTER=COUNTER+1

sleep 1

fi

done