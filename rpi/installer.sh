#!/bin/sh

if [ ! -f $HOME/printer_data/config/printer.cfg ]; then
  >&2 echo "ERROR: Printer data not setup"
  exit 1
fi

MODEL=e3

# everything else in the script assumes its cloned to $HOME/pellcorp
# so we must verify this or shit goes wrong
if [ "$(dirname $(readlink -f $0))" != "$HOME/pellcorp/k1" ]; then
  >&2 echo "ERROR: This git repo must be cloned to $HOME/pellcorp"
  exit 1
fi

REMAINING_ROOT_DISK=$(df -m / | tail -1 | awk '{print $4}')
if [ $REMAINING_ROOT_DISK -gt 25 ]; then
    echo "INFO: There is $(df -h / | tail -1 | awk '{print $4}') remaining on your / partition"
else
    echo "CRITICAL: Remaining / space is critically low!"
    echo "CRITICAL: There is $(df -h / | tail -1 | awk '{print $4}') remaining on your / partition"
    exit 1
fi

REMAINING_TMP_DISK=$(df -m /tmp | tail -1 | awk '{print $4}')
if [ $REMAINING_TMP_DISK -gt 25 ]; then
    echo "INFO: There is $(df -h /tmp | tail -1 | awk '{print $4}') remaining on your /tmp partition"
else
    echo "CRITICAL: Remaining /tmp space is critically low!"
    echo "CRITICAL: There is $(df -h /tmp | tail -1 | awk '{print $4}') remaining on your /tmp partition"
    exit 1
fi

REMAINING_DATA_DISK=$(df -m /usr/data | tail -1 | awk '{print $4}')
if [ $REMAINING_DATA_DISK -gt 1000 ]; then
    echo "INFO: There is $(df -h /usr/data | tail -1 | awk '{print $4}') remaining on your /usr/data partition"
else
    echo "CRITICAL: Remaining disk space is critically low!"
    echo "CRITICAL: There is $(df -h /usr/data | tail -1 | awk '{print $4}') remaining on your /usr/data partition"
    exit 1
fi
echo

cp $HOME/pellcorp/k1/services/S45cleanup /etc/init.d || exit $?
cp $HOME/pellcorp/k1/services/S58factoryreset /etc/init.d || exit $?
cp $HOME/pellcorp/k1/services/S50dropbear /etc/init.d/ || exit $?

# for k1 the installed curl does not do ssl, so we replace it first
# and we can then make use of it going forward
cp $HOME/pellcorp/k1/tools/curl /usr/bin/curl || exit $?

CONFIG_HELPER="$HOME/pellcorp/k1/config-helper.py"

# thanks to @Nestaa51 for the timeout changes to not wait forever for moonraker
function restart_moonraker() {
    echo
    echo "INFO: Restarting Moonraker ..."
    /etc/init.d/S56moonraker_service restart

    timeout=60
    start_time=$(date +%s)

    # this is mostly for k1-qemu where Moonraker takes a while to start up
    echo "INFO: Waiting for Moonraker ..."
    while true; do
        KLIPPER_PATH=$(curl localhost:7125/printer/info 2> /dev/null | jq -r .result.klipper_path)
        # moonraker will start reporting the location of klipper as $HOME/klipper when using a soft link
        if [ "$KLIPPER_PATH" = "/usr/share/klipper" ] || [ "$KLIPPER_PATH" = "$HOME/klipper" ]; then
            break;
        fi

        current_time=$(date +%s)
        elapsed_time=$((current_time - start_time))

        if [ $elapsed_time -ge $timeout ]; then
            break;
        fi
        sleep 1
    done
}

function update_repo() {
    local repo_dir=$1
    local branch=$2

    if [ -d "${repo_dir}/.git" ]; then
        cd $repo_dir
        branch_ref=$(git rev-parse --abbrev-ref HEAD)
        if [ -n "$branch_ref" ]; then
            git fetch
            if [ $? -ne 0 ]; then
                cd - > /dev/null
                echo "ERROR: Failed to pull latest changes!"
                return 1
            fi

            if [ -z "$branch" ]; then
                git reset --hard origin/$branch_ref
            else
                git switch $branch
                if [ $? -eq 0 ]; then
                  git reset --hard origin/$branch
                else
                  echo "ERROR: Failed to switch branches!"
                  return 1
                fi
            fi
            cd - > /dev/null
        else
            cd - > /dev/null
            echo "ERROR: Failed to detect current branch!"
            return 1
        fi
    else
        echo "ERROR: Invalid $repo_dir specified"
        return 1
    fi
    return 0
}

function update_klipper() {
  if [ -d $HOME/cartographer-klipper ]; then
      $HOME/cartographer-klipper/install.sh || return $?
  fi
  if [ -d $HOME/beacon-klipper ]; then
      $HOME/pellcorp/k1/beacon-install.sh || return $?
  fi
  /usr/share/klippy-env/bin/python3 -m compileall $HOME/klipper/klippy || return $?
  $HOME/pellcorp/k1/tools/check-firmware.sh --status
  if [ $? -eq 0 ]; then
      echo "INFO: Restarting Klipper ..."
      /etc/init.d/S55klipper_service restart
  fi
  return $?
}

function install_config_updater() {
    python3 -c 'from configupdater import ConfigUpdater' 2> /dev/null
    if [ $? -ne 0 ]; then
        echo
        echo "INFO: Installing configupdater python package ..."
        pip3 install configupdater==3.2

        python3 -c 'from configupdater import ConfigUpdater' 2> /dev/null
        if [ $? -ne 0 ]; then
            echo "ERROR: Something bad happened, can't continue"
            exit 1
        fi
    fi

    # old pellcorp-env not required anymore
    if [ -d $HOME/pellcorp-env/ ]; then
        rm -rf $HOME/pellcorp-env/
    fi
}

function install_webcam() {
    local mode=$1
    
    grep -q "webcam" $HOME/pellcorp.done
    if [ $? -ne 0 ]; then
        if [ "$mode" != "update" ] || [ ! -f /opt/bin/mjpg_streamer ]; then
            echo
            echo "INFO: Installing mjpg streamer ..."
            /opt/bin/opkg install mjpg-streamer mjpg-streamer-input-http mjpg-streamer-input-uvc mjpg-streamer-output-http mjpg-streamer-www || exit $?
        fi

        echo "INFO: Updating webcam config ..."
        # we do not want to start the entware version of the service ever
        if [ -f /opt/etc/init.d/S96mjpg-streamer ]; then
            rm /opt/etc/init.d/S96mjpg-streamer
        fi
        # kill the existing creality services so that we can use the app right away without a restart
        pidof cam_app &>/dev/null && killall -TERM cam_app > /dev/null 2>&1
        pidof mjpg_streamer &>/dev/null && killall -TERM mjpg_streamer > /dev/null 2>&1

        if [ -f /etc/init.d/S50webcam ]; then
            /etc/init.d/S50webcam stop > /dev/null 2>&1
        fi

        # auto_uvc.sh is responsible for starting the web cam_app
        [ -f /usr/bin/auto_uvc.sh ] && rm /usr/bin/auto_uvc.sh
        cp $HOME/pellcorp/k1/files/auto_uvc.sh /usr/bin/
        chmod 777 /usr/bin/auto_uvc.sh

        cp $HOME/pellcorp/k1/services/S50webcam /etc/init.d/
        /etc/init.d/S50webcam start

        if [ -f $HOME/pellcorp.ipaddress ]; then
          # don't wipe the pellcorp.ipaddress if its been explicitly set to skip
          PREVIOUS_IP_ADDRESS=$(cat $HOME/pellcorp.ipaddress 2> /dev/null)
          if [ "$PREVIOUS_IP_ADDRESS" != "skip" ]; then
            rm $HOME/pellcorp.ipaddress
          fi
        fi
        cp $HOME/pellcorp/k1/webcam.conf $HOME/printer_data/config/ || exit $?

        echo "webcam" >> $HOME/pellcorp.done
        return 1
    fi
    return 0
}

