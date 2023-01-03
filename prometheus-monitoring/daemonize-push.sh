#!/bin/bash
while [ $(curl -o /dev/null -s -w "%{http_code}\n" "http://192.168.1.235:30500/api/v1/query?query=sum(DCGM_FI_DEV_POWER_USAGE)") == 200 ];
    do 
        pixlet render /workspace/prometheus-monitoring.star
        pixlet push ${DEVICE_ID} /workspace/prometheus-monitoring.webp
        sleep 30
done