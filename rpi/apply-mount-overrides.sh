#!/bin/sh

CONFIG_HELPER="$HOME/pellcorp/k1/config-helper.py"

MODEL=e3

function apply_mount_overrides() {
    local probe=$1
    local mount=$2

    return_status=0
    overrides_dir=$HOME/pellcorp/k1/mounts/$probe/$mount
    if [ ! -f $HOME/pellcorp/k1/mounts/$probe/${mount}.overrides ]; then
        echo "ERROR: Probe and Mount combination not found"
        exit 0 # FIXME unfortunately we are using this exit code to know overrides were applied
    fi

    echo
    echo "INFO: Applying mount overrides ..."
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
    done < "$HOME/pellcorp/k1/mounts/$probe/${mount}.overrides"

  files=$(find $overrides_dir -maxdepth 1 -name "*.cfg")
  for file in $files; do
      file=$(basename $file)

      if [ "$file" = "bltouch.cfg" ] && [ "$probe" = "bltouch" ]; then # bltouch.cfg is merged into printer.cfg
          target_file=printer.cfg
      elif [ "$file" = "microprobe.cfg" ] && [ "$probe" = "microprobe" ]; then # microprobe.cfg is merged into printer.cfg
          target_file=printer.cfg
      elif [ "$file" = "printer-${model}.cfg" ]; then
          target_file=printer.cfg
      elif [ "$file" = "klicky_macro-${model}.cfg" ]; then # special case for _KLICKY_VARIABLES
        target_file=klicky_macro.cfg
      else
          target_file=$file
      fi

      if [ -f $HOME/printer_data/config/$target_file ]; then
          echo "Applying mount overrides for $target_file ..."
          $CONFIG_HELPER --file $target_file --patches $overrides_dir/$file || exit $?
      fi
      return_status=1
  done
  rm -rf $overrides_dir
  return $return_status
}

mode=config
if [ "$1" = "--verify" ]; then
    mode=verify
    shift
fi

if [ $# -eq 0 ]; then
    echo "Usage: $0 <cartotouch|btteddy|eddyng|microprobe|bltouch|beacon> <mount>"
    exit 0
fi

probe=$1
mount=$2

if [ "$mode" = "verify" ]; then
    if [ -d $HOME/pellcorp/k1/mounts/$probe ]; then
        if [ -f $HOME/pellcorp/k1/mounts/$probe/${mount}.overrides ]; then
            exit 0
        else
            if [ -n "$mount" ]; then
                echo "ERROR: Invalid $probe mount $mount specified!"
            fi
            echo
            echo "The following mounts are available:"
            echo

            if [ -f $HOME/pellcorp/k1/mounts/$probe/Default.overrides ]; then
                comment=$(cat $HOME/pellcorp/k1/mounts/$probe/Default.overrides | grep "^#" | head -1 | sed 's/#\s*//g')
                echo "  * Default - $comment"
            fi

            files=$(find $HOME/pellcorp/k1/mounts/$probe -maxdepth 1 -name "*.overrides")
            for file in $files; do
                comment=$(cat $file | grep "^#" | head -1 | sed 's/#\s*//g')
                file=$(basename $file .overrides)
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
fi