function install_moonraker() {
    local mode=$1

    grep -q "moonraker" $HOME/pellcorp.done
    if [ $? -ne 0 ]; then
        echo
        
        if [ "$mode" != "update" ] && [ -d $HOME/moonraker ]; then
            if [ -f /etc/init.d/S56moonraker_service ]; then
                /etc/init.d/S56moonraker_service stop
            fi
            if [ -d $HOME/printer_data/database/ ]; then
                [ -f $HOME/moonraker-database.tar.gz ] && rm $HOME/moonraker-database.tar.gz

                echo "INFO: Backing up moonraker database ..."
                cd $HOME/printer_data/

                tar -zcf $HOME/moonraker-database.tar.gz database/
                cd 
            fi
            rm -rf $HOME/moonraker
        fi

        if [ "$mode" != "update" ] && [ -d $HOME/moonraker-env ]; then
            rm -rf $HOME/moonraker-env
        elif [ ! -d $HOME/moonraker-env/lib/python3.8/site-packages/dbus_fast ] || [ -d $HOME/moonraker-env/lib/python3.8/site-packages/apprise-1.7.1.dist-info ]; then
            echo "INFO: Forcing recreation of moonraker-env ..."
            rm -rf $HOME/moonraker-env
        fi

        if [ -d $HOME/moonraker/.git ]; then
            cd $HOME/moonraker
            MOONRAKER_URL=$(git remote get-url origin)
            cd - > /dev/null
            if [ "$MOONRAKER_URL" != "https://github.com/pellcorp/moonraker.git" ]; then
                echo "INFO: Forcing moonraker to switch to pellcorp/moonraker"
                rm -rf $HOME/moonraker
            fi
        fi

        if [ ! -d $HOME/moonraker/.git ]; then
            echo "INFO: Installing moonraker ..."
        
            [ -d $HOME/moonraker ] && rm -rf $HOME/moonraker
            [ -d $HOME/moonraker-env ] && rm -rf $HOME/moonraker-env

            echo
            if [ "$AF_GIT_CLONE" = "ssh" ]; then
                export GIT_SSH_IDENTITY=moonraker
                export GIT_SSH=$HOME/pellcorp/k1/ssh/git-ssh.sh
                git clone git@github.com:pellcorp/moonraker.git $HOME/moonraker || exit $?
                cd $HOME/moonraker && git remote set-url origin https://github.com/pellcorp/moonraker.git && cd - > /dev/null
            else
                git clone https://github.com/pellcorp/moonraker.git $HOME/moonraker || exit $?
            fi

            if [ -f $HOME/moonraker-database.tar.gz ]; then
                echo
                echo "INFO: Restoring moonraker database ..."
                cd $HOME/printer_data/
                tar -zxf $HOME/moonraker-database.tar.gz
                rm $HOME/moonraker-database.tar.gz
                cd
            fi
        fi

        if [ ! -f $HOME/moonraker-timelapse/component/timelapse.py ]; then
            if [ -d $HOME/moonraker-timelapse ]; then
                rm -rf $HOME/moonraker-timelapse
            fi
            git clone https://github.com/mainsail-crew/moonraker-timelapse.git $HOME/moonraker-timelapse/ || exit $?
        fi

        if [ ! -d $HOME/moonraker-env ]; then
            tar -zxf $HOME/pellcorp/k1/moonraker-env.tar.gz -C $HOME/ || exit $?
        fi

        if [ "$mode" != "update" ] || [ ! -f /opt/bin/ffmpeg ]; then
            echo "INFO: Upgrading ffmpeg for moonraker timelapse ..."
            /opt/bin/opkg install ffmpeg || exit $?
        fi

        echo "INFO: Updating moonraker config ..."

        # an existing bug where the moonraker secrets was not correctly copied
        if [ ! -f $HOME/printer_data/moonraker.secrets ]; then
            cp $HOME/pellcorp/k1/moonraker.secrets $HOME/printer_data/
        fi

        ln -sf $HOME/pellcorp/k1/tools/supervisorctl /usr/bin/ || exit $?
        ln -sf $HOME/pellcorp/k1/tools/systemctl /usr/bin/ || exit $?
        ln -sf $HOME/pellcorp/k1/tools/sudo /usr/bin/ || exit $?
        cp $HOME/pellcorp/k1/services/S56moonraker_service /etc/init.d/ || exit $?
        cp $HOME/pellcorp/k1/moonraker.conf $HOME/printer_data/config/ || exit $?
        ln -sf $HOME/pellcorp/k1/moonraker.asvc $HOME/printer_data/ || exit $?

        ln -sf $HOME/moonraker-timelapse/component/timelapse.py $HOME/moonraker/moonraker/components/ || exit $?
        if ! grep -q "moonraker/components/timelapse.py" "$HOME/moonraker/.git/info/exclude"; then
            echo "moonraker/components/timelapse.py" >> "$HOME/moonraker/.git/info/exclude"
        fi
        ln -sf $HOME/moonraker-timelapse/klipper_macro/timelapse.cfg $HOME/printer_data/config/ || exit $?
        cp $HOME/pellcorp/k1/timelapse.conf $HOME/printer_data/config/ || exit $?

        ln -sf $HOME/pellcorp/k1/spoolman.cfg $HOME/printer_data/config/ || exit $?
        cp $HOME/pellcorp/k1/spoolman.conf $HOME/printer_data/config/ || exit $?

        # after an initial install do not overwrite notifier.conf or moonraker.secrets
        if [ ! -f $HOME/printer_data/config/notifier.conf ]; then
            cp $HOME/pellcorp/k1/notifier.conf $HOME/printer_data/config/ || exit $?
        fi
        if [ ! -f $HOME/printer_data/moonraker.secrets ]; then
            cp $HOME/pellcorp/k1/moonraker.secrets $HOME/printer_data/ || exit $?
        fi

        echo "moonraker" >> $HOME/pellcorp.done

        # means nginx and moonraker need to be restarted
        return 1
    fi
    return 0
}

function install_nginx() {
    local mode=$1

    grep -q "nginx" $HOME/pellcorp.done
    if [ $? -ne 0 ]; then
        command -v /usr/sbin/nginx > /dev/null
        if [ $? -ne 0 ]; then
          echo
          echo "INFO: Installing nginx ..."
          sudo apt-get install -y nginx || exit $?
        fi

        default_ui=fluidd
        if [ -f /etc/nginx/nginx/sites-enabled/mainsail ]; then
          grep "#listen" /etc/nginx/nginx/sites-enabled/mainsail > /dev/null
          if [ $? -ne 0 ]; then
            default_ui=mainsail
          fi
        fi

        echo "INFO: Updating nginx config ..."
        cp $HOME/pellcorp/k1/nginx.conf $HOME/nginx/nginx/conf.d/ || exit $?
        cp $HOME/pellcorp/k1/nginx/fluidd /etc/nginx/sites-enabled/ || exit $?
        cp $HOME/pellcorp/k1/nginx/mainsail /etc/nginx/sites-enabled/ || exit $?

        if [ "$default_ui" = "mainsail" ]; then
          echo "INFO: Restoring mainsail as default UI"
          sed -i 's/.*listen 80 default_server;/    #listen 80 default_server;/g' /etc/nginx/sites-enabled/fluidd || exit $?
          sed -i 's/.*#listen 80 default_server;/    listen 80 default_server;/g' /etc/nginx/sites-enabled/mainsail || exit $?
        fi

        sudo systemctl reload nginx

        echo "nginx" >> $HOME/pellcorp.done

        # means nginx needs to be restarted
        return 1
    fi
    return 0
}

function install_fluidd() {
    local mode=$1

    grep -q "fluidd" $HOME/pellcorp.done
    if [ $? -ne 0 ]; then
        if [ "$mode" != "update" ] && [ -d $HOME/fluidd ]; then
            rm -rf $HOME/fluidd
        fi
        if [ "$mode" != "update" ] && [ -d $HOME/fluidd-config ]; then
            rm -rf $HOME/fluidd-config
        fi

        if [ ! -d $HOME/fluidd ]; then
            echo
            echo "INFO: Installing fluidd ..."

            mkdir -p $HOME/fluidd || exit $?
            curl -L "https://github.com/fluidd-core/fluidd/releases/latest/download/fluidd.zip" -o $HOME/fluidd.zip || exit $?
            unzip -qd $HOME/fluidd $HOME/fluidd.zip || exit $?
            rm $HOME/fluidd.zip
        fi
        
        if [ ! -d $HOME/fluidd-config ]; then
            git clone https://github.com/fluidd-core/fluidd-config.git $HOME/fluidd-config || exit $?
        fi

        echo "INFO: Updating client config ..."
        [ -e $HOME/printer_data/config/fluidd.cfg ] && rm $HOME/printer_data/config/fluidd.cfg

        ln -sf $HOME/fluidd-config/client.cfg $HOME/printer_data/config/
        $CONFIG_HELPER --add-include "client.cfg" || exit $?

        # for moonraker to be able to use moonraker fluidd client.cfg out of the box need to
        ln -sf $HOME/printer_data/ /root

        # these are already defined in fluidd config so get rid of them from printer.cfg
        $CONFIG_HELPER --remove-section "pause_resume" || exit $?
        $CONFIG_HELPER --remove-section "display_status" || exit $?
        $CONFIG_HELPER --remove-section "virtual_sdcard" || exit $?

        $CONFIG_HELPER --replace-section-entry "filament_switch_sensor filament_sensor" "runout_gcode" "_ON_FILAMENT_RUNOUT" || exit $?

        echo "fluidd" >> $HOME/pellcorp.done

        # means nginx needs to be restarted
        return 1
    fi
    return 0
}

function install_mainsail() {
    local mode=$1

    grep -q "mainsail" $HOME/pellcorp.done
    if [ $? -ne 0 ]; then
        if [ "$mode" != "update" ] && [ -d $HOME/mainsail ]; then
            rm -rf $HOME/mainsail
        fi

        if [ ! -d $HOME/mainsail ]; then
            echo
            echo "INFO: Installing mainsail ..."

            mkdir -p $HOME/mainsail || exit $?
            curl -L "https://github.com/mainsail-crew/mainsail/releases/latest/download/mainsail.zip" -o $HOME/mainsail.zip || exit $?
            unzip -qd $HOME/mainsail $HOME/mainsail.zip || exit $?
            rm $HOME/mainsail.zip
        fi

        echo "INFO: Updating mainsail config ..."

        # the mainsail and fluidd client.cfg are exactly the same
        [ -f $HOME/printer_data/config/mainsail.cfg ] && rm $HOME/printer_data/config/mainsail.cfg

        echo "mainsail" >> $HOME/pellcorp.done

        # means nginx needs to be restarted
        return 1
    fi
    return 0
}

function install_kamp() {
    local mode=$1

    grep -q "KAMP" $HOME/pellcorp.done
    if [ $? -ne 0 ]; then
        if [ "$mode" != "update" ] && [ -d $HOME/KAMP ]; then
            rm -rf $HOME/KAMP
        fi
        
        if [ ! -d $HOME/KAMP/.git ]; then
            echo
            echo "INFO: Installing KAMP ..."
            [ -d $HOME/KAMP ] && rm -rf $HOME/KAMP

            if [ "$AF_GIT_CLONE" = "ssh" ]; then
                export GIT_SSH_IDENTITY=KAMP
                export GIT_SSH=$HOME/pellcorp/k1/ssh/git-ssh.sh
                git clone git@github.com:pellcorp/Klipper-Adaptive-Meshing-Purging.git $HOME/KAMP || exit $?
                cd $HOME/KAMP && git remote set-url origin https://github.com/kyleisah/Klipper-Adaptive-Meshing-Purging.git && cd - > /dev/null
            else
                git clone https://github.com/kyleisah/Klipper-Adaptive-Meshing-Purging.git $HOME/KAMP || exit $?
            fi
        fi

        echo "INFO: Updating KAMP config ..."
        ln -sf $HOME/KAMP/Configuration $HOME/printer_data/config/KAMP || exit $?

        cp $HOME/KAMP/Configuration/KAMP_Settings.cfg $HOME/printer_data/config/ || exit $?

        $CONFIG_HELPER --add-include "KAMP_Settings.cfg" || exit $?

        # LINE_PURGE
        sed -i 's:#\[include ./KAMP/Line_Purge.cfg\]:\[include ./KAMP/Line_Purge.cfg\]:g' $HOME/printer_data/config/KAMP_Settings.cfg

        # SMART_PARK
        sed -i 's:#\[include ./KAMP/Smart_Park.cfg\]:\[include ./KAMP/Smart_Park.cfg\]:g' $HOME/printer_data/config/KAMP_Settings.cfg

        # lower and longer purge line
        $CONFIG_HELPER --file KAMP_Settings.cfg --replace-section-entry "gcode_macro _KAMP_Settings" variable_purge_height 0.5
        $CONFIG_HELPER --file KAMP_Settings.cfg --replace-section-entry "gcode_macro _KAMP_Settings" variable_purge_amount 48
        # same setting as cancel_retract in start_end.cfg
        $CONFIG_HELPER --file KAMP_Settings.cfg --replace-section-entry "gcode_macro _KAMP_Settings" variable_tip_distance 7.0

        cp $HOME/printer_data/config/KAMP_Settings.cfg $HOME/pellcorp-backups/

        echo "KAMP" >> $HOME/pellcorp.done

        # means klipper needs to be restarted
        return 1
    fi
    return 0
}

