#!/usr/bin/env bash
if [ -n "${DEBUG_SCRIPT:-}" ]; then
  set -x
fi
set -eu -o pipefail
cd $APP_ROOT

LOG_FILE="logs/init-$(date +%F-%T).log"
exec > >(tee $LOG_FILE) 2>&1

TIMEFORMAT=%lR
# For faster performance, don't audit dependencies automatically.
export COMPOSER_NO_AUDIT=1
# For faster performance, don't install dev dependencies.
export COMPOSER_NO_DEV=1

# Install VSCode Extensions
if [ -n "${DP_VSCODE_EXTENSIONS:-}" ]; then
  IFS=','
  for value in $DP_VSCODE_EXTENSIONS; do
    time code-server --install-extension $value
  done
fi

#== Remove root-owned files.
echo
echo Remove root-owned files.
time sudo rm -rf lost+found

#== Composer install.
echo
if [ -f composer.json ]; then
  if composer show --locked cweagans/composer-patches ^2 &> /dev/null; then
    if [ "${DP_REGENERATE_PATCHES_LOCK:-0}" = "1" ]; then
      echo 'Regenerating patches.lock.json (DP_REGENERATE_PATCHES_LOCK=1).'
      time composer patches:lock
      echo
    else
      echo 'Skipping patches.lock.json regeneration (set DP_REGENERATE_PATCHES_LOCK=1 to enable).'
    fi
  fi
else
  echo 'Generate composer.json.'
  time source .devpanel/composer_setup.sh
  echo
fi
# If update fails, change it to install.
# Clear Composer cache to avoid stale cached patch artifacts.
time composer clear-cache
time composer -n update --no-dev --no-progress

#== Create the private files directory.
if [ ! -d private ]; then
  echo
  echo 'Create the private files directory.'
  time mkdir private
fi

#== Create the config sync directory.
if [ ! -d config/sync ]; then
  echo
  echo 'Create the config sync directory.'
  time mkdir -p config/sync
fi

#== Ensure public files directory exists and is writable.
if [ ! -d web/sites/default/files ]; then
  echo
  echo 'Create the public files directory.'
  # If a file exists at the path, remove it first.
  if [ -f web/sites/default/files ]; then
    rm -f web/sites/default/files || :
  fi
  time mkdir -p web/sites/default/files || :
fi
echo 'Set permissions on public files directory.'
time chmod -R 775 web/sites/default/files || :

#== Generate hash salt.
if [ ! -f .devpanel/salt.txt ]; then
  echo
  echo 'Generate hash salt.'
  time openssl rand -hex 32 > .devpanel/salt.txt
fi

#== Install Drupal.
echo
if [ -z "$(drush status --field=db-status)" ]; then
  echo 'Install Drupal.'
  # Match the behavior of the project's ddev install script.
  time drush -n site:install \
    --account-name=admin \
    --account-pass=admin \
    --account-mail=admin@example.com \
    --site-name="Drupal Cloud Site" \
    --site-mail=noreply@example.com

  echo
  echo 'Tell Automatic Updates about patches.'
  drush -n cset --input-format=yaml package_manager.settings additional_trusted_composer_plugins '["cweagans/composer-patches"]'
  drush -n cset --input-format=yaml package_manager.settings additional_known_files_in_project_root '["patches.json", "patches.lock.json"]'
  time drush ev '\Drupal::moduleHandler()->invoke("automatic_updates", "modules_installed", [[], FALSE]);'

  echo
  echo 'Applying dcloud-core recipe...'
  # Apply the same recipe as the host install script (relative to web root).
  time drush -n recipe ../recipes/dcloud-core || :

  echo 'Clearing cache...'
  time drush -n cr || :

  echo 'Run consumers-next script...'
  time drush -n scr ../scripts/consumers-next.php || :

  echo 'Generating login link...'
  drush -n uli || :
else
  echo 'Update database.'
  time drush -n updb
fi

#== Warm up caches.
echo
echo 'Run cron.'
time drush cron
echo
echo 'Populate caches.'
time drush cache:warm &> /dev/null || :
time .devpanel/warm

#== Finish measuring script time.
INIT_DURATION=$SECONDS
INIT_HOURS=$(($INIT_DURATION / 3600))
INIT_MINUTES=$(($INIT_DURATION % 3600 / 60))
INIT_SECONDS=$(($INIT_DURATION % 60))
printf "\nTotal elapsed time: %d:%02d:%02d\n" $INIT_HOURS $INIT_MINUTES $INIT_SECONDS
