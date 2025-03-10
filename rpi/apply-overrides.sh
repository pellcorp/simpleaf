#!/bin/sh

CONFIG_HELPER="$HOME/pellcorp/k1/config-helper.py"

function apply_overrides() {
    return_status=0
    if [ -d $HOME/pellcorp-overrides ]; then
        echo
        echo "INFO: Applying overrides ..."

        overrides_dir=$HOME/pellcorp-overrides

        files=$(find $overrides_dir -maxdepth 1 ! -name 'printer-*.cfg' -a ! -name ".printer.cfg" -a -name "*.cfg" -o -name "*.conf" -o -name "*.json" -o -name "printer.cfg.save_config")
        for file in $files; do
            file=$(basename $file)
            # special case for moonraker.secrets
            if [ "$file" = "moonraker.secrets" ]; then
                echo "INFO: Restoring $HOME/printer_data/$file ..."
                cp $overrides_dir/$file $HOME/printer_data/
            elif [ "$file" = "guppyscreen.json" ]; then
                $HOME/pellcorp/k1/update-guppyscreen.sh --apply-overrides
            elif [ -L $HOME/printer_data/config/$file ] || [ "$file" = "useful_macros.cfg" ] || [ "$file" = "internal_macros.cfg" ] || [ "$file" = "guppyscreen.cfg" ]; then
                if [ "$file" = "guppyscreen.cfg" ]; then  # we removed guppy module loader completely
                    $HOME/pellcorp/k1/config-helper.py --file guppyscreen.cfg --remove-section guppy_module_loader
                fi
                echo "WARN: Ignoring $file ..."
            elif [ -f "$HOME/pellcorp-backups/$file" ] || [ -f "$HOME/pellcorp/k1/$file" ]; then
              if [ -f $HOME/printer_data/config/$file ]; then
                # we renamed the SENSORLESS_PARAMS to hide it
                if [ "$file" = "sensorless.cfg" ]; then
                    sed -i 's/gcode_macro SENSORLESS_PARAMS/gcode_macro _SENSORLESS_PARAMS/g' $HOME/pellcorp-overrides/sensorless.cfg
                fi

                echo "INFO: Applying overrides for $HOME/printer_data/config/$file ..."
                $CONFIG_HELPER --file $file --overrides $overrides_dir/$file || exit $?

                if [ "$file" = "moonraker.conf" ]; then  # we moved cartographer to a separate cartographer.conf include
                    $HOME/pellcorp/k1/config-helper.py --file moonraker.conf --remove-section "update_manager cartographer"
                fi
              else # if switching probes we might run into this
                echo "WARN: Ignoring overrides for missing $HOME/printer_data/config/$file"
              fi
            elif [ "$file" != "printer.cfg.save_config" ]; then
                echo "INFO: Restoring $HOME/printer_data/config/$file ..."
                cp $overrides_dir/$file $HOME/printer_data/config/
            fi
            # fixme - we currently have no way to know if the file was updated assume if we got here it was
            return_status=1
        done

        # we want to apply the save config last
        if [ -f $overrides_dir/printer.cfg.save_config ]; then
          # if the printer.cfg already has SAVE_CONFIG skip applying it again
          if ! grep -q "#*# <---------------------- SAVE_CONFIG ---------------------->" $HOME/printer_data/config/printer.cfg ; then
            echo "INFO: Applying save config state to $HOME/printer_data/config/printer.cfg"
            echo "" >> $HOME/printer_data/config/printer.cfg
            cat $overrides_dir/printer.cfg.save_config >> $HOME/printer_data/config/printer.cfg
            return_status=1
          else
            echo "WARN: Skipped applying save config state to $HOME/printer_data/config/printer.cfg"
          fi
        fi

        if [ -d /tmp/overrides.$$ ]; then
            rm -rf /tmp/overrides.$$
        fi
    fi
    return $return_status
}

mkdir -p $HOME/printer_data/config/backups/
apply_overrides
exit $?
