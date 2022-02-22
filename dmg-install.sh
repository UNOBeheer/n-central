#!/bin/bash

SECRET_VALUE="*****"
SRC=MacAgentInstallation.dmg

while getopts 'k:c:i:s:p:a:x:r:t:P:T:D:V:' OPTION
do
    case ${OPTION} in
    k)
        ACTIVATE_KEY=${OPTARG}
        ;;
    c)
        CUSTOMER_NAME=${OPTARG}
        ;;
    i)
        CUSTOMER_ID=${OPTARG}
        ;;
    s)
        SERVER=${OPTARG}
        ;;
    p)
        PROTOCOL=${OPTARG}
        ;;
    a)
        PORT=${OPTARG}
        ;;
    x)
        PROXY=${OPTARG}
        ;;
    t)
        REGISTRATION_TOKEN=${OPTARG}
        ;;
    T)
        SRC=${OPTARG}
        ;;
    *)
        echo "Unknown option: '${OPTION}'"
        ;;
    esac
done
if [[ ! -f ${SRC} ]]; then
    echo "Disk image ${SRC} does not exists"
    exit 1
fi
# Default Values for port and protocol
if [[ -z ${PORT} ]]; then
    PORT=443
fi
if [[ -z ${PROTOCOL} ]]; then
    PROTOCOL=https
fi

usage() {
    cat <<EOF
    Usage:
    To install with an activation key, retrieved from the central server
    sudo dmg-install.sh -k <activation key>

    To install with a Customer Name and Customer ID
    sudo dmg-install.sh -s <server endpoint ip/fqdn> -c <customer name> -i <customer id> -t <registration token>
    NB:  Customer name may need to be quoted if it contains spaces or shell meta-characters

    Other Flags for the Customer Specific Installer
    -p Specify the protocol for the agent to use (default https)
    -a Specify the port for the agent to use (default 443)
    -x Specify an http proxy for the agent to use
EOF
}

decode_key() {
    DecodedKey=$(echo "$1" | openssl enc -base64 -d -A)

    # decoded key format:  https://warsteiner.lab2.n-able.com:443|37683|1|0
    uri=$( echo -n "${DecodedKey}" | awk -F"|" '{print $1}' )
    APPLIANCE=$( echo -n "${DecodedKey}" | awk -F"|" '{print $2}' )
    REGISTRATION_TOKEN=$( echo -n "${DecodedKey}" | awk -F"|" '{print $4}' )
    PROTOCOL=$( echo -n "${uri}" | awk -F":" '{print $1}' )
    SERVER=$( echo -n "${uri}" | awk -F":" '{print $2}' | sed -e 's!^//!!' )
    PORT=$( echo -n "${uri}" | awk -F":" '{print $3}' )
}

if [[ -z ${SERVER} || -z ${CUSTOMER_NAME} || -z ${CUSTOMER_ID} || -z ${REGISTRATION_TOKEN} ]]; then
    if [[ -n ${ACTIVATE_KEY} ]]; then
        decode_key "${ACTIVATE_KEY}"
    else
        usage
        exit 1
    fi
fi

hdiutil mount "${SRC}"
if [[ ! -d /Applications/Mac_Agent.app ]]; then
    mkdir /Applications/Mac_Agent.app
fi
cp -fR "/Volumes/Mac Agent Installation/.Mac_Agent.app/Contents" /Applications/Mac_Agent.app/
hdiutil unmount "/Volumes/Mac Agent Installation"
chown -R root /Applications/Mac_Agent.app/
chgrp -R wheel /Applications/Mac_Agent.app/
validate_path=/Applications/Mac_Agent.app/Contents/Daemon/usr/sbin/InitialValidate
if [[ -n ${SERVER} && -n ${PORT} && -n ${PROTOCOL} ]]; then
    validate_command="sudo \"${validate_path}\" -s ${SERVER} -n ${PORT} -p ${PROTOCOL} "
else
    echo "Not valid activation key"
fi
if [[ -n ${PROXY} ]]; then
    validate_command=${validate_command}"-x ${PROXY} "
fi
if [[ -n ${CUSTOMER_ID} && -n ${CUSTOMER_NAME} && -n ${REGISTRATION_TOKEN} ]]; then
    command_to_print_out=${validate_command}" -f /tmp/nagent.conf -i ${CUSTOMER_ID} -c \"${CUSTOMER_NAME}\" -t ${SECRET_VALUE} -l /tmp/nagent_install_log"
    validate_command=${validate_command}" -f /tmp/nagent.conf -i ${CUSTOMER_ID} -c \"${CUSTOMER_NAME}\" -t ${REGISTRATION_TOKEN} -l /tmp/nagent_install_log"
elif [[ -n ${APPLIANCE} ]]; then
    command_to_print_out=${validate_command}" -f /tmp/nagent.conf -a ${APPLIANCE} -t ${SECRET_VALUE} -l /tmp/nagent_install_log"
    validate_command=${validate_command}" -f /tmp/nagent.conf -a ${APPLIANCE} -t ${REGISTRATION_TOKEN} -l /tmp/nagent_install_log"
else
    usage
    exit 1
fi

if [[ -n ${command_to_print_out} ]]; then
    echo "${command_to_print_out}"
else
    echo "${validate_command}"
fi

# Cleanup
rm -f /tmp/nagent.conf
return_code=0
# Run validate command and install upon success
eval "${validate_command}"
return_code=$?
# On failure display error message
if [[ ${return_code} -gt 0 ]]; then
    echo "Could not successfully self-register agent"
    case ${return_code} in
        10)
            echo "Could not connect to N-central server"
            ;;
        11)
            echo "Invalid Customer Name"
            ;;
        12)
            echo "Invalid Customer ID"
            ;;
        13)
            echo "Invalid Appliance ID"
            ;;
        14)
            echo "Local Asset Discovery failed, check /tmp/nagent_install_log for more details"
            ;;
        15)
            echo "The N-central server cannot register the agent"
            ;;
        16)
            echo "Unable to create Configuration file"
            ;;
        17)
            echo "Unable to create log file"
            ;;
        *)
            usage
            echo "Unknown Error occurred, check /tmp/nagent_install_log for more details"
            ;;
    esac
    /Applications/Mac_Agent.app/Contents/Daemon/usr/sbin/uninstall-nagent y
    exit 1
fi
echo "Update nagent.conf"
cat <<EOF >> /tmp/nagent.conf
    logfilename=/var/log/N-able/N-agent/nagent.log
    loglevel=3
    homedir=/Applications/Mac_Agent.app/Contents/Daemon/home/nagent/
    thread_limitation=50 
    poll_delay=1
    datablock_size=20
EOF
cp -f /tmp/nagent.conf /Applications/Mac_Agent.app/Contents/Daemon/etc/
rm -f /tmp/nagent.conf
cp -f /Applications/Mac_Agent.app/Contents/Daemon/etc/*.plist /Library/LaunchDaemons/
launchctl load /Library/LaunchDaemons/com.n-able.agent-macosx.plist
launchctl load /Library/LaunchDaemons/com.n-able.agent-macosx.logrotate-daily.plist
echo "The install was successful."
