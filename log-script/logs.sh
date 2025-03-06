#!/bin/bash

#Declaring global variables
DOWN_FILE=""
HEALTH_FILE=""
CPU_ALERT_FILE=""
MEMORY_ALERT_FILE=""
CPU_THRESHOLD_FILE=""
today=""

create_log_files() {
  find /logs/ -type f -mmin +0 -exec rm {} \; ##find /logs/ -type f -mtime +4 -exec rm {} \; ##replace the condition with this if you want to remove files that are 5 days old(test it before uncommenting)
  
  today=$(date +'%Y-%m-%d-%H:%M:%S')
  DOWN_FILE="/logs/container_down_${today}.prom"
  HEALTH_FILE="/logs/container_health_${today}.prom"
  CPU_ALERT_FILE="/logs/container_cpu_${today}.prom"
  MEMORY_ALERT_FILE="/logs/container_memory_${today}.prom"
  CPU_THRESHOLD_FILE="/logs/cpu_threshold_${today}.prom"

  files=("$DOWN_FILE" "$HEALTH_FILE" "$CPU_ALERT_FILE" "$MEMORY_ALERT_FILE" "$CPU_THRESHOLD_FILE")

  for file in "${files[@]}"; do
    touch "$file"

    dir_path="$(dirname "$file")"
      
    mkdir -p "$dir_path" || sudo mkdir -p "$dir_path"
      
    chmod 777 "$dir_path" || sudo chmod 777 "$dir_path"
  done  
}

create_log_files

#loop to create and delete log files
while true; do
  create_log_files
  sleep 60  # Wait for 1 minute before running again
  # current_time=$(date +%s)
  # next_midnight=$(date -d "tomorrow" +%s)
  # sleep_duration=$((next_midnight - current_time))
  # sleep $sleep_duration ##uncomment these 4 lines and remove the sleep 60 command to run this loop once every midnight
done&

IGNORE_CONTAINERS=("") # Add container names enclosed in double quotes as space-separated-values to be ignored    

