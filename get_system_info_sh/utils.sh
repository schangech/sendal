#!/bin/bash

function push_to_falcon() {
    local ret_code=$(curl -s -m 180 -w %{http_code} -X POST -d "$1" http://127.0.0.1:1988/v1/push -o /dev/null)
    if [ ${ret_code} -eq 200 ]; then
        echo "push to falcon successfully"
        return 0
    else
        echo "push to falcon failed"
        return 1
    fi
}

# print metric data to std out
function echo_metric() {
    echo '{"endpoint": "'$(hostname)'", "metric": "'${1}'", "timestamp": '$(date +%s)', "step": 60, "value": '${2}', "counterType": "GAUGE", "tags": "'${3}'"},'
}

function install_tool() {
    local command=${1}
    local tool=${2}
    type ${command} &> /dev/null
    local ret_val=$?
    if [ ${ret_val} -eq 0 ]; then
        echo_metric "yum.install.status" 0 "name=${tool},project=cmdb"
        return 0
    fi
    yum install -y ${tool} &> /dev/null
    local ret_val=$?
    if [ ${ret_val} -eq 0 ]; then
        echo_metric "yum.install.status" 0 "name=${tool},project=cmdb"
        return 0
    fi
    echo_metric "yum.install.status" 1 "name=${tool},project=cmdb"
    return ${ret_val}
}

function read_smartctl_data() {
    local device=${1}
    while read line; do
        if [ $(echo ${line} | grep -c "failed: No such device") -gt 0 ]; then
            echo_metric "smart.info" 1 "device=${device},name=SMARTHealthStatus"
        elif [ $(echo ${line} | grep -Ec "Vendor:"\|"Device Model:") -gt 0 ]; then
            local model=$(echo ${line} | awk -F : '{sub(/^ /, "", $2);print $2}')
        elif [ $(echo ${line} | grep -c "Product:") -gt 0 ]; then
            local product=$(echo ${line} | awk -F : '{sub(/^ /, "", $2);print $2}')
            local model="${model} ${product}"
        elif [ $(echo ${line} | grep -ic "Serial Number:") -gt 0 ]; then
            local serial=$(echo ${line} | awk -F : '{sub(/^ /, "", $2);print $2}')
        elif [ $(echo ${line} | grep -c "User Capacity:") -gt 0 ]; then
            local volume=$(echo ${line} | awk '{gsub(",", "", $3);print int($3/1000000000)}')
        elif [ $(echo ${line} | grep -c "Rotation Rate:") -gt 0 ]; then
            if [ $(echo ${line} | grep -ic "Solid State Device") -gt 0 ]; then
                local rotation_rate="null"
            else
                local rotation_rate=$(echo ${line} | awk '{print $3}')
            fi
        elif [ $(echo ${line} | grep -c "Form Factor:") -gt 0 ]; then
            local form_factor=$(echo ${line} | awk '{print $3}')
        elif [ $(echo ${line} | grep -Ec "SMART Health Status:"\|"SMART overall-health self-assessment test result:") -gt 0 ]; then
            local disk_health=$(echo ${line} | grep -Evc "OK"\|"PASSED")
            echo_metric "smart.info" ${disk_health} "device=${device},name=SMARTHealthStatus"
        elif [ $(echo ${line} | grep -c "Current Drive Temperature:") -gt 0 ]; then
            local current_drive_temperature=$(echo ${line} | awk '{print $4}')
            echo_metric "smart.info" ${current_drive_temperature} "device=${device},name=CurrentDriveTemperature"
        elif [ $(echo ${line} | grep -c "Drive Trip Temperature:") -gt 0 ]; then
            local drive_trip_temperatrue=$(echo ${line} | awk '{print $4}')
            echo_metric "smart.info" ${drive_trip_temperatrue} "device=${device},name=DriveTripTemperature"
        elif [ $(echo ${line} | grep -c "Power_On_Hours") -gt 0 ]; then
            local power_on_hours=$(echo ${line} | awk '{if (index($10, "h") > 0) {print substr($10, 1, index($10, "h") -1)} else print $10}')
        elif [ $(echo ${line} | grep -c "number of hours powered up") -gt 0 ]; then
            local power_on_hours=$(echo ${line} | awk '{print int($NF)}')
        elif [ $(echo ${line} | grep -c "Airflow_Temperature_Cel") -gt 0 ]; then
            local airflow_temperature=$(echo ${line} | awk '{print $10}')
            echo_metric "smart.info" ${airflow_temperature} "device=${device},name=AirflowTemperatureCel"
        elif [ $(echo ${line} | grep -c "Temperature_Celsius") -gt 0 ]; then
            local temperature_celsius=$(echo ${line} | awk '{print $10}')
            echo_metric "smart.info" ${temperature_celsius} "device=${device},name=TemperatureCelsius"
        else
            continue
        fi
    done < ${2}
    echo '            "volume":' ${volume}',' >> ${machine_data}
    echo '            "model":' '"'${model}'",' >> ${machine_data}
    echo '            "serial":' '"'${serial}'",' >> ${machine_data}
    echo '            "rotation_rate":' ${rotation_rate:-null}',' >> ${machine_data}
    echo '            "form_factor":' ${form_factor:-null}',' >> ${machine_data}
    echo '            "power_on_hours":' ${power_on_hours:-null} >> ${machine_data}
}


function check_with_smartctl() {
    mkdir -p ./tmp
    local fdisk_data=./tmp/fdisk.dat
    fdisk -l | grep -E "Disk /dev/sd"\|"Disk /dev/vd" > ${fdisk_data}
    local counter=0
    while read line; do
        local storage_label=$(echo ${line} | awk '{print $2}')
        local storage_label=${storage_label%%:}
        local device=${storage_label#/dev/}
        local volume=$(echo ${line} | awk '{print int($5/1000000000)}')
        local rotational=$(cat /sys/block/${storage_label#/dev/}/queue/rotational)
        if [ ${rotational} -eq 0 ]; then
            local media="SSD"
        else
            local media="HDD"
        fi
        if [ ${counter} -gt 0 ]; then
            echo '        },' >> ${machine_data}
        fi
        echo '        {' >> ${machine_data}
        echo '            "media":' ${rotational}',' >> ${machine_data}
        local smartctl_device_data=./tmp/smartctl_${device}.dat
        smartctl -a ${storage_label} > ${smartctl_device_data}
        read_smartctl_data ${device} ${smartctl_device_data}
        counter=$((counter+1))
    done < ${fdisk_data}
    if [ ${counter} -gt 0 ]; then
        echo '        }' >> ${machine_data}
    fi
    echo '    ],' >> ${machine_data}
}

function check_disk() {
    # check if smartmontools is installed
    install_tool "smartctl" "smartmontools"
    local ret_val=$?
    if [ ${ret_val} -ne 0 ]; then
        return 1
    fi
    echo '    "storage": [' >> ${machine_data}
    mkdir -p ./tmp
    local megaraid_data=./tmp/megaraid.dat
    [ -f /opt/MegaRAID/MegaCli/MegaCli64 ] && /opt/MegaRAID/MegaCli/MegaCli64 -PDList -aALL | grep -E "Device Id:"\|"Media Type:" > ${megaraid_data}
    if [ -s ${megaraid_data} ]; then
        local counter=0
        while read line; do
            if [ $(echo ${line} | grep -c "Device Id:") -gt 0 ]; then
                local device_id=$(echo ${line} | awk '{print $3}')
            elif [ $(echo ${line} | grep -c "Media Type:") -gt 0 ]; then
                if [ $(echo ${line} | grep -c "Solid State Device") -gt 0 ]; then
                    local media=0
                elif [ $(echo ${line} | grep -c "Hard Disk Device") -gt 0 ]; then
                    local media=1
                else
                    local media=1
                fi
                if [ ${counter} -gt 0 ]; then
                    echo '        },' >> ${machine_data}
                fi
                echo '        {' >> ${machine_data}
                echo '            "media":' ${media}',' >> ${machine_data}
                local smartctl_megaraid_data=./tmp/smartctl_device_${device_id}.dat
                smartctl -d megaraid,${device_id} -a /dev/sda > ${smartctl_megaraid_data}
                if [ $(cat ${smartctl_megaraid_data} | grep -c "failed: No such device") -gt 0 ]; then
                    echo_metric "smart.info" 1 "device=sda,name=SMARTHealthStatus"
                    smartctl -d megaraid,${device_id} -a /dev/sdb > ${smartctl_megaraid_data}
                fi
                if [ $(cat ${smartctl_megaraid_data} | grep -c 'open device.*failed') -gt 0 ]; then
                    smartctl $(grep -oP "\\-d.+megaraid" ${smartctl_megaraid_data}),${device_id} -a /dev/sda > ${smartctl_megaraid_data}
                fi
                read_smartctl_data ${device_id} ${smartctl_megaraid_data}
                counter=$((counter+1))
            else
                continue
            fi
        done < ${megaraid_data}
        if [ ${counter} -gt 0 ]; then
            echo '        }' >> ${machine_data}
        fi
        echo '    ],' >> ${machine_data}
    else
        check_with_smartctl
    fi
}