#!/bin/sh
#
# Script for automatic setup of glances + Influxdb + Grafana on Ubuntu.
# Tested on Ubuntu 16.04 on Amazon Lightsail VMs.
#
# Copyright (C) 2019 Peter Jiping Xie <peter.jp.xie@gmail.com>

# set -x

SYS_DT="$(date +%F-%T)"

exiterr()  { echo "Error: $1" >&2; exit 1; }
conf_bk() { /bin/cp -f "$1" "$1.old-$SYS_DT" 2>/dev/null; }

# root only
if [ "$(id -u)" != 0 ]; then
    exiterr "Script must be run as root. Try 'sudo -H sh $0'"
fi

# check os is ubuntu or debian
os_type="$(lsb_release -si 2>/dev/null)"
if [ -z "$os_type" ]; then
    [ -f /etc/os-release  ] && os_type="$(. /etc/os-release  && echo "$ID")"
    [ -f /etc/lsb-release ] && os_type="$(. /etc/lsb-release && echo "$DISTRIB_ID")"
fi

if ! printf '%s' "$os_type" | head -n 1 | grep -qiF -e ubuntu -e debian; then
    exiterr "This script only supports Ubuntu and Debian."
fi

# Require Ubuntu 16.04 or above
if [ "$os_type" = "Ubuntu" ]; then
    # ubuntu_version = "$(lsb_release -r 2>/dev/null)"
    lsb_release -r 2>/dev/null | awk '
    { if($2 < 16.04)
        print "This script supports only Ubuntu 16.04 or above.";
    }'
fi

# Use with caution with debian, not tested though it may work
if [ "$os_type" != "Ubuntu" ]; then
    echo "Use with CAUTION! debian is not tested though it should work."
fi

### Install glances ###
# ref: https://nicolargo.github.io/glances/

# check pre-requisites: Python3 and pip3
# Install python3 if not installed.
if ! command -v python3 > /dev/null; then
  echo "Python3 is not installed. Installing now..."
  apt-get install python3-dev
fi

# install pip3 if not installed
if ! command -v pip3 > /dev/null; then
  echo "pip3 is not installed. Installing now..."
  apt-get install python3-pip
fi

# install glances and required packages
# Note: influxdb here is the python influxdb client
echo "### Installing glances... ###"
pip3 install -U glances bottle influxdb

# copy default glances settings. Default is good enough.
mkdir -p /etc/glances
cp /usr/local/share/doc/glances/glances.conf /etc/glances/glances.conf


### Install  influxdb ###
# ref: https://docs.influxdata.com/influxdb/v1.7/introduction/installation/
echo "### Installing influxdb... ###"

# add InfluxData repository 
if [ "$os_type" = "Ubuntu" ]; then 
  # ubuntu
  wget -qO- https://repos.influxdata.com/influxdb.key | apt-key add -
  . /etc/lsb-release && echo "deb https://repos.influxdata.com/ubuntu $DISTRIB_CODENAME stable" | tee /etc/apt/sources.list.d/influxdb.list
else 
  # debian
  wget -qO- https://repos.influxdata.com/influxdb.key | apt-key add -
  . /etc/os-release
  test "$VERSION_ID" = "7" && echo "deb https://repos.influxdata.com/debian wheezy stable" | tee /etc/apt/sources.list.d/influxdb.list
  test "$VERSION_ID" = "8" && echo "deb https://repos.influxdata.com/debian jessie stable" | tee /etc/apt/sources.list.d/influxdb.list
  test "$VERSION_ID" = "9" && echo "deb https://repos.influxdata.com/debian stretch stable" | tee /etc/apt/sources.list.d/influxdb.list
fi

# install 
apt-get update && apt-get -yq install influxdb
# It starts service automatically after installation.
# systemctl start influxdb

# enable service start on bootup
systemctl enable influxdb

# create database "glances" via REST API. This is db name in glances default config.
echo "Wait 5 seconds for influxdb to start."
sleep 5
curl -XPOST 'http://localhost:8086/query' --data-urlencode 'q=CREATE DATABASE "glances"'   
curl -XPOST 'http://localhost:8086/query' --data-urlencode 'q=show databases'  

### Install Grafana ###
# ref: https://grafana.com/docs/installation/debian/
echo "### Installing Grafana ... ###"

apt-get install -y software-properties-common
add-apt-repository "deb https://packages.grafana.com/oss/deb stable main" 

wget -q -O - https://packages.grafana.com/gpg.key | apt-key add -
apt-get update
apt-get -yq install grafana
systemctl start grafana-server
# enable service start on bootup
systemctl daemon-reload
systemctl enable grafana-server

### Modify iptables to allow remote access to these services. ###
# glances web - optional: TCP 61208
# influxdb: TCP 8086, 8088
# grafana: TCP 3000

# Run the rules
# Added for glances web - optional
iptables -I INPUT -p tcp --dport 61208 -j ACCEPT

# Added for Influxdb
iptables -I INPUT -p tcp --dport 8086 -j ACCEPT
iptables -I INPUT -p tcp --dport 8088 -j ACCEPT

# Added for Grafana
iptables -I INPUT -p tcp --dport 3000 -j ACCEPT

# Add iptable rules to /etc/rc.local so it will take effect on bootup.
# You can also modify /etc/iptables.rules.

# create rc.local if not exist.
if [ -f /etc/rc.local ]; then
    conf_bk "/etc/rc.local"
    # remove last line "exit 0" first, will add back later.
    sed -i '/^exit 0/d' /etc/rc.local
else
    echo '#!/bin/sh' > /etc/rc.local
fi

cat >> /etc/rc.local <<'EOF'

# Added for glances web - optional
iptables -I INPUT -p tcp --dport 61208 -j ACCEPT

# Added for Influxdb
iptables -I INPUT -p tcp --dport 8086 -j ACCEPT
iptables -I INPUT -p tcp --dport 8088 -j ACCEPT

# Added for Grafana
iptables -I INPUT -p tcp --dport 3000 -j ACCEPT

exit 0
EOF


cat <<EOF

================================================

Congrats!
You have installed Glances, Influxdb and Grafana. And all services are running.

### To do ###
If you want to access Grafana portal remotely, you need to open below ports in your firewall settings other than iptables rules if there is any.
(iptables rules have been taken cared of.)

glances web - optional: TCP 61208
influxdb: TCP 8086, 8088
grafana: TCP 3000

### To use ###
Run this command to start collecting data:
glances --export influxdb

Then create Grafana dashboards to view data:
http://<server ip>:3000/

================================================
EOF