docker events --format '{{.Status}} {{.Actor.Attributes.name}}' | while read event container; do
  if [[ "$event" == "stop" ]] && [[ ! " ${IGNORE_CONTAINERS[@]} " =~ " $container " ]]; then          
    echo "Detected stopped container: $container"

    # Fetch last 5 logs
    LOGS=$(docker logs --tail 5 "$container" 2>&1 | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/"/\\"/g'| tr '\n' ' ')

    TIMESTAMP=$(date +"%d-%b-%Y at %H:%M:%S")

    # Write logs to the file
    echo "container_down{name=\"$container\", logs=\"$LOGS\", stopped_at=\"$TIMESTAMP\"} 1" >> "$DOWN_FILE"

    if [[ $? -eq 0 ]]; then
      echo "Logs written to $DOWN_FILE"
    else
      echo "❌ Failed to write logs to $DOWN_FILE"
    fi
  elif [[ "$event" == "start" ]]; then
    if grep -q "name=\"$container\"" "$DOWN_FILE"; then
      echo "Removing logs for restarted container: $container"
      sed -i "/name=\"$container\"/d" "$DOWN_FILE"  
    fi 
  fi
done &

while true; do 
  grep -o 'name="[^"]*"' "$DOWN_FILE" | sed 's/name="//;s/"//' | while read logged_container; do #to keep track of containers that recovered while the monitoring stack is down
    if docker ps --filter "status=running" --filter "name=$logged_container" --format "{{.Names}}" | grep -q "$logged_container"; then
      echo "Removing down log for recovered container: $logged_container"
      sed -i "/name=\"$logged_container\"/d" "$DOWN_FILE"
    fi
  done

  docker ps --filter "status=exited" --format "{{.Names}}" | while read container; do #to keep track of containers that went down while monitoring stack is down
    if ! grep -q "name=\"$container\"" "$DOWN_FILE" && [[ ! " ${IGNORE_CONTAINERS[@]} " =~ " $container " ]]; then      
      echo "Detected exited container: $container"

      TIMESTAMP=$(date +"%d-%b-%Y at %H:%M:%S")
      LOGS=$(docker logs --tail 5 "$container" 2>&1 | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/"/\\"/g'| tr '\n' ' ')

      echo "container_exited{name=\"$container\", status=\"unhealthy\", logs=\"$LOGS\", detected_at=\"$TIMESTAMP\"} 1" >> "$DOWN_FILE"
      echo "Logs written to $DOWN_FILE"                
    fi
  done
  sleep 10
done&

while true; do
  # To track unhealthy containers
  docker ps --filter "health=unhealthy" --format "{{.Names}}" | while read container; do
    if ! grep -q "name=\"$container\"" "$HEALTH_FILE"; then
      echo "Detected unhealthy container: $container"

      TIMESTAMP=$(date +"%d-%b-%Y %H:%M:%S")
      LOGS=$(docker logs --tail 5 "$container" 2>&1 | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/"/\\"/g'| tr '\n' ' ')

      echo "docker_container_health_status{name=\"$container\", status=\"unhealthy\", logs=\"$LOGS\", detected_at=\"$TIMESTAMP\"} 1" >> "$HEALTH_FILE"
      echo "Health status written to $HEALTH_FILE"      
    fi
  done

  # Remove logs for containers that have recovered
  grep -o 'name="[^"]*"' "$HEALTH_FILE" | sed 's/name="//;s/"//' | while read logged_container; do
    if ! docker ps --filter "name=$logged_container" --filter "health=unhealthy" --format "{{.Names}}" | grep -q "$logged_container"; then
      echo "Removing health log for recovered container: $logged_container"
      sed -i "/name=\"$logged_container\"/d" "$HEALTH_FILE"
    fi
  done

  sleep 10  # Check every 10 seconds
done &

CPU_THRESHOLD=80
MEM_THRESHOLD=80
CPU_COUNT=$(nproc) #to get number of cpu cores on the host

while true; do  
  docker stats --no-stream --format "{{.Name}} {{.CPUPerc}} {{.MemPerc}}" | while read container cpu mem; do
    cpu=${cpu%\%}  # Remove % sign
    mem=${mem%\%}      
    cpu=$(echo "$cpu / $CPU_COUNT" | bc -l)    

    if (( $(echo "$cpu > $CPU_THRESHOLD" | bc -l) )); then
      if ! grep -q "name=\"$container\"" "$CPU_ALERT_FILE"; then 
        echo "🚨 High CPU Usage: $container is using $cpu% CPU"
        LOGS=$(docker logs --tail 5 "$container" 2>&1 | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/"/\\"/g'| tr '\n' ' ')
        TIMESTAMP=$(date +"%d-%b-%Y %H:%M:%S")
        echo "container_cpu_alert{name=\"$container\", usage=\"$cpu\", logs=\"$LOGS\", detected_at=\"$TIMESTAMP\"} 1" >> "$CPU_ALERT_FILE"
        echo "Logs written to $CPU_ALERT_FILE"
      fi
    else     
      if grep -q "name=\"$container\"" "$CPU_ALERT_FILE"; then
        echo "✅ CPU usage back to normal for $container. Removing alert log."
        sed -i "/name=\"$container\"/d" "$CPU_ALERT_FILE"
      fi
    fi

    if (( $(echo "$mem > $MEM_THRESHOLD" | bc -l) )); then
      if ! grep -q "name=\"$container\"" "$MEMORY_ALERT_FILE"; then      
        echo "🚨 High Memory Usage: $container is using $mem% memory"
        LOGS=$(docker logs --tail 5 "$container" 2>&1 | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/"/\\"/g' | tr '\n' ' ')
        TIMESTAMP=$(date +"%d-%b-%Y %H:%M:%S")  
        echo "container_memory_alert{name=\"$container\", usage=\"$mem\", logs=\"$LOGS\", detected_at=\"$TIMESTAMP\"} 1" >> "$MEMORY_ALERT_FILE"
        echo "Logs written to $MEMORY_ALERT_FILE"
      fi  
    else     
      if grep -q "name=\"$container\"" "$MEMORY_ALERT_FILE"; then
        echo "✅ Memory usage back to normal for $container. Removing alert log."
        sed -i "/name=\"$container\"/d" "$MEMORY_ALERT_FILE"
      fi
    fi
  done    

  sleep 10
done& 

while true; do
    TOTAL_CPU=0    
    while read container cpu; do
        cpu=${cpu%\%}  
        TOTAL_CPU=$(echo "$TOTAL_CPU + $cpu" | bc)            
    done < <(docker stats --no-stream --format "{{.Name}} {{.CPUPerc}}")   
    TOTAL_CPU=$(echo "$TOTAL_CPU / $CPU_COUNT" | bc -l) 

    if (( $(echo "$TOTAL_CPU > $CPU_THRESHOLD" | bc -l) )); then                   
        if [ ! -s "$CPU_THRESHOLD_FILE" ]; then          
          TIMESTAMP=$(date +"%d-%b-%Y %H:%M:%S")
          echo "🚨 High CPU Usage: Host is running at $TOTAL_CPU%"
          echo "cpu_threshold{detected_at=\"$TIMESTAMP\"} 1" > "$CPU_THRESHOLD_FILE"
          echo "Logs written to $CPU_THRESHOLD_FILE"
        fi
    else        
        if [ -s "$CPU_THRESHOLD_FILE" ]; then
            echo "✅ CPU usage is back to normal. Removing alert log."
            > "$CPU_THRESHOLD_FILE"  # Clears the file
        fi
    fi
    
    sleep 10
done