#!/bin/sh

BASEDIR=/home/pi

if [ ! -f $BASEDIR/printer_data/config/printer.cfg ]; then
  >&2 echo "ERROR: Printer data not setup"
  exit 1
fi

# everything else in the script assumes its cloned to $BASEDIR/pellcorp
# so we must verify this or shit goes wrong
if [ "$(dirname $(readlink -f $0))" != "$BASEDIR/pellcorp/rpi" ]; then
  >&2 echo "ERROR: This git repo must be cloned to $BASEDIR/pellcorp"
  exit 1
fi

CONFIG_HELPER="$BASEDIR/pellcorp/rpi/config-helper.py"

# thanks to @Nestaa51 for the timeout changes to not wait forever for moonraker
function restart_moonraker() {
    echo
    echo "INFO: Restarting Moonraker ..."
    sudo systemctl restart moonraker

    timeout=60
    start_time=$(date +%s)

    # this is mostly for k1-qemu where Moonraker takes a while to start up
    echo "INFO: Waiting for Moonraker ..."
    while true; do
        KLIPPER_PATH=$(curl localhost:7125/printer/info 2> /dev/null | jq -r .result.klipper_path)
        if [ "$KLIPPER_PATH" = "$BASEDIR/klipper" ]; then
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
            sync
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
  if [ -d $BASEDIR/cartographer-klipper ]; then
      $BASEDIR/cartographer-klipper/install.sh || return $?
      sync
  fi
  if [ -d $BASEDIR/beacon-klipper ]; then
      $BASEDIR/pellcorp/rpi/beacon-install.sh || return $?
      sync
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
}

function install_crowsnest() {
    local mode=$1
    
    grep -q "crowsnest" $BASEDIR/pellcorp.done
    if [ $? -ne 0 ]; then
        if [ "$mode" != "update" ] || [ ! -f /usr/local/bin/crowsnest ]; then
            echo
            echo "INFO: Installing crowsnest ..."
            cd $BASEDIR
            git clone https://github.com/mainsail-crew/crowsnest.git $BASEDIR/crowsnest
            cd $BASEDIR/crowsnest
            sudo CROWSNEST_UNATTENDED=1 make install
        fi

        echo "INFO: Updating crowsnest config ..."

        if [ -f /etc/systemd/system/crowsnest.service ]; then
            sudo systemctl stop crowsnest
        fi

        cp $BASEDIR/pellcorp/rpi/services/crowsnest.service /etc/systemd/system/
        sudo systemctl enable crowsnest
        sudo systemctl start crowsnest

        cp $BASEDIR/pellcorp/rpi/webcam.conf $BASEDIR/printer_data/config/ || exit $?

        echo "crowsnest" >> $BASEDIR/pellcorp.done
        sync
        return 1
    fi
    return 0
}

function install_moonraker() {
    local mode=$1

    grep -q "moonraker" $BASEDIR/pellcorp.done
    if [ $? -ne 0 ]; then
        echo
        
        if [ "$mode" != "update" ] && [ -d $BASEDIR/moonraker ]; then
            if [ -f /etc/systemd/system/moonraker.service ]; then
                sudo systemctl stop moonraker
            fi
            if [ -d $BASEDIR/printer_data/database/ ]; then
                [ -f $BASEDIR/moonraker-database.tar.gz ] && rm $BASEDIR/moonraker-database.tar.gz

                echo "INFO: Backing up moonraker database ..."
                cd $BASEDIR/printer_data/

                tar -zcf $BASEDIR/moonraker-database.tar.gz database/
                cd 
            fi
            rm -rf $BASEDIR/moonraker
        fi

        if [ "$mode" != "update" ] && [ -d $BASEDIR/moonraker-env ]; then
            rm -rf $BASEDIR/moonraker-env
        fi

        if [ ! -d $BASEDIR/moonraker/.git ]; then
            echo "INFO: Installing moonraker ..."
        
            [ -d $BASEDIR/moonraker ] && rm -rf $BASEDIR/moonraker
            [ -d $BASEDIR/moonraker-env ] && rm -rf $BASEDIR/moonraker-env

            echo
            git clone https://github.com/pellcorp/moonraker.git $BASEDIR/moonraker || exit $?

            if [ -f $BASEDIR/moonraker-database.tar.gz ]; then
                echo
                echo "INFO: Restoring moonraker database ..."
                cd $BASEDIR/printer_data/
                tar -zxf $BASEDIR/moonraker-database.tar.gz
                rm $BASEDIR/moonraker-database.tar.gz
                cd
            fi
        fi

        if [ ! -f $BASEDIR/moonraker-timelapse/component/timelapse.py ]; then
            if [ -d $BASEDIR/moonraker-timelapse ]; then
                rm -rf $BASEDIR/moonraker-timelapse
            fi
            git clone https://github.com/mainsail-crew/moonraker-timelapse.git $BASEDIR/moonraker-timelapse/ || exit $?
        fi

        if [ ! -d $BASEDIR/moonraker-env ]; then
            virtualenv -p python3 $BASEDIR/moonraker-env
            $BASEDIR/moonraker-env/bin/pip install -r $BASEDIR/moonraker/scripts/moonraker-requirements.txt
            $BASEDIR/moonraker-env/bin/pip install -r $BASEDIR/moonraker/scripts/moonraker-speedups.txt
        fi

        echo "INFO: Updating moonraker config ..."

        # an existing bug where the moonraker secrets was not correctly copied
        if [ ! -f $BASEDIR/printer_data/moonraker.secrets ]; then
            cp $BASEDIR/pellcorp/rpi/moonraker.secrets $BASEDIR/printer_data/
        fi

        cp $BASEDIR/pellcorp/rpi/services/moonraker.service /etc/systemd/system/ || exit $?
        cp $BASEDIR/pellcorp/rpi/moonraker.conf $BASEDIR/printer_data/config/ || exit $?
        ln -sf $BASEDIR/pellcorp/rpi/moonraker.asvc $BASEDIR/printer_data/ || exit $?

        ln -sf $BASEDIR/moonraker-timelapse/component/timelapse.py $BASEDIR/moonraker/moonraker/components/ || exit $?
        if ! grep -q "moonraker/components/timelapse.py" "$BASEDIR/moonraker/.git/info/exclude"; then
            echo "moonraker/components/timelapse.py" >> "$BASEDIR/moonraker/.git/info/exclude"
        fi
        ln -sf $BASEDIR/moonraker-timelapse/klipper_macro/timelapse.cfg $BASEDIR/printer_data/config/ || exit $?
        cp $BASEDIR/pellcorp/rpi/timelapse.conf $BASEDIR/printer_data/config/ || exit $?

        ln -sf $BASEDIR/pellcorp/rpi/spoolman.cfg $BASEDIR/printer_data/config/ || exit $?
        cp $BASEDIR/pellcorp/rpi/spoolman.conf $BASEDIR/printer_data/config/ || exit $?

        # after an initial install do not overwrite notifier.conf or moonraker.secrets
        if [ ! -f $BASEDIR/printer_data/config/notifier.conf ]; then
            cp $BASEDIR/pellcorp/rpi/notifier.conf $BASEDIR/printer_data/config/ || exit $?
        fi
        if [ ! -f $BASEDIR/printer_data/moonraker.secrets ]; then
            cp $BASEDIR/pellcorp/rpi/moonraker.secrets $BASEDIR/printer_data/ || exit $?
        fi

        sudo systemctl enable moonraker

        echo "moonraker" >> $BASEDIR/pellcorp.done
        sync

        # means nginx and moonraker need to be restarted
        return 1
    fi
    return 0
}

