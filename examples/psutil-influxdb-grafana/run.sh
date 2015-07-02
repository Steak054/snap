#!/bin/bash

die () {
    echo >&2 "$@"
    exit 1
}

[ "$#" -eq 1 ] || die "Error: Expected to get one or more machine names as arguments."
command -v docker-machine >/dev/null 2>&1 || die "Error: docker-machine is required."
command -v docker-compose >/dev/null 2>&1 || die "Error: docker-compose is required."
command -v docker >/dev/null 2>&1 || die "Error: docker is required."
command -v netcat >/dev/null 2>&1 || die "Error: netcat is required."


#docker machine ip
dm_ip=$(docker-machine ip $1) || die 
echo "docker machine ip: ${dm_ip}"

#start containers
docker-compose up -d

echo -n "waiting for influxdb and grafana to start"

# wait for influxdb to start up
while ! curl --silent -G "http://${dm_ip}:8086/query?u=admin&p=admin" --data-urlencode "q=SHOW DATABASES" 2>&1 > /dev/null ; do   
  sleep 1 
  echo -n "."
done
echo ""

#influxdb IP 
influx_ip=$(docker inspect --format '{{ .NetworkSettings.IPAddress }}' psutilinfluxdbgrafana_influxdb_1)
echo "influxdb ip: ${influx_ip}"

# create pulse database in influxdb
echo -n "creating pulse influx db => "
curl -G "http://${dm_ip}:8086/query?u=admin&p=admin" --data-urlencode "q=CREATE DATABASE pulse"
echo ""

# create influxdb datasource in grafana
echo -n "adding influxdb datasource to grafana => "
COOKIEJAR=$(mktemp -t 'pulse-tmp')
curl -H 'Content-Type: application/json;charset=UTF-8' \
	--data-binary '{"user":"admin","email":"","password":"admin"}' \
    --cookie-jar "$COOKIEJAR" \
    "http://${dm_ip}:3000/login"

curl --cookie "$COOKIEJAR" \
	-X POST \
	--silent \
	-H 'Content-Type: application/json;charset=UTF-8' \
	--data-binary "{\"name\":\"influx\",\"type\":\"influxdb\",\"url\":\"http://${influx_ip}:8086\",\"access\":\"proxy\",\"database\":\"pulse\",\"user\":\"admin\",\"password\":\"admin\"}" \
	"http://${dm_ip}:3000/api/datasources"
echo ""

dashboard=$(cat grafana/dashboard.json)
curl --cookie "$COOKIEJAR" \
	-X POST \
	--silent \
	-H 'Content-Type: application/json;charset=UTF-8' \
	--data "$dashboard" \
	"http://${dm_ip}:3000/api/dashboards/db"
echo ""

echo -n "starting pulsed"
$PULSE_PATH/bin/pulsed --log-level 1 --auto-discover $PULSE_PATH/plugin > /tmp/pulse.out 2>&1  &
echo ""

sleep 3

echo -n "adding task "
TASK="${TMPDIR}/pulse-task-$$.json"
echo "$TASK"
cat $PULSE_PATH/../cmd/pulsectl/sample/psutil-influx.json | sed s/172.16.105.128/${dm_ip}/ > $TASK 
$PULSE_PATH/bin/pulsectl task create $TASK

echo "start task"
$PULSE_PATH/bin/pulsectl task start 1

tail -f /tmp/pulse.out

