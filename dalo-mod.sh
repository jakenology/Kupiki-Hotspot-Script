#!/bin/bash

# PLEASE EDIT NEXT LINES TO DEFINE YOUR OWN CONFIGURATION

# Name of the log file
LOGNAME="pihotspot.log"
# Path where the logfile will be stored
# be sure to add a / at the end of the path
LOGPATH="$(pwd)"
# Password for user root (MySql/MariaDB not system)
MYSQL_PASSWORD="pihotspot"
# Secret word for FreeRadius
FREERADIUS_SECRETKEY=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1`
# Install Daloradius Portal (compatible with FR2 only in theory)
# Set value to Y or N
DALORADIUS_INSTALL="Y"
# *************************************
#
# PLEASE DO NOT MODIFY THE LINES BELOW
#
# *************************************

# Default Portal port
HOTSPOT_PORT="80"
HOTSPOT_PROTOCOL="http:\/\/"
# If we need HTTPS support, change port and protocol
if [ $HOTSPOT_HTTPS = "Y" ]; then
    HOTSPOT_PORT="443"
    HOTSPOT_PROTOCOL="https:\/\/"
fi

# Default version of MariaDB
MARIADB_VERSION='10.1'
# Daloradius URL
DALORADIUS_ARCHIVE="https://github.com/lirantal/daloradius.git"

### PKG Vars ###
PKG_MANAGER="apt-get"
PKG_CACHE="/var/lib/apt/lists/"
UPDATE_PKG_CACHE="${PKG_MANAGER} update"
PKG_INSTALL="${PKG_MANAGER} --yes install"
PKG_UPGRADE="${PKG_MANAGER} --yes upgrade"
#PKG_DIST_UPGRADE="apt dist-upgrade -y --force-yes"
PKG_DIST_UPGRADE="apt dist-upgrade -y --allow-remove-essential --allow-change-held-packages"
PKG_COUNT="${PKG_MANAGER} -s -o Debug::NoLocking=true upgrade | grep -c ^Inst || true"


check_returned_code() {
    RETURNED_CODE=$@
    if [ $RETURNED_CODE -ne 0 ]; then
        display_message ""
        display_message "Something went wrong with the last command. Please check the log file"
        display_message ""
        exit 1
    fi
}

display_message() {
    MESSAGE=$@
    # Display on console
    echo "::: $MESSAGE"
    # Save it to log file
    echo "::: $MESSAGE" >> $LOGPATH$LOGNAME
}

execute_command() {
    display_message "$3"
    COMMAND="$1 >> $LOGPATH$LOGNAME 2>&1"
    eval $COMMAND
    COMMAND_RESULT=$?
    if [ "$2" != "false" ]; then
        check_returned_code $COMMAND_RESULT
    fi
}

prepare_logfile() {
    echo "::: Preparing log file"
    if [ -f $LOGPATH$LOGNAME ]; then
        echo "::: Log file already exists. Creating a backup."
        execute_command "mv $LOGPATH$LOGNAME $LOGPATH$LOGNAME.`date +%Y%m%d.%H%M%S`"
    fi
    echo "::: Creating the log file"
    execute_command "touch $LOGPATH$LOGNAME"
    display_message "Log file created : $LOGPATH$LOGNAME"
    display_message "Use command 'tail -f $LOGPATH$LOGNAME' in a new console to get installation details"
}

prepare_install() {
    # Prepare the log file
    prepare_logfile

    # Force IPv4 on APT resources
    execute_command "echo 'Acquire::ForceIPv4 \"true\";' | sudo tee /etc/apt/apt.conf.d/99force-ipv4" true "Updating APT config to force IPv4"

    display_message "Configuring localepurge"
cat > /tmp/localepurge.conf << EOF
localepurge	localepurge/quickndirtycalc	boolean	false
localepurge	localepurge/none_selected	boolean	false
localepurge	localepurge/mandelete	boolean	true
localepurge	localepurge/dontbothernew	boolean	true
localepurge	localepurge/verbose	boolean	false
localepurge	localepurge/use-dpkg-feature	boolean	false
localepurge	localepurge/remove_no	note
localepurge	localepurge/showfreedspace	boolean	true
localepurge	localepurge/nopurge	multiselect	en, en_US.UTF-8
EOF
    check_returned_code $?
    debconf-set-selections < /tmp/localepurge.conf
    check_returned_code $?
    rm -f /tmp/localepurge.conf
    check_returned_code $?
}

check_root() {
    # Must be root to install the hotspot
    echo ":::"
    if [[ $EUID -eq 0 ]];then
        echo "::: You are root - OK"
    else
        echo "::: sudo will be used for the install."
        # Check if it is actually installed
        # If it isn't, exit because the install cannot complete
        if [[ $(dpkg-query -s sudo) ]];then
            export SUDO="sudo"
            export SUDOE="sudo -E"
        else
            echo "::: Please install sudo or run this as root."
            exit 1
        fi
    fi
}

jumpto() {
    label=$1
    cmd=$(sed -n "/$label:/{:a;n;p;ba};" $0 | grep -v ':$')
    eval "$cmd"
    exit
}

verifyFreeDiskSpace() {
    # Needed free space
    local required_free_megabytes=1024
    # If user installs unattended-upgrades we will check for 1GB free
    echo ":::"
    echo -n "::: Verifying free disk space ($required_free_megabytes Mb)"
    local existing_free_megabytes=$(df -Pk | grep -m1 '\/$' | awk '{print $4}')

    # - Unknown free disk space , not a integer
    if ! [[ "${existing_free_megabytes}" =~ ^([0-9])+$ ]]; then
        echo ""
        echo "::: Unknown free disk space!"
        echo "::: We were unable to determine available free disk space on this system."
        echo "::: You may continue with the installation, however, it is not recommended."
        read -r -p "::: If you are sure you want to continue, type YES and press enter :: " response
        case $response in
            [Y][E][S])
                ;;
            *)
                echo "::: Confirmation not received, exiting..."
                exit 1
                ;;
        esac
    # - Insufficient free disk space
    elif [[ ${existing_free_megabytes} -lt ${required_free_megabytes} ]]; then
        echo ""
        echo "::: Insufficient Disk Space!"
        echo "::: Your system appears to be low on disk space. Pi-HotSpot recommends a minimum of $required_free_megabytes MegaBytes."
        echo "::: You only have ${existing_free_megabytes} MegaBytes free."
        echo ":::"
        echo "::: If this is a new install on a Raspberry Pi you may need to expand your disk."
        echo "::: Try running 'sudo raspi-config', and choose the 'expand file system option'"
        echo ":::"
        echo "::: After rebooting, run this installation again."

        echo "Insufficient free space, exiting..."
        exit 1
    else
        echo " - OK"
    fi
}

update_package_cache() {
	echo "::: Updating packages list"
	if command -v debconf-apt-progress &> /dev/null; then
			$SUDO debconf-apt-progress -- ${UPDATE_PKG_CACHE}
	else
			$SUDO ${UPDATE_PKG_CACHE} &> /dev/null
	fi
  echo ":::"
}

notify_package_updates_available() {
  echo ":::"
  echo -n "::: Checking ${PKG_MANAGER} for upgraded packages...."
  updatesToInstall=$(eval "${PKG_COUNT}")
  echo " done!"
  echo ":::"
  if [[ ${updatesToInstall} -eq "0" ]]; then
    echo "::: Your system is up to date! Continuing with Pi-Hotspot installation..."
  else
    echo "::: There are ${updatesToInstall} updates available for your system!"
    echo ":::"
    execute_command "apt-get upgrade -y --allow-remove-essential --allow-change-held-packages" true "Upgrading the packages. Please be patient."
  fi
}

download_all_sources() {
  echo ":::"
  if [ $DALORADIUS_INSTALL = "Y" ]; then

    execute_command "cd /usr/src/ && rm -rf daloradius && git clone $DALORADIUS_ARCHIVE daloradius" true "Cloning daloradius project"

  fi
}

package_check_install() {
    dpkg-query -W -f='${Status}' "${1}" 2>/dev/null | grep -c "ok installed" || ${PKG_INSTALL} "${1}"
}

PIHOTSPOT_DEPS=( wget build-essential grep whiptail debconf-utils nfdump figlet git fail2ban hostapd php-mysql php-pear php-gd php-db php-fpm libgd2-xpm-dev libpcrecpp0v5 libxpm4 nginx debhelper libssl-dev libcurl4-gnutls-dev mariadb-server freeradius freeradius-mysql gcc make libnl1 libnl-dev pkg-config iptables haserl libjson-c-dev gengetopt devscripts libtool bash-completion autoconf automake )

install_dependent_packages() {

  declare -a argArray1=("${!1}")

  if command -v debconf-apt-progress &> /dev/null; then
    $SUDO debconf-apt-progress -- ${PKG_INSTALL} "${argArray1[@]}"
  else
    for i in "${argArray1[@]}"; do
      echo -n ":::    Checking for $i..."
      $SUDO package_check_install "${i}" &> /dev/null
      echo " installed!"
    done
  fi
}


check_root

DEBIAN_VERSION=`cat /etc/*-release | grep VERSION_ID | awk -F= '{print $2}' | sed -e 's/^"//' -e 's/"$//'`
if [[ $DEBIAN_VERSION -ne 9 ]];then
        display_message ""
        display_message "This script is used to get installed on Raspbian Stretch Lite"
        display_message ""
	exit 1
fi

verifyFreeDiskSpace

prepare_install

update_package_cache

notify_package_updates_available

install_dependent_packages PIHOTSPOT_DEPS_START[@]

execute_command "/sbin/lsmod | grep tun" false "Checking for tun module"
if [ $COMMAND_RESULT -ne 0 ]; then
    display_message "Insert tun module if existing (for Raspbian Jessie Lite)"
    find /lib/modules/ -iname "tun.ko.gz" -exec /sbin/insmod {} \;
    check_returned_code $?

    display_message "Modprobe module (no check - useless if already loaded)"
    /sbin/modprobe tun

    execute_command "/sbin/lsmod | grep tun" false "Checking for tun module"
    if [ $COMMAND_RESULT -ne 0 ]; then
        display_message "Unable to get tun module up. Please solve before running the script again."
        display_message "If your distribution has been upgraded you should try to reboot first."
        exit 1
    fi
fi


execute_command "echo 'maria-db-$MARIADB_VERSION mysql-server/root_password password $MYSQL_PASSWORD' | debconf-set-selections" true "Adding MariaDb password"
execute_command "echo 'maria-db-$MARIADB_VERSION mysql-server/root_password_again password $MYSQL_PASSWORD' | debconf-set-selections" true "Adding MariaDb password (confirmation)"

display_message "Getting WAN IP of the Raspberry Pi (for daloradius access)"
MY_IP=`ifconfig $WAN_INTERFACE | grep "inet " | awk '{ print $2 }'`


install_dependent_packages PIHOTSPOT_DEPS[@]

notify_package_updates_available

download_all_sources

execute_command "service mariadb restart" true "Starting MySql service"

execute_command "service freeradius stop" true "Stopping freeradius service to update the configuration"

display_message "Creating freeradius database"
echo 'drop database if exists radius;' | mariadb -u root -p$MYSQL_PASSWORD
echo "GRANT USAGE ON *.* TO 'radius'@'localhost';" | mariadb -u root -p$MYSQL_PASSWORD
echo "DROP USER 'radius'@'localhost';" | mariadb -u root -p$MYSQL_PASSWORD
echo 'create database radius;' | mariadb -u root -p$MYSQL_PASSWORD
check_returned_code $?

display_message "Installing freeradius schema"
mariadb -u root -p$MYSQL_PASSWORD radius < /etc/freeradius/3.0/mods-config/sql/main/mysql/schema.sql
check_returned_code $?

display_message "Adding setup data"
mariadb -u root -p$MYSQL_PASSWORD radius < /etc/freeradius/3.0/mods-config/sql/main/mysql/setup.sql
check_returned_code $?

display_message "Updating freeradius configuration - Activate SQL support"
ln -sf /etc/freeradius/3.0/mods-available/sql /etc/freeradius/3.0/mods-enabled/sql
check_returned_code $?
chown -h freerad:freerad /etc/freeradius/3.0/mods-enabled/sql
check_returned_code $?

display_message "Configuration of the Freeradius SQL driver"
sed -i 's/"rlm_sql_null"$/"rlm_sql_mysql"/' /etc/freeradius/3.0/mods-enabled/sql
check_returned_code $?

display_message "Change dialect of the Freeradius SQL driver to mysql"
sed -i 's/"sqlite"$/"mysql"/' /etc/freeradius/3.0/mods-enabled/sql
check_returned_code $?

display_message "Configuration of the Freeradius SQL connection"
DIALECT_LINE=`awk 's=index($0,"dialect = ") { print NR }' /etc/freeradius/3.0/mods-enabled/sql`
((DIALECT_LINE+=1))
#by default the radius_db is set to radius
#sed -i "${DIALECT_LINE}iradius_db = \"radius\"" /etc/freeradius/3.0/mods-enabled/sql
sed -i "${DIALECT_LINE}ipassword = \"radpass\"" /etc/freeradius/3.0/mods-enabled/sql
sed -i "${DIALECT_LINE}ilogin = \"radius\"" /etc/freeradius/3.0/mods-enabled/sql
sed -i "${DIALECT_LINE}iport = 3306" /etc/freeradius/3.0/mods-enabled/sql
sed -i "${DIALECT_LINE}iserver = \"localhost\"" /etc/freeradius/3.0/mods-enabled/sql
check_returned_code $?

display_message "Updating freeradius configuration - Activate SQL counters"
ln -sf /etc/freeradius/3.0/mods-available/sqlcounter /etc/freeradius/3.0/mods-enabled/sqlcounter
check_returned_code $?
chown -h freerad:freerad /etc/freeradius/3.0/mods-enabled/sqlcounter
check_returned_code $?

display_message "Bug fix for SQL dialect once SQL Counters are activated"
sed -i 's/dialect = \${modules\.sql\.dialect}/dialect = mysql/g' /etc/freeradius/3.0/mods-available/sqlcounter
check_returned_code $?

display_message "Update of Freeradius secret key"
sed -i "s/testing123/$FREERADIUS_SECRETKEY/g" /etc/freeradius/3.0/clients.conf
check_returned_code $?

display_message "Updating inner-tunnel configuration (1)"
sed -i 's/^[ \t]*-sql/sql/g' /etc/freeradius/3.0/sites-available/inner-tunnel
check_returned_code $?

display_message "Updating inner-tunnel configuration (2)"
sed -i 's/^#[ \t]*sql$/sql/g' /etc/freeradius/3.0/sites-available/inner-tunnel
check_returned_code $?

display_message "Updating freeradius default configuration (1)"
sed -i 's/^[ \t]*-sql/sql/g' /etc/freeradius/3.0/sites-available/default
check_returned_code $?

display_message "Updating freeradius default configuration (2)"
sed -i 's/^#[ \t]*sql$/sql/g' /etc/freeradius/3.0/sites-available/default
check_returned_code $?

execute_command "freeradius -C" true "Checking freeradius configuration"

if [ $DALORADIUS_INSTALL = "Y" ]; then

    execute_command "cp -Rf /usr/src/daloradius /usr/share/nginx/html/" true "Installing Daloradius in Nginx folder"

    display_message "Loading daloradius configuration into MySql"
    mariadb -u root -p$MYSQL_PASSWORD radius < /usr/share/nginx/html/daloradius/contrib/db/fr2-mysql-daloradius-and-freeradius.sql
    check_returned_code $?

    display_message "Drop freeradius tables created by Daloradius to reload the Freeradius 3.0 version"
    echo 'drop table if exists radius.radacct, radius.radcheck, radius.radgroupcheck, radius.radgroupreply, radius.radreply, radius.radusergroup, radius.radpostauth, radius.nas ;' | mariadb -u root -p$MYSQL_PASSWORD
    check_returned_code $?

    display_message "Reload original Freeradius schema"
    mariadb -u root -p$MYSQL_PASSWORD radius < /etc/freeradius/3.0/mods-config/sql/main/mysql/schema.sql
    check_returned_code $?

    display_message "Creating users privileges for localhost"
    echo "GRANT ALL ON radius.* to 'radius'@'localhost';" > /tmp/grant.sql
    check_returned_code $?

    display_message "Granting users privileges"
    mysql -u root -p$MYSQL_PASSWORD < /tmp/grant.sql
    check_returned_code $?

    display_message "Configuring daloradius DB user name"
    sed -i "s/\$configValues\['CONFIG_DB_USER'\] = 'root';/\$configValues\['CONFIG_DB_USER'\] = 'radius';/g" /usr/share/nginx/html/daloradius/library/daloradius.conf.php
    check_returned_code $?
    display_message "Configuring daloradius DB user password"
    sed -i "s/\$configValues\['CONFIG_DB_PASS'\] = '';/\$configValues\['CONFIG_DB_PASS'\] = 'radpass';/g" /usr/share/nginx/html/daloradius/library/daloradius.conf.php
    check_returned_code $?

    display_message "Building NGINX configuration (default listen port : 80)"
    echo '
    server {
            listen 80 default_server;
            listen [::]:80 default_server;

            root /usr/share/nginx/html/daloradius;

            index index.html index.htm index.php;

            server_name _;

            location / {
                try_files $uri $uri/ =404;
            }

            location ~ \.php$ {
                include snippets/fastcgi-php.conf;
                fastcgi_pass unix:/var/run/php/php7.0-fpm.sock;
            }
    }' > /etc/nginx/sites-available/default
    check_returned_code $?

fi

display_message "Building NGINX configuration for the portal (default listen port : $HOTSPOT_PORT)"
if [ $HOTSPOT_HTTPS = "Y" ]; then
    display_message "Creating folder for Nginx certificates"
    mkdir /etc/nginx/certs/
    check_returned_code $?

    display_message "Generating self-signed certificate"
    openssl req -x509 -nodes -days $CERT_DAYS -newkey rsa:2048 -keyout /etc/nginx/certs/$HOTSPOT_NAME.key -out /etc/nginx/certs/$HOTSPOT_NAME.crt -subj '/CN=$HOTSPOT_NAME'
    check_returned_code $?

    echo "
server {
       	listen $HOTSPOT_IP:$HOTSPOT_PORT ssl default_server;

        ssl_certificate /etc/nginx/certs/$HOTSPOT_NAME.crt;
	    ssl_certificate_key /etc/nginx/certs/$HOTSPOT_NAME.key;

       	root /usr/share/nginx/portal;

       	index index.html;

       	server_name _;

       	location / {
       		try_files \$uri \$uri/ =404;
       	}

       	location ~ \.php\$ {
       		include snippets/fastcgi-php.conf;
       		fastcgi_pass unix:/var/run/php/php7.0-fpm.sock;
       	}
}" > /etc/nginx/sites-available/portal
else
    echo "
server {
       	listen $HOTSPOT_IP:$HOTSPOT_PORT default_server;

       	root /usr/share/nginx/portal;

       	index index.html;

       	server_name _;

       	location / {
       		try_files \$uri \$uri/ =404;
       	}

       	location ~ \.php\$ {
       		include snippets/fastcgi-php.conf;
       		fastcgi_pass unix:/var/run/php/php7.0-fpm.sock;
       	}
}" > /etc/nginx/sites-available/portal
fi
check_returned_code $?

execute_command "ln -sfT /etc/nginx/sites-available/portal /etc/nginx/sites-enabled/portal" true "Activating portal website"

execute_command "cp -Rf /usr/src/portal /usr/share/nginx/" true "Installing the portal in Nginx folder"

display_message "Updating Captive Portal file"
sed -i "/XXXXXX/s/XXXXXX/$HOTSPOT_IP/g" /usr/share/nginx/portal/js/configuration.json
check_returned_code $?

execute_command "nginx -t" true "Checking Nginx configuration file"

display_message "Adding Freeradius in systemd startup"
echo "
[Unit]
Description=Start of freeradius after mysql
After=syslog.target network.target
After=mariadb.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/freeradius
# disable timeout logic
TimeoutSec=0
#StandardOutput=tty
RemainAfterExit=yes
SysVStartPriority=99

[Install]
WantedBy=multi-user.target
" > /etc/systemd/system/freeradius.service
check_returned_code $?
/bin/systemctl enable freeradius.service
check_returned_code $?

display_message "Correct configuration for Collectd daemon"
sed -i "s/^FQDNLookup true$/FQDNLookup false/g" /etc/collectd/collectd.conf
check_returned_code $?

if [ $FAIL2BAN_ENABLED = "Y" ]; then
    display_message "Creating fail2ban local configuration"
    cp /etc/fail2ban/fail2ban.conf /etc/fail2ban/fail2ban.local
    check_returned_code $?

    display_message "Configuring fail2ban jail rules"
    cat > /etc/fail2ban/jail.local << EOT
[DEFAULT]
ignoreip = 127.0.0.1
bantime  = 600
findtime  = 600
maxretry = 3
backend = auto

[sshd]
enabled  = true
filter   = sshd
action   = iptables[name=SSH, port=ssh, protocol=tcp]
logpath  = /var/log/auth.log
maxretry = 3

EOT

    display_message "Reloading fail2ban local configuration"
    /usr/bin/fail2ban-client reload
    check_returned_code $?
fi

display_message "Create banner on login"
/usr/bin/figlet -f lean -c "Kupiki Hotspot" | tr ' _/' ' /' > /etc/ssh/kupiki-banner
check_returned_code $?

display_message "Append script version to the banner"
echo "

Kupiki Hotspot - Version $KUPIKI_VERSION - (c) www.pihomeserver.fr

" >> /etc/ssh/kupiki-banner
check_returned_code $?

display_message "Changing banner rights"
chmod 644 /etc/ssh/kupiki-banner && chown root:root /etc/ssh/kupiki-banner
check_returned_code $?

display_message "Activating the banner for SSH"
sed -i "s?^#Banner.*?Banner /etc/ssh/kupiki-banner?g" /etc/ssh/sshd_config
check_returned_code $?

display_message ""
sed -i "s?^Banner.*?Banner /etc/ssh/kupiki-banner?g" /etc/ssh/sshd_config
check_returned_code $?

execute_command "service freeradius start" true "Starting freeradius service"

execute_command "service nginx reload" true "Restarting Nginx"

execute_command "service hostapd restart" true "Restarting hostapd"

execute_command "service chilli start" true "Starting CoovaChilli service"

if [ $NETFLOW_ENABLED = "Y" ]; then
    execute_command "service fprobe start" true "Starting fprobe service"

    execute_command "systemctl daemon-reload" true "Reloading units for systemctl"

    execute_command "service nfdump start" true "Starting nfdump service"
fi

execute_command "service ssh reload" true "Reload configuration for SSH service"

execute_command "sleep 15 && ifconfig -a | grep tun0" false "Checking if interface tun0 has been created by CoovaChilli"
if [ $COMMAND_RESULT -ne 0 ]; then
    display_message "*** Warning ***"
    display_message "Unable to find chilli interface tun0"
    display_message "Try to restart chilli and check if tun0 interface is available (use 'ifconfig -a')"
    # Do not exit to display connection information
    #exit 1
fi

# Last message to display once installation ended successfully

display_message ""
display_message ""
display_message "Congratulation ! You now have your hotspot ready !"
display_message ""
display_message "- Wifi Hotspot available : $HOTSPOT_NAME"
if [ $AVAHI_INSTALL = "Y" ]; then
    display_message "- For the user management, please connect to http://$MY_IP/ or http://$HOTSPOT_NAME.local/"
else
    display_message "- For the user management, please connect to http://$MY_IP/"
fi
display_message "  (login : administrator / password : radius)"

exit 0