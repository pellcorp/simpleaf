#!/bin/sh

if [ "$1" != "mainsail" ] && [ "$1" != "fluidd" ]; then
    echo "Invalid choice - must specify either mainsail or fluidd!"
    exit 1
fi

cp $HOME/pellcorp/k1/nginx/fluidd $HOME/nginx/nginx/sites/ || exit $?
cp $HOME/pellcorp/k1/nginx/mainsail $HOME/nginx/nginx/sites/ || exit $?

if [ "$1" = "mainsail" ]; then
    sed -i 's/.*listen 80 default_server;/    #listen 80 default_server;/g' $HOME/nginx/nginx/sites/fluidd || exit $?
    sed -i 's/.*#listen 80 default_server;/    listen 80 default_server;/g' $HOME/nginx/nginx/sites/mainsail || exit $?
else # else fluidd
    sed -i 's/.*listen 80 default_server;/    #listen 80 default_server;/g' $HOME/nginx/nginx/sites/mainsail || exit $?
    sed -i 's/.*#listen 80 default_server;/    listen 80 default_server;/g' $HOME/nginx/nginx/sites/fluidd || exit $?
fi

echo "Restarting nginx ..."
/etc/init.d/S50nginx_service restart
