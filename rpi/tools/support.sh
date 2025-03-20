#!/bin/sh

BASEDIR=/home/pi

echo "Generating support.zip, please wait..."

if [ -f $BASEDIR/printer_data/config/support.tar.gz ]; then
    rm $BASEDIR/printer_data/config/support.tar.gz
fi
if [ -f $BASEDIR/support.zip ]; then
    rm $BASEDIR/support.zip
fi
if [ -f $BASEDIR/printer_data/config/support.zip ]; then
    rm $BASEDIR/printer_data/config/support.zip
fi

if [ -f $BASEDIR/support.log ]; then
    rm $BASEDIR/support.log
fi

DATE_TIME=$(date +"%Y-%m-%d %H:%M:%S")
echo "----------------------------------------------------------------------------" >> $BASEDIR/support.log
echo "Simple AF installation details ${DATE_TIME}" >> $BASEDIR/support.log
echo "---------------- top -------------------------------------------------------" >> $BASEDIR/support.log
top -b -n 1 >> $BASEDIR/support.log
echo "---------------- free ------------------------------------------------------" >> $BASEDIR/support.log
free >> $BASEDIR/support.log
echo "---------------- lsusb -----------------------------------------------------" >> $BASEDIR/support.log
lsusb >> $BASEDIR/support.log
echo "---------------- ls -la /etc/init.d ----------------------------------------" >> $BASEDIR/support.log
ls -la /etc/init.d >> $BASEDIR/support.log
echo "---------------- ls -laR /usr/data -----------------------------------------" >> $BASEDIR/support.log
ls -laR $BASEDIR >> $BASEDIR/support.log
echo "----------------------------------------------------------------------------" >> $BASEDIR/support.log

cd $BASEDIR
python3 -m zipfile -c $BASEDIR/support.zip support.log pellcorp-overrides/ pellcorp-backups/ printer_data/config/ printer_data/logs/installer-*.log printer_data/logs/klippy.log printer_data/logs/moonraker.log printer_data/logs/guppyscreen.log /var/log/messages 2> /dev/null
cd - > /dev/null

rm $BASEDIR/support.log
if [ -f $BASEDIR/support.zip ]; then
    mv $BASEDIR/support.zip $BASEDIR/printer_data/config/
    echo "Upload the support.zip to discord"
else
    echo "ERROR: Failed to create the support.zip file"
fi
