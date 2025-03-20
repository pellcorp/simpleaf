#!/bin/sh

BASEDIR=/home/pi

mode=
restore=
while true; do
    if [ "$1" = "--create" ]; then
        mode=create
        shift
    elif [ "$1" = "--latest" ]; then
        shift
        mode=latest
    elif [ "$1" = "--list" ]; then
        shift
        mode=list
    elif [ "$1" = "--restore" ]; then
        shift
        mode=restore
        restore=$1
        shift

        if [ "$restore" = "latest" ]; then
            if [ -d $BASEDIR/printer_data/config/backups ] && [ $(ls -lt $BASEDIR/printer_data/config/backups/*.tar.gz 2> /dev/null | wc -l) -gt 0 ]; then
                restore=$(ls -lt $BASEDIR/printer_data/config/backups/*.tar.gz 2> /dev/null | head -1 | awk '{print $9}' | awk -F '/' '{print $7}')
            else
                echo "ERROR: No backups found"
                exit 1
            fi
        fi

        if [ ! -f $BASEDIR/printer_data/config/backups/$restore ]; then
            echo "ERROR: Backup $BASEDIR/printer_data/config/backups/$restore not found!"
            exit 1
        fi

    else # no more parameters
        break
    fi
done

if [ "$mode" = "create" ]; then
    if [ -z "$TIMESTAMP" ]; then
        export TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
    fi

    cd $BASEDIR
    CFG_ARG='printer_data/config/*.cfg'
    CONF_ARG=''
    ls printer_data/config/*.conf > /dev/null 2>&1
    # straight from a factory reset, there will be no conf files
    if [ $? -eq 0 ]; then
        CONF_ARG='printer_data/config/*.conf'
    fi

    PELLCORP_BACKUPS=''
    if [ -d pellcorp-backups ]; then
        PELLCORP_BACKUPS='pellcorp-backups/*'
    fi

    PELLCORP_OVERRIDES=''
    if [ -d pellcorp-overrides ]; then
        PELLCORP_OVERRIDES='pellcorp-overrides/*'
    fi

    PELLCORP_DONE=''
    if [ -f pellcorp.done ]; then
        PELLCORP_DONE=pellcorp.done
    fi

    tar -zcf $BASEDIR/printer_data/config/backups/backup-${TIMESTAMP}.tar.gz $CFG_ARG $CONF_ARG $PELLCORP_BACKUPS $PELLCORP_OVERRIDES $PELLCORP_DONE
    sync

    cd - > /dev/null
    exit 0
elif [ "$mode" = "latest" ]; then
    if [ -d $BASEDIR/printer_data/config/backups ] && [ $(ls -lt $BASEDIR/printer_data/config/backups/*.tar.gz 2> /dev/null | wc -l) -gt 0 ]; then
        latest=$(ls -lt $BASEDIR/printer_data/config/backups/*.tar.gz 2> /dev/null | head -1 | awk '{print $9}' | awk -F '/' '{print $7}')
        if [ -n "$latest" ]; then
            echo "$latest"
            exit 0
        else
            echo "ERROR: No latest backup found"
            exit 1
        fi
    else
        echo "ERROR: No backups found"
        exit 1
    fi
elif [ "$mode" = "list" ]; then
    if [ -d $BASEDIR/printer_data/config/backups ] && [ $(ls -lt $BASEDIR/printer_data/config/backups/*.tar.gz 2> /dev/null | wc -l) -gt 0 ]; then
        ls -lt $BASEDIR/printer_data/config/backups/*.tar.gz 2> /dev/null | awk '{print $9}' | awk -F '/' '{print $7}'
        exit 0
    else
        echo "ERROR: No backups found"
        exit 1
    fi
elif [ "$mode" = "restore" ] && [ -f $BASEDIR/printer_data/config/backups/$restore ]; then
    echo "INFO: Restoring $BASEDIR/printer_data/config/backups/$restore ..."

    # ensure the backup file is suitable for an automatic restore, older backups which do not include
    # pellcorp-overrides, pellcorp.done and pellcorp-backups are not suitable for an automatic restore
    # because they do not restore the entire state of the printer and will result in subsequent updates
    # making matters much much worse.
    backup_files=$(tar -ztvf $BASEDIR/printer_data/config/backups/$restore)
    valid_backup=true
    if [ $(echo "$backup_files" | grep "pellcorp-overrides/" | wc -l) -eq 0 ]; then
        echo "ERROR: This backup cannot be used to do a full restoration - it is missing pellcorp-overrides/"
        valid_backup=false
    fi
    if [ $(echo "$backup_files" | grep "pellcorp-backups/" | wc -l) -eq 0 ]; then
        echo "ERROR: This backup cannot be used to do a full restoration - it is missing pellcorp-backups/"
        valid_backup=false
    fi
    if [ $(echo "$backup_files" | grep "pellcorp.done" | wc -l) -eq 0 ]; then
        echo "ERROR: This backup cannot be used to do a full restoration - it is missing pellcorp.done"
        valid_backup=false
    fi
    if [ $(echo "$backup_files" | grep "printer_data/config/" | wc -l) -eq 0 ]; then
        echo "ERROR: This backup cannot be used to do a full restoration - it is missing printer_data/config/"
        valid_backup=false
    fi
    if [ "$valid_backup" = "false" ]; then
        exit 1
    fi

    if [ -d "$BASEDIR/pellcorp-overrides" ]; then
        if [ -d $BASEDIR/pellcorp-overrides.old ]; then
            rm -rf $BASEDIR/pellcorp-overrides.old
        fi
        mv $BASEDIR/pellcorp-overrides $BASEDIR/pellcorp-overrides.old
    fi

    if [ -d "$BASEDIR/pellcorp-backups" ]; then
        if [ -d $BASEDIR/pellcorp-backups.old ]; then
            rm -rf $BASEDIR/pellcorp-backups.old
        fi
        mv $BASEDIR/pellcorp-backups $BASEDIR/pellcorp-backups.old
    fi

    echo "Restoring $restore ..."
    tar -zxf $BASEDIR/printer_data/config/backups/$restore -C /usr/data
    sync

    echo "Restarting Klippper ..."
    sudo systemctl restart klipper
    echo "Restarting Moonraker ..."
    sudo systemcctl restart moonraker
else
    echo "You have the following options for using:"
    echo "  $0 --create"
    echo "  $0 --latest"
    echo "  $0 --list"
    echo "  $0 --restore <backup file|latest>"
    exit 1
fi
