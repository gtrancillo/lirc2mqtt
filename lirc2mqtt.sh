#!/bin/bash

mqtt_server="localhost"
mqtt_base_topic="lirc"
debug="1"
if [ -f "/data/lirc2mqtt.config" ]
then
  # Read parameters from config file
  eval "$( grep --regexp="^[a-z][a-z_]*='[^']*'" "/data/lirc2mqtt.config" )"
  if [ "${debug}" != "0" ]; then echo "Read parameters from '/data/lirc2mqtt.config'"; fi
else
  if [ -f "./example.config" ]
  then
    if [ "${debug}" != "0" ]; then echo "Create config file: /data/lirc2mqtt.config"; fi
    cp "./example.config" "/data/lirc2mqtt.config"
  fi
fi
invalidate_file=$( tempfile )

read_parameters()
{
  while [ $# -gt 0 ]       #Solange die Anzahl der Parameter ($#) größer 0
  do
    if [ "${debug}" != "0" ]; then echo "Option: $1"; fi
    option_name=$( echo $1 | sed "s#\(--.*=\).*\$#\1#" )
    option_value=$( echo $1 | sed "s#--.*=\(.*\)\$#\1#" )
    case "${option_name}" in
      "--mqtt-server=")
        mqtt_server="${option_value}"
      ;;
      "--mqtt-base-topic=")
        mqtt_base_topic="${option_value}"
      ;;
      "--debug=")
        debug="${option_value}"
      ;;
      "*")
        echo "Unknown command line option: \"$1\"" >&2
        exit 1
      ;;
    esac
    
    shift                  #Parameter verschieben $2->$1, $3->$2, $4->$3,...
  done
}

read_parameters "$@"

if [ "${debug}" != "0" ]
then
  echo "debug = ${debug}"
  echo "mqtt_server = ${mqtt_server}"
  echo "mqtt_base_topic = ${mqtt_base_topic}"
fi

# Parameter $1 is the remote defined in lirc.
# Parameter $2 is the line sent by mqtt.
interprete_mqtt_command()
{
  remote="$1"
  line="$2"
  if [ "${debug}" != "0" ]; then echo "interprete_mqtt_command( '${remote}', '${line}' )"; fi
  ##strip and remove brackets
  #line=$( echo "${line}" | sed "s#^ *\[\(.*\)\] *\$#\1#" )
  ##make it a line with quoted commands
  #options=$( echo "${line}" | sed  -e "s#[\"]##g" -e "s#[, ]#\" \"#g" -e "s#^#\"#;s#\$#\"#" )
  #if [ "${debug}" != "0" ]; then echo "Full command line is 'irsend send_once \"${remote}\" ${options}'."; fi
  ##Use xargs to interprete the options string as a list of strings
  #echo "SEND_ONCE \"${remote}\" ${options}" | xargs irsend
  #Possible commands:
  # { "send":"once", "commands": ["cmd1", "cmd2", "cmd1"] }
  # { "send":"hold", "time_msec":"1500", "commands": ["cmd1", "cmd2", "cmd1"] }
  #strip spaces
  send=$( echo "${line}" | jq --compact-output --raw-output ".send" )
  time_msec=$( echo "${line}" | jq --compact-output --raw-output ".time_msec" )
  commands=$( echo "${line}" | jq --compact-output '.commands | .[]' )
  if [ "${time_msec}" != "null"  -a  "$( echo "${time_msec}" | sed "s#[^0-9]*\([0-9]\+\).*#\1#" )" = "" ]
  then
    echo "The value of 'time_msec' has to contain a number. '${time_msec}' isn't a valid value" >&2
    return 1
  fi
  if [ "${time_msec}" != "null"  -a  "${time_msec}" != "" ]
  then
    if [ "${time_msec}" -ge "60000" ]
    then
      echo "The value of 'time_msec' is '${time_msec}' that's one minute or more. Will be clamped to 60 seconds."
      time_msec="60000"
    fi
  fi
  if [ "${commands}" = "" ]
  then
    echo "The attribute 'commands' needs to contain at least on key to send." >&2
    return 2
  fi

  if [ "${send}" = "hold" ]
  then
    if [ "${time_msec}" != "null" ]
    then
      echo "SEND_START \"${remote}\" ${commands}" | xargs irsend
      sleep "$( expr "${time_msec}" "/" "1000" ).$( expr "${time_msec}" "%" "1000" )"
      echo "SEND_STOP \"${remote}\" ${commands}" | xargs irsend
    else
      echo "On '{\"send\": \"hold\", ...}' the attribute 'time_msec' is needed as well." >&2
    fi
  fi
  if [ "${send}" = "once" ]
  then
    echo "SEND_ONCE \"${remote}\" ${commands}" | xargs irsend
  fi
  
  if [ "${send}" != "once"  -a  "${send}" != "hold" ]
  then
    echo "The attribute 'send' needs to have a value 'once' or 'hold'. '${send}' is not valid." >&2
    return 3
  fi
}


# Parameter $1 is the remote defined in Lirc.
loop_for_mqtt_set()
{
  remote="$1"
  if [ "${debug}" != "0" ]; then echo "loop_for_mqtt_set(${remote})"; fi
  echo "${remote}" | grep -q "[\\/ \"]"
  if [ "$?" = "0" -o "${remote}" = "" ]
  then
    echo "A remote named '${remote}' will not work in this system." >&2
    exit 2
  fi
  if [ "${debug}" != "0" ]; then echo "Remote name is OK '${remote}'. Getting commands..."; fi
  commands=$( irsend LIST "${remote}" "" | grep "." | sed "s#^[^ ]* ##" )
  if [ "${debug}" != "0" ]; then echo "List of commands in ${remote}:"; echo "${commands}"; fi
  for command in $( echo "${commands}" )
  do
    echo "${command}" | grep "[\\/ \"-\[\]]"
    if [ "$?" = "0" -o "${command}" = "" ]
    then
      echo "A remote command named '${command}' will not work in this system. (Found on remote '${remote}'.)" >&2
      exit 2
    fi
  done
  if [ "${debug}" != "0" ]; then echo "Start listening for '${mqtt_base_topic}/${remote}/send'."; fi
  while IFS= read -r line
  do
    echo "${remote}" "${line}"
    interprete_mqtt_command "${remote}" "${line}" &
  done < <( mqtt sub -h "${mqtt_server}" -t "${mqtt_base_topic}/${remote}/send" )
}

#MQTT test
mqtt_test_results=$( mqtt test -h "${mqtt_server}" )
if [ "${debug}" != "0" ]; then echo "${mqtt_test_results}"; fi
echo "${mqtt_test_results}" | grep -q "OK"
if [ "$?" != "0" ]
then
  echo "Mqtt failed to test host - exit script." >&2
  ping "${mqtt_server}" -c 1
  exit 3
fi

#Get all remotes defined in lirc
list_of_remotes=$( irsend LIST "" "" | grep "." )
num_remotes=$( echo "${list_of_remotes}" | grep -c "^..*" )

if [ "${debug}" != "0" ]; then echo "List of remotes:"; echo "${list_of_remotes}"; fi

#Start one process for each remote
#Potential concurrency problems will be solved, when irsend opens '/var/run/lirc/lircd' for writing.
counter="0"
for remote in $( echo "${list_of_remotes}" )
do
  counter=$( expr "${counter}" "+" "1" )
  if [ "${counter}" != "${num_remotes}" ]
  then
    loop_for_mqtt_set "${remote}" &
  else
    #The last remote is looped in main thread
    loop_for_mqtt_set "${remote}"
  fi
done
