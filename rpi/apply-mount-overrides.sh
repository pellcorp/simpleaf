#!/bin/sh

BASEDIR=/home/pi
CONFIG_HELPER="$BASEDIR/pellcorp/k1/config-helper.py"
MOUNTS_DIR="$BASEDIR/pellcorp/k1/mounts"

MODEL=$(/usr/bin/get_sn_mac.sh model)
if [ "$MODEL" = "CR-K1" ] || [ "$MODEL" = "K1C" ] || [ "$MODEL" = "K1 SE" ]; then
    model=k1
elif [ "$MODEL" = "CR-K1 Max" ] || [ "$MODEL" = "K1 Max SE" ]; then
    model=k1m
elif [ "$MODEL" = "F004" ]; then
    model=f004
else
    echo "This script is not supported for $MODEL!"
    exit 1
fi

function apply_mount_overrides() {
    local probe=$1
    local mount=$2

    return_status=0
    overrides_dir=$MOUNTS_DIR/$probe/$mount
    if [ ! -f $MOUNTS_DIR/$probe/${mount}-${model}.overrides ]; then
        echo "ERROR: Probe (${probe}), Mount (${mount}) and Model (${model}) combination not found"
        exit 0 # FIXME unfortunately we are using this exit code to know overrides were applied
    fi

    echo
    echo "INFO: Applying mount ($mount) overrides ..."
    echo "WARNING: Please verify the mount configuration is correct before homing your printer, performing a bed mesh or using Screws Tilt Calculate"
    overrides_dir=/tmp/overrides.$$
    mkdir $overrides_dir
    file=
    while IFS= read -r line; do
        if echo "$line" | grep -q "^--"; then
            file=$(echo $line | sed 's/-- //g')
            touch $overrides_dir/$file
        elif echo "$line" | grep -q "^#"; then
            continue # skip comments
        elif [ -n "$file" ] && [ -f $overrides_dir/$file ]; then
            echo "$line" >> $overrides_dir/$file
        fi
    done < "$MOUNTS_DIR/$probe/${mount}-${model}.overrides"

  files=$(find $overrides_dir -maxdepth 1 -name "*.cfg")
  for file in $files; do
      file=$(basename $file)

      if [ -f $BASEDIR/printer_data/config/$file ]; then
          $CONFIG_HELPER --file $file --patches $overrides_dir/$file || exit $?
          return_status=1
      fi
  done
  rm -rf $overrides_dir
  sync
  return $return_status
}

restart_klipper=false

mode=config
if [ "$1" = "--verify" ]; then
    mode=verify
    shift
elif [ "$1" = "--restart" ]; then
  restart_klipper=true
  shift
fi

if [ $# -eq 0 ]; then
    echo "Usage: $0 [--verify] <cartotouch|btteddy|eddyng|microprobe|bltouch|beacon|klicky> <mount>"
    exit 0
fi

probe=$1
mount=$2

if [ "$mode" = "verify" ]; then
    if [ -d $MOUNTS_DIR/$probe ]; then
        if [ -f $MOUNTS_DIR/$probe/${mount}-${model}.overrides ]; then
            exit 0
        else
            if [ -n "$mount" ]; then
                echo "ERROR: Invalid Probe (${probe}), Mount (${mount}) and Model (${model}) combination"
            fi
            echo
            echo "The following mounts are available:"
            echo

            if [ -f $MOUNTS_DIR/$probe/Default-${model}.overrides ]; then
                comment=$(cat $MOUNTS_DIR/$probe/Default-${model}.overrides | grep "^#" | head -1 | sed 's/#\s*//g')
                echo "  * Default - $comment"
            fi

            files=$(find $MOUNTS_DIR/mounts/$probe -maxdepth 1 -name "*-${model}.overrides")
            for file in $files; do
                comment=$(cat $file | grep "^#" | head -1 | sed 's/#\s*//g')
                file=$(basename $file .overrides | sed "s/-${model}//g")
                if [ "$file" != "Default" ]; then
                    echo "  * $file - $comment"
                fi
            done
            echo
            echo "WARNING: Please verify the mount configuration is correct before homing your printer, performing a bed mesh or using Screws Tilt Calculate"
            echo
            exit 1
        fi
      else
          echo "ERROR: Invalid probe $probe specified!"
          exit 1
      fi
else
    apply_mount_overrides "$probe" "$mount"
    status=$?
    if [ $status -ne 0 ] && [ "$restart_klipper" = "true" ]; then
      echo "INFO: Restarting Klipper ..."
      sudo systemctl restart klipper
    fi
    exit $status
fi
