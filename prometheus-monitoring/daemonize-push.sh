#!/bin/bash
while [ $(curl -o /dev/null -s -w "%{http_code}\n" "http://192.168.1.235:30500/api/v1/query?query=sum(DCGM_FI_DEV_POWER_USAGE)") == 200 ];
    do 
        pixlet render /workspace/prometheus-monitoring.star
        CURRENT_KWH=$(curl --no-progress-meter "http://192.168.1.235:30500/api/v1/query?query=sum(DCGM_FI_DEV_POWER_USAGE)" | jq '.["data"]["result"][0]["value"][1]')
        pixlet push ${DEVICE_ID} /workspace/prometheus-monitoring.webp
        echo "Current kWh: ${CURRENT_KWH}"
        sleep 10
done