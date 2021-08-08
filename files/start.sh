#!/bin/bash

export BASEHTML="/var/www/html"
export DOCROOT="/var/www/html/web"
export GRPID=$(stat -c "%g" /var/lib/mysql/)
export DRUSH="${DOCROOT}/vendor/bin/drush"
export LOCAL_IP=$(hostname -I | awk '{print $1}')
export HOSTIP=$(/sbin/ip route | awk '/default/ { print $3 }')
export DRUPALVER=${DRUPALVER:-'9'}
echo "${HOSTIP} dockerhost" >>/etc/hosts
echo "Started Container: $(date)"

# Create a basic mysql install
if [ ! -d /var/lib/mysql/mysql ]; then
  echo "**** No MySQL data found. Creating data on /var/lib/mysql/ ****"
  mysqld --initialize-insecure
else
  echo "**** MySQL data found on /var/lib/mysql/ ****"
fi

# Start supervisord
supervisord -c /etc/supervisor/conf.d/supervisord.conf -l /tmp/supervisord.log

# If there is no index.php, download drupal
if [ ! -f ${DOCROOT}/index.php ]; then
  echo "**** No Drupal found. Downloading latest to ${DOCROOT}/ ****"
  cd ${BASEHTML}
  # Get the latest version number
  DV=$(curl -s https://git.drupalcode.org/project/drupal/-/tags?format=atom | grep -e '<title>' | grep -Eo '[0-9\.]+' | sort -nr | grep ^${DRUPALVER} | head -n1)
  git clone --depth 1 --single-branch -b ${DV} \
    https://git.drupalcode.org/project/drupal.git web
  # TODO: also require drupal/memcache
  cd web
  composer require drush/drush:~10
  composer install
  chmod a+w ${DOCROOT}/sites/default
  mkdir ${DOCROOT}/sites/default/files
  wget "http://www.adminer.org/latest.php" -O ${DOCROOT}/adminer.php
  chown -R www-data:${GRPID} ${DOCROOT}
  chmod -R ug+w ${DOCROOT}
else
  echo "**** ${DOCROOT}/index.php found  ****"
fi

# Setup Drupal if services.yml or settings.php is missing
if (! grep -q 'database.*=>.*drupal' ${DOCROOT}/sites/default/settings.php 2>/dev/null); then
  # Generate random passwords
  DRUPAL_DB="drupal"
  DEBPASS=$(grep password /etc/mysql/debian.cnf | head -n1 | awk '{print $3}')
  ROOT_PASSWORD=$(pwgen -c -n -1 12)
  DRUPAL_PASSWORD=$(pwgen -c -n -1 12)
  echo ${ROOT_PASSWORD} >/var/lib/mysql/mysql/mysql-root-pw.txt
  echo ${DRUPAL_PASSWORD} >/var/lib/mysql/mysql/drupal-db-pw.txt
  # Wait for mysql
  echo -n "Waiting for mysql "
  while ! mysqladmin status >/dev/null 2>&1; do
    echo -n .
    sleep 1
  done
  echo
  # Create and change MySQL creds
  mysqladmin -u root password ${ROOT_PASSWORD} 2>/dev/null
  echo -e "[client]\npassword=${ROOT_PASSWORD}\n" >/root/.my.cnf
  mysql -e \
    "CREATE USER 'debian-sys-maint'@'localhost' IDENTIFIED WITH mysql_native_password BY '${DEBPASS}';
         GRANT ALL ON *.* TO 'debian-sys-maint'@'localhost';
         CREATE DATABASE drupal;
         CREATE USER 'drupal'@'%' IDENTIFIED WITH mysql_native_password BY '${DRUPAL_PASSWORD}';
         GRANT ALL ON drupal.* TO 'drupal'@'%';
         FLUSH PRIVILEGES;"
  cd ${DOCROOT}
  cp sites/default/default.settings.php sites/default/settings.php
  ${DRUSH} site-install standard -y --account-name=admin --account-pass=admin \
    --db-url="mysql://drupal:${DRUPAL_PASSWORD}@localhost:3306/drupal" \
    --site-name="Drupal9 docker App" | grep -v 'continue?' 2>/dev/null
  #${DRUSH} -y en memcache | grep -v 'continue?' | grep -v error 2>/dev/null
else
  echo "**** ${DOCROOT}/sites/default/settings.php database found ****"
  ROOT_PASSWORD=$(cat /var/lib/mysql/mysql/mysql-root-pw.txt)
  DRUPAL_PASSWORD=$(cat /var/lib/mysql/mysql/drupal-db-pw.txt)
fi

# Change root password
echo "root:${ROOT_PASSWORD}" | chpasswd

# Clear caches and reset files perms
chown -R www-data:${GRPID} ${DOCROOT}/sites/default/
chmod -R ug+w ${DOCROOT}/sites/default/
chown -R mysql:${GRPID} /var/lib/mysql/
chmod -R ug+w /var/lib/mysql/
find -type d -exec chmod +xr {} \;
(
  sleep 3
  drush --root=${DOCROOT}/ cache-rebuild 2>/dev/null
) &

echo
echo "---------------------- USERS CREDENTIALS ($(date +%T)) -------------------------------"
echo
echo "    DRUPAL:  http://${LOCAL_IP}              with user/pass: admin/admin"
echo
echo "    MYSQL :  http://${LOCAL_IP}/adminer.php  drupal/${DRUPAL_PASSWORD} or root/${ROOT_PASSWORD}"
echo "    SSH   :  ssh root@${LOCAL_IP}            with user/pass: root/${ROOT_PASSWORD}"
echo
echo "  Please report any issues to https://github.com/ricardoamaro/drupal9-docker-app"
echo "  USE CTRL+C TO STOP THIS APP"
echo
echo "------------------------------ STARTING SERVICES ---------------------------------------"

tail -f /tmp/supervisord.log