function cleanup_klipper() {
    if [ -f /etc/init.d/S55klipper_service ]; then
        /etc/init.d/S55klipper_service stop
    fi
    rm -rf $HOME/klipper

    # a reinstall should reset the choice of what klipper to run
    if [ -f $HOME/pellcorp.klipper ]; then
      rm $HOME/pellcorp.klipper
    fi
}

function install_klipper() {
    local mode=$1
    local probe=$2

    grep -q "klipper" $HOME/pellcorp.done
    if [ $? -ne 0 ]; then
        echo

        klipper_repo=klipper
        existing_klipper_repo=$(cat $HOME/pellcorp.klipper 2> /dev/null)
        if [ "$mode" = "update" ] && [ "$existing_klipper_repo" = "k1-carto-klipper" ]; then
            echo "INFO: Forcing Klipper repo to be switched from pellcorp/${existing_klipper_repo} to pellcorp/${klipper_repo}"
            cleanup_klipper
        elif [ "$mode" != "update" ] && [ -d $HOME/klipper ]; then
            cleanup_klipper
        fi

        # switch to required klipper version except where there is a flag file indicating we explicitly
        # decided to use a particular version of klipper
        if [ -d $HOME/klipper/.git ] && [ ! -f $HOME/pellcorp.klipper ]; then
            cd $HOME/klipper/
            remote_repo=$(git remote get-url origin | awk -F '/' '{print $NF}' | sed 's/.git//g')
            cd - > /dev/null
            if [ "$remote_repo" != "$klipper_repo" ]; then
                echo "INFO: Forcing Klipper repo to be switched from pellcorp/${remote_repo} to pellcorp/${klipper_repo}"
                rm -rf $HOME/klipper/
            fi
        fi

        if [ ! -d $HOME/klipper/.git ]; then
            echo "INFO: Installing ${klipper_repo} ..."

            if [ "$AF_GIT_CLONE" = "ssh" ]; then
                export GIT_SSH_IDENTITY=${klipper_repo}
                export GIT_SSH=$HOME/pellcorp/k1/ssh/git-ssh.sh
                git clone git@github.com:pellcorp/${klipper_repo}.git $HOME/klipper || exit $?
                # reset the origin url to make moonraker happy
                cd $HOME/klipper && git remote set-url origin https://github.com/pellcorp/${klipper_repo}.git && cd - > /dev/null
            else
                git clone https://github.com/pellcorp/${klipper_repo}.git $HOME/klipper || exit $?
            fi
            [ -d /usr/share/klipper ] && rm -rf /usr/share/klipper
        else
            cd $HOME/klipper/
            remote_repo=$(git remote get-url origin | awk -F '/' '{print $NF}' | sed 's/.git//g')
            git log | grep -q "add SET_KINEMATIC_POSITION CLEAR=Z feature to allow us to clear z in sensorless.cfg"
            klipper_status=$?
            cd - > /dev/null

            # force klipper update to get reverted kinematic position feature
            if [ "$remote_repo" = "klipper" ] && [ $klipper_status -ne 0 ]; then
                echo "INFO: Forcing update of klipper to latest master"
                update_repo $HOME/klipper master || exit $?
            fi
        fi

        echo "INFO: Updating klipper config ..."
        /usr/share/klippy-env/bin/python3 -m compileall $HOME/klipper/klippy || exit $?

        # FIXME - one day maybe we can get rid of this link
        ln -sf $HOME/klipper /usr/share/ || exit $?

        # for scripts like ~/klipper/scripts, a soft link makes things a little bit easier
        ln -sf $HOME/klipper/ /root

        cp $HOME/pellcorp/k1/services/S55klipper_service /etc/init.d/ || exit $?

        # currently no support for updating firmware on Ender 5 Max :-(
        if [ "$MODEL" != "F004" ]; then
            cp $HOME/pellcorp/k1/services/S13mcu_update /etc/init.d/ || exit $?
        fi

        cp $HOME/pellcorp/k1/sensorless.cfg $HOME/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "sensorless.cfg" || exit $?

        # for Ender 5 Max we need to disable sensorless homing, reversing homing order,don't move away and do not repeat homing
        # but we are still going to use homing override even though the max has physical endstops to make things a bit easier
        if [ "$MODEL" = "F004" ]; then
            $CONFIG_HELPER --file sensorless.cfg --replace-section-entry "gcode_macro _SENSORLESS_PARAMS" "variable_sensorless_homing" "False" || exit $?
            $CONFIG_HELPER --file sensorless.cfg --replace-section-entry "gcode_macro _SENSORLESS_PARAMS" "variable_home_y_before_x" "True" || exit $?
            $CONFIG_HELPER --file sensorless.cfg --replace-section-entry "gcode_macro _SENSORLESS_PARAMS" "variable_repeat_home_xy" "False" || exit $?
            $CONFIG_HELPER --file sensorless.cfg --replace-section-entry "gcode_macro _SENSORLESS_PARAMS" "variable_homing_move_away_x" "0" || exit $?
            $CONFIG_HELPER --file sensorless.cfg --replace-section-entry "gcode_macro _SENSORLESS_PARAMS" "variable_homing_move_away_y" "0" || exit $?
        fi

        cp $HOME/pellcorp/k1/internal_macros.cfg $HOME/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "internal_macros.cfg" || exit $?

        cp $HOME/pellcorp/k1/useful_macros.cfg $HOME/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "useful_macros.cfg" || exit $?

        # the klipper_mcu is not even used, so just get rid of it
        $CONFIG_HELPER --remove-section "mcu rpi" || exit $?

        # ender 5 max
       if [ "$MODEL" = "F004" ]; then
            $CONFIG_HELPER --remove-section "Height_module2" || exit $?
            $CONFIG_HELPER --remove-section "z_compensate" || exit $?
            $CONFIG_HELPER --remove-section "output_pin aobi" || exit $?
            $CONFIG_HELPER --remove-section "output_pin USB_EN" || exit $?
            $CONFIG_HELPER --remove-section "hx711s" || exit $?
            $CONFIG_HELPER --remove-section "filter" || exit $?
            $CONFIG_HELPER --remove-section "dirzctl" || exit $?

            # for ender 5 max we can't use on board adxl and only beacon and cartotouch support
            # configuring separate adxl
            if [ "$probe" != "beacon" ] && [ "$probe" != "cartotouch" ]; then
                $CONFIG_HELPER --remove-section "adxl345" || exit $?
                $CONFIG_HELPER --remove-section "resonance_tester" || exit $?
            fi
        fi

        $CONFIG_HELPER --remove-section "mcu leveling_mcu" || exit $?
        $CONFIG_HELPER --remove-section "bl24c16f" || exit $?
        $CONFIG_HELPER --remove-section "prtouch_v2" || exit $?
        $CONFIG_HELPER --remove-section "output_pin power" || exit $?
        $CONFIG_HELPER --remove-section-entry "printer" "square_corner_max_velocity" || exit $?
        $CONFIG_HELPER --remove-section-entry "printer" "max_accel_to_decel" || exit $?

        # https://www.klipper3d.org/TMC_Drivers.html#prefer-to-not-specify-a-hold_current
        $CONFIG_HELPER --remove-section-entry "tmc2209 stepper_x" "hold_current" || exit $?
        $CONFIG_HELPER --remove-section-entry "tmc2209 stepper_y" "hold_current" || exit $?

        $CONFIG_HELPER --remove-include "printer_params.cfg" || exit $?
        $CONFIG_HELPER --remove-include "gcode_macro.cfg" || exit $?
        $CONFIG_HELPER --remove-include "custom_gcode.cfg" || exit $?

        if [ -f $HOME/printer_data/config/custom_gcode.cfg ]; then
            rm $HOME/printer_data/config/custom_gcode.cfg
        fi

        if [ -f $HOME/printer_data/config/gcode_macro.cfg ]; then
            rm $HOME/printer_data/config/gcode_macro.cfg
        fi

        if [ -f $HOME/printer_data/config/printer_params.cfg ]; then
            rm $HOME/printer_data/config/printer_params.cfg
        fi

        if [ -f $HOME/printer_data/config/factory_printer.cfg ]; then
            rm $HOME/printer_data/config/factory_printer.cfg
        fi

        cp $HOME/pellcorp/k1/start_end.cfg $HOME/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "start_end.cfg" || exit $?

        if [ -f $HOME/pellcorp/k1/fan_control.${model}.cfg ]; then
            cp $HOME/pellcorp/k1/fan_control.${model}.cfg $HOME/printer_data/config || exit $?
        else
            cp $HOME/pellcorp/k1/fan_control.cfg $HOME/printer_data/config || exit $?
        fi
        $CONFIG_HELPER --add-include "fan_control.cfg" || exit $?

        # K1 SE has no chamber fan
        if [ "$MODEL" = "K1 SE" ]; then
            $CONFIG_HELPER --file fan_control.cfg --remove-section "gcode_macro M191" || exit $?
            $CONFIG_HELPER --file fan_control.cfg --remove-section "gcode_macro M141" || exit $?
            $CONFIG_HELPER --file fan_control.cfg --remove-section "temperature_sensor chamber_temp" || exit $?
            $CONFIG_HELPER --file fan_control.cfg --remove-section "temperature_fan chamber_fan" || exit $?
            $CONFIG_HELPER --file fan_control.cfg --remove-section "fan_generic chamber" || exit $?
            $CONFIG_HELPER --file fan_control.cfg --replace-section-entry "duplicate_pin_override" "pins" "PC5" || exit $?
        elif [ "$MODEL" = "F004" ]; then
            $CONFIG_HELPER --remove-section "output_pin MainBoardFan" || exit $?
            $CONFIG_HELPER --remove-section "output_pin en_nozzle_fan" || exit $?
            $CONFIG_HELPER --remove-section "output_pin en_fan0" || exit $?
            $CONFIG_HELPER --remove-section "output_pin col_pwm" || exit $?
            $CONFIG_HELPER --remove-section "output_pin col" || exit $?
            $CONFIG_HELPER --remove-section "heater_fan nozzle_fan" || exit $?
        fi

        $CONFIG_HELPER --remove-section "output_pin fan0" || exit $?
        $CONFIG_HELPER --remove-section "output_pin fan1" || exit $?
        $CONFIG_HELPER --remove-section "output_pin fan2" || exit $?

        # a few strange duplicate pins appear in some firmware
        $CONFIG_HELPER --remove-section "output_pin PA0" || exit $?
        $CONFIG_HELPER --remove-section "output_pin PB2" || exit $?
        $CONFIG_HELPER --remove-section "output_pin PB10" || exit $?
        $CONFIG_HELPER --remove-section "output_pin PC8" || exit $?
        $CONFIG_HELPER --remove-section "output_pin PC9" || exit $?
        
        # duplicate pin can only be assigned once, so we remove it from printer.cfg so we can
        # configure it in fan_control.cfg
        $CONFIG_HELPER --remove-section "duplicate_pin_override" || exit $?
        
        # no longer required as we configure the part fan entirely in fan_control.cfg
        $CONFIG_HELPER --remove-section "static_digital_output my_fan_output_pins" || exit $?

        # moving the heater_fan to fan_control.cfg
        $CONFIG_HELPER --remove-section "heater_fan hotend_fan" || exit $?

        # all the fans and temp sensors are going to fan control now
        $CONFIG_HELPER --remove-section "temperature_sensor mcu_temp" || exit $?
        $CONFIG_HELPER --remove-section "temperature_sensor chamber_temp" || exit $?
        $CONFIG_HELPER --remove-section "temperature_fan chamber_fan" || exit $?

        # just in case anyone manually has added this to printer.cfg
        $CONFIG_HELPER --remove-section "temperature_fan mcu_fan" || exit $?

        # the nozzle should not trigger the MCU anymore        
        $CONFIG_HELPER --remove-section "multi_pin heater_fans" || exit $?

        # moving idle timeout to start_end.cfg so we can have some integration with
        # start and end print and warp stabilisation if needed
        $CONFIG_HELPER --remove-section "idle_timeout" || exit $?

        # just in case its missing from stock printer.cfg make sure it gets added
        $CONFIG_HELPER --add-section "exclude_object" || exit $?

        echo "klipper" >> $HOME/pellcorp.done

        # means klipper needs to be restarted
        return 1
    fi
    return 0
}

