#!/bin/sh

BASEDIR=/home/pi

config_overrides=true
apply_overrides=true
update_guppyscreen=true

while true; do
    if [ "$1" = "--config-overrides" ]; then
        apply_overrides=false
        update_guppyscreen=false
        shift
    elif [ "$1" = "--apply-overrides" ]; then
        config_overrides=false
        update_guppyscreen=false
        shift
    fi
    break
done

if [ "$config_overrides" = "true" ]; then
    if [ -f $BASEDIR/pellcorp-backups/guppyscreen.json ] && [ -f $BASEDIR/guppyscreen/guppyscreen.json ]; then
        [ -f $BASEDIR/pellcorp-overrides/guppyscreen.json ] && rm $BASEDIR/pellcorp-overrides/guppyscreen.json
        for entry in display_brightness invert_z_icon display_sleep_sec theme touch_calibration_coeff; do
            stock_value=$(jq -cr ".$entry" $BASEDIR/pellcorp-backups/guppyscreen.json)
            new_value=$(jq -cr ".$entry" $BASEDIR/guppyscreen/guppyscreen.json)
            # you know what its not an actual json file its just the properties we support updating
            if [ "$entry" = "touch_calibration_coeff" ] && [ "$new_value" != "null" ]; then
                echo "$entry=$new_value" >> $BASEDIR/pellcorp-overrides/guppyscreen.json
            elif [ "$stock_value" != "null" ] && [ "$new_value" != "null" ] && [ "$stock_value" != "$new_value" ]; then
                echo "$entry=$new_value" >> $BASEDIR/pellcorp-overrides/guppyscreen.json
            fi
        done
        if [ -f $BASEDIR/pellcorp-overrides/guppyscreen.json ]; then
            echo "INFO: Saving overrides to $BASEDIR/pellcorp-overrides/guppyscreen.json"
            sync
        fi
    else
        echo "INFO: Overrides not supported for $file"
    fi
fi

if [ "$update_guppyscreen" = "true" ]; then
    target=main
    if [ -n "$1" ] && [ "$1" != "nightly" ]; then
      target=$1
    fi

    asset_name=guppyscreen-rpi.tar.gz
    curl -L "https://github.com/pellcorp/guppyscreen/releases/download/$target/$asset_name" -o $BASEDIR/guppyscreen.tar.gz || exit $?
    tar xf $BASEDIR/guppyscreen.tar.gz -C $BASEDIR/ || exit $?
    rm $BASEDIR/guppyscreen.tar.gz
fi

if [ "$apply_overrides" = "true" ] && [ -f $BASEDIR/pellcorp-overrides/guppyscreen.json ]; then
    command=""
    for entry in display_brightness invert_z_icon display_sleep_sec theme touch_calibration_coeff; do
      value=$(cat $BASEDIR/pellcorp-overrides/guppyscreen.json | grep "${entry}=" | awk -F '=' '{print $2}')
      if [ -n "$value" ]; then
          if [ -n "$command" ]; then
              command="$command | "
          fi
          if [ "$entry" = "theme" ]; then
              command="${command}.${entry} = \"$value\""
          else
              command="${command}.${entry} = $value"
          fi
      fi
    done

    if [ -n "$command" ]; then
        echo "Applying overrides $BASEDIR/guppyscreen/guppyscreen.json ..."
        jq "$command" $BASEDIR/guppyscreen/guppyscreen.json > $BASEDIR/guppyscreen/guppyscreen.json.$$
        mv $BASEDIR/guppyscreen/guppyscreen.json.$$ $BASEDIR/guppyscreen/guppyscreen.json
    fi
fi

if [ "$update_guppyscreen" = "true" ]; then
    sudo systemctl restart grumpyscreen
fi
