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
    RUN_TASKS=("/root/upgrades/pre-upgrade-backup.yml")
    RUN_TASKS+=("/root/upgrades/prep-upgrade.yml")
    RUN_TASKS+=("/root/upgrades/build-configs.yml")
    RUN_TASKS+=("/root/upgrades/build-venvs.yml")
    RUN_TASKS+=("/root/upgrades/shutdown-containers.yml")
    RUN_TASKS+=("/root/upgrades/upgrade-database-ocata.yml")
    RUN_TASKS+=("/root/upgrades/upgrade-database-pike.yml")
    RUN_TASKS+=("/root/upgrades/upgrade-database-queens.yml")
    RUN_TASKS+=("/root/upgrades/post-upgrade-backup.yml")
    for item in ${!RUN_TASKS[@]}; do
      run_lock $item "${RUN_TASKS[$item]}"
    done
  popd
}

function pre_flight {
  upgrade_marker_file="bootstrap"
  upgrade_marker="/etc/openstack_deploy/upgrade-${TARGET_SERIES}/$upgrade_marker_file.complete"

  if [ ! -f "$upgrade_marker" ];then

    openstack-ansible /root/upgrades/prep-jump.yml

    if [ ! -d  "/opt/openstack-ansible" ]; then
        pushd /opt
           git clone https://github.com/openstack/openstack-ansible
        popd
    fi
    pushd /opt/openstack-ansible
        git stash
        git checkout master
        git fetch && git fetch --tags
        git checkout stable/rocky
        git pull
        echo "Waiting for containers to start up"
        sleep 2m
        /opt/openstack-ansible/scripts/bootstrap-ansible.sh
    popd
    touch "$upgrade_marker"
  fi
}

function main {
    pre_flight
    pushd /opt/openstack-ansible
        cp /opt/openstack-ansible/inventory/env.d/nova.yml /etc/openstack_deploy/env.d
        RUN_TASKS=("/opt/openstack-ansible/playbooks/lxc-containers-destroy.yml -e force_containers_destroy=true -e force_containers_data_destroy=true")
        RUN_TASKS+=("/root/upgrades/cleanup-for-bm.yml")
        RUN_TASKS+=("/root/upgrades/cleanup-heat.yml")
        RUN_TASKS+=("/root/upgrades/cleanup-ironic.yml")
        RUN_TASKS+=("/root/upgrades/cleanup-nova.yml")
        RUN_TASKS+=("/root/upgrades/deploy-config-changes.yml")
        RUN_TASKS+=("/opt/openstack-ansible/playbooks/setup-hosts.yml -f 50 -l '!compute_all'")
        RUN_TASKS+=("/root/upgrades/venv_install.yml")
        RUN_TASKS+=("/opt/openstack-ansible/playbooks/setup-infrastructure.yml -f 50 -l '!compute_all'")
        RUN_TASKS+=("/root/upgrades/install_db.yml")
        RUN_TASKS+=("/opt/openstack-ansible/playbooks/setup-openstack.yml -f 50 -l '!compute_all'")
        for item in ${!RUN_TASKS[@]}; do
          run_lock $item "${RUN_TASKS[$item]}"
        done
    popd
}

TARGET_SERIES="queens"
upgrade_database
main