function install_nginx() {
    local mode=$1

    grep -q "nginx" $BASEDIR/pellcorp.done
    if [ $? -ne 0 ]; then
        default_ui=fluidd
        if [ -f /etc/nginx/sites-enabled/mainsail ]; then
          grep "#listen" /etc/nginx/sites-enabled/mainsail > /dev/null
          if [ $? -ne 0 ]; then
            default_ui=mainsail
          fi
        fi

        command -v /usr/sbin/nginx > /dev/null
        if [ $? -ne 0 ]; then
            echo
            echo "INFO: Installing nginx ..."

            sudo apt-get install -y nginx || exit $?
        fi

        echo "INFO: Updating nginx config ..."
        cp $BASEDIR/pellcorp/rpi/nginx/upstreams.conf /etc/nginx/conf.d/ || exit $?
        cp $BASEDIR/pellcorp/rpi/nginx/fluidd /etc/nginx/sites-enabled/ || exit $?
        cp $BASEDIR/pellcorp/rpi/nginx/mainsail /etc/nginx/sites-enabled/ || exit $?

        if [ "$default_ui" = "mainsail" ]; then
          echo "INFO: Restoring mainsail as default UI"
          sed -i 's/.*listen 80 default_server;/    #listen 80 default_server;/g' $BASEDIR/nginx/nginx/sites/fluidd || exit $?
          sed -i 's/.*#listen 80 default_server;/    listen 80 default_server;/g' $BASEDIR/nginx/nginx/sites/mainsail || exit $?
        fi

        cp $BASEDIR/pellcorp/rpi/services/nginx.service /etc/systemd/system/ || exit $?

        echo "nginx" >> $BASEDIR/pellcorp.done
        sync

        # means nginx needs to be restarted
        return 1
    fi
    return 0
}

function install_fluidd() {
    local mode=$1

    grep -q "fluidd" $BASEDIR/pellcorp.done
    if [ $? -ne 0 ]; then
        if [ "$mode" != "update" ] && [ -d $BASEDIR/fluidd ]; then
            rm -rf $BASEDIR/fluidd
        fi
        if [ "$mode" != "update" ] && [ -d $BASEDIR/fluidd-config ]; then
            rm -rf $BASEDIR/fluidd-config
        fi

        if [ ! -d $BASEDIR/fluidd ]; then
            echo
            echo "INFO: Installing fluidd ..."

            mkdir -p $BASEDIR/fluidd || exit $?
            curl -L "https://github.com/fluidd-core/fluidd/releases/latest/download/fluidd.zip" -o $BASEDIR/fluidd.zip || exit $?
            unzip -qd $BASEDIR/fluidd $BASEDIR/fluidd.zip || exit $?
            rm $BASEDIR/fluidd.zip
        fi
        
        if [ ! -d $BASEDIR/fluidd-config ]; then
            git clone https://github.com/fluidd-core/fluidd-config.git $BASEDIR/fluidd-config || exit $?
        fi

        echo "INFO: Updating client config ..."
        [ -e $BASEDIR/printer_data/config/fluidd.cfg ] && rm $BASEDIR/printer_data/config/fluidd.cfg

        ln -sf $BASEDIR/fluidd-config/client.cfg $BASEDIR/printer_data/config/
        $CONFIG_HELPER --add-include "client.cfg" || exit $?

        # these are already defined in fluidd config so get rid of them from printer.cfg
        $CONFIG_HELPER --remove-section "pause_resume" || exit $?
        $CONFIG_HELPER --remove-section "display_status" || exit $?
        $CONFIG_HELPER --remove-section "virtual_sdcard" || exit $?

        $CONFIG_HELPER --replace-section-entry "filament_switch_sensor filament_sensor" "runout_gcode" "_ON_FILAMENT_RUNOUT" || exit $?

        echo "fluidd" >> $BASEDIR/pellcorp.done
        sync

        # means nginx needs to be restarted
        return 1
    fi
    return 0
}

