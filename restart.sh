#!/bin/bash -eux

sudo cp my.cnf /etc/mysql/my.cnf
sudo cp mysqld.cnf /etc/mysql/mysql.conf.d/mysqld.cnf
sudo cp nginx.conf /etc/nginx/nginx.conf
sudo cp isuda.perl.service /etc/systemd/system/isuda.perl.service
sudo nginx -t

sudo rm /var/log/mysql/mysql-slow.log
sudo rm /var/log/nginx/access.log

sudo systemctl daemon-reload && sudo systemctl restart nginx.service mysql.service isuda.perl.service

