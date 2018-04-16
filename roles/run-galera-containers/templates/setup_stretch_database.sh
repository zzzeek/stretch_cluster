#!/bin/sh
set -x

/usr/bin/mysql_install_db --datadir=/var/lib/mysql --user=mysql

/usr/bin/mysqld_safe --skip-grant-tables &

/usr/bin/mysql -u root -e "UPDATE mysql.user SET password=PASSWORD('{{ mysql_root_password }}') where user='root'; flush privileges;"
/usr/bin/mysqladmin -u root --password={{ mysql_root_password }} -h localhost shutdown