function install_mainsail() {
    local mode=$1

    grep -q "mainsail" $BASEDIR/pellcorp.done
    if [ $? -ne 0 ]; then
        if [ "$mode" != "update" ] && [ -d $BASEDIR/mainsail ]; then
            rm -rf $BASEDIR/mainsail
        fi

        if [ ! -d $BASEDIR/mainsail ]; then
            echo
            echo "INFO: Installing mainsail ..."

            mkdir -p $BASEDIR/mainsail || exit $?
            curl -L "https://github.com/mainsail-crew/mainsail/releases/latest/download/mainsail.zip" -o $BASEDIR/mainsail.zip || exit $?
            unzip -qd $BASEDIR/mainsail $BASEDIR/mainsail.zip || exit $?
            rm $BASEDIR/mainsail.zip
        fi

        echo "INFO: Updating mainsail config ..."

        # the mainsail and fluidd client.cfg are exactly the same
        [ -f $BASEDIR/printer_data/config/mainsail.cfg ] && rm $BASEDIR/printer_data/config/mainsail.cfg

        echo "mainsail" >> $BASEDIR/pellcorp.done
        sync

        # means nginx needs to be restarted
        return 1
    fi
    return 0
}

# copied from install_debian.sh
function install_klipper_packages() {
    # Packages for python cffi
    PKGLIST="virtualenv python3-dev libffi-dev git build-essential"
    # kconfig requirements
    PKGLIST="${PKGLIST} libncurses-dev"
    # hub-ctrl
    PKGLIST="${PKGLIST} libusb-dev"
    # AVR chip installation and building
    PKGLIST="${PKGLIST} avrdude gcc-avr binutils-avr avr-libc"
    # ARM chip installation and building
    PKGLIST="${PKGLIST} stm32flash libnewlib-arm-none-eabi"
    PKGLIST="${PKGLIST} gcc-arm-none-eabi binutils-arm-none-eabi libusb-1.0 pkg-config"

    # Update system package info
    sudo apt-get update

    # Install desired packages
    sudo apt-get install --yes ${PKGLIST}
}

function install_klipper() {
    local mode=$1
    local probe=$2

    grep -q "klipper" $BASEDIR/pellcorp.done
    if [ $? -ne 0 ]; then
        echo

        if [ "$mode" != "update" ] && [ -d $BASEDIR/klipper ]; then
            if [ -f /etc/systemd/system/klipper.service ]; then
                sudo systemctl restart stop
            fi
            rm -rf $BASEDIR/klipper
        fi

        if [ ! -d $BASEDIR/klipper/ ]; then
            install_klipper_packages

            echo "INFO: Installing klipper ..."
            git clone https://github.com/pellcorp/klipper-rpi.git $BASEDIR/klipper || exit $?
        fi

        sudo usermod -a -G tty pi
        sudo usermod -a -G dialout pi

        if [ ! -d $BASEDIR/klipper-env ]; then
            virtualenv -p python3 $BASEDIR/klipper-env
            $BASEDIR/klipper-env/bin/pip install -r $BASEDIR/klipper/scripts/klippy-requirements.txt
        fi

        echo "INFO: Updating klipper config ..."

        sudo cp $BASEDIR/pellcorp/rpi/services/klipper.service /etc/systemd/system || exit $?

        cp $BASEDIR/pellcorp/rpi/sensorless.cfg $BASEDIR/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "sensorless.cfg" || exit $?

        cp $BASEDIR/pellcorp/rpi/internal_macros.cfg $BASEDIR/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "internal_macros.cfg" || exit $?

        cp $BASEDIR/pellcorp/rpi/useful_macros.cfg $BASEDIR/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "useful_macros.cfg" || exit $?

        cp $BASEDIR/pellcorp/rpi/start_end.cfg $BASEDIR/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "start_end.cfg" || exit $?

        ln -sf /usr/data/pellcorp/rpi/Line_Purge.cfg /usr/data/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "Line_Purge.cfg" || exit $?

        ln -sf /usr/data/pellcorp/rpi/Smart_Park.cfg /usr/data/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "Smart_Park.cfg" || exit $?

        cp $BASEDIR/pellcorp/rpi/fan_control.cfg $BASEDIR/printer_data/config || exit $?
        $CONFIG_HELPER --add-include "fan_control.cfg" || exit $?

        # just in case its missing from stock printer.cfg make sure it gets added
        $CONFIG_HELPER --add-section "exclude_object" || exit $?

        echo "klipper" >> $BASEDIR/pellcorp.done
        sync

        # means klipper needs to be restarted
        return 1
    fi
    return 0
}

function install_guppyscreen() {
    local mode=$1

    grep -q "guppyscreen" $BASEDIR/pellcorp.done
    if [ $? -ne 0 ]; then
        echo

        if [ "$mode" != "update" ] && [ -d $BASEDIR/guppyscreen ]; then
            if [ -f /etc/systemd/system/grumpyscreen.service ]; then
              sudo systemctl stop grumpyscreen > /dev/null 2>&1
            fi
            rm -rf $BASEDIR/guppyscreen
        fi

        if [ ! -d $BASEDIR/guppyscreen ]; then
            echo "INFO: Installing grumpyscreen ..."

            asset_name=guppyscreen-rpi.tar.gz
            curl -L "https://github.com/pellcorp/guppyscreen/releases/download/main/${asset_name}" -o $BASEDIR/guppyscreen.tar.gz || exit $?
            tar xf $BASEDIR/guppyscreen.tar.gz -C $BASEDIR/ || exit $?
            rm $BASEDIR/guppyscreen.tar.gz
        fi

        echo "INFO: Updating grumpyscreen config ..."
        sudo cp $BASEDIR/pellcorp/rpi/services/grumpyscreen.service /etc/systemd/system/ || exit $?

        cp $BASEDIR/pellcorp/rpi/guppyscreen.cfg $BASEDIR/printer_data/config/ || exit $?

        $CONFIG_HELPER --add-include "guppyscreen.cfg" || exit $?

        echo "guppyscreen" >> $BASEDIR/pellcorp.done
        sync

        # means klipper needs to be restarted
        return 1
    fi
    return 0
}