function setup_probe() {
    grep -q "probe" $HOME/pellcorp.done
    if [ $? -ne 0 ]; then
        echo
        echo "INFO: Setting up generic probe config ..."

        $CONFIG_HELPER --remove-section "bed_mesh" || exit $?
        $CONFIG_HELPER --remove-section-entry "stepper_z" "position_endstop" || exit $?
        $CONFIG_HELPER --replace-section-entry "stepper_z" "endstop_pin" "probe:z_virtual_endstop" || exit $?

        cp $HOME/pellcorp/k1/quickstart.cfg $HOME/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "quickstart.cfg" || exit $?

        # because we are using force move with 3mm, as a safety feature we will lower the position max
        # by 3mm ootb to avoid damaging the printer if you do a really big print
        position_max=$($CONFIG_HELPER --get-section-entry "stepper_z" "position_max" --minus 3 --integer)
        $CONFIG_HELPER --replace-section-entry "stepper_z" "position_max" "$position_max" || exit $?

        echo "probe" >> $HOME/pellcorp.done

        # means klipper needs to be restarted
        return 1
    fi
    return 0
}

function install_cartographer_klipper() {
    local mode=$1

    grep -q "cartographer-klipper" $HOME/pellcorp.done
    if [ $? -ne 0 ]; then
        if [ "$mode" != "update" ] && [ -d $HOME/cartographer-klipper ]; then
            rm -rf $HOME/cartographer-klipper
        fi

        if [ ! -d $HOME/cartographer-klipper ]; then
            echo
            echo "INFO: Installing cartographer-klipper ..."
            git clone https://github.com/pellcorp/cartographer-klipper.git $HOME/cartographer-klipper || exit $?
        else
            cd $HOME/cartographer-klipper
            REMOTE_URL=$(git remote get-url origin)
            if [ "$REMOTE_URL" != "https://github.com/pellcorp/cartographer-klipper.git" ]; then
                echo "INFO: Switching cartographer-klipper to pellcorp fork"
                git remote set-url origin https://github.com/pellcorp/cartographer-klipper.git
                git fetch origin
            fi

            branch=$(git rev-parse --abbrev-ref HEAD)
            # do not stuff up a different branch
            if [ "$branch" = "master" ]; then
                revision=$(git rev-parse --short HEAD)
                # reset our branch or update from v1.0.5
                if [ "$revision" = "303ea63" ] || [ "$revision" = "8324877" ]; then
                    echo "INFO: Forcing cartographer-klipper update"
                    git fetch origin
                    git reset --hard v1.1.0
                fi
            fi
        fi
        cd - > /dev/null

        echo
        echo "INFO: Running cartographer-klipper installer ..."
        bash $HOME/cartographer-klipper/install.sh || exit $?
        /usr/share/klippy-env/bin/python3 -m compileall $HOME/klipper/klippy || exit $?

        echo "cartographer-klipper" >> $HOME/pellcorp.done
        return 1
    fi
    return 0
}

function install_beacon_klipper() {
    local mode=$1

    grep -q "beacon-klipper" $HOME/pellcorp.done
    if [ $? -ne 0 ]; then
        if [ "$mode" != "update" ] && [ -d $HOME/beacon-klipper ]; then
            rm -rf $HOME/beacon-klipper
        fi

        if [ ! -d $HOME/beacon-klipper ]; then
            echo
            echo "INFO: Installing beacon-klipper ..."
            git clone https://github.com/beacon3d/beacon_klipper $HOME/beacon-klipper || exit $?
        fi

        # FIXME - maybe beacon will accept a PR to make their installer work on k1
        $HOME/pellcorp/k1/beacon-install.sh

        /usr/share/klippy-env/bin/python3 -m compileall $HOME/klipper/klippy || exit $?

        echo "beacon-klipper" >> $HOME/pellcorp.done
        return 1
    fi
    return 0
}

function cleanup_probe() {
    local probe=$1

    if [ -f $HOME/printer_data/config/${probe}_macro.cfg ]; then
        rm $HOME/printer_data/config/${probe}_macro.cfg
    fi
    $CONFIG_HELPER --remove-include "${probe}_macro.cfg" || exit $?

    if [ "$probe" = "cartotouch" ] || [ "$probe" = "beacon" ]; then
        $CONFIG_HELPER --remove-section-entry "stepper_z" "homing_retract_dist" || exit $?
    fi

    if [ -f $HOME/printer_data/config/$probe.cfg ]; then
        rm $HOME/printer_data/config/$probe.cfg
    fi
    $CONFIG_HELPER --remove-include "$probe.cfg" || exit $?

    # if switching from btt eddy remove this file
    if [ "$probe" = "btteddy" ] && [ -f $HOME/printer_data/config/variables.cfg ]; then
        rm $HOME/printer_data/config/variables.cfg
    fi

    # we use the cartographer includes
    if [ "$probe" = "cartotouch" ]; then
        probe=cartographer
    elif [ "$probe" = "eddyng" ]; then
        probe=btteddy
    fi

    if [ -f $HOME/printer_data/config/${probe}.conf ]; then
        rm $HOME/printer_data/config/${probe}.conf
    fi

    $CONFIG_HELPER --file moonraker.conf --remove-include "${probe}.conf" || exit $?

    if [ -f $HOME/printer_data/config/${probe}_calibrate.cfg ]; then
        rm $HOME/printer_data/config/${probe}_calibrate.cfg
    fi
    $CONFIG_HELPER --remove-include "${probe}_calibrate.cfg" || exit $?

    [ -f $HOME/printer_data/config/$probe-${model}.cfg ] && rm $HOME/printer_data/config/$probe-${model}.cfg
    $CONFIG_HELPER --remove-include "$probe-${model}.cfg" || exit $?
}

function setup_bltouch() {
    grep -q "bltouch-probe" $HOME/pellcorp.done
    if [ $? -ne 0 ]; then
        echo
        echo "INFO: Setting up bltouch/crtouch/3dtouch ..."

        cleanup_probe microprobe
        cleanup_probe btteddy
        cleanup_probe eddyng
        cleanup_probe cartotouch
        cleanup_probe beacon
        cleanup_probe klicky

        # we merge bltouch.cfg into printer.cfg so that z_offset can be set
        if [ -f $HOME/printer_data/config/bltouch.cfg ]; then
          rm $HOME/printer_data/config/bltouch.cfg
        fi
        $CONFIG_HELPER --remove-include "bltouch.cfg" || exit $?
        $CONFIG_HELPER --overrides "$HOME/pellcorp/k1/bltouch.cfg" || exit $?

        cp $HOME/pellcorp/k1/bltouch_macro.cfg $HOME/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "bltouch_macro.cfg" || exit $?

        cp $HOME/pellcorp/k1/bltouch-${model}.cfg $HOME/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "bltouch-${model}.cfg" || exit $?

        # because the model sits out the back we do need to set position max back
        position_max=$($CONFIG_HELPER --get-section-entry "stepper_y" "position_max" --minus 17 --integer)
        $CONFIG_HELPER --replace-section-entry "stepper_y" "position_max" "$position_max" || exit $?

        echo "bltouch-probe" >> $HOME/pellcorp.done

        # means klipper needs to be restarted
        return 1
    fi
    return 0
}

