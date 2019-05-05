#!/bin/bash
export LANG="en_US.UTF-8"
export PATH=$PATH:/usr/sbin/
current_dir=$(dirname $0)
cd ${current_dir} && source ./utils.sh || exit 1

readonly TOKEN="61c8af7afd24853995cf679f5f84258d87204aa1"
readonly RENAME_URL="http://192.168.21.142:8000/api/rename/"
readonly RENAME_STATUS_URL="http://192.168.21.142:8000/api/updateRenameStatus/"
readonly FALCON_HOST_GROUP_URL="http://192.168.21.144:28080/v1/service/cmdb.plugin.sm/instance"
readonly UPLOAD_URL="http://192.168.21.142:8000/api/machine/"

mkdir -p ./tmp
machine_data=./tmp/machine.dat

function rename() {
    local rename_data=./tmp/rename.dat
    local uuid=$(dmidecode -s system-uuid)
    local rename_url="${RENAME_URL}?machine__uuid=${uuid}&old=$(hostname)&status=0"
    local ret_val=$(curl -s -m 180 -w %{http_code} -H "Content-Type: application/json" -H "Authorization: Token ${TOKEN}" "${rename_url}" -o ${rename_data})
    if [ ${ret_val} -ne 200 ]; then
        echo_metric "falcon.plugin.status" 1 "name=rename,project=cmdb"
        return 1
    fi
    if [ "$(cat ${rename_data})" = "[]" ]; then
        echo_metric "falcon.plugin.status" 0 "name=rename,project=cmdb"
        return 0
    fi
    for line in $(cat ${rename_data} | awk '{len=split($0, arr, ",");for(i=1;i<=len;i++) print arr[i]}'); do
        if [ $(echo ${line} | grep -c '"id":') -gt 0 ]; then
            local id=$(echo ${line} | awk -F : '{print $2}')
        elif [ $(echo ${line} | grep -c '"old":') -gt 0 ]; then
            local old=$(echo ${line} | awk -F : '{print substr($2, 2, length($2) -2)}')
        elif [ $(echo ${line} | grep -c '"new":') -gt 0 ]; then
            local new=$(echo ${line} | awk -F : '{print substr($2, 2, length($2) -2)}')
        else
            continue
        fi
    done
    if [ "${old}" = "$(hostname)" ] && [ -n "${id}" ] && [ -n "${new}" ]; then
        if [ "${old}" = "${new}" ]; then
            return 0
        fi
        local rename_lock=./tmp/rename.lock
        if [ -f ${rename_lock} ]; then
            echo_metric "falcon.plugin.status" 1 "name=rename,project=cmdb"
            return 1
        else
            touch ${rename_lock}
        fi
        if [ -d /etc/NetworkManager/conf.d/ ] && [ ! -f /etc/NetworkManager/conf.d/nodns.conf ]; then
            echo -e "[main]\ndns=none" > /etc/NetworkManager/conf.d/nodns.conf
            if [ $(ps -ef | grep '/usr/sbin/NetworkManager' | grep -v grep | wc -l) -gt 0 ]; then
                systemctl restart NetworkManager
                if [ $? -ne 0 ]; then
                    echo_metric "falcon.plugin.status" 1 "name=rename,project=cmdb"
                    return 1
                fi
            fi
        fi
        if [ -f /etc/NetworkManager/conf.d/nodns.conf ]; then
            local rename_status_url="${RENAME_STATUS_URL}${id}/"
            cp -f /etc/resolv.conf ./tmp/resolv.conf
            hostnamectl --static set-hostname ${new}
            if [ $? -ne 0 ]; then
                echo_metric "falcon.plugin.status" 1 "name=rename,project=cmdb"
                local ret_val=$(curl -s -m 180 -w %{http_code} -H "Content-Type: application/json" -H "Authorization: Token ${TOKEN}" -X PATCH -d '{"status": 2}' "${rename_status_url}" -o /dev/null)
                return 1
            fi
            local ret_val=$(curl -s -m 180 -w %{http_code} -H "Content-Type: application/json" -H "Authorization: Token ${TOKEN}" -X PATCH -d '{"status": 1}' "${rename_status_url}" -o /dev/null)
            if [ ${ret_val} -ne 200 ]; then
                echo_metric "falcon.plugin.status" 1 "name=rename,project=cmdb"
                return 1
            fi
            local ret_val=$(curl -s -m 180 -w %{http_code} -H 'Content-Type: application/json' -X PATCH -d '{"hosts": ["'${new}'"], "action": "add"}' "${FALCON_HOST_GROUP_URL}" -o /dev/null)
            if [ ${ret_val} -ne 200 ]; then
                echo_metric "falcon.plugin.status" 1 "name=rename,project=cmdb"
                return 1
            fi
        fi
        echo_metric "falcon.plugin.status" 0 "name=rename,project=cmdb"
        rm -f ${rename_lock}
    else
        echo_metric "falcon.plugin.status" 1 "name=rename,project=cmdb"
        return 1
    fi
}