function setup_probe() {
    grep -q "probe" $BASEDIR/pellcorp.done
    if [ $? -ne 0 ]; then
        echo
        echo "INFO: Setting up generic probe config ..."

        $CONFIG_HELPER --remove-section "bed_mesh" || exit $?
        $CONFIG_HELPER --remove-section-entry "stepper_z" "position_endstop" || exit $?
        $CONFIG_HELPER --replace-section-entry "stepper_z" "endstop_pin" "probe:z_virtual_endstop" || exit $?

        cp $BASEDIR/pellcorp/rpi/quickstart.cfg $BASEDIR/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "quickstart.cfg" || exit $?

        # because we are using force move with 3mm, as a safety feature we will lower the position max
        # by 3mm ootb to avoid damaging the printer if you do a really big print
        position_max=$($CONFIG_HELPER --get-section-entry "stepper_z" "position_max" --minus 3 --integer)
        $CONFIG_HELPER --replace-section-entry "stepper_z" "position_max" "$position_max" || exit $?

        echo "probe" >> $BASEDIR/pellcorp.done
        sync

        # means klipper needs to be restarted
        return 1
    fi
    return 0
}

function install_cartographer_klipper() {
    local mode=$1

    grep -q "cartographer-klipper" $BASEDIR/pellcorp.done
    if [ $? -ne 0 ]; then
        if [ "$mode" != "update" ] && [ -d $BASEDIR/cartographer-klipper ]; then
            rm -rf $BASEDIR/cartographer-klipper
        fi

        if [ ! -d $BASEDIR/cartographer-klipper ]; then
            echo
            echo "INFO: Installing cartographer-klipper ..."
            git clone https://github.com/pellcorp/cartographer-klipper.git $BASEDIR/cartographer-klipper || exit $?
        fi
        cd - > /dev/null

        echo
        echo "INFO: Running cartographer-klipper installer ..."
        bash $BASEDIR/cartographer-klipper/install.sh || exit $?

        echo "cartographer-klipper" >> $BASEDIR/pellcorp.done
        sync
        return 1
    fi
    return 0
}

function install_beacon_klipper() {
    local mode=$1

    grep -q "beacon-klipper" $BASEDIR/pellcorp.done
    if [ $? -ne 0 ]; then
        if [ "$mode" != "update" ] && [ -d $BASEDIR/beacon-klipper ]; then
            rm -rf $BASEDIR/beacon-klipper
        fi

        if [ ! -d $BASEDIR/beacon-klipper ]; then
            echo
            echo "INFO: Installing beacon-klipper ..."
            git clone https://github.com/beacon3d/beacon_klipper $BASEDIR/beacon-klipper || exit $?
        fi

        # FIXME - maybe beacon will accept a PR to make their installer work on k1
        $BASEDIR/pellcorp/rpi/beacon-install.sh

        echo "beacon-klipper" >> $BASEDIR/pellcorp.done
        sync
        return 1
    fi
    return 0
}

function cleanup_probe() {
    local probe=$1

    if [ -f $BASEDIR/printer_data/config/${probe}_macro.cfg ]; then
        rm $BASEDIR/printer_data/config/${probe}_macro.cfg
    fi
    $CONFIG_HELPER --remove-include "${probe}_macro.cfg" || exit $?

    if [ "$probe" = "cartotouch" ] || [ "$probe" = "beacon" ]; then
        $CONFIG_HELPER --remove-section-entry "stepper_z" "homing_retract_dist" || exit $?
    fi

    if [ -f $BASEDIR/printer_data/config/$probe.cfg ]; then
        rm $BASEDIR/printer_data/config/$probe.cfg
    fi
    $CONFIG_HELPER --remove-include "$probe.cfg" || exit $?

    # if switching from btt eddy remove this file
    if [ "$probe" = "btteddy" ] && [ -f $BASEDIR/printer_data/config/variables.cfg ]; then
        rm $BASEDIR/printer_data/config/variables.cfg
    fi

    # we use the cartographer includes
    if [ "$probe" = "cartotouch" ]; then
        probe=cartographer
    elif [ "$probe" = "eddyng" ]; then
        probe=btteddy
    fi

    if [ -f $BASEDIR/printer_data/config/${probe}.conf ]; then
        rm $BASEDIR/printer_data/config/${probe}.conf
    fi

    $CONFIG_HELPER --file moonraker.conf --remove-include "${probe}.conf" || exit $?

    if [ -f $BASEDIR/printer_data/config/${probe}_calibrate.cfg ]; then
        rm $BASEDIR/printer_data/config/${probe}_calibrate.cfg
    fi
    $CONFIG_HELPER --remove-include "${probe}_calibrate.cfg" || exit $?

    if [ -f $BASEDIR/printer_data/config/$probe-${model}.cfg ]; then
        rm $BASEDIR/printer_data/config/$probe-${model}.cfg
    fi
    $CONFIG_HELPER --remove-include "$probe-${model}.cfg" || exit $?
}

function cleanup_probes() {
  cleanup_probe microprobe
  cleanup_probe btteddy
  cleanup_probe eddyng
  cleanup_probe cartotouch
  cleanup_probe beacon
  cleanup_probe klicky
  cleanup_probe bltouch
}

function setup_bltouch() {
    grep -q "bltouch-probe" $BASEDIR/pellcorp.done
    if [ $? -ne 0 ]; then
        echo
        echo "INFO: Setting up bltouch/crtouch/3dtouch ..."

        cleanup_probes

        cp $BASEDIR/pellcorp/rpi/bltouch.cfg $BASEDIR/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "bltouch.cfg" || exit $?

        cp $BASEDIR/pellcorp/rpi/bltouch_macro.cfg $BASEDIR/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "bltouch_macro.cfg" || exit $?

        # need to add a empty bltouch section for baby stepping to work
        $CONFIG_HELPER --remove-section "bltouch" || exit $?
        $CONFIG_HELPER --add-section "bltouch" || exit $?
        z_offset=$($CONFIG_HELPER --ignore-missing --file $BASEDIR/pellcorp-overrides/printer.cfg.save_config --get-section-entry bltouch z_offset)
        if [ -n "$z_offset" ]; then
          $CONFIG_HELPER --replace-section-entry "bltouch" "# z_offset" "0.0" || exit $?
        else
          $CONFIG_HELPER --replace-section-entry "bltouch" "z_offset" "0.0" || exit $?
        fi

        echo "bltouch-probe" >> $BASEDIR/pellcorp.done
        sync

        # means klipper needs to be restarted
        return 1
    fi
    return 0
}