function setup_microprobe() {
    grep -q "microprobe-probe" $HOME/pellcorp.done
    if [ $? -ne 0 ]; then
        echo
        echo "INFO: Setting up microprobe ..."

        cleanup_probe bltouch
        cleanup_probe btteddy
        cleanup_probe eddyng
        cleanup_probe cartotouch
        cleanup_probe beacon
        cleanup_probe klicky

        # we merge microprobe.cfg into printer.cfg so that z_offset can be set
        if [ -f $HOME/printer_data/config/microprobe.cfg ]; then
          rm $HOME/printer_data/config/microprobe.cfg
        fi
        $CONFIG_HELPER --remove-include "microprobe.cfg" || exit $?
        $CONFIG_HELPER --overrides "$HOME/pellcorp/k1/microprobe.cfg" || exit $?

        cp $HOME/pellcorp/k1/microprobe_macro.cfg $HOME/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "microprobe_macro.cfg" || exit $?

        cp $HOME/pellcorp/k1/microprobe-${model}.cfg $HOME/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "microprobe-${model}.cfg" || exit $?

        echo "microprobe-probe" >> $HOME/pellcorp.done

        # means klipper needs to be restarted
        return 1
    fi
    return 0
}

function setup_klicky() {
    grep -q "klicky-probe" $HOME/pellcorp.done
    if [ $? -ne 0 ]; then
        echo
        echo "INFO: Setting up klicky ..."

        cleanup_probe bltouch
        cleanup_probe btteddy
        cleanup_probe eddyng
        cleanup_probe cartotouch
        cleanup_probe beacon
        cleanup_probe microprobe

        cp $HOME/pellcorp/k1/klicky.cfg $HOME/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "klicky.cfg" || exit $?

        # need to add a empty probe section for baby stepping to work
        $CONFIG_HELPER --add-section "probe" || exit $?
        z_offset=$($CONFIG_HELPER --ignore-missing --file $HOME/pellcorp-overrides/printer.cfg.save_config --get-section-entry probe z_offset)
        if [ -n "$z_offset" ]; then
          $CONFIG_HELPER --replace-section-entry "probe" "# z_offset" "2.0" || exit $?
        else
          $CONFIG_HELPER --replace-section-entry "probe" "z_offset" "2.0" || exit $?
        fi

        cp $HOME/pellcorp/k1/klicky_macro.cfg $HOME/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "klicky_macro.cfg" || exit $?

        cp $HOME/pellcorp/k1/klicky-${model}.cfg $HOME/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "klicky-${model}.cfg" || exit $?

        echo "klicky-probe" >> $HOME/pellcorp.done

        # means klipper needs to be restarted
        return 1
    fi
    return 0
}

function set_serial_cartotouch() {
    local SERIAL_ID=$(ls /dev/serial/by-id/usb-Cartographer* | head -1)
    if [ -n "$SERIAL_ID" ]; then
        local EXISTING_SERIAL_ID=$($CONFIG_HELPER --file cartotouch.cfg --get-section-entry "scanner" "serial")
        if [ "$EXISTING_SERIAL_ID" != "$SERIAL_ID" ]; then
            $CONFIG_HELPER --file cartotouch.cfg --replace-section-entry "scanner" "serial" "$SERIAL_ID" || exit $?
            return 1
        else
            echo "Serial value is unchanged"
            return 0
        fi
    else
        echo "WARNING: There does not seem to be a cartographer attached - skipping auto configuration"
        return 0
    fi
}

function setup_cartotouch() {
    grep -q "cartotouch-probe" $HOME/pellcorp.done
    if [ $? -ne 0 ]; then
        echo
        echo "INFO: Setting up carto touch ..."

        cleanup_probe bltouch
        cleanup_probe microprobe
        cleanup_probe btteddy
        cleanup_probe eddyng
        cleanup_probe beacon
        cleanup_probe klicky

        cp $HOME/pellcorp/k1/cartographer.conf $HOME/printer_data/config/ || exit $?
        $CONFIG_HELPER --file moonraker.conf --add-include "cartographer.conf" || exit $?

        cp $HOME/pellcorp/k1/cartotouch_macro.cfg $HOME/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "cartotouch_macro.cfg" || exit $?

        $CONFIG_HELPER --replace-section-entry "stepper_z" "homing_retract_dist" "0" || exit $?

        cp $HOME/pellcorp/k1/cartotouch.cfg $HOME/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "cartotouch.cfg" || exit $?

        set_serial_cartotouch

        # a slight change to the way cartotouch is configured
        $CONFIG_HELPER --remove-section "force_move" || exit $?

        # as we are referencing the included cartographer now we want to remove the included value
        # from any previous installation
        $CONFIG_HELPER --remove-section "scanner" || exit $?
        $CONFIG_HELPER --add-section "scanner" || exit $?

        scanner_touch_z_offset=$($CONFIG_HELPER --ignore-missing --file $HOME/pellcorp-overrides/printer.cfg.save_config --get-section-entry scanner scanner_touch_z_offset)
        if [ -n "$scanner_touch_z_offset" ]; then
          $CONFIG_HELPER --replace-section-entry "scanner" "# scanner_touch_z_offset" "0.05" || exit $?
        else
          $CONFIG_HELPER --replace-section-entry "scanner" "scanner_touch_z_offset" "0.05" || exit $?
        fi

        scanner_mode=$($CONFIG_HELPER --ignore-missing --file $HOME/pellcorp-overrides/printer.cfg.save_config --get-section-entry scanner mode)
        if [ -n "$scanner_mode" ]; then
            $CONFIG_HELPER --replace-section-entry "scanner" "# mode" "touch" || exit $?
        else
            $CONFIG_HELPER --replace-section-entry "scanner" "mode" "touch" || exit $?
        fi

        cp $HOME/pellcorp/k1/cartographer-${model}.cfg $HOME/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "cartographer-${model}.cfg" || exit $?

        if [ "$MODEL" != "F004" ]; then
            # because the model sits out the back we do need to set position max back
            position_max=$($CONFIG_HELPER --get-section-entry "stepper_y" "position_max" --minus 16 --integer)
            $CONFIG_HELPER --replace-section-entry "stepper_y" "position_max" "$position_max" || exit $?
        fi

        cp $HOME/pellcorp/k1/cartographer_calibrate.cfg $HOME/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "cartographer_calibrate.cfg" || exit $?

        # Ender 5 Max we don't have firmware for it, so need to configure cartographer instead for adxl
        if [ "$MODEL" = "F004" ]; then
            $CONFIG_HELPER --replace-section-entry "adxl345" "cs_pin" "scanner:PA3" || exit $?
            $CONFIG_HELPER --replace-section-entry "adxl345" "spi_bus" "spi1" || exit $?
            $CONFIG_HELPER --replace-section-entry "adxl345" "axes_map" "x,y,z" || exit $?
            $CONFIG_HELPER --remove-section-entry "adxl345" "spi_speed" || exit $?
            $CONFIG_HELPER --remove-section-entry "adxl345" "spi_software_sclk_pin" || exit $?
            $CONFIG_HELPER --remove-section-entry "adxl345" "spi_software_mosi_pin" || exit $?
            $CONFIG_HELPER --remove-section-entry "adxl345" "spi_software_miso_pin" || exit $?
        fi

        echo "cartotouch-probe" >> $HOME/pellcorp.done
        return 1
    fi
    return 0
}

function set_serial_beacon() {
    local SERIAL_ID=$(ls /dev/serial/by-id/usb-Beacon_Beacon* | head -1)
    if [ -n "$SERIAL_ID" ]; then
        local EXISTING_SERIAL_ID=$($CONFIG_HELPER --file beacon.cfg --get-section-entry "beacon" "serial")
        if [ "$EXISTING_SERIAL_ID" != "$SERIAL_ID" ]; then
            $CONFIG_HELPER --file beacon.cfg --replace-section-entry "beacon" "serial" "$SERIAL_ID" || exit $?
            return 1
        else
            echo "Serial value is unchanged"
            return 0
        fi
    else
        echo "WARNING: There does not seem to be a beacon attached - skipping auto configuration"
        return 0
    fi
}

function setup_beacon() {
    grep -q "beacon-probe" $HOME/pellcorp.done
    if [ $? -ne 0 ]; then
        echo
        echo "INFO: Setting up beacon ..."

        cleanup_probe bltouch
        cleanup_probe microprobe
        cleanup_probe btteddy
        cleanup_probe eddyng
        cleanup_probe cartotouch
        cleanup_probe klicky

        cp $HOME/pellcorp/k1/beacon.conf $HOME/printer_data/config/ || exit $?
        $CONFIG_HELPER --file moonraker.conf --add-include "beacon.conf" || exit $?

        cp $HOME/pellcorp/k1/beacon_macro.cfg $HOME/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "beacon_macro.cfg" || exit $?

        $CONFIG_HELPER --replace-section-entry "stepper_z" "homing_retract_dist" "0" || exit $?

        cp $HOME/pellcorp/k1/beacon.cfg $HOME/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "beacon.cfg" || exit $?

        # for beacon can't use homing override
        $CONFIG_HELPER --file sensorless.cfg --remove-section "homing_override"

        y_position_mid=$($CONFIG_HELPER --get-section-entry "stepper_y" "position_max" --divisor 2 --integer)
        x_position_mid=$($CONFIG_HELPER --get-section-entry "stepper_x" "position_max" --divisor 2 --integer)
        $CONFIG_HELPER --file beacon.cfg --replace-section-entry "beacon" "home_xy_position" "$x_position_mid,$y_position_mid" || exit $?

        # for Ender 5 Max need to swap homing order for beacon
        if [ "$MODEL" = "F004" ]; then
            $CONFIG_HELPER --file beacon.cfg --replace-section-entry "beacon" "home_y_before_x" "True" || exit $?
        fi

        set_serial_beacon

        $CONFIG_HELPER --remove-section "beacon" || exit $?
        $CONFIG_HELPER --add-section "beacon" || exit $?

        beacon_cal_nozzle_z=$($CONFIG_HELPER --ignore-missing --file $HOME/pellcorp-overrides/printer.cfg.save_config --get-section-entry beacon cal_nozzle_z)
        if [ -n "$beacon_cal_nozzle_z" ]; then
          $CONFIG_HELPER --replace-section-entry "beacon" "# cal_nozzle_z" "0.1" || exit $?
        else
          $CONFIG_HELPER --replace-section-entry "beacon" "cal_nozzle_z" "0.1" || exit $?
        fi

        cp $HOME/pellcorp/k1/beacon-${model}.cfg $HOME/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "beacon-${model}.cfg" || exit $?

        if [ "$MODEL" != "F004" ]; then
            # 25mm for safety in case someone is using a RevD or low profile, lots of space to reclaim
            # if you are using the side mount
            position_max=$($CONFIG_HELPER --get-section-entry "stepper_y" "position_max" --minus 25 --integer)
            $CONFIG_HELPER --replace-section-entry "stepper_y" "position_max" "$position_max" || exit $?
        fi

        echo "beacon-probe" >> $HOME/pellcorp.done
        return 1
    fi
    return 0
}

