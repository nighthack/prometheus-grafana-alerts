#!/bin/bash

DOWN_FILE="/logs/container_down.prom"
HEALTH_FILE="/logs/container_health.prom"
CPU_ALERT_FILE="/logs/container_cpu.prom"
MEMORY_ALERT_FILE="/logs/container_memory.prom"
CPU_THRESHOLD_FILE="/logs/cpu_threshold.prom"

  
today=$(date +'%Y-%m-%d')
STORAGE_FILE="/storage_logs/log_${today}.log"

files=("$DOWN_FILE" "$HEALTH_FILE" "$CPU_ALERT_FILE" "$MEMORY_ALERT_FILE" "$CPU_THRESHOLD_FILE" "$STORAGE_FILE")

for file in "${files[@]}"; do
  touch "$file"

  dir_path="$(dirname "$file")"
    
  mkdir -p "$dir_path" || sudo mkdir -p "$dir_path"
    
  chmod 777 "$dir_path" || sudo chmod 777 "$dir_path"
done 
 

IGNORE_CONTAINERS=("") # Add container names enclosed in double quotes as space-separated-values to be ignored    

docker events --format '{{.Status}} {{.Actor.Attributes.name}}' | while read event container; do
  if [[ "$event" == "stop" ]]; then     
    if ! grep -q "name=\"$container\"" "$DOWN_FILE" && [[ ! " ${IGNORE_CONTAINERS[@]} " =~ " $container " ]]; then
      echo "Detected stopped container: $container" | tee -a "$STORAGE_FILE"
      # Fetch last 5 logs
      LOGS=$(docker logs --tail 5 "$container" 2>&1 | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/"/\\"/g'| tr '\n' ' ')

      TIMESTAMP=$(date +"%d-%b-%Y at %H:%M:%S")

    # Write logs to the file
      echo "container_down{name=\"$container\", logs=\"$LOGS\", stopped_at=\"$TIMESTAMP\"} 1" >> "$DOWN_FILE"
      echo "container_down{name=\"$container\", logs=\"$LOGS\", stopped_at=\"$TIMESTAMP\"} 1" >> "$STORAGE_FILE"

      if [[ $? -eq 0 ]]; then
        echo "Logs written to $DOWN_FILE"
      else
        echo "❌ Failed to write logs to $DOWN_FILE"
      fi
    fi
    if grep -q "name=\"$container\"" "$CPU_ALERT_FILE"; then
      echo "Removing cpu utilization logs for stopped container: $container" | tee -a "$STORAGE_FILE"
      sed -i "/name=\"$container\"/d" "$CPU_ALERT_FILE"
    fi
    if grep -q "name=\"$container\"" "$MEMORY_ALERT_FILE"; then
      echo "Removing memory utilization logs for stopped container: $container" | tee -a "$STORAGE_FILE"
      sed -i "/name=\"$container\"/d" "$MEMORY_ALERT_FILE"
    fi    
  elif [[ "$event" == "start" ]]; then
    if grep -q "name=\"$container\"" "$DOWN_FILE"; then
      echo "Removing down logs for restarted container: $container" | tee -a "$STORAGE_FILE"
      sed -i "/name=\"$container\"/d" "$DOWN_FILE"  
    fi 
  elif [[ "$event" == "destroy" ]]; then
    if grep -q "name=\"$container\"" "$DOWN_FILE"; then
      echo "The container $container is removed. Removing its down log" | tee -a "$STORAGE_FILE"
      sed -i "/name=\"$container\"/d" "$DOWN_FILE"  
    fi 
    if grep -q "name=\"$container\"" "$CPU_ALERT_FILE"; then
      echo "The container $container is removed. Removing cpu utilization log for $container" | tee -a "$STORAGE_FILE"
      sed -i "/name=\"$container\"/d" "$CPU_ALERT_FILE"
    fi
    if grep -q "name=\"$container\"" "$MEMORY_ALERT_FILE"; then
      echo "The container $container is removed. Removing memory utilization log for $container" | tee -a "$STORAGE_FILE"
      sed -i "/name=\"$container\"/d" "$MEMORY_ALERT_FILE"
    fi 
    if grep -q "name=\"$container\"" "$HEALTH_FILE"; then
      echo "The container $container is removed. Removing health log for $container" | tee -a "$STORAGE_FILE"
      sed -i "/name=\"$container\"/d" "$HEALTH_FILE"
    fi
  fi  
done&

while true; do 
  grep -o 'name="[^"]*"' "$DOWN_FILE" | sed 's/name="//;s/"//' | while read logged_container; do #to keep track of containers that recovered while the monitoring stack is down
    if docker ps --filter "status=running" --filter "name=$logged_container" --format "{{.Names}}" | grep -q "$logged_container"; then
      echo "Removing down log for recovered container: $logged_container" | tee -a "$STORAGE_FILE"
      sed -i "/name=\"$logged_container\"/d" "$DOWN_FILE"
    fi
  done

  docker ps --filter "status=exited" --format "{{.Names}}" | while read container; do #to keep track of containers that went down while monitoring stack is down
    if ! grep -q "name=\"$container\"" "$DOWN_FILE" && [[ ! " ${IGNORE_CONTAINERS[@]} " =~ " $container " ]]; then      
      echo "Detected exited container: $container" | tee -a "$STORAGE_FILE"

      TIMESTAMP=$(date +"%d-%b-%Y at %H:%M:%S")
      LOGS=$(docker logs --tail 5 "$container" 2>&1 | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/"/\\"/g'| tr '\n' ' ')

      echo "container_exited{name=\"$container\", logs=\"$LOGS\", detected_at=\"$TIMESTAMP\"} 1" >> "$DOWN_FILE"
      echo "container_exited{name=\"$container\", logs=\"$LOGS\", detected_at=\"$TIMESTAMP\"} 1" >> "$STORAGE_FILE"
      echo "Logs written to $DOWN_FILE"                
    fi
  done
  sleep 10
done&

while true; do
  # To track unhealthy containers
  docker ps --filter "health=unhealthy" --format "{{.Names}}" | while read container; do
    if ! grep -q "name=\"$container\"" "$HEALTH_FILE"; then
      echo "Detected unhealthy container: $container" | tee -a "$STORAGE_FILE"

      TIMESTAMP=$(date +"%d-%b-%Y %H:%M:%S")
      LOGS=$(docker logs --tail 5 "$container" 2>&1 | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/"/\\"/g'| tr '\n' ' ')

      echo "docker_container_health_status{name=\"$container\", status=\"unhealthy\", logs=\"$LOGS\", detected_at=\"$TIMESTAMP\"} 1" >> "$HEALTH_FILE"
      echo "docker_container_health_status{name=\"$container\", status=\"unhealthy\", logs=\"$LOGS\", detected_at=\"$TIMESTAMP\"} 1" >> "$STORAGE_FILE"
      echo "Health status written to $HEALTH_FILE"      
    fi
  done

  # Remove logs for containers that have recovered
  grep -o 'name="[^"]*"' "$HEALTH_FILE" | sed 's/name="//;s/"//' | while read logged_container; do
    if ! docker ps --filter "name=$logged_container" --filter "health=unhealthy" --format "{{.Names}}" | grep -q "$logged_container"; then
      echo "Removing health log for recovered container: $logged_container" | tee -a "$STORAGE_FILE"
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
        echo "🚨 High CPU Usage: $container is using $cpu% CPU" | tee -a "$STORAGE_FILE"
        LOGS=$(docker logs --tail 5 "$container" 2>&1 | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/"/\\"/g'| tr '\n' ' ')
        TIMESTAMP=$(date +"%d-%b-%Y %H:%M:%S")
        echo "container_cpu_alert{name=\"$container\", usage=\"$cpu\", logs=\"$LOGS\", detected_at=\"$TIMESTAMP\"} 1" >> "$CPU_ALERT_FILE"
        echo "container_cpu_alert{name=\"$container\", usage=\"$cpu\", logs=\"$LOGS\", detected_at=\"$TIMESTAMP\"} 1" >> "$STORAGE_FILE"
        echo "Logs written to $CPU_ALERT_FILE"
      fi
    else     
      if grep -q "name=\"$container\"" "$CPU_ALERT_FILE"; then
        echo "✅ CPU usage back to normal for $container. Removing alert log." | tee -a "$STORAGE_FILE"
        sed -i "/name=\"$container\"/d" "$CPU_ALERT_FILE"
      fi
    fi

    if (( $(echo "$mem > $MEM_THRESHOLD" | bc -l) )); then
      if ! grep -q "name=\"$container\"" "$MEMORY_ALERT_FILE"; then      
        echo "🚨 High Memory Usage: $container is using $mem% memory" | tee -a "$STORAGE_FILE"
        LOGS=$(docker logs --tail 5 "$container" 2>&1 | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/"/\\"/g' | tr '\n' ' ')
        TIMESTAMP=$(date +"%d-%b-%Y %H:%M:%S")  
        echo "container_memory_alert{name=\"$container\", usage=\"$mem\", logs=\"$LOGS\", detected_at=\"$TIMESTAMP\"} 1" >> "$MEMORY_ALERT_FILE"
        echo "container_memory_alert{name=\"$container\", usage=\"$mem\", logs=\"$LOGS\", detected_at=\"$TIMESTAMP\"} 1" >> "$STORAGE_FILE"
        echo "Logs written to $MEMORY_ALERT_FILE"
      fi  
    else     
      if grep -q "name=\"$container\"" "$MEMORY_ALERT_FILE"; then
        echo "✅ Memory usage back to normal for $container. Removing alert log." | tee -a "$STORAGE_FILE"
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
          echo "🚨 High Host CPU Usage: Host is running at $TOTAL_CPU%" | tee -a "$STORAGE_FILE"
          echo "cpu_threshold{detected_at=\"$TIMESTAMP\"} 1" > "$CPU_THRESHOLD_FILE"
          echo "Logs written to $CPU_THRESHOLD_FILE"
        fi
    else        
        if [ -s "$CPU_THRESHOLD_FILE" ]; then
            echo "✅ Host CPU usage is back to normal. Removing alert log." | tee -a "$STORAGE_FILE"
            > "$CPU_THRESHOLD_FILE"  # Clears the file
        fi
    fi
    
    sleep 10
done