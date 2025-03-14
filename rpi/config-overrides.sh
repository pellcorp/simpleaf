#!/bin/sh

CONFIG_OVERRIDES="$HOME/pellcorp/k1/config-overrides.py"

setup_git_repo() {
    if [ -d $HOME/pellcorp-overrides ]; then
        cd $HOME/pellcorp-overrides
        if ! git status > /dev/null 2>&1; then
          if [ $(ls | wc -l) -gt 0 ]; then
            cd - > /dev/null
            mv $HOME/pellcorp-overrides $HOME/pellcorp-overrides.$$
          else
            cd - > /dev/null
            rm -rf $HOME/pellcorp-overrides/
          fi
        fi
    fi

    git clone "https://$GITHUB_USERNAME:$GITHUB_TOKEN@github.com/$GITHUB_USERNAME/$GITHUB_REPO.git" $HOME/pellcorp-overrides || exit $?
    cd $HOME/pellcorp-overrides || exit $?
    git config user.name "$GITHUB_USERNAME" || exit $?
    git config user.email "$EMAIL_ADDRESS" || exit $?

    if [ -z "$GITHUB_BRANCH" ]; then
        export GITHUB_BRANCH=main
    fi

    branch=$(git rev-parse --abbrev-ref HEAD)
    if [ "$branch" != "$GITHUB_BRANCH" ]; then
      git switch $GITHUB_BRANCH 2>/dev/null
      if [ $? -eq 0 ]; then
        echo "Switched to branch $GITHUB_BRANCH"
      else
        git switch --orphan $GITHUB_BRANCH
        echo "Switched to new branch $GITHUB_BRANCH"
      fi
    fi

    # is this a brand new repo, setup a simple readme as the first commit
    if [ $(ls | wc -l) -eq 0 ]; then
        echo "# simple af pellcorp-overrides" >> README.md
        echo "https://pellcorp.github.io/creality-wiki/config_overrides/#git-backups-for-configuration-overrides" >> README.md
        git add README.md || exit $?
        git commit -m "initial commit" || exit $?
        git branch -M $GITHUB_BRANCH || exit $?
        git push -u origin $GITHUB_BRANCH || exit $?
    fi

    # the rest of the script will actually push the changes if needed
    if [ -d $HOME/pellcorp-overrides.$$ ]; then
        mv $HOME/pellcorp-overrides.$$/* $HOME/pellcorp-overrides/
        rm -rf $HOME/pellcorp-overrides.$$
    fi
}

override_file() {
    local file=$1

    if [ -L $HOME/printer_data/config/$file ]; then
        echo "INFO: Overrides not supported for $file"
        return 0
    fi

    overrides_file="$HOME/pellcorp-overrides/$file"
    original_file="$HOME/pellcorp/k1/$file"
    updated_file="$HOME/printer_data/config/$file"
    
    if [ -f "$HOME/pellcorp-backups/$file" ]; then
        original_file="$HOME/pellcorp-backups/$file"
    elif [ "$file" = "guppyscreen.cfg" ] || [ "$file" = "internal_macros.cfg" ] || [ "$file" = "useful_macros.cfg" ]; then
        echo "INFO: Overrides not supported for $file"
        return 0
    elif [ "$file" = "printer.cfg" ] || [ "$file" = "beacon.conf" ] || [ "$file" = "cartographer.conf" ] || [ "$file" = "moonraker.conf" ] || [ "$file" = "start_end.cfg" ] || [ "$file" = "fan_control.cfg" ]; then
        # for printer.cfg, useful_macros.cfg, start_end.cfg, fan_control.cfg and moonraker.conf - there must be an pellcorp-backups file
        echo "INFO: Overrides not supported for $file"
        return 0
    elif [ ! -f "$HOME/pellcorp/k1/$file" ]; then
        echo "INFO: Backing up $HOME/printer_data/config/$file ..."
        cp  $HOME/printer_data/config/$file $HOME/pellcorp-overrides/
        return 0
    fi
    $CONFIG_OVERRIDES --original "$original_file" --updated "$updated_file" --overrides "$overrides_file" || exit $?

    # we renamed the SENSORLESS_PARAMS to hide it
    if [ -f $HOME/pellcorp-overrides/sensorless.cfg ]; then
      sed -i 's/gcode_macro SENSORLESS_PARAMS/gcode_macro _SENSORLESS_PARAMS/g' $HOME/pellcorp-overrides/sensorless.cfg
    fi

    if [ "$file" = "printer.cfg" ]; then
      saves=false
      while IFS= read -r line; do
        if [ "$line" = "#*# <---------------------- SAVE_CONFIG ---------------------->" ]; then
          saves=true
          echo "" > $HOME/pellcorp-overrides/printer.cfg.save_config
          echo "INFO: Saving save config state to $HOME/pellcorp-overrides/printer.cfg.save_config"
        fi
        if [ "$saves" = "true" ]; then
          echo "$line" >> $HOME/pellcorp-overrides/printer.cfg.save_config
        fi
      done < "$updated_file"
    fi
}

# make sure we are outside of the $HOME/pellcorp-overrides directory
cd /root/

if [ "$1" = "--help" ]; then
  echo "Use '$(basename $0) --repo' to create a new git repo in $HOME/pellcorp-overrides"
  echo "Use '$(basename $0) --clean-repo' to create a new git repo in $HOME/pellcorp-overrides and ignore local files"
  exit 0
elif [ "$1" = "--repo" ] || [ "$1" = "--clean-repo" ]; then
  if [ -n "$GITHUB_USERNAME" ] && [ -n "$EMAIL_ADDRESS" ] && [ -n "$GITHUB_TOKEN" ] && [ -n "$GITHUB_REPO" ]; then
        if [ -d $HOME/pellcorp-overrides/.git ]; then
          echo "ERROR: Repo dir $HOME/pellcorp-overrides/.git exists"
          exit 1
        fi

        if [ "$1" = "--clean-repo" ] && [ -d $HOME/pellcorp-overrides ]; then
          echo "INFO: Deleting existing $HOME/pellcorp-overrides"
          rm -rf $HOME/pellcorp-overrides
        fi
        setup_git_repo
    else
        echo "You must define these environment variables:"
        echo "  GITHUB_USERNAME"
        echo "  EMAIL_ADDRESS"
        echo "  GITHUB_TOKEN"
        echo "  GITHUB_REPO"
        echo
        echo "Optionally if you want to use a branch other than 'main':"
        echo "  GITHUB_BRANCH"
        echo
        echo "https://pellcorp.github.io/creality-wiki/config_overrides/#git-backups-for-configuration-overrides"
        exit 1
    fi
else
  # there will be no support for generating pellcorp-overrides unless you have done a factory reset
  if [ -f $HOME/pellcorp-backups/printer.factory.cfg ]; then
      # the pellcorp-backups do not need .pellcorp extension, so this is to fix backwards compatible
      if [ -f $HOME/pellcorp-backups/printer.pellcorp.cfg ]; then
          mv $HOME/pellcorp-backups/printer.pellcorp.cfg $HOME/pellcorp-backups/printer.cfg
      fi
  fi

  if [ ! -f $HOME/pellcorp-backups/printer.cfg ]; then
      echo "ERROR: $HOME/pellcorp-backups/printer.cfg missing"
      exit 1
  fi

  if [ -f $HOME/pellcorp-overrides.cfg ]; then
      echo "ERROR: $HOME/pellcorp-overrides.cfg exists!"
      exit 1
  fi

  if [ ! -f $HOME/pellcorp.done ]; then
      echo "ERROR: No installation found"
      exit 1
  fi

  if [ $(grep "probe" $HOME/pellcorp.done | wc -l) -lt 2 ]; then
    echo "ERROR: Previous partial installation detected, configuration overrides will not be generated"
    if [ -d $HOME/pellcorp-overrides ]; then
        echo "INFO: Previous configuration overrides will be used instead"
    fi
    exit 1
  fi

  mkdir -p $HOME/pellcorp-overrides

  # in case we changed config and no longer need an override file, we should delete all
  # all the config files there.
  rm $HOME/pellcorp-overrides/*.cfg 2> /dev/null
  rm $HOME/pellcorp-overrides/*.conf 2> /dev/null
  rm $HOME/pellcorp-overrides/*.json 2> /dev/null
  if [ -f $HOME/pellcorp-overrides/printer.cfg.save_config ]; then
    rm $HOME/pellcorp-overrides/printer.cfg.save_config
  fi
  if [ -f $HOME/pellcorp-overrides/moonraker.secrets ]; then
    rm $HOME/pellcorp-overrides/moonraker.secrets
  fi

  # special case for moonraker.secrets
  if [ -f $HOME/printer_data/moonraker.secrets ] && [ -f $HOME/pellcorp/k1/moonraker.secrets ]; then
      diff $HOME/printer_data/moonraker.secrets $HOME/pellcorp/k1/moonraker.secrets > /dev/null
      if [ $? -ne 0 ]; then
          echo "INFO: Backing up $HOME/printer_data/moonraker.secrets..."
          cp $HOME/printer_data/moonraker.secrets $HOME/pellcorp-overrides/
      fi
  fi

  files=$(find $HOME/printer_data/config/ -maxdepth 1 ! -name 'printer-*.cfg' -a ! -name ".printer.cfg" -a -name "*.cfg" -o -name "*.conf")
  for file in $files; do
    file=$(basename $file)
    override_file $file
  done

  $HOME/pellcorp/k1/update-guppyscreen.sh --config-overrides
fi

cd $HOME/pellcorp-overrides
if git status > /dev/null 2>&1; then
    echo
    echo "INFO: $HOME/pellcorp-overrides is a git repository"

    # special handling for moonraker.secrets, we do not want to source control this
    # file for fear of leaking credentials
    if [ ! -f .gitignore ]; then
      echo "moonraker.secrets" > .gitignore
    elif ! grep -q "moonraker.secrets" .gitignore; then
      echo "moonraker.secrets" >> .gitignore
    fi

    # make sure we remove any versioned file
    git rm --cached moonraker.secrets 2> /dev/null

    status=$(git status)
    echo "$status" | grep -q "nothing to commit, working tree clean"
    if [ $? -eq 0 ]; then
        echo "INFO: No changes in git repository"
    else
        echo "INFO: Outstanding changes - pushing them to remote repository"
        branch=$(git rev-parse --abbrev-ref HEAD)
        git add --all || exit $?
        git commit -m "pellcorp override changes" || exit $?
        git push -u origin $branch || exit $?
    fi
fi