function set_serial_btteddy() {
    local SERIAL_ID=$(ls /dev/serial/by-id/usb-Klipper_rp2040* | head -1)
    if [ -n "$SERIAL_ID" ]; then
        local EXISTING_SERIAL_ID=$($CONFIG_HELPER --file btteddy.cfg --get-section-entry "mcu eddy" "serial")
        if [ "$EXISTING_SERIAL_ID" != "$SERIAL_ID" ]; then
            $CONFIG_HELPER --file btteddy.cfg --replace-section-entry "mcu eddy" "serial" "$SERIAL_ID" || exit $?
            return 1
        else
            echo "Serial value is unchanged"
            return 0
        fi
    else
        echo "WARNING: There does not seem to be a btt eddy attached - skipping auto configuration"
        return 0
    fi
}

function setup_btteddy() {
    grep -q "btteddy-probe" $HOME/pellcorp.done
    if [ $? -ne 0 ]; then
        echo
        echo "INFO: Setting up btteddy ..."

        cleanup_probe bltouch
        cleanup_probe microprobe
        cleanup_probe cartotouch
        cleanup_probe beacon
        cleanup_probe eddyng
        cleanup_probe klicky

        cp $HOME/pellcorp/k1/btteddy.cfg $HOME/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "btteddy.cfg" || exit $?

        set_serial_btteddy

        cp $HOME/pellcorp/k1/btteddy_macro.cfg $HOME/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "btteddy_macro.cfg" || exit $?

        # K1 SE has no chamber fan
        if [ "$MODEL" = "K1 SE" ]; then
            sed -i '/SET_FAN_SPEED FAN=chamber.*/d' $HOME/printer_data/config/btteddy_macro.cfg
        fi

        $CONFIG_HELPER --remove-section "probe_eddy_current btt_eddy" || exit $?
        $CONFIG_HELPER --add-section "probe_eddy_current btt_eddy" || exit $?

        cp $HOME/pellcorp/k1/btteddy-${model}.cfg $HOME/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "btteddy-${model}.cfg" || exit $?

        # because the model sits out the back we do need to set position max back
        position_max=$($CONFIG_HELPER --get-section-entry "stepper_y" "position_max" --minus 16 --integer)
        $CONFIG_HELPER --replace-section-entry "stepper_y" "position_max" "$position_max" || exit $?

        cp $HOME/pellcorp/k1/btteddy_calibrate.cfg $HOME/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "btteddy_calibrate.cfg" || exit $?

        echo "btteddy-probe" >> $HOME/pellcorp.done
        return 1
    fi
    return 0
}

function set_serial_eddyng() {
    local SERIAL_ID=$(ls /dev/serial/by-id/usb-Klipper_rp2040* | head -1)
    if [ -n "$SERIAL_ID" ]; then
        local EXISTING_SERIAL_ID=$($CONFIG_HELPER --file eddyng.cfg --get-section-entry "mcu eddy" "serial")
        if [ "$EXISTING_SERIAL_ID" != "$SERIAL_ID" ]; then
            $CONFIG_HELPER --file eddyng.cfg --replace-section-entry "mcu eddy" "serial" "$SERIAL_ID" || exit $?
            return 1
        else
            echo "Serial value is unchanged"
            return 0
        fi
    else
        echo "WARNING: There does not seem to be a btt eddy ng attached - skipping auto configuration"
        return 0
    fi
}

function setup_eddyng() {
    grep -q "eddyng-probe" $HOME/pellcorp.done
    if [ $? -ne 0 ]; then
        echo
        echo "INFO: Setting up btt eddy-ng ..."

        cleanup_probe bltouch
        cleanup_probe microprobe
        cleanup_probe cartotouch
        cleanup_probe beacon
        cleanup_probe btteddy

        cp $HOME/pellcorp/k1/eddyng.cfg $HOME/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "eddyng.cfg" || exit $?

        set_serial_eddyng

        cp $HOME/pellcorp/k1/eddyng_macro.cfg $HOME/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "eddyng_macro.cfg" || exit $?

        $CONFIG_HELPER --remove-section "probe_eddy_ng btt_eddy" || exit $?
        $CONFIG_HELPER --add-section "probe_eddy_ng btt_eddy" || exit $?

        cp $HOME/pellcorp/k1/btteddy-${model}.cfg $HOME/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "btteddy-${model}.cfg" || exit $?

        # because the model sits out the back we do need to set position max back
        position_max=$($CONFIG_HELPER --get-section-entry "stepper_y" "position_max" --minus 16 --integer)
        $CONFIG_HELPER --replace-section-entry "stepper_y" "position_max" "$position_max" || exit $?

        echo "eddyng-probe" >> $HOME/pellcorp.done
        return 1
    fi
    return 0
}

function install_entware() {
    local mode=$1
    if ! grep -q "entware" $HOME/pellcorp.done; then
        echo
        $HOME/pellcorp/k1/entware-install.sh "$mode" || exit $?

        echo "entware" >> $HOME/pellcorp.done
    fi
}

function apply_overrides() {
    return_status=0
    grep -q "overrides" $HOME/pellcorp.done
    if [ $? -ne 0 ]; then
        $HOME/pellcorp/k1/apply-overrides.sh
        return_status=$?
        echo "overrides" >> $HOME/pellcorp.done
    fi
    return $return_status
}

# the start_end.cfg CLIENT_VARIABLE configuration must be based on the printer.cfg max positions after
# mount overrides and user overrides have been applied
function fixup_client_variables_config() {
    echo
    echo "INFO: Fixing up client variables ..."

    changed=0
    position_min_x=$($CONFIG_HELPER --get-section-entry "stepper_x" "position_min" --integer)
    position_min_y=$($CONFIG_HELPER --get-section-entry "stepper_y" "position_min" --integer)
    position_max_x=$($CONFIG_HELPER --get-section-entry "stepper_x" "position_max" --integer)
    position_max_y=$($CONFIG_HELPER --get-section-entry "stepper_y" "position_max" --integer)
    variable_custom_park_y=$($CONFIG_HELPER --file start_end.cfg --get-section-entry "gcode_macro _CLIENT_VARIABLE" "variable_custom_park_y" --integer)
    variable_custom_park_x=$($CONFIG_HELPER --file start_end.cfg --get-section-entry "gcode_macro _CLIENT_VARIABLE" "variable_custom_park_x" --integer)
    variable_park_at_cancel_y=$($CONFIG_HELPER --file start_end.cfg --get-section-entry "gcode_macro _CLIENT_VARIABLE" "variable_park_at_cancel_y" --integer)
    variable_park_at_cancel_x=$($CONFIG_HELPER --file start_end.cfg --get-section-entry "gcode_macro _CLIENT_VARIABLE" "variable_park_at_cancel_x" --integer)

    if [ $position_max_x -le $position_min_x ]; then
        echo "ERROR: The stepper_x position_max seems to be incorrect: $position_max_x"
        return 0
    fi
    if [ $position_max_y -le $position_min_y ]; then
        echo "ERROR: The stepper_y position_max seems to be incorrect: $position_max_y"
        return 0
    fi
    if [ -z "$variable_custom_park_y" ]; then
        echo "ERROR: The variable_custom_park_y has no value"
        return 0
    fi
    if [ -z "$variable_custom_park_x" ]; then
        echo "ERROR: The variable_custom_park_x has no value"
        return 0
    fi
    if [ -z "$variable_park_at_cancel_y" ]; then
        echo "ERROR: The variable_park_at_cancel_y has no value"
        return 0
    fi
    if [ -z "$variable_park_at_cancel_x" ]; then
        echo "ERROR: The variable_park_at_cancel_x has no value"
        return 0
    fi

    if [ $variable_custom_park_x -eq 0 ] || [ $variable_custom_park_x -ge $position_max_x ] || [ $variable_custom_park_x -le $position_min_x ]; then
        pause_park_x=$((position_max_x - 10))
        if [ $pause_park_x -ne $variable_custom_park_x ]; then
            echo "Overriding variable_custom_park_x to $pause_park_x (was $variable_custom_park_x)"
            $CONFIG_HELPER --file start_end.cfg --replace-section-entry "gcode_macro _CLIENT_VARIABLE" "variable_custom_park_x" $pause_park_x
            changed=1
        fi
    fi

    if [ $variable_custom_park_y -eq 0 ] || [ $variable_custom_park_y -le $position_min_y ]; then
        pause_park_y=$(($position_min_y + 10))
        if [ $pause_park_y -ne $variable_custom_park_y ]; then
            echo "Overriding variable_custom_park_y to $pause_park_y (was $variable_custom_park_y)"
            $CONFIG_HELPER --file start_end.cfg --replace-section-entry "gcode_macro _CLIENT_VARIABLE" "variable_custom_park_y" $pause_park_y
            changed=1
        fi
    fi

    # as long as parking has not been overriden
    if [ $variable_park_at_cancel_x -eq 0 ] || [ $variable_park_at_cancel_x -ge $position_max_x ]; then
        custom_park_x=$((position_max_x - 10))
        if [ $custom_park_x -ne $variable_park_at_cancel_x ]; then
            echo "Overriding variable_park_at_cancel_x to $custom_park_x (was $variable_park_at_cancel_x)"
            $CONFIG_HELPER --file start_end.cfg --replace-section-entry "gcode_macro _CLIENT_VARIABLE" "variable_park_at_cancel_x" $custom_park_x
            changed=1
        fi
    fi

    if [ $variable_park_at_cancel_y -eq 0 ] || [ $variable_park_at_cancel_y -ge $position_max_y ]; then
        custom_park_y=$((position_max_y - 10))
        if [ $custom_park_y -ne $variable_park_at_cancel_y ]; then
            echo "Overriding variable_park_at_cancel_y to $custom_park_y (was $variable_park_at_cancel_y)"
            $CONFIG_HELPER --file start_end.cfg --replace-section-entry "gcode_macro _CLIENT_VARIABLE" "variable_park_at_cancel_y" $custom_park_y
            changed=1
        fi
    fi

    return $changed
}