function setup_microprobe() {
    grep -q "microprobe-probe" $BASEDIR/pellcorp.done
    if [ $? -ne 0 ]; then
        echo
        echo "INFO: Setting up microprobe ..."

        cleanup_probes

        cp $BASEDIR/pellcorp/rpi/microprobe.cfg $BASEDIR/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "microprobe.cfg" || exit $?

        cp $BASEDIR/pellcorp/rpi/microprobe_macro.cfg $BASEDIR/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "microprobe_macro.cfg" || exit $?

        # remove previous directly imported microprobe config
        $CONFIG_HELPER --remove-section "output_pin probe_enable" || exit $?

        # need to add a empty probe section for baby stepping to work
        $CONFIG_HELPER --remove-section "probe" || exit $?
        $CONFIG_HELPER --add-section "probe" || exit $?
        z_offset=$($CONFIG_HELPER --ignore-missing --file $BASEDIR/pellcorp-overrides/printer.cfg.save_config --get-section-entry probe z_offset)
        if [ -n "$z_offset" ]; then
          $CONFIG_HELPER --replace-section-entry "probe" "# z_offset" "0.0" || exit $?
        else
          $CONFIG_HELPER --replace-section-entry "probe" "z_offset" "0.0" || exit $?
        fi

        echo "microprobe-probe" >> $BASEDIR/pellcorp.done
        sync

        # means klipper needs to be restarted
        return 1
    fi
    return 0
}

function setup_klicky() {
    grep -q "klicky-probe" $BASEDIR/pellcorp.done
    if [ $? -ne 0 ]; then
        echo
        echo "INFO: Setting up klicky ..."

        cleanup_probes

        cp $BASEDIR/pellcorp/rpi/klicky.cfg $BASEDIR/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "klicky.cfg" || exit $?

        # need to add a empty probe section for baby stepping to work
        $CONFIG_HELPER --remove-section "probe" || exit $?
        $CONFIG_HELPER --add-section "probe" || exit $?
        z_offset=$($CONFIG_HELPER --ignore-missing --file $BASEDIR/pellcorp-overrides/printer.cfg.save_config --get-section-entry probe z_offset)
        if [ -n "$z_offset" ]; then
          $CONFIG_HELPER --replace-section-entry "probe" "# z_offset" "2.0" || exit $?
        else
          $CONFIG_HELPER --replace-section-entry "probe" "z_offset" "2.0" || exit $?
        fi

        cp $BASEDIR/pellcorp/rpi/klicky_macro.cfg $BASEDIR/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "klicky_macro.cfg" || exit $?

        echo "klicky-probe" >> $BASEDIR/pellcorp.done
        sync

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
    grep -q "cartotouch-probe" $BASEDIR/pellcorp.done
    if [ $? -ne 0 ]; then
        echo
        echo "INFO: Setting up carto touch ..."

        cleanup_probes

        cp $BASEDIR/pellcorp/rpi/cartographer.conf $BASEDIR/printer_data/config/ || exit $?
        $CONFIG_HELPER --file moonraker.conf --add-include "cartographer.conf" || exit $?

        cp $BASEDIR/pellcorp/rpi/cartotouch_macro.cfg $BASEDIR/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "cartotouch_macro.cfg" || exit $?

        $CONFIG_HELPER --replace-section-entry "stepper_z" "homing_retract_dist" "0" || exit $?

        cp $BASEDIR/pellcorp/rpi/cartotouch.cfg $BASEDIR/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "cartotouch.cfg" || exit $?

        y_position_mid=$($CONFIG_HELPER --get-section-entry "stepper_y" "position_max" --divisor 2 --integer)
        x_position_mid=$($CONFIG_HELPER --get-section-entry "stepper_x" "position_max" --divisor 2 --integer)
        $CONFIG_HELPER --file cartotouch.cfg --replace-section-entry "bed_mesh" "zero_reference_position" "$x_position_mid,$y_position_mid" || exit $?

        set_serial_cartotouch

        # a slight change to the way cartotouch is configured
        $CONFIG_HELPER --remove-section "force_move" || exit $?

        # as we are referencing the included cartographer now we want to remove the included value
        # from any previous installation
        $CONFIG_HELPER --remove-section "scanner" || exit $?
        $CONFIG_HELPER --add-section "scanner" || exit $?

        scanner_touch_z_offset=$($CONFIG_HELPER --ignore-missing --file $BASEDIR/pellcorp-overrides/printer.cfg.save_config --get-section-entry scanner scanner_touch_z_offset)
        if [ -n "$scanner_touch_z_offset" ]; then
          $CONFIG_HELPER --replace-section-entry "scanner" "# scanner_touch_z_offset" "0.05" || exit $?
        else
          $CONFIG_HELPER --replace-section-entry "scanner" "scanner_touch_z_offset" "0.05" || exit $?
        fi

        scanner_mode=$($CONFIG_HELPER --ignore-missing --file $BASEDIR/pellcorp-overrides/printer.cfg.save_config --get-section-entry scanner mode)
        if [ -n "$scanner_mode" ]; then
            $CONFIG_HELPER --replace-section-entry "scanner" "# mode" "touch" || exit $?
        else
            $CONFIG_HELPER --replace-section-entry "scanner" "mode" "touch" || exit $?
        fi

        cp $BASEDIR/pellcorp/rpi/cartographer_calibrate.cfg $BASEDIR/printer_data/config/ || exit $?
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

        echo "cartotouch-probe" >> $BASEDIR/pellcorp.done
        sync
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
    grep -q "beacon-probe" $BASEDIR/pellcorp.done
    if [ $? -ne 0 ]; then
        echo
        echo "INFO: Setting up beacon ..."

        cleanup_probes

        cp $BASEDIR/pellcorp/rpi/beacon.conf $BASEDIR/printer_data/config/ || exit $?
        $CONFIG_HELPER --file moonraker.conf --add-include "beacon.conf" || exit $?

        cp $BASEDIR/pellcorp/rpi/beacon_macro.cfg $BASEDIR/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "beacon_macro.cfg" || exit $?

        $CONFIG_HELPER --replace-section-entry "stepper_z" "homing_retract_dist" "0" || exit $?

        cp $BASEDIR/pellcorp/rpi/beacon.cfg $BASEDIR/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "beacon.cfg" || exit $?

        # for beacon can't use homing override
        $CONFIG_HELPER --file sensorless.cfg --remove-section "homing_override"

        y_position_mid=$($CONFIG_HELPER --get-section-entry "stepper_y" "position_max" --divisor 2 --integer)
        x_position_mid=$($CONFIG_HELPER --get-section-entry "stepper_x" "position_max" --divisor 2 --integer)
        $CONFIG_HELPER --file beacon.cfg --replace-section-entry "beacon" "home_xy_position" "$x_position_mid,$y_position_mid" || exit $?
        $CONFIG_HELPER --file beacon.cfg --replace-section-entry "bed_mesh" "zero_reference_position" "$x_position_mid,$y_position_mid" || exit $?

        # for Ender 5 Max need to swap homing order for beacon
        if [ "$MODEL" = "F004" ]; then
            $CONFIG_HELPER --file beacon.cfg --replace-section-entry "beacon" "home_y_before_x" "True" || exit $?
        fi

        set_serial_beacon

        $CONFIG_HELPER --remove-section "beacon" || exit $?
        $CONFIG_HELPER --add-section "beacon" || exit $?

        beacon_cal_nozzle_z=$($CONFIG_HELPER --ignore-missing --file $BASEDIR/pellcorp-overrides/printer.cfg.save_config --get-section-entry beacon cal_nozzle_z)
        if [ -n "$beacon_cal_nozzle_z" ]; then
          $CONFIG_HELPER --replace-section-entry "beacon" "# cal_nozzle_z" "0.1" || exit $?
        else
          $CONFIG_HELPER --replace-section-entry "beacon" "cal_nozzle_z" "0.1" || exit $?
        fi

        echo "beacon-probe" >> $BASEDIR/pellcorp.done
        sync
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
    grep -q "btteddy-probe" $BASEDIR/pellcorp.done
    if [ $? -ne 0 ]; then
        echo
        echo "INFO: Setting up btteddy ..."

        cleanup_probes

        cp $BASEDIR/pellcorp/rpi/btteddy.cfg $BASEDIR/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "btteddy.cfg" || exit $?

        set_serial_btteddy

        cp $BASEDIR/pellcorp/rpi/btteddy_macro.cfg $BASEDIR/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "btteddy_macro.cfg" || exit $?

        # K1 SE has no chamber fan
        if [ "$MODEL" = "K1 SE" ]; then
            sed -i '/SET_FAN_SPEED FAN=chamber.*/d' $BASEDIR/printer_data/config/btteddy_macro.cfg
        fi

        $CONFIG_HELPER --remove-section "probe_eddy_current btt_eddy" || exit $?
        $CONFIG_HELPER --add-section "probe_eddy_current btt_eddy" || exit $?

# these guided macros are out of date, removing them temporarily to avoid confusion
#        cp $BASEDIR/pellcorp/rpi/btteddy_calibrate.cfg $BASEDIR/printer_data/config/ || exit $?
#        $CONFIG_HELPER --add-include "btteddy_calibrate.cfg" || exit $?

        echo "btteddy-probe" >> $BASEDIR/pellcorp.done
        sync
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
    grep -q "eddyng-probe" $BASEDIR/pellcorp.done
    if [ $? -ne 0 ]; then
        echo
        echo "INFO: Setting up btt eddy-ng ..."

        cleanup_probes

        cp $BASEDIR/pellcorp/rpi/eddyng.cfg $BASEDIR/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "eddyng.cfg" || exit $?

        set_serial_eddyng

        cp $BASEDIR/pellcorp/rpi/eddyng_macro.cfg $BASEDIR/printer_data/config/ || exit $?
        $CONFIG_HELPER --add-include "eddyng_macro.cfg" || exit $?

        $CONFIG_HELPER --remove-section "probe_eddy_ng btt_eddy" || exit $?
        $CONFIG_HELPER --add-section "probe_eddy_ng btt_eddy" || exit $?

        echo "eddyng-probe" >> $BASEDIR/pellcorp.done
        sync
        return 1
    fi
    return 0
}

