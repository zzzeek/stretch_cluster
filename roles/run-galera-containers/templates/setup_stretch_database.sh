#!/bin/sh
set -x

if [ -d "/var/lib/mysql/mysql" ]; then
    exit
fi

/usr/bin/mysql_install_db --datadir=/var/lib/mysql --user=mysql


/usr/bin/mysqld_safe --port {{ galera_listen_port }} --skip-grant-tables --wsrep-provider=none &
sleep 7

# these connect on unix socket so port doesn't matter
/usr/bin/mysql -u root -e "UPDATE mysql.user SET password=PASSWORD('{{ galera_root_password }}') where user='root'; flush privileges;"
/usr/bin/mysqladmin -u root --password={{ galera_root_password }}  shutdown