function fix_custom_config() {
    changed=0
    custom_configs=$(find $HOME/printer_data/config/ -maxdepth 1 -exec grep -l "\[gcode_macro M109\]" {} \;)
    if [ -n "$custom_configs" ]; then
        for custom_config in $custom_configs; do
            filename=$(basename $custom_config)
            if [ "$filename" != "useful_macros.cfg" ]; then
                echo "INFO: Deleting M109 macro from $custom_config"
                $CONFIG_HELPER --file $filename --remove-section "gcode_macro M109"
                changed=1
            fi
        done
    fi
    custom_configs=$(find $HOME/printer_data/config/ -maxdepth 1 -exec grep -l "\[gcode_macro M190\]" {} \;)
    if [ -n "$custom_configs" ]; then
        for custom_config in $custom_configs; do
            filename=$(basename $custom_config)
            if [ "$filename" != "useful_macros.cfg" ]; then
                echo "INFO: Deleting M190 macro from $custom_config"
                $CONFIG_HELPER --file $filename --remove-section "gcode_macro M190"
                changed=1
            fi
        done
    fi
    return $changed
}

# special mode to update the repo only
# this stuff we do not want to have a log file for
if [ "$1" = "--update-repo" ] || [ "$1" = "--update-branch" ]; then
    update_repo $HOME/pellcorp
    exit $?
elif [ "$1" = "--branch" ] && [ -n "$2" ]; then # convenience for testing new features
    update_repo $HOME/pellcorp $2 || exit $?
    exit $?
elif [ "$1" = "--cartographer-branch" ]; then
    shift
    if [ -d $HOME/cartographer-klipper ]; then
        branch=master
        channel=stable
        if [ "$1" = "stable" ]; then
            branch=master
        elif [ "$1" = "beta" ]; then
            branch=beta
            channel=dev
        else
            branch=$1
            channel=dev
        fi
        update_repo $HOME/cartographer-klipper $branch || exit $?
        update_klipper || exit $?
        if [ -f $HOME/printer_data/config/cartographer.conf ]; then
            $CONFIG_HELPER --file cartographer.conf --replace-section-entry 'update_manager cartographer' channel $channel || exit $?
            $CONFIG_HELPER --file cartographer.conf --replace-section-entry 'update_manager cartographer' primary_branch $branch || exit $?
            restart_moonraker || exit $?
        fi
    else
        echo "Error cartographer-klipper repo does not exist"
        exit 1
    fi
    exit 0
elif [ "$1" = "--klipper-branch" ]; then # convenience for testing new features
    if [ -n "$2" ]; then
        update_repo $HOME/klipper $2 || exit $?
        update_klipper || exit $?
        exit 0
    else
        echo "Error invalid branch specified"
        exit 1
    fi
elif [ "$1" = "--klipper-repo" ]; then # convenience for testing new features
    if [ -n "$2" ]; then
        klipper_repo=$2
        if [ "$klipper_repo" = "k1-carto-klipper" ]; then
            echo "ERROR: Switching to k1-carto-klipper is no longer supported"
            exit 1
        fi

        if [ -d $HOME/klipper/.git ]; then
            cd $HOME/klipper/
            remote_repo=$(git remote get-url origin | awk -F '/' '{print $NF}' | sed 's/.git//g')
            cd - > /dev/null
            if [ "$remote_repo" != "$klipper_repo" ]; then
                echo "INFO: Switching klipper from pellcorp/$remote_repo to pellcorp/${klipper_repo} ..."
                rm -rf $HOME/klipper

                echo "$klipper_repo" > $HOME/pellcorp.klipper
            fi
        fi

        if [ ! -d $HOME/klipper ]; then
            git clone https://github.com/pellcorp/${klipper_repo}.git $HOME/klipper || exit $?
            if [ -n "$3" ]; then
              cd $HOME/klipper && git switch $3 && cd - > /dev/null
            fi
        else
            update_repo $HOME/klipper $3 || exit $?
        fi

        update_klipper || exit $?
        exit 0
    else
        echo "Error invalid klipper repo specified"
        exit 1
    fi
fi

export TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE=$HOME/printer_data/logs/installer-$TIMESTAMP.log

cd $HOME/pellcorp
PELLCORP_GIT_SHA=$(git rev-parse HEAD)
cd - > /dev/null

