#!/bin/sh

BASEDIR=/home/pi

# we want to get the timestamp before ntp starts
start_timestamp=$(date +%s)

function log() {
    local msg="$1"
    if [ "$client" = "true" ]; then
        echo "$msg" | tee -a $BASEDIR/cleanup.log
    else
        echo "$msg" >> $BASEDIR/cleanup.log
    fi
}

function delete() {
    local file="$1"

    if [ "$dryrun" = "true" ]; then
        log "[Dryrun] Deleting $file"
    else
        log "Deleting $file"
        rm $file
    fi
}

if [ -f $BASEDIR/cleanup.log ]; then
    rm $BASEDIR/cleanup.log
    sync
fi

client=false
dryrun=false
while true; do
    if [ "$1" = "--dry-run" ]; then
        dryrun=true
        client=true
        shift
    elif [ "$1" = "--client" ]; then
        shift
        client=true
        shift
    else # no more parameters
        break
    fi
done

# if there is less than 1GB left, activate deletion of old gcode files
REMAINING_DISK=$(df -m / | tail -1 | awk '{print $4}')
if [ $REMAINING_DISK -lt 1000 ]; then
    log "Performing gcode cleanup"
    files=$(find $BASEDIR/printer_data/gcodes/ -maxdepth 1 -name "*.gcode" -type f -mtime +7 -print)
    for file in $files; do
        delete $file
    done
fi

# clear out tmp dir
files=$(find $BASEDIR/tmp/ -type f -mtime 0 -print)
for file in $files; do
    filename=$(basename $file)
    if [ "$filename" = "moonraker_instance_ids" ]; then
        log "Skipped $file"
    else
        delete $file
    fi
done

# we no longer create old style backups
files=$(find $BASEDIR/printer_data/config/backups/ -maxdepth 1 -name "*.override.bkp" -type f -mtime 0 -print)
for file in $files; do
    delete $file
done

# we no longer create these old style backup files
files=$(find $BASEDIR/printer_data/config/backups/ -maxdepth 1 -name "printer-*.cfg" -type f -mtime 0 -print)
for file in $files; do
    delete $file
done

files=$(find $BASEDIR/printer_data/logs/ -maxdepth 1 -name "*.log" -type f -mtime +7 -print)
for file in $files; do
    filename=$(basename $file)
    # lets just make sure we do not delete these files accidentally
    if [ "$filename" = "moonraker.log" ] || [ "$filename" = "guppyscreen.log" ] || [ "$filename" = "klippy.log" ]; then
        log "Skipped $file"
    else
        delete $file
    fi
done
sync

# clean out backup tar balls
files=$(find $BASEDIR/printer_data/config/backups/ -maxdepth 1 -name "backup-*.tar.gz" -type f -mtime +7 -print | sort -r)
# for simplicity sake always skip the newest old file in case its the only file left
skipped=false
for file in $files; do
    if [ "$skipped" = "false" ]; then
        log "Skipped $file"
        skipped=true
    else
        delete $file
    fi
done

# old save and restart config files
files=$(find $BASEDIR/printer_data/config/ -maxdepth 1 -name "printer-*.cfg" -type f -mtime +7 -print | sort -r)
# for simplicity sake always skip the newest old file in case its the only file left
skipped=false
for file in $files; do
    if [ "$skipped" = "false" ]; then
        log "Skipped $file"
        skipped=true
    else
        delete $file
    fi
done
