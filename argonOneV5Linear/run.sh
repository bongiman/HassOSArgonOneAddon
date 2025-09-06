#!/usr/bin/with-contenv bashio

###
# ArgonOne V5 Active Linear Cooling Script
# Methods - functions called by script
###

## Make everything into a float
mkfloat() {
    str=$1
    if [[ $str != *"."* ]]; then
        str=$str".0"
    fi
    echo "$str"
}

## Perform basic checks and return the port number of the detected device
calibrateI2CPort() {
    if [ -z "$(ls /dev/i2c-*)" ]; then
        echo "Cannot find I2C port. You must enable I2C for this add-on to operate properly"
        sleep 999999
        exit 1
    fi

    echo "Detecting Layout of i2c, we expect to see \"1a\" here."
    
    for device in /dev/i2c-*; do
        port=${device:9}
        echo "checking i2c port ${port} at ${device}"
        detection=$(i2cdetect -y "${port}")
        echo "${detection}"
        if echo "${detection}" | grep -q -E ' 1a | 1b '; then
            thePort=${port}
            echo "found at $device"
            break
        fi
        echo "not found on ${device}"
    done
    
    if [ -z "${thePort}" ]; then
        echo "ArgonOne device not found on any I2C port"
        exit 1
    fi
    
    port=${thePort}
    echo "I2C Port ${port}"
}

## Float comparison so that we don't need to call non-bash processes
fcomp() {
    local oldIFS="$IFS" op=$2 x y digitx digity
    IFS='.'
    x=( ${1##+([0]|[-]|[+])} )
    y=( ${3##+([0]|[-]|[+])} )
    IFS="$oldIFS"

    while [[ "${x[1]}${y[1]}" =~ [^0] ]]; do
        digitx=${x[1]:0:1}
        digity=${y[1]:0:1}
        (( x[0] = x[0] * 10 + ${digitx:-0} , y[0] = y[0] * 10 + ${digity:-0} ))
        x[1]=${x[1]:1} y[1]=${y[1]:1}
    done
    [[ ${1:0:1} == '-' ]] && (( x[0] *= -1 ))
    [[ ${3:0:1} == '-' ]] && (( y[0] *= -1 ))
    (( "${x:-0}" "$op" "${y:-0}" ))
}

## Report fan speed to Home Assistant
fanSpeedReportLinear(){
    fanPercent=${1}
    cpuTemp=${2}
    CorF=${3}
    icon=mdi:fan
    reqBody='{"state": "'"${fanPercent}"'", "attributes": { "unit_of_measurement": "%", "icon": "'"${icon}"'", "Temperature '"${CorF}"'": "'"${cpuTemp}"'", "friendly_name": "Argon Fan Speed"}}'
    exec 3<>/dev/tcp/hassio/80
    echo -ne "POST /homeassistant/api/states/sensor.argon_one_addon_fan_speed HTTP/1.1\r\n" >&3
    echo -ne "Connection: close\r\n" >&3
    echo -ne "Authorization: Bearer ${SUPERVISOR_TOKEN}\r\n" >&3
    echo -ne "Content-Length: $(echo -ne "${reqBody}" | wc -c)\r\n" >&3
    echo -ne "\r\n" >&3
    echo -ne "${reqBody}" >&3
    timeout=5
    while read -t "${timeout}" -r line; do
        echo "${line}" >/dev/null
    done <&3
    exec 3>&-
}

## Linear fan control action
actionLinear() {
    fanPercent=${1}
    cpuTemp=${2}
    CorF=${3}
    
    if [[ $fanPercent -lt 0 ]]; then
        fanPercent=0
    fi
    if [[ $fanPercent -gt 100 ]]; then
        fanPercent=100
    fi
    
    # Send all hexadecimal format 0x00 > 0x64 (0>100%)
    if [[ $fanPercent -lt 10 ]]; then
        fanPercentHex=$(printf '0x0%x' "${fanPercent}")
    else
        fanPercentHex=$(printf '0x%x' "${fanPercent}")
    fi
    
    echo "$(date '+%Y-%m-%d_%H:%M:%S'): ${cpuTemp}${CorF} - Fan ${fanPercent}% | hex:(${fanPercentHex})"
    
    # Try to write to I2C device with error handling
    if i2cset -y "${port}" 0x1a "${fanPercentHex}" 2>/dev/null; then
        returnValue=0
    else
        echo "Failed ${LINENO}: i2cset -y \"${port}\" 0x1a \"${fanPercentHex}\""
        echo "Error: Write failed"
        echo "Safe Mode Activated!"
        returnValue=1
    fi
    
    test "${createEntity}" == "true" && fanSpeedReportLinear "${fanPercent}" "${cpuTemp}" "${CorF}" &
    return "${returnValue}"
}

###
# Main execution starts here
###

# Read configuration from Home Assistant addon options
tmini=$(jq -r '."Minimum Temperature"' /data/options.json 2>/dev/null || echo "55")
tmaxi=$(jq -r '."Maximum Temperature"' /data/options.json 2>/dev/null || echo "85")
createEntity=$(jq -r '."Create Entity"' /data/options.json 2>/dev/null || echo "false")
tempUnit=$(jq -r '."Temperature Unit"' /data/options.json 2>/dev/null || echo "F")

# Convert temperatures to float format
tmini=$(mkfloat "${tmini}")
tmaxi=$(mkfloat "${tmaxi}")

echo "Settings initialized. Argon One V5 Detected. Beginning monitor.."

# Calibrate I2C port
calibrateI2CPort

# Main monitoring loop
while true; do
    # Get CPU temperature
    if [[ "${tempUnit}" == "C" ]]; then
        # Read temperature in Celsius
        cpuRawTemp=$(cat /sys/class/thermal/thermal_zone0/temp)
        cpuTemp=$(echo "scale=1; ${cpuRawTemp}/1000" | bc)
        CorF="°C"
    else
        # Read temperature in Fahrenheit  
        cpuRawTemp=$(cat /sys/class/thermal/thermal_zone0/temp)
        cpuTempC=$(echo "scale=1; ${cpuRawTemp}/1000" | bc)
        cpuTemp=$(echo "scale=1; ${cpuTempC}*9/5+32" | bc)
        CorF="°F"
    fi
    
    echo "Current Temperature = ${cpuTemp} ${CorF}"
    
    # Calculate fan speed based on temperature (linear interpolation)
    if fcomp "${cpuTemp}" -le "${tmini}"; then
        # Below minimum temperature - fan off
        fanPercent=0
    elif fcomp "${cpuTemp}" -ge "${tmaxi}"; then
        # Above maximum temperature - fan at 100%
        fanPercent=100
    else
        # Linear interpolation between min and max temperatures
        tempRange=$(echo "scale=2; ${tmaxi} - ${tmini}" | bc)
        tempDiff=$(echo "scale=2; ${cpuTemp} - ${tmini}" | bc)
        fanPercent=$(echo "scale=0; ${tempDiff} * 100 / ${tempRange}" | bc)
    fi
    
    # Execute fan control
    actionLinear "${fanPercent}" "${cpuTemp}" "${CorF}"
    
    # Wait 30 seconds before next check
    sleep 30
done