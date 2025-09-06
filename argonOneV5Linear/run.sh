#!/usr/bin/with-contenv bashio
# ArgonOne V5 Active Linear Cooling – Raspberry Pi 5

#################################
# 1. Configuration and Constants
#################################

# Default temperature settings
DEFAULT_MIN_TEMP=32.0
DEFAULT_MAX_TEMP=65.0
DEFAULT_CREATE_ENTITY=false
DEFAULT_TEMP_UNIT="C"

# I2C addresses for ArgonOne fan controller
I2C_ADDRESS_PRIMARY="0x1a"
I2C_ADDRESS_SECONDARY="0x1b"

# Home Assistant API endpoint for fan speed sensor
HA_API_ENDPOINT="/homeassistant/api/states/sensor.argon_one_addon_fan_speed"
HA_HOST="hassio"
HA_PORT=80

#################################
# 2. Utility functions
#################################

# Log messages with timestamp
log_message() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1"
}

# Check if a string is a valid number (integer or float)
is_numeric() {
  [[ "$1" =~ ^[+-]?[0-9]+(\.[0-9]+)?$ ]]
}

#################################
# 3. Detect I²C bus and address
#################################

# Calibrates the I2C port by scanning for the ArgonOne device.
# Sets the global 'I2C_PORT' variable upon success.
calibrateI2CPort() {
  if [[ -z $(ls /dev/i2c-* 2>/dev/null) ]]; then
    log_message "ERROR: Cannot find any /dev/i2c-* device – enable I²C first."
    exit 1
  fi

  log_message 'Detecting Layout of I²C, we expect to see "1a" or "1b" here.'
  local detected_port=""
  for device in /dev/i2c-*; do
    local port_scan=${device##*/i2c-}
    log_message "Checking i2c port ${port_scan} at ${device}"
    local detection_output
    detection_output=$(i2cdetect -y "$port_scan" 2>&1)
    log_message "$detection_output"
    if echo "$detection_output" | grep -q -E " ${I2C_ADDRESS_PRIMARY#0x} | ${I2C_ADDRESS_SECONDARY#0x} "; then
      detected_port=$port_scan
      log_message "ArgonOne device found at $device"
      break
    fi
    log_message "ArgonOne device not found on $device"
  done

  if [[ -z $detected_port ]]; then
    log_message "ERROR: ArgonOne device not found on any I²C port."
    exit 1
  fi

  I2C_PORT=$detected_port
  log_message "I²C Port $I2C_PORT selected."
}

#################################
# 4. Push fan speed to HA sensor
#################################

# Reports the current fan speed to Home Assistant via its API.
# Arguments: fanPercent, cpuTemp, unit
fanSpeedReportLinear() {
  local fanPercent="$1" cpuTemp="$2" unit="$3"
  local icon="mdi:fan"
  local body

  body=$(jq -nc \
    --arg s "$fanPercent" \
    --arg t "$cpuTemp" \
    --arg u "$unit" \
    --arg icon "$icon" \
    '{
      state: $s,
      attributes: {
        unit_of_measurement: "%",
        icon: $icon,
        ("Temperature "+$u): $t,
        friendly_name: "Argon Fan Speed"
      }
    }')

  if [[ -z "$body" ]]; then
    log_message "WARNING: Failed to create JSON body for fan speed report."
    return 1
  fi

  # Open TCP connection to Home Assistant
  exec 3<>/dev/tcp/"$HA_HOST"/"$HA_PORT" || {
    log_message "WARNING: Failed to connect to Home Assistant at $HA_HOST:$HA_PORT."
    return 1
  }

  printf 'POST %s HTTP/1.1\r\n' "$HA_API_ENDPOINT" >&3
  printf 'Host: %s:%s\r\n' "$HA_HOST" "$HA_PORT" >&3 # Add Host header for good measure
  printf 'Connection: close\r\nAuthorization: Bearer %s\r\n' "$SUPERVISOR_TOKEN" >&3
  printf 'Content-Type: application/json\r\n' >&3 # Explicitly set Content-Type
  printf 'Content-Length: %s\r\n\r\n%s' "${#body}" "$body" >&3

  # Read response with a timeout
  local response_line
  local http_status=""
  if read -t 5 -r response_line <&3; then
    http_status=$(echo "$response_line" | awk '{print $2}')
    log_message "DEBUG: HA API Response: $response_line"
    # Consume remaining lines to ensure connection closes cleanly
    while read -t 1 -r _; do :; done <&3
  else
    log_message "WARNING: No response from Home Assistant API within 5 seconds."
  fi

  exec 3>&- # Close file descriptor

  if [[ "$http_status" != "200" && "$http_status" != "201" ]]; then
    log_message "WARNING: Home Assistant API call failed with status $http_status for fan speed report."
    return 1
  fi
  log_message "Fan speed reported to Home Assistant: ${fanPercent}%"
}

#################################
# 5. Write fan PWM with fallback
#################################

# Sets the fan speed via I2C.
# Arguments: fanPercent, cpuTemp, unit, i2c_port
actionLinear() {
  local fanPercent="$1" cpuTemp="$2" unit="$3" i2c_port="$4"
  
  # Ensure fanPercent is within 0-100 range
  fanPercent=$(echo "$fanPercent" | bc -l) # Ensure it's treated as a number for comparison
  if (( $(echo "$fanPercent < 0" | bc -l) )); then
    fanPercent=0
  elif (( $(echo "$fanPercent > 100" | bc -l) )); then
    fanPercent=100
  fi
  
  # Convert to integer for hex conversion
  local fanPercentInt=$(printf "%.0f" "$fanPercent")
  local fanHex
  printf -v fanHex '0x%02x' "${fanPercentInt}"

  log_message "Current Temp: ${cpuTemp}${unit} – Fan Speed: ${fanPercentInt}% | hex:(${fanHex})"

  if ! i2cset -y "$i2c_port" "$I2C_ADDRESS_PRIMARY" "$fanHex" >/dev/null 2>&1; then
    if ! i2cset -y "$i2c_port" "$I2C_ADDRESS_SECONDARY" "$fanHex" >/dev/null 2>&1; then
      log_message "ERROR: I²C write failed on both $I2C_ADDRESS_PRIMARY and $I2C_ADDRESS_SECONDARY – Safe-Mode."
      return 1
    fi
  fi

  # Report to Home Assistant in background if enabled
  if [[ "$CREATE_ENTITY" == "true" ]]; then
    fanSpeedReportLinear "${fanPercentInt}" "${cpuTemp}" "${unit}" &
  fi
}

#################################
# 6. Read add-on options
#################################

# Reads configuration options from /data/options.json with fallbacks.
read_options() {
  MIN_TEMP=$(jq -r '."Minimum Temperature"' /data/options.json 2>/dev/null) || MIN_TEMP="$DEFAULT_MIN_TEMP"
  MAX_TEMP=$(jq -r '."Maximum Temperature"' /data/options.json 2>/dev/null) || MAX_TEMP="$DEFAULT_MAX_TEMP"
  CREATE_ENTITY=$(jq -r '."Create Entity"' /data/options.json 2>/dev/null) || CREATE_ENTITY="$DEFAULT_CREATE_ENTITY"
  TEMP_UNIT=$(jq -r '."Temperature Unit"' /data/options.json 2>/dev/null) || TEMP_UNIT="$DEFAULT_TEMP_UNIT"

  # Validate and normalize temperature settings
  if ! is_numeric "$MIN_TEMP"; then
    log_message "WARNING: Invalid 'Minimum Temperature' setting: '$MIN_TEMP'. Using default: $DEFAULT_MIN_TEMP"
    MIN_TEMP="$DEFAULT_MIN_TEMP"
  fi
  if ! is_numeric "$MAX_TEMP"; then
    log_message "WARNING: Invalid 'Maximum Temperature' setting: '$MAX_TEMP'. Using default: $DEFAULT_MAX_TEMP"
    MAX_TEMP="$DEFAULT_MAX_TEMP"
  fi

  # Ensure temperatures are floats for bc
  MIN_TEMP=$(echo "$MIN_TEMP" | bc -l)
  MAX_TEMP=$(echo "$MAX_TEMP" | bc -l)

  # Ensure min_temp is not greater than max_temp
  if (( $(echo "$MIN_TEMP > $MAX_TEMP" | bc -l) )); then
    log_message "WARNING: Minimum Temperature ($MIN_TEMP) is greater than Maximum Temperature ($MAX_TEMP). Swapping values."
    local temp_swap="$MIN_TEMP"
    MIN_TEMP="$MAX_TEMP"
    MAX_TEMP="$temp_swap"
  fi

  # Normalize CREATE_ENTITY to "true" or "false"
  if [[ "$CREATE_ENTITY" != "true" ]]; then
    CREATE_ENTITY="false"
  fi

  # Normalize TEMP_UNIT to "C" or "F"
  if [[ "$TEMP_UNIT" != "C" ]]; then
    TEMP_UNIT="F"
  fi

  log_message "Settings loaded: Min Temp=${MIN_TEMP}, Max Temp=${MAX_TEMP}, Create Entity=${CREATE_ENTITY}, Temp Unit=${TEMP_UNIT}"
}

#################################
# 7. Main execution
#################################

read_options
calibrateI2CPort

log_message "Argon One V5 Detected. Beginning monitor..."

while true; do
  # Read CPU temperature
  local cpuRaw
  cpuRaw=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
  if [[ -z "$cpuRaw" ]]; then
    log_message "ERROR: Could not read CPU temperature from /sys/class/thermal/thermal_zone0/temp. Retrying in 30s."
    sleep 30
    continue
  fi

  local cpuC
  cpuC=$(echo "scale=1; ${cpuRaw}/1000" | bc -l)
  if [[ $? -ne 0 ]]; then
    log_message "ERROR: Failed to calculate CPU temperature in Celsius using bc. Raw: ${cpuRaw}. Retrying in 30s."
    sleep 30
    continue
  fi

  local cpuTemp unit
  if [[ "$TEMP_UNIT" == "C" ]]; then
    cpuTemp="$cpuC"; unit="°C"
  else
    cpuTemp=$(echo "scale=1; ${cpuC}*9/5+32" | bc -l)
    if [[ $? -ne 0 ]]; then
      log_message "ERROR: Failed to calculate CPU temperature in Fahrenheit using bc. Celsius: ${cpuC}. Retrying in 30s."
      sleep 30
      continue
    fi
    unit="°F"
  fi

  local fan_speed
  # Decide fan speed using bc for float comparisons
  if (( $(echo "${cpuTemp} <= ${MIN_TEMP}" | bc -l) )); then
    fan_speed=0
  elif (( $(echo "${cpuTemp} >= ${MAX_TEMP}" | bc -l) )); then
    fan_speed=100
  else
    local range diff
    range=$(echo "scale=2; ${MAX_TEMP} - ${MIN_TEMP}" | bc -l)
    diff=$(echo  "scale=2; ${cpuTemp} - ${MIN_TEMP}" | bc -l)
    
    if (( $(echo "$range == 0" | bc -l) )); then
      log_message "WARNING: Temperature range is zero (${MIN_TEMP} - ${MAX_TEMP}). Setting fan to 0%."
      fan_speed=0
    else
      fan_speed=$(echo "scale=0; (${diff} * 100) / ${range}" | bc -l)
    fi
  fi

  actionLinear "${fan_speed}" "${cpuTemp}" "${unit}" "$I2C_PORT"
  sleep 30
done