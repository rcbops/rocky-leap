#!/bin/bash

function run_lock {
  set +e
  run_item="${RUN_TASKS[$1]}"
  file_part="${run_item}"

  for part in $run_item; do
    if [[ "$part" == *.yml ]];then
      file_part="$part"
      break
    fi
  done

  if [ ! -d  "/etc/openstack_deploy/upgrade-${TARGET_SERIES}" ]; then
      mkdir -p "/etc/openstack_deploy/upgrade-${TARGET_SERIES}"
  fi

  upgrade_marker_file=$(basename ${file_part} .yml)
  upgrade_marker="/etc/openstack_deploy/upgrade-${TARGET_SERIES}/$upgrade_marker_file.complete"

  if [ ! -f "$upgrade_marker" ];then
    eval "openstack-ansible $2"
    playbook_status="$?"
    echo "ran $run_item"

    if [ "$playbook_status" == "0" ];then
      RUN_TASKS=("${RUN_TASKS[@]/$run_item}")
      touch "$upgrade_marker"
      echo "$run_item has been marked as success"
    else
      echo "******************** failure ********************"
      echo "The upgrade script has encountered a failure."
      echo "Failed on task \"$run_item\""
      echo "Re-run the run-upgrade.sh script, or"
      echo "execute the remaining tasks manually:"
      for item in $(seq $1 $((${#RUN_TASKS[@]} - 1))); do
        if [ -n "${RUN_TASKS[$item]}" ]; then
          echo "openstack-ansible ${RUN_TASKS[$item]}"
        fi
      done
      echo "******************** failure ********************"
      exit 99
    fi
  else
    RUN_TASKS=("${RUN_TASKS[@]/$run_item.*}")
  fi
  set -e
}

function upgrade_database {
  pushd /root/upgrades
    RUN_TASKS=("/root/upgrades/prep-upgrade.yml --ask-vault-pass")
    RUN_TASKS+=("/root/upgrades/build-configs.yml --ask-vault-pass")
    RUN_TASKS+=("/root/upgrades/build-venvs.yml --ask-vault-pass")
    RUN_TASKS+=("/root/upgrades/pre-upgrade-backup.yml --ask-vault-pass")
    RUN_TASKS+=("/root/upgrades/upgrade-database-ocata.yml --ask-vault-pass")
    RUN_TASKS+=("/root/upgrades/upgrade-database-pike.yml --ask-vault-pass")
    RUN_TASKS+=("/root/upgrades/upgrade-database-queens.yml --ask-vault-pass")
    RUN_TASKS+=("/root/upgrades/upgrade-database-rocky.yml --ask-vault-pass")
    RUN_TASKS+=("/root/upgrades/post-upgrade-backup.yml --ask-vault-pass")
    for item in ${!RUN_TASKS[@]}; do
      run_lock $item "${RUN_TASKS[$item]}"
    done
  popd
}

function pre_flight {
    pushd /opt/openstack-ansible
        git stash
        git checkout master
        git fetch && git fetch --tags
        git checkout stable/rocky
#        git checkout 18.1.6
        echo "Wait for containers to be available"
        sleep 2m
        /opt/openstack-ansible/scripts/bootstrap-ansible.sh
    popd
}


function main {
    openstack-ansible /root/upgrades/prep-jump.yml
    pre_flight
    pushd /opt/openstack-ansible
        RUN_TASKS=("/opt/openstack-ansible/playbooks/lxc-containers-destroy.yml -e force_containers_destroy=true -e force_containers_data_destroy=true")
        RUN_TASKS+=("/opt/openstack-ansible/playbooks/setup-hosts.yml -f 50")
        RUN_TASKS=("/opt/openstack-ansible/playbooks/setup-infrastructure.yml -f 50")
        RUN_TASKS+=("/root/upgrades/install_db.yml")
        RUN_TASKS+=("/opt/openstack-ansible/playbooks/setup-openstack.yml -f 50 -l '!compute_all'")
        for item in ${!RUN_TASKS[@]}; do
          run_lock $item "${RUN_TASKS[$item]}"
        done
    popd
}

TARGET_SERIES="rocky"
upgrade_database
main
