#!/bin/sh
set -x

if [ ! -d "/var/lib/mysql/mysql" ]
then
    /usr/bin/mysql_install_db --datadir=/var/lib/mysql --user=mysql
fi


/usr/bin/mysqld_safe --port 3307 --skip-grant-tables --wsrep-provider=none &
sleep 7

# these connect on unix socket so port doesn't matter
/usr/bin/mysql -u root -e "UPDATE mysql.user SET password=PASSWORD('{{ mysql_root_password }}') where user='root'; flush privileges;"
/usr/bin/mysqladmin -u root --password={{ mysql_root_password }}  shutdown