function apply_overrides() {
    return_status=0
    grep -q "overrides" $BASEDIR/pellcorp.done
    if [ $? -ne 0 ]; then
        $BASEDIR/pellcorp/rpi/apply-overrides.sh
        return_status=$?
        echo "overrides" >> $BASEDIR/pellcorp.done
        sync
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

    sync
    return $changed
}

# special mode to update the repo only
# this stuff we do not want to have a log file for
if [ "$1" = "--update-repo" ] || [ "$1" = "--update-branch" ]; then
    update_repo $BASEDIR/pellcorp
    exit $?
elif [ "$1" = "--branch" ] && [ -n "$2" ]; then # convenience for testing new features
    update_repo $BASEDIR/pellcorp $2 || exit $?
    exit $?
elif [ "$1" = "--cartographer-branch" ]; then
    shift
    if [ -d $BASEDIR/cartographer-klipper ]; then
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
        update_repo $BASEDIR/cartographer-klipper $branch || exit $?
        update_klipper || exit $?
        if [ -f $BASEDIR/printer_data/config/cartographer.conf ]; then
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
        update_repo $BASEDIR/klipper $2 || exit $?
        update_klipper || exit $?
        exit 0
    else
        echo "Error invalid branch specified"
        exit 1
    fi
fi

export TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE=$BASEDIR/printer_data/logs/installer-$TIMESTAMP.log

cd $BASEDIR/pellcorp
PELLCORP_GIT_SHA=$(git rev-parse HEAD)
cd - > /dev/null

