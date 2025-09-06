#!/usr/bin/with-contenv bashio
#
# ArgonOne V5 Active Linear Cooling – Raspberry Pi 5

#################################
# 1.  Utility functions
#################################

# Ensure a value is a float (adds “.0” if missing)
mkfloat() {
    local str="$1"
    [[ $str != *"."* ]] && str="${str}.0"
    echo "$str"
}

#################################
# 2.  Detect I²C bus and address
#################################

calibrateI2CPort() {
    [[ -z $(ls /dev/i2c-*) ]] && {
        echo "Cannot find any /dev/i2c-* device – enable I²C first."
        sleep 999999
        exit 1
    }

    echo 'Detecting Layout of I²C, we expect to see "1a" here.'
    for device in /dev/i2c-*; do
        port=${device##*/i2c-}
        echo "checking i2c port ${port} at ${device}"
        detection=$(i2cdetect -y "$port")
        echo "$detection"
        if echo "$detection" | grep -q -E ' 1a | 1b '; then
            thePort=$port
            echo "found at $device"
            break
        fi
        echo "not found on $device"
    done

    [[ -z $thePort ]] && {
        echo "ArgonOne device not found on any I²C port"
        exit 1
    }

    port=$thePort
    echo "I²C Port $port"
}

#################################
# 3.  Pure-bash float comparison
#################################

fcomp() {                             # $1 <op> $3
    local oldIFS=$IFS op=$2
    local -a x y; local digitx digity
    IFS='.';  x=( ${1##[+-]} ); y=( ${3##[+-]} );  IFS=$oldIFS

    while [[ ${x[1]}${y[1]} =~ [^0] ]]; do
        digitx=${x[1]:0:1}; digity=${y[1]:0:1}
        (( x[0]=x[0]*10+${digitx:-0}, y[0]=y[0]*10+${digity:-0} ))
        x[1]=${x[1]:1}; y[1]=${y[1]:1}
    done
    [[ $1 == -* ]] && (( x[0]*=-1 ))
    [[ $3 == -* ]] && (( y[0]*=-1 ))
    ((${x[0]} $op ${y[0]}))
}

#################################
# 4.  Push fan speed to HA sensor
#################################

fanSpeedReportLinear() {
    local fanPercent=$1 cpuTemp=$2 unit=$3
    local icon=mdi:fan
    local body
    body=$(jq -nc --arg s "$fanPercent" --arg t "$cpuTemp" --arg u "$unit" --arg icon "$icon" '{
        state: $s,
        attributes: {
            unit_of_measurement: "%",
            icon: $icon,
            ("Temperature "+$u): $t,
            friendly_name: "Argon Fan Speed"
        }
    }')
    exec 3<>/dev/tcp/hassio/80
    printf 'POST /homeassistant/api/states/sensor.argon_one_addon_fan_speed HTTP/1.1\r\n' >&3
    printf 'Connection: close\r\nAuthorization: Bearer %s\r\n' "$SUPERVISOR_TOKEN" >&3
    printf 'Content-Length: %s\r\n\r\n%s' "${#body}" "$body" >&3
    while read -t 5 -r _; do :; done <&3
    exec 3>&-
}

#################################
# 5.  Write fan PWM with fallback
#################################

actionLinear() {
    local fanPercent=$1 cpuTemp=$2 unit=$3
    (( fanPercent < 0 ))  && fanPercent=0
    (( fanPercent > 100 ))&& fanPercent=100

    local fanHex
    printf -v fanHex '0x%02x' "$fanPercent"

    printf '%s: %s%s – Fan %s%% | hex:(%s)\n' \
        "$(date '+%Y-%m-%d_%H:%M:%S')" "$cpuTemp" "$unit" "$fanPercent" "$fanHex"

    if ! i2cset -y "$port" 0x1a "$fanHex" >/dev/null 2>&1; then
        i2cset -y "$port" 0x1b "$fanHex" >/dev/null 2>&1 || {
            echo "I²C write failed on both 0x1a and 0x1b – Safe-Mode."
            return 1
        }
    fi

    [[ $createEntity == true ]] && fanSpeedReportLinear "$fanPercent" "$cpuTemp" "$unit" &
}

#################################
# 6.  Read add-on options
#################################

tmini=$(jq -r '."Minimum Temperature"'  /data/options.json 2>/dev/null || echo 55)
tmaxi=$(jq -r '."Maximum Temperature"'  /data/options.json 2>/dev/null || echo 85)
createEntity=$(jq -r '."Create Entity"' /data/options.json 2>/dev/null || echo false)
tempUnit=$(jq -r '."Temperature Unit"'  /data/options.json 2>/dev/null || echo "F")

tmini=$(mkfloat "$tmini")
tmaxi=$(mkfloat "$tmaxi")

echo "Settings initialized. Argon One V5 Detected. Beginning monitor.."

#################################
# 7.  Start
#################################

calibrateI2CPort

while true; do
    # Read CPU temperature
    cpuRaw=$(cat /sys/class/thermal/thermal_zone0/temp)
    cpuC=$(echo "scale=1; $cpuRaw/1000" | bc)

    if [[ $tempUnit == "C" ]]; then
        cpuTemp=$cpuC; unit="°C"
    else
        cpuTemp=$(echo "scale=1; $cpuC*9/5+32" | bc)
        unit="°F"
    fi

    echo "Current Temperature = $cpuTemp $unit"

    # Decide fan speed
    if fcomp "$cpuTemp" -le "$tmini"; then
        fan=0
    elif fcomp "$cpuTemp" -ge "$tmaxi"; then
        fan=100
    else
        range=$(echo "scale=2; $tmaxi - $tmini" | bc)
        diff=$(echo  "scale=2; $cpuTemp - $tmini" | bc)
        fan=$(echo  "scale=0; $diff * 100 / $range" | bc)
    fi

    actionLinear "$fan" "$cpuTemp" "$unit"
    sleep 30
done