{
    # figure out what existing probe if any is being used
    probe=
    if [ -f $HOME/printer_data/config/bltouch-${model}.cfg ]; then
        probe=bltouch
    elif [ -f $HOME/printer_data/config/cartotouch.cfg ]; then
        probe=cartotouch
    elif [ -f $HOME/printer_data/config/beacon.cfg ]; then
        probe=beacon
    elif [ -f $HOME/printer_data/config/klicky.cfg ]; then
        probe=klicky
    elif [ -f $HOME/printer_data/config/eddyng.cfg ]; then
        probe=eddyng
    elif grep -q "\[scanner\]" $HOME/printer_data/config/printer.cfg; then
        probe=cartotouch
    elif [ -f $HOME/printer_data/config/microprobe-${model}.cfg ]; then
        probe=microprobe
    elif [ -f $HOME/printer_data/config/btteddy-${model}.cfg ]; then
        probe=btteddy
    elif [ -f $HOME/printer_data/config/cartographer-${model}.cfg ]; then
        probe=cartographer
    fi

    client=cli
    mode=install
    skip_overrides=false
    mount=
    # parse arguments here

    while true; do
        if [ "$1" = "--fix-client-variables" ] || [ "$1" = "--fix-serial" ] || [ "$1" = "--install" ] || [ "$1" = "--update" ] || [ "$1" = "--reinstall" ] || [ "$1" = "--clean-install" ] || [ "$1" = "--clean-update" ] || [ "$1" = "--clean-reinstall" ]; then
            mode=$(echo $1 | sed 's/--//g')
            shift
            if [ "$mode" = "clean-install" ] || [ "$mode" = "clean-reinstall" ] || [ "$mode" = "clean-update" ]; then
                skip_overrides=true
                mode=$(echo $mode | sed 's/clean-//g')
            fi
        elif [ "$1" = "--mount" ]; then
            shift
            mount=$1
            if [ -z "$mount" ]; then
                mount=unknown
            fi
            shift
        elif [ "$1" = "--client" ]; then
            shift
            client=$1
            shift
        elif [ "$1" = "microprobe" ] || [ "$1" = "bltouch" ] || [ "$1" = "beacon" ] || [ "$1" = "klicky" ] || [ "$1" = "cartographer" ] || [ "$1" = "cartotouch" ] || [ "$1" = "btteddy" ] || [ "$1" = "eddyng" ]; then
            if [ "$mode" = "fix-serial" ]; then
                echo "ERROR: Switching probes is not supported while trying to fix serial!"
                exit 1
            fi
            if [ -n "$probe" ] && [ "$1" != "$probe" ]; then
              echo "WARNING: About to switch from $probe to $1!"
            fi
            probe=$1
            shift
        elif [ -n "$1" ]; then # no more valid parameters
            break
        else # no more parameters
            break
        fi
    done

    if [ -z "$probe" ]; then
        echo "ERROR: You must specify a probe you want to configure"
        echo "One of: [microprobe, bltouch, cartotouch, btteddy, eddyng, beacon, klicky]"
        exit 1
    fi

    probe_model=${probe}
    if [ "$probe" = "cartotouch" ]; then
        probe_model=cartographer
    elif [ "$probe" = "eddyng" ]; then
        probe_model=btteddy
    fi

    # some newer printers we support might not support all probes out of the box
    if [ ! -f $HOME/pellcorp/k1/${probe_model}-${model}.cfg ]; then
        echo "ERROR: Model $MODEL not supported for $probe"
        exit 1
    fi

    echo "INFO: Mode is $mode"
    echo "INFO: Probe is $probe"

    if [ -n "$mount" ]; then
        $HOME/pellcorp/k1/apply-mount-overrides.sh --verify $probe $mount
        if [ $? -eq 0 ]; then
            echo "INFO: Mount is $mount"
        else
            exit 1
        fi
    fi
    echo

    if [ "$probe" = "cartographer" ]; then
      echo "ERROR: Cartographer for 4.0.0 firmware is no longer supported!"
      exit 1
    fi

    if [ "$mode" = "install" ] && [ -f $HOME/pellcorp.done ]; then
        PELLCORP_GIT_SHA=$(cat $HOME/pellcorp.done | grep "installed_sha" | awk -F '=' '{print $2}')
        if [ -n "$PELLCORP_GIT_SHA" ]; then
            echo "ERROR: Installation has already completed"

            cd $HOME/pellcorp
            CURRENT_REVISION=$(git rev-parse HEAD)
            cd - > /dev/null
            if [ "$PELLCORP_GIT_SHA" != "$CURRENT_REVISION" ]; then
                echo "Perhaps you meant to execute an --update or a --reinstall instead!"
                echo "  https://pellcorp.github.io/creality-wiki/misc/#updating"
                echo "  https://pellcorp.github.io/creality-wiki/misc/#reinstalling"
            fi
            echo
            exit 1
        fi
    fi

    if [ "$mode" = "fix-serial" ]; then
        if [ -f $HOME/pellcorp.done ]; then
            if [ "$probe" = "cartotouch" ]; then
                set_serial_cartotouch
                set_serial=$?
            elif [ "$probe" = "beacon" ]; then
                set_serial_beacon
                set_serial=$?
            elif [ "$probe" = "btteddy" ]; then
                set_serial_btteddy
                set_serial=$?
            elif [ "$probe" = "eddyng" ]; then
                set_serial_eddyng
                set_serial=$?
            else
                echo "ERROR: Fix serial not supported for $probe"
                exit 1
            fi
        else
            echo "ERROR: No installation found"
            exit 1
        fi
        if [ $set_serial -ne 0 ]; then
            if [ "$client" = "cli" ]; then
                echo
                echo "INFO: Restarting Klipper ..."
                /etc/init.d/S55klipper_service restart
            else
                echo "WARNING: Klipper restart required"
            fi
        fi
        exit 0
    elif [ "$mode" = "fix-client-variables" ]; then
        if [ -f $HOME/pellcorp.done ]; then
            fixup_client_variables_config
            fixup_client_variables_config=$?
            if [ $fixup_client_variables_config -ne 0 ]; then
                if [ "$client" = "cli" ]; then
                    echo
                    echo "INFO: Restarting Klipper ..."
                    /etc/init.d/S55klipper_service restart
                else
                    echo "WARNING: Klipper restart required"
                fi
            else
                echo "INFO: No changes made"
            fi
            exit 0
        else
            echo "ERROR: No installation found"
            exit 1
        fi
    fi

    # to avoid cluttering the printer_data/config directory lets move stuff
    mkdir -p $HOME/printer_data/config/backups/

    # we don't do these kinds of backups anymore
    rm $HOME/printer_data/config/*.bkp 2> /dev/null

    echo "INFO: Backing up existing configuration ..."
    $HOME/pellcorp/k1/tools/backups.sh --create
    echo

    mkdir -p $HOME/pellcorp-backups
    # the pellcorp-backups do not need .pellcorp extension, so this is to fix backwards compatible
    if [ -f $HOME/pellcorp-backups/printer.pellcorp.cfg ]; then
        mv $HOME/pellcorp-backups/printer.pellcorp.cfg $HOME/pellcorp-backups/printer.cfg
    fi

    # so if the installer has never been run we should grab a backup of the printer.cfg
    if [ ! -f $HOME/pellcorp.done ] && [ ! -f $HOME/pellcorp-backups/printer.factory.cfg ]; then
        # just to make sure we don't accidentally copy printer.cfg to backup if the backup directory
        # is deleted, add a stamp to config files to we can know for sure.
        if ! grep -q "# Modified by Simple AF " $HOME/printer_data/config/printer.cfg; then
            cp $HOME/printer_data/config/printer.cfg $HOME/pellcorp-backups/printer.factory.cfg
        else
          echo "WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING"
          echo "WARNING: No pristine factory printer.cfg available - config overrides are disabled!"
          echo "WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING"
        fi
    fi

    if [ "$skip_overrides" = "true" ]; then
        echo "INFO: Configuration overrides will not be saved or applied"
    fi

    # we want to disable creality services at the very beginning otherwise shit gets weird
    # if the crazy creality S55klipper_service is still copying files
    disable_creality_services

    install_config_updater

    if [ "$mode" = "reinstall" ] || [ "$mode" = "update" ]; then
        if [ "$skip_overrides" != "true" ]; then
            if [ -f $HOME/pellcorp-backups/printer.cfg ]; then
                $HOME/pellcorp/k1/config-overrides.sh
            elif [ -f $HOME/pellcorp.done ]; then # for a factory reset this warning is superfluous
              echo "WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING"
              echo "WARNING: No $HOME/pellcorp-backups/printer.cfg - config overrides won't be generated!"
              echo "WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING"
            fi
        fi

        if [ -f $HOME/pellcorp.done ]; then
          rm $HOME/pellcorp.done
        fi

        # if we took a post factory reset backup for a reinstall restore it now
        if [ -f $HOME/pellcorp-backups/printer.factory.cfg ]; then
            # lets just repair existing printer.factory.cfg if someone failed to factory reset, we will get them next time
            # but config overrides should generally work even if its not truly a factory config file
            if grep -q "#*# <---------------------- SAVE_CONFIG ---------------------->" $HOME/pellcorp-backups/printer.factory.cfg; then
                sed -i '/^#*#/d' $HOME/pellcorp-backups/printer.factory.cfg
            fi

            cp $HOME/pellcorp-backups/printer.factory.cfg $HOME/printer_data/config/printer.cfg
            DATE_TIME=$(date +"%Y-%m-%d %H:%M:%S")
            sed -i "1s/^/# Modified by Simple AF ${DATE_TIME}\n/" $HOME/printer_data/config/printer.cfg
        elif [ "$mode" = "update" ]; then
            echo "ERROR: Update mode is not available as pristine factory printer.cfg is missing"
            exit 1
        fi
    fi

    # lets make sure we are not stranded in some repo dir
    cd $HOME

    touch $HOME/pellcorp.done

    install_webcam $mode

    install_moonraker $mode
    install_moonraker=$?

    install_nginx $mode
    install_nginx=$?

    install_fluidd $mode
    install_fluidd=$?

    install_mainsail $mode
    install_mainsail=$?

    # KAMP is in the moonraker.conf file so it must be installed before moonraker is first started
    install_kamp $mode
    install_kamp=$?

    install_klipper $mode $probe
    install_klipper=$?

    install_cartographer_klipper=0
    install_beacon_klipper=0
    if [ "$probe" = "cartographer" ] || [ "$probe" = "cartotouch" ]; then
      install_cartographer_klipper $mode
      install_cartographer_klipper=$?
    elif [ "$probe" = "beacon" ]; then
      install_beacon_klipper $mode
      install_beacon_klipper=$?
    fi

    setup_probe
    setup_probe=$?

    if [ "$probe" = "cartotouch" ]; then
        setup_cartotouch
        setup_probe_specific=$?
    elif [ "$probe" = "bltouch" ]; then
        setup_bltouch
        setup_probe_specific=$?
    elif [ "$probe" = "btteddy" ]; then
        setup_btteddy
        setup_probe_specific=$?
    elif [ "$probe" = "eddyng" ]; then
        setup_eddyng
        setup_probe_specific=$?
    elif [ "$probe" = "microprobe" ]; then
        setup_microprobe
        setup_probe_specific=$?
    elif [ "$probe" = "beacon" ]; then
        setup_beacon
        setup_probe_specific=$?
    elif [ "$probe" = "klicky" ]; then
        setup_klicky
        setup_probe_specific=$?
    else
        echo "ERROR: Probe $probe not supported"
        exit 1
    fi

    if [ -f $HOME/pellcorp-backups/printer.factory.cfg ]; then
        # we want a copy of the file before config overrides are re-applied so we can correctly generate diffs
        # against different generations of the original file
        for file in printer.cfg start_end.cfg fan_control.cfg $probe_model.conf spoolman.conf timelapse.conf moonraker.conf webcam.conf sensorless.cfg ${probe}_macro.cfg ${probe}.cfg ${probe_model}-${model}.cfg; do
            if [ -f $HOME/printer_data/config/$file ]; then
                cp $HOME/printer_data/config/$file $HOME/pellcorp-backups/$file
            fi
        done

        if [ -f $HOME/guppyscreen/guppyscreen.json ]; then
          cp $HOME/guppyscreen/guppyscreen.json $HOME/pellcorp-backups/
        fi
    fi

    apply_overrides=0
    # there will be no support for generating pellcorp-overrides unless you have done a factory reset
    if [ -f $HOME/pellcorp-backups/printer.factory.cfg ]; then
        if [ "$skip_overrides" != "true" ]; then
            apply_overrides
            apply_overrides=$?
        fi
    fi

    apply_mount_overrides=0
    if [ -n "$mount" ]; then
        $HOME/pellcorp/k1/apply-mount-overrides.sh $probe $mount
        apply_mount_overrides=$?
    fi

    # cleanup any M109 or M190 redefined
    fix_custom_config
    fix_custom_config=$?

    fixup_client_variables_config
    fixup_client_variables_config=$?
    if [ $fixup_client_variables_config -eq 0 ]; then
        echo "INFO: No changes made"
    fi

    echo
    $HOME/pellcorp/k1/update-ip-address.sh
    update_ip_address=$?

    if [ $apply_overrides -ne 0 ] || [ $install_moonraker -ne 0 ] || [ $install_cartographer_klipper -ne 0 ] || [ $install_beacon_klipper -ne 0 ] || [ $update_ip_address -ne 0 ]; then
        if [ "$client" = "cli" ]; then
            restart_moonraker
        else
            echo "WARNING: Moonraker restart required"
        fi
    fi

    if [ $install_moonraker -ne 0 ] || [ $install_nginx -ne 0 ] || [ $install_fluidd -ne 0 ] || [ $install_mainsail -ne 0 ]; then
        if [ "$client" = "cli" ]; then
            echo
            echo "INFO: Restarting Nginx ..."
            /etc/init.d/S50nginx_service restart
        else
            echo "WARNING: NGINX restart required"
        fi
    fi

    if [ $fix_custom_config -ne 0 ] || [ $fixup_client_variables_config -ne 0 ] || [ $apply_overrides -ne 0 ] || [ $apply_mount_overrides -ne 0 ] || [ $install_cartographer_klipper -ne 0 ] || [ $install_beacon_klipper -ne 0 ] || [ $install_kamp -ne 0 ] || [ $install_klipper -ne 0 ] || [ $setup_probe -ne 0 ] || [ $setup_probe_specific -ne 0 ]; then
        if [ "$client" = "cli" ]; then
            echo
            echo "INFO: Restarting Klipper ..."
            /etc/init.d/S55klipper_service restart
        else
            echo "WARNING: Klipper restart required"
        fi
    fi

    echo "installed_sha=$PELLCORP_GIT_SHA" >> $HOME/pellcorp.done
    exit 0
} 2>&1 | tee -a $LOG_FILE
