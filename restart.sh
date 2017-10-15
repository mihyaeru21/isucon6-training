#!/bin/bash -eux

sudo cp my.cnf /etc/mysql/my.cnf
sudo cp mysqld.cnf /etc/mysql/mysql.conf.d/mysqld.cnf
sudo cp nginx.conf /etc/nginx/nginx.conf
sudo nginx -t
sudo systemctl daemon-reload && sudo systemctl restart nginx.service mysql.service isutar.perl.service isuda.perl.service