function gather_cpu_info () {
    local physical_cpu_count=$(cat /proc/cpuinfo | grep "physical id" | sort | uniq | wc -l)
    local logic_cpu_cores=$(cat /proc/cpuinfo | grep "processor" | wc -l)
    local cpu_core=$(cat /proc/cpuinfo | grep "cpu cores" | uniq | awk -F : '{print $NF}')
    local cpu_name=$(cat /proc/cpuinfo | grep name | awk -F: '{print $NF}'| uniq)
    if [ $(echo ${cpu_name} | grep -c "GHz") -gt 0 ]; then
        local trimed_cpu_name=${cpu_name%@*}
        local trimed_cpu_name=${trimed_cpu_name%% }
        local trimed_cpu_name=${trimed_cpu_name## }
        local cpu_frequency=${cpu_name#*@}
    else
        local trimed_cpu_name=${cpu_name}
        local trimed_cpu_name=${trimed_cpu_name%% }
        local trimed_cpu_name=${trimed_cpu_name## }
    fi
    if [ -z "${cpu_frequency}" ]; then
        cpu_frequency=$(cat /proc/cpuinfo | grep MHz | uniq | awk -F : '{printf("%.2f\n", $NF/1000)}')
    fi
    cpu_frequency=${cpu_frequency%GHz}
    echo '    "physical_cpu_count":' ${physical_cpu_count}',' >> ${machine_data}
    echo '    "cpu_core":' ${cpu_core}',' >> ${machine_data}
    echo '    "logic_cpu_cores":' ${logic_cpu_cores}',' >> ${machine_data}
    echo '    "cpu_name":' '"'${trimed_cpu_name}'",' >> ${machine_data}
    echo '    "cpu_frequency":' ${cpu_frequency}',' >> ${machine_data}
}

function gather_os_info () {
    install_tool "dmidecode" "dmidecode"
    local ret_val=$?
    if [ ${ret_val} -ne 0 ]; then
        return ${ret_val}
    fi
    local manufacturer=$(dmidecode -s system-manufacturer)
    local product_name=$(dmidecode -s system-product-name)
    local serial=$(dmidecode -s system-serial-number)
    local uuid=$(dmidecode -s system-uuid)
    if [ -f /etc/redhat-release ]; then
        local os_name=$(cat /etc/redhat-release)
    else
        local os_name=$(grep PRETTY_NAME /etc/os-release | awk -F = '{print substr($2,2,length($2)-2)}')
    fi
    local kernel=$(uname -r)
    echo '    "manufacturer":' '"'${manufacturer}'",' >> ${machine_data}
    echo '    "product_name":' '"'${product_name}'",' >> ${machine_data}
    echo '    "serial":' '"'${serial}'",' >> ${machine_data}
    echo '    "uuid":' '"'${uuid}'",' >> ${machine_data}
    echo '    "os":' '"'${os_name%% }'",' >> ${machine_data}
    echo '    "kernel":' '"'${kernel}'",' >> ${machine_data}
}

function gather_nic_info () {
    install_tool "lspci" "pciutils"
    local ret_val=$?
    if [ ${ret_val} -ne 0 ]; then
        return ${ret_val}
    fi
    echo '    "nic": [' >> ${machine_data}
    local counter=0
    for nic in $(cat /proc/net/dev | grep -E ^\(\\s\)*e | awk -F : '{print $1}' | sort); do
        local nic_name=$(lspci | grep "^$(ethtool -i ${nic} | awk -F":" '/bus-info/{print $(NF-1)":"$NF}')" | awk -F : '{sub(/^ /, "", $NF); print $NF}')
        if [ -z "${nic_name}" ]; then
            continue
        fi
        if [ $(ethtool ${nic} | grep -c "Supported link modes:   Not reported") -gt 0 ]; then
            local capability=$(ethtool ${nic} | grep -B1 "Advertised pause frame use" | grep -v "Advertised pause frame use" | awk '{print substr($NF,1,index($NF,"baseT/Full")-1)}')
        else
            local capability=$(ethtool ${nic} | grep -B1 "Supported pause frame use" | grep -v "Supported pause frame use" | awk '{print substr($NF,1,index($NF,"baseT/Full")-1)}')
        fi
        if [ -z "${capability}" ]; then
            capability=100
        fi
        if [ ${counter} -gt 0 ]; then
            echo '        },' >> ${machine_data}
        fi
        echo '        {' >> ${machine_data}
        echo '            "name":' '"'${nic_name}'",' >> ${machine_data}
        echo '            "capability":' ${capability} >> ${machine_data}
        counter=$((counter+1))
    done
    if [ ${counter} -gt 0 ]; then
        echo '        }' >> ${machine_data}
    fi
    echo '    ],' >> ${machine_data}
}

function gather_ip_info () {
    echo '    "ip": [' >> ${machine_data}
    local counter=0
    for ip_address in $(ip -f inet addr | grep inet | grep -Ev '127.0.0.1'\|'flannel'\|'docker'\|'virbr'\|'lo:'\|'br-' | awk '{if(index($2,"addr:")>0){print substr($2,6,index($2,"/")-6)}else{print substr($2,1,index($2,"/")-1)}}' | sort | uniq); do
        if [ ${counter} -gt 0 ]; then
            echo '        },' >> ${machine_data}
        fi
        echo '        {' >> ${machine_data}
        echo '            "address":' '"'${ip_address}'"' >> ${machine_data}
        counter=$((counter+1))
    done
    if [ ${counter} -gt 0 ]; then
        echo '        }' >> ${machine_data}
    fi
    echo '    ],' >> ${machine_data}
}

function gather_storage_info () {
    # from utils.sh
    check_disk
}

function gather_memory_info () {
    mkdir -p ./tmp
    echo '    "memory": [' >> ${machine_data}
    local counter=0
    local memory_data=./tmp/memory.dat
    dmidecode -t memory > ${memory_data}
    while read line; do
        if [ $(echo ${line} | grep -c "Size:") -gt 0 ]; then
            local size=$(echo ${line} | awk  '{if($3=="GB") {print $2} else print $2/1024}')
        elif [ $(echo ${line} | grep -c "^Type:") -gt 0 ]; then
            local model="$(echo ${line} | awk -F : '{sub(/^ /, "", $2);print $2}')"
        elif [ $(echo ${line} | grep -c "^Speed:") -gt 0 ]; then
            local speed=$(echo ${line} | awk '{if ($2 ~/^[0-9]+$/ && $3=="MHz") print $2}')
        elif [ $(echo ${line} | grep -c "Manufacturer:") -gt 0 ]; then
            local manufacturer=$(echo ${line} | awk -F : '{sub(/^ /, "", $2); print $2}')
        elif [ $(echo ${line} | grep -c "Serial Number:") -gt 0 ]; then
            local serial=$(echo ${line} | awk -F : '{sub(/^ /, "", $2); print $2}')
        elif [ $(echo ${line} | grep -c "Memory Device") -gt 0 ]; then
            if [ -n "${size}" ] && [ ${size} -gt 0 ]; then
                if [ ${counter} -gt 0 ]; then
                    echo '        },' >> ${machine_data}
                fi
                echo '        {' >> ${machine_data}
                echo '            "size":' ${size}',' >> ${machine_data}
                echo '            "model":' '"'${model}'",' >> ${machine_data}
                echo '            "speed":' ${speed:-null}',' >> ${machine_data}
                echo '            "manufacturer":' '"'${manufacturer}'",' >> ${machine_data}
                echo '            "serial":' '"'${serial}'"' >> ${machine_data}
                counter=$((counter+1))
            fi
        else
            continue
        fi
    done < ${memory_data}
    if [ -n "${size}" ] && [ ${size} -gt 0 ]; then
        if [ ${counter} -gt 0 ]; then
            echo '        },' >> ${machine_data}
        fi
        echo '        {' >> ${machine_data}
        echo '            "size":' ${size}',' >> ${machine_data}
        echo '            "model":' '"'${model}'",' >> ${machine_data}
        echo '            "speed":' ${speed:-null}',' >> ${machine_data}
        echo '            "manufacturer":' '"'${manufacturer}'",' >> ${machine_data}
        echo '            "serial":' '"'${serial}'"' >> ${machine_data}
        echo '        }' >> ${machine_data}
    else
        if [ ${counter} -gt 0 ]; then
            echo '        }' >> ${machine_data}
        fi
    fi
    echo '    ],' >> ${machine_data}
}

function gather_mount_info() {
    echo '    "mount": [' >> ${machine_data}
    df_data=./tmp/df.dat
    blkid_data=./tmp/blkid.dat
    if [ -f ${df_data} ]; then
        mv ${df_data} ${df_data}.bak
    fi
    df -h | grep -Ev "Filesystem"\|"kubernetes"\|"docker"\|"tmpfs" | awk '{print $1" "$NF}' | sort > ${df_data}
    blkid > ${blkid_data}
    local updated=1
    if [ -f ${df_data}.bak ]; then
        diff ${df_data} ${df_data}.bak &> /dev/null
        updated=$?
    fi
    local counter=0
    while read device path; do
        # check if device is healthy
        ls ${path} &> /dev/null
        local ret_val=$?
        if [ ${ret_val} -ne 0 ]; then
            echo_metric "device.health" 1 "device=${device},path=${path},name=command"
        else
            echo_metric "device.health" 0 "device=${device},path=${path},name=command"
        fi
        if [ ${updated} -eq 0 ]; then
            continue
        fi
        for item in $(grep "^${device}:" ${blkid_data}); do
            if [ $(echo ${item} | grep -c "^UUID") -gt 0 ]; then
                local uuid=$(echo ${item} | awk -F = '{print substr($2, 2, length($2) - 2)}')
            elif [ $(echo ${item} | grep -c "^TYPE") -gt 0 ]; then
                local filesystem=$(echo ${item} | awk -F = '{print substr($2, 2, length($2) - 2)}')
            elif [ $(echo ${item} | grep -c "^PARTUUID") -gt 0 ]; then
                local partuuid=$(echo ${item} | awk -F = '{print substr($2, 2, length($2) - 2)}')
            else
                continue
            fi
        done
        if [ ${counter} -gt 0 ]; then
            echo '        },' >> ${machine_data}
        fi
        echo '        {' >> ${machine_data}
        echo '            "device": ''"'${device}'",' >> ${machine_data}
        echo '            "path": ''"'${path}'",' >> ${machine_data}
        echo '            "filesystem": ''"'${filesystem}'",' >> ${machine_data}
        echo '            "uuid": ''"'${uuid}'",' >> ${machine_data}
        echo '            "partuuid": ''"'${partuuid}'"' >> ${machine_data}
        counter=$((counter+1))
    done < ${df_data}
    if [ ${counter} -gt 0 ]; then
        echo '        }' >> ${machine_data}
    fi
    echo '    ]' >> ${machine_data}
}

function upload () {
    local updated=1
    if [ -f ${machine_data}.bak ]; then
        diff ${machine_data} ${machine_data}.bak &> /dev/null
        updated=$?
    fi
    if [ ${updated} -ne 0 ]; then
        local ret_val=$(curl -s -m 180 -w %{http_code} -H "Content-Type: application/json" -H "Authorization: Token ${TOKEN}" -X POST -d "$(cat ${machine_data})" "${UPLOAD_URL}" -o /dev/null)
        if [ ${ret_val} -ne 200 ]; then
            return 1
        fi
    fi
}

function main() {
    rename
    local ret_val=$?
    if [ ${ret_val} -ne 0 ]; then
        return ${ret_val}
    fi
    if [ -f ${machine_data} ]; then
        mv ${machine_data} ${machine_data}.bak
    fi
    echo '{' > ${machine_data}
    echo '    "hostname":' '"'$(hostname)'",' >> ${machine_data}
    gather_cpu_info
    gather_os_info
    local ret_val=$?
    if [ ${ret_val} -ne 0 ]; then
        return ${ret_val}
    fi
    gather_nic_info
    local ret_val=$?
    if [ ${ret_val} -ne 0 ]; then
        return ${ret_val}
    fi
    gather_ip_info
    gather_storage_info
    gather_memory_info
    gather_mount_info
    echo '}' >> ${machine_data}
    upload
    if [ $? -ne 0 ]; then
        rm -f ${machine_data} ${machine_data}.bak
        return 1
    fi
}

main