{
    # figure out what existing probe if any is being used
    probe=

    if [ -f $BASEDIR/printer_data/config/bltouch.cfg ]; then
        probe=bltouch
    elif [ -f $BASEDIR/printer_data/config/microprobe.cfg ]; then
        probe=microprobe
    elif [ -f $BASEDIR/printer_data/config/cartotouch.cfg ]; then
        probe=cartotouch
    elif [ -f $BASEDIR/printer_data/config/beacon.cfg ]; then
        probe=beacon
    elif [ -f $BASEDIR/printer_data/config/klicky.cfg ]; then
        probe=klicky
    elif [ -f $BASEDIR/printer_data/config/eddyng.cfg ]; then
        probe=eddyng
    elif [ -f $BASEDIR/printer_data/config/btteddy.cfg ]; then
        probe=btteddy
    elif grep -q "\[scanner\]" $BASEDIR/printer_data/config/printer.cfg; then
        probe=cartotouch
    elif [ -f $BASEDIR/printer_data/config/bltouch-${model}.cfg ]; then
        probe=bltouch
    elif [ -f $BASEDIR/printer_data/config/microprobe-${model}.cfg ]; then
        probe=microprobe
    elif [ -f $BASEDIR/printer_data/config/btteddy-${model}.cfg ]; then
        probe=btteddy
    fi

    client=cli
    mode=install
    skip_overrides=false
    probe_switch=false
    mount=
    # parse arguments here

    if [ -f $BASEDIR/pellcorp.done ]; then
        install_mount=$(cat $BASEDIR/pellcorp.done | grep "mount=" | awk -F '=' '{print $2}')
    fi

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
        elif [ "$1" = "microprobe" ] || [ "$1" = "bltouch" ] || [ "$1" = "beacon" ] || [ "$1" = "klicky" ] || [ "$1" = "cartotouch" ] || [ "$1" = "btteddy" ] || [ "$1" = "eddyng" ]; then
            if [ "$mode" = "fix-serial" ]; then
                echo "ERROR: Switching probes is not supported while trying to fix serial!"
                exit 1
            fi
            if [ -n "$probe" ] && [ "$1" != "$probe" ]; then
              echo "WARNING: About to switch from $probe to $1!"
              probe_switch=true
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

    echo "INFO: Mode is $mode"
    echo "INFO: Probe is $probe"

    # don't try and validate a mount if all we are wanting to do is fix serial
    if [ "$mode" != "fix-serial" ]; then
      if [ -z "$mount" ] && [ -n "$install_mount" ] && [ "$probe_switch" != "true" ]; then
        # for a partial install where we selected a mount, we can grab it from the pellcorp.done file
        if [ "$mode" = "install" ]; then
          mount=$install_mount
        elif [ -f $BASEDIR/printer_data/config/${probe_model}-${model}.cfg ]; then
          # if we are about to migrate an older installation we need to force the reapplication of the mount overrides
          # mounts which might have had the same config as some default -k1 / -k1m config so there would have been
          # no mount overrides generated
          echo "WARNING: Enforcing mount overrides for mount $install_mount for migration"
          mount=$install_mount
        fi
      fi

      if [ -n "$mount" ]; then
          $BASEDIR/pellcorp/rpi/apply-mount-overrides.sh --verify $probe $mount
          if [ $? -eq 0 ]; then
              echo "INFO: Mount is $mount"
          else
              exit 1
          fi
      elif [ ! -d $BASEDIR/pellcorp-overrides ]; then
        echo "ERROR: Mount option must be specified"
        exit 1
      elif [ "$skip_overrides" = "true" ] || [ "$mode" = "install" ] || [ "$mode" = "reinstall" ]; then
          echo "ERROR: Mount option must be specified"
          exit 1
      elif [ -f $BASEDIR/pellcorp.done ]; then
          if [ -z "$install_mount" ] || [ "$probe_switch" = "true" ]; then
              echo "ERROR: Mount option must be specified"
              exit 1
          else
              echo "INFO: Mount is $install_mount"
          fi
      fi
      echo
    fi

    if [ "$mode" = "install" ] && [ -f $BASEDIR/pellcorp.done ]; then
        PELLCORP_GIT_SHA=$(cat $BASEDIR/pellcorp.done | grep "installed_sha" | awk -F '=' '{print $2}')
        if [ -n "$PELLCORP_GIT_SHA" ]; then
            echo "ERROR: Installation has already completed"

            cd $BASEDIR/pellcorp
            CURRENT_REVISION=$(git rev-parse HEAD)
            cd - > /dev/null
            if [ "$PELLCORP_GIT_SHA" != "$CURRENT_REVISION" ]; then
                echo "Perhaps you meant to execute an --update or a --reinstall instead!"
                echo "  https://pellcorp.github.io/creality-wiki/updating/#updating"
                echo "  https://pellcorp.github.io/creality-wiki/updating/#reinstalling"
            fi
            echo
            exit 1
        fi
    fi

    if [ "$mode" = "fix-serial" ]; then
        if [ -f $BASEDIR/pellcorp.done ]; then
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
                sudo systemctl restart klipper
            else
                echo "WARNING: Klipper restart required"
            fi
        fi
        exit 0
    elif [ "$mode" = "fix-client-variables" ]; then
        if [ -f $BASEDIR/pellcorp.done ]; then
            fixup_client_variables_config
            fixup_client_variables_config=$?
            if [ $fixup_client_variables_config -ne 0 ]; then
                if [ "$client" = "cli" ]; then
                    echo
                    echo "INFO: Restarting Klipper ..."
                    sudo systemctl restart klipper
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
    mkdir -p $BASEDIR/printer_data/config/backups/

    echo "INFO: Backing up existing configuration ..."
    TIMESTAMP=${TIMESTAMP} $BASEDIR/pellcorp/rpi/tools/backups.sh --create
    echo

    mkdir -p $BASEDIR/pellcorp-backups

    # so if the installer has never been run we should grab a backup of the printer.cfg
    if [ ! -f $BASEDIR/pellcorp.done ] && [ ! -f $BASEDIR/pellcorp-backups/printer.factory.cfg ]; then
        # just to make sure we don't accidentally copy printer.cfg to backup if the backup directory
        # is deleted, add a stamp to config files to we can know for sure.
        if ! grep -q "# Modified by Simple AF " $BASEDIR/printer_data/config/printer.cfg; then
            cp $BASEDIR/printer_data/config/printer.cfg $BASEDIR/pellcorp-backups/printer.factory.cfg
        else
          echo "WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING"
          echo "WARNING: No pristine factory printer.cfg available - config overrides are disabled!"
          echo "WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING"
        fi
    fi

    if [ "$skip_overrides" = "true" ]; then
        echo "INFO: Configuration overrides will not be saved or applied"
    fi

    install_config_updater

    if [ "$mode" = "reinstall" ] || [ "$mode" = "update" ]; then
        if [ "$skip_overrides" != "true" ]; then
            if [ -f $BASEDIR/pellcorp-backups/printer.cfg ]; then
                $BASEDIR/pellcorp/rpi/config-overrides.sh
            elif [ -f $BASEDIR/pellcorp.done ]; then # for a factory reset this warning is superfluous
              echo "WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING"
              echo "WARNING: No $BASEDIR/pellcorp-backups/printer.cfg - config overrides won't be generated!"
              echo "WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING"
            fi
        fi

        if [ -f $BASEDIR/pellcorp.done ]; then
          rm $BASEDIR/pellcorp.done
        fi

        # if we took a post factory reset backup for a reinstall restore it now
        if [ -f $BASEDIR/pellcorp-backups/printer.factory.cfg ]; then
            # lets just repair existing printer.factory.cfg if someone failed to factory reset, we will get them next time
            # but config overrides should generally work even if its not truly a factory config file
            if grep -q "#*# <---------------------- SAVE_CONFIG ---------------------->" $BASEDIR/pellcorp-backups/printer.factory.cfg; then
                sed -i '/^#*#/d' $BASEDIR/pellcorp-backups/printer.factory.cfg
            fi

            cp $BASEDIR/pellcorp-backups/printer.factory.cfg $BASEDIR/printer_data/config/printer.cfg
            sed -i "1s/^/# Modified by Simple AF ${TIMESTAMP}\n/" $BASEDIR/printer_data/config/printer.cfg
        elif [ "$mode" = "update" ]; then
            echo "ERROR: Update mode is not available as pristine factory printer.cfg is missing"
            exit 1
        fi
    fi

    if [ ! -f $BASEDIR/pellcorp.done ]; then
        # we need a flag to know what mount we are using
        if [ -n "$mount" ]; then
            echo "mount=$mount" > $BASEDIR/pellcorp.done
        elif [ -n "$install_mount" ]; then
            echo "mount=$install_mount" > $BASEDIR/pellcorp.done
        fi
    fi

    cd $HOME

    touch $BASEDIR/pellcorp.done

    install_crowsnest $mode

    install_moonraker $mode
    install_moonraker=$?

    install_nginx $mode
    install_nginx=$?

    install_fluidd $mode
    install_fluidd=$?

    install_mainsail $mode
    install_mainsail=$?

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

    install_guppyscreen $mode
    install_guppyscreen=$?

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

    if [ -f $BASEDIR/pellcorp-backups/printer.factory.cfg ]; then
        # we want a copy of the file before config overrides are re-applied so we can correctly generate diffs
        # against different generations of the original file
        for file in printer.cfg start_end.cfg fan_control.cfg $probe_model.conf spoolman.conf timelapse.conf moonraker.conf webcam.conf sensorless.cfg ${probe}_macro.cfg ${probe}.cfg; do
            if [ -f $BASEDIR/printer_data/config/$file ]; then
                cp $BASEDIR/printer_data/config/$file $BASEDIR/pellcorp-backups/$file
            fi
        done

        if [ -f $BASEDIR/guppyscreen/guppyscreen.json ]; then
          cp $BASEDIR/guppyscreen/guppyscreen.json $BASEDIR/pellcorp-backups/
        fi
    fi

    apply_overrides=0
    # there will be no support for generating pellcorp-overrides unless you have done a factory reset
    if [ -f $BASEDIR/pellcorp-backups/printer.factory.cfg ]; then
        if [ "$skip_overrides" != "true" ]; then
            apply_overrides
            apply_overrides=$?
        fi
    fi

    apply_mount_overrides=0
    if [ -n "$mount" ]; then
        $BASEDIR/pellcorp/rpi/apply-mount-overrides.sh $probe $mount
        apply_mount_overrides=$?
    fi

    fixup_client_variables_config
    fixup_client_variables_config=$?
    if [ $fixup_client_variables_config -eq 0 ]; then
        echo "INFO: No changes made"
    fi

    if [ $apply_overrides -ne 0 ] || [ $install_moonraker -ne 0 ] || [ $install_cartographer_klipper -ne 0 ] || [ $install_beacon_klipper -ne 0 ]; then
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
            sudo systemctl restart nginx
        else
            echo "WARNING: NGINX restart required"
        fi
    fi

    if [ $fix_custom_config -ne 0 ] || [ $fixup_client_variables_config -ne 0 ] || [ $apply_overrides -ne 0 ] || [ $apply_mount_overrides -ne 0 ] || [ $install_cartographer_klipper -ne 0 ] || [ $install_beacon_klipper -ne 0 ] || [ $install_klipper -ne 0 ] || [ $setup_probe -ne 0 ] || [ $setup_probe_specific -ne 0 ]; then
        if [ "$client" = "cli" ]; then
            echo
            echo "INFO: Restarting Klipper ..."
            sudo systemctl restart Klipper
        else
            echo "WARNING: Klipper restart required"
        fi
    fi

    if [ $apply_overrides -ne 0 ] || [ $install_guppyscreen -ne 0 ]; then
        if [ "$client" = "cli" ]; then
            echo
            echo "INFO: Restarting Grumpyscreen ..."
            sudo systemctl restart grumpyscreen
        else
            echo "WARNING: Grumpyscreen restart required"
        fi
    fi

    echo "installed_sha=$PELLCORP_GIT_SHA" >> $BASEDIR/pellcorp.done
    sync

    exit 0
} 2>&1 | tee -a $LOG_FILE
