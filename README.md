<pre>Upgrades Newton to Rocky JCB style

////////////////////////////////////////////////////////////////////////////////
// PRE SCHEDULING REQUIREMENTS
////////////////////////////////////////////////////////////////////////////////

1. Please check the environment health at the time as creating the
   maintenance plan (MaaS, Dell/HP hardware monitors and OpenStack
   service states)

2. All customizations done in playbooks and containers are not migrated.
   These changed have to be reimplemented, if required and applied
   via playbooks since ALL containers of the OpenStack control plane are getting
   destroyed and rebuild. These customizations need to be applied post upgrade

3. Customers using VXLAN with l2pop (default setup) are expected to experience
   prolonged downtime during the upgrade.
   The downtime can only be prevented when using
   a) VXLAN via multicast
   b) Migration to VLAN provider
   Rackspace is preferring option b) to prevent this issue.
   Either option needs to be executed before scheduling this maintenance,
   unless the prolonged downtime is acceptable

4. If swift proxy are running inside containers, the swift/object storage service
   will be unavailable for the duration of the maintenance

5. All hosts and containers need to be running Ubuntu 16.04 (Xenial)
   A host OS upgrade to Xenial will need to be scheduled.

////////////////////////////////////////////////////////////////////////////////
// Maintenance Template for upgrading RPC Newton to openstack-Ansible Rocky release
////////////////////////////////////////////////////////////////////////////////

////////////////////////////////////////////////////////////////////////////////
// MAINTENANCE PREP
////////////////////////////////////////////////////////////////////////////////

 (1) Maintenance objective:
    - Update Newton (RPC14) to Rocky (OSA 18) version

 (1a) What should we check to confirm the solution is functioning as expected?
    - Environment is running a RPC18, Rocky version
    - Galera cluster is functioning
    - Rabbit cluster is functioning
    - OpenStack services are functioning
    - Instances are reachable

 (2) Departments involved:
    - RPCO
    - Ensure all teams assigned to this maintenance are available

 (3) Owning department: RPCO

 (4) Amount of time estimated for maintenance:

    Less than 30 compute nodes: Up to 8 hours

--------------------------------------------------------------------------------
 (5) Maintenance Steps:
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
 (5.1) Maintenance Prep:
--------------------------------------------------------------------------------

- <RPCO> Configure session on deployment node

   # Configure Ctrl b + H shortcut to enable session logging
   grep -q tmux.log 2>/dev/null ~/.tmux.conf || cat << _EOF >> ~/.tmux.conf
bind-key H pipe-pane -o "exec cat >>$HOME/'#W-tmux.log'" \; display-message 'Toggled logging to $HOME/#W-tmux.log'
_EOF

   tmux new -s newton-rocky-jump

   # To enable screen logging press: Ctrl + b followed by H

   export PS1='${debian_chroot:+($debian_chroot)}\u@\h:\w $(date +'%s') \$ '
   export BKUPDIR=/root/upgrade-backups; mkdir $BKUPDIR
   export ANSIBLE_FORKS=50

- <RPCO> 5.1.1 Create upgrade directory and set environment

!!! /root/upgrades already there
git clone https://github.com/rcbops/rocky-leap /root/upgrades

- <RPCO> 5.1.2 Clean up apt sources.list

/etc/apt/sources.list

deb http://us.archive.ubuntu.com/ubuntu/ xenial main restricted
deb http://us.archive.ubuntu.com/ubuntu/ xenial-updates main restricted
deb http://us.archive.ubuntu.com/ubuntu/ xenial universe
deb http://us.archive.ubuntu.com/ubuntu/ xenial-updates universe
deb http://us.archive.ubuntu.com/ubuntu/ xenial multiverse
deb http://us.archive.ubuntu.com/ubuntu/ xenial-updates multiverse
deb http://us.archive.ubuntu.com/ubuntu/ xenial-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu xenial-security main restricted
deb http://security.ubuntu.com/ubuntu xenial-security universe
deb http://security.ubuntu.com/ubuntu xenial-security multiverse

- <RPCO> 5.1.3 Clean up apt sources.list.d

Remove any sources that point to openstack sources like:
   deb http://ubuntu-cloud.archive.canonical.com/ubuntu xenial-updates/newton main

run apt-get update verify there are no errors

- <RPCO> 5.1.2 Setup monitoring suppression

   ## https://rba.rackspace.com/suppression-manager/ ##

- <RPCO> 5.1.3 Backup the existing playbooks

   tar czf $BKUPDIR/rpc-openstack-$(date +%F-%H%M%S).tar.gz /opt/rpc-openstack  2>/dev/null
   Remove symlink /opt/openstack-ansible

- <RPCO> 5.1.4 For environments with Swift: Connect to the proxy node and verify the swift cluster

	Swift is decoupled, this enviornment only uses it as a storage location and does not manage it

   Swift is deployed decoupled from all Ultime environments
   # Deployment Node:
   #ssh $(grep swift_proxy_container /etc/openstack_deploy/openstack_hostnames_ips.yml |sort -u |head -n1 |awk -F\" '{print $2}')

     #grep -q venvs /etc/init/swift-proxy-server.conf && source $( awk '/venvs.*activate/ { print $2 }' /etc/init/swift-proxy-server.conf )
     #source /root/openrc
     #swift-recon -arlud --md5 --human-readable
     #exit

- <RPCO> 5.1.5 Check OpenStack endpoints with the openstack_user_config.yml configuration

   ( source /usr/local/bin/openstack-ansible.rc; ansible utility_container[0] -m shell -a '. ~/openrc; openstack endpoint list' ) | tee $BKUPDIR/openstack_endpoints.txt

   # Verify that the internalURL endpoints match the configuration at internal_lb_vip_address
   # inside the openstack_user_config.yml

   # Verify that the publicURL endpoints match the configuration at external_lb_vip_address
   # inside the openstack_user_config.yml

   # If SSL and self signed certs are used for any endpoint please enable the
   # insecure flag for the OpenStack clients via:

   grep -q 'openrc_insecure:' 2>/dev/null /etc/openstack_deploy/user_*.yml ||
     echo 'openrc_insecure: true' >> /etc/openstack_deploy/user_osa_variables_overrides.yml

   # WARNING:
   # If this check is not executed properly, the OpenStack endpoints will be duplicated as the result
   # causing client side endpoint selection issues !
   #
   # Additionally please verify that configured public OpenStack endpoints can be accessed
   # from inside the OpenStack containers.

--------------------------------------------------------------------------------

- <RPCO> 5.1.6 Install OpenStack python clients if not already installed

   # Ensure that a correct pip.conf is in place to install release matching OpenStack clients

   ( source /usr/local/bin/openstack-ansible.rc; ansible utility_container[0] -m synchronize -a 'mode=pull src=/root/.pip dest=/root' )
   grep -q os-release ~/.pip/pip.conf 2>/dev/null && pip install --upgrade python-novaclient python-openstackclient \
     python-neutronclient python-heatclient python-cinderclient
     
- <RPCO> 5.1.7 Check if customer is using a custom 'dhcp_domain' or 'dns_domain'

   # Validate whether they're using DOMAIN for Neutron/Nova metadata -- if this doesn't exist, move to 5.2
   egrep -Ri 'dhcp_domain|dns_domain' /etc/openstack_deploy/user*
   
   # Check if there is a custom 'nova_nova_conf' or 'neutron_neutron_conf' -- duplicating these will be a problem
   egrep -Ri 'nova_nova_conf|neutron_neutron_conf' /etc/openstack_deploy/user*
   
   # If there is a 'nova_nova_conf' or 'neutron_neutron_conf' add the missing bits below to it, otherwise add this in entirety
   vi /etc/openstack_deploy/user_osa_variables_overrides.yml
   dhcp_domain: "<DOMAIN>" 
   nova_nova_conf_overrides:
     DEFAULT:
       dhcp_domain: "{{ dhcp_domain }}"
   neutron_neutron_conf_overrides:   
     DEFAULT:     
       dns_domain: "{{ dhcp_domain }}"    

- <RPCO> 5.1.8 Configure proxy overrides for pip and apt when operated behind a company proxy server

  cat << EOF >> /etc/openstack_deploy/user_osa_variables_overrides.yml

  ### Configure proxy overrides for PIP and APT
  proxy_env_url: "<http/s URL to proxy server>"
  proxy_custom_ca_cert: "/etc/ssl/certs/<customer ca crt>"

  ### The following overrides are automatically generated from the OSA inventory
  no_proxy_env: "localhost,monitoring.api.rackspacecloud.com,{{ internal_lb_vip_address }},{{ external_lb_vip_address }},{% for host in groups['all_containers'] %}{{ hostvars[host]['container_address'] }}{% if not loop.last %},{% endif %}{% endfor %}"

  deployment_environment_variables:
    HTTP_PROXY: "{{ proxy_env_url }}"
    HTTPS_PROXY: "{{ proxy_env_url }}"
    NO_PROXY: "{{ no_proxy_env }}"
    http_proxy: "{{ proxy_env_url }}"
    https_proxy: "{{ proxy_env_url }}"
    no_proxy: "{{ no_proxy_env }}"


  pip_install_options: " --timeout 120 --cert /etc/ssl/certs/ca-certificates.crt --cert {{ proxy_custom_ca_cert }} --trusted-host={{ internal_lb_vip_address }} --trusted-host=files.pythonhosted.org --trusted-host=pythonhosted.org --trusted-host=pypi.org --trusted-host=pypi.python.org --trusted-host=git.openstack.org "

  pip_get_pip_options: "{{ pip_install_options }}"

  repo_build_venv_pip_install_options: >-
    {{ pip_install_options }}
    --timeout 120
    --find-links {{ repo_build_release_path }}

  EOF

  Edit proxy_env_url and proxy_custom_ca_cert inside /etc/openstack_deploy/user_osa_variables_overrides.yml


###### NOTE
# In cases where the repo build process fails with
#    distutils.errors.DistutilsError: Download error for https://files.pythonhosted.org

# Please run the following command to monkey patch the python code:

# ansible repo_all -m lineinfile -a 'dest=/usr/local/lib/python2.7/dist-packages/setuptools/package_index.py regexp="^(.*)verify_ssl=True(.*)$" line="\1verify_ssl=False\2" backup=yes backrefs=yes'


--------------------------------------------------------------------------------
 (5.2) Maintenance Prep (Steps to be completed during maintenance time):
--------------------------------------------------------------------------------

- <RPCO> 5.2.1 Download code and configure

  # cd /root
  # git clone https://github.com/rcbops/rocky-leap /root/upgrades
  # cd /root/upgrades
  
  Edit defaults.yml to set a different db backup location

- <RPCO> 5.2.2 Decrypt Ansible vault files
 
   -- Non encrypted
   ansible-vault decrypt /etc/openstack_deploy/user*secret*.yml
   ansible-vault decrypt /etc/openstack_deploy/user*ldap*.yml

- <RPCO> 5.2.3 Run pre upgrade checks

   # Archive galera backup on deployment host
 #  rsync -av $(source /usr/local/bin/openstack-ansible.rc; ansible --list-hosts galera_container[0] |awk '/galera_container-/ {print $1}'; ):/var/backup/galera-backup-$(date +'%F')*.xbstream ${BKUPDIR}/

- <RPCO> 5.2.4 Environment pre upgrade configuration and verification

   sed -i -e '/^rpc_release:.*/d' /etc/openstack_deploy/user*.yml
   sed -i -e '/^keystone_cache_backend_argument:.*/d' /etc/openstack_deploy/user*.yml

 #  grep -q ceph_client_package_state /etc/openstack_deploy/*.yml || \
 #    echo "ceph_client_package_state: present" |tee -a /etc/openstack_deploy/user_rpco_variables_overrides.yml

   ##########################################
   # Cleanup the nova database
   #
   # In case the script execution stops with
   # foreign key errors, please restart it.
   # Depending on the volume of data the
   # database has to prune, it can run several
   # minutes.
   ( source /usr/local/bin/openstack-ansible.rc;
   ansible -m synchronize galera_container[0] -a 'mode=push src=/opt/openstack-ops/playbooks/files/rpc-o-support/nova-instance-cleanup.sh dest=/root/' && \
    ansible -m shell galera_container[0] -a 'bash -x /root/nova-instance-cleanup.sh' )
 
- <RPCO> 5.2.4
  Remove all rpco references in /etc/openstack_deploy/user_osa_variables_overrides.yml or convert to OSA equivalents
  
  add lvm_type to all cinder nodes in openstack_user_config.yml . Default (for thick-provisioning) or auto (for thin-provisioning) () 
  
  openstack_user_config.yml
   XXXXXX-cinder01:
     container_vars:
       cinder_backends:
         lvm:
           volume_backend_name: LVM_iSCSI
           volume_driver: cinder.volume.drivers.lvm.LVMVolumeDriver
           volume_group: cinder-volumes
           lvm_type: default     #This has to be set in order to get thick provisioning
 
- <RPCO> 5.2.5  Environment cleanup
 
 Verify no instances outside of ACTIVE, RUNNING, STOPPED.  Clean up any error states or transient instance states
 # nova list --all-t | egrep -iv 'ACTIVE|RUNNING|STOPPED'
 
 Verify all volumes in AVAILABLE or IN-USE state.  Clean up any volumes outside of these states
 # cinder list --all-t | egrep -iv 'AVAILABLE|IN-USE'

--------------------------------------------------------------------------------
 (5.3) Starting the upgrade to Rocky
--------------------------------------------------------------------------------

- <Network Engineer> 5.3.1 F5 LB only: Change F5 monitors to half-open TCP checks during upgrade

- <RPCO> 5.3.2 Upgrade to Rocky
   cd /root/upgrades
   ./jump.sh
    
--------------------------------------------------------------------------------
 (5.4) POST Deployment QC
--------------------------------------------------------------------------------

- <RPCO> 5.4.1 Verify Cloud state

   # The post upgrade RPC-O cloud checks are automated inside the rpc-post-upgrades.yml
   # playbook which includes the following checks:
   # - Galera DB cluster check
   # - RabbitMQ cluster check
   # - Nova, Neutron, Cinder Service states
   # - Elasticsearch Health indexes

   ( cd /opt/rpc-upgrades/playbooks && openstack-ansible -ebackup_dir=$BKUPDIR rpc-post-upgrades.yml --ask-vault-pass )


   # In case Swift is installed please verify overall health
   # via swift-recon

   # Deployment Node:
   ssh $(grep swift_proxy_container /etc/openstack_deploy/openstack_hostnames_ips.yml |sort -u |head -n1 |awk -F\" '{print $2}')

     grep -q venvs /etc/init/swift-proxy-server.conf && source $( awk '/venvs.*activate/ { print $2 }' /etc/init/swift-proxy-server.conf )
     source /root/openrc
     swift-recon -arlud --md5 --human-readable
     exit

- <RPCO> 5.4.2 Create a test instance and verify it can connect out

- <RPCO> 5.4.3 Create a cinder volume

- <RPCO> 5.4.4 Attach the volume to the test instance

- <RPCO> 5.4.5 Create a filesystem on the volume, write some data to it, verify it took, unmount

   # fdisk /dev/vdb
   # mkfs.ext4 /dev/vdb
   # mount /dev/vdb /mnt
   # echo "this is a test file" > /mnt/test-file.txt
   # cat /mnt/test-file.txt
   # umount /mnt

- <RPCO> 5.4.6 Delete the cinder volume

- <RPCO> 5.4.7 Delete the instance

- <RPCO> 5.4.8 Verify customer instances are reachable

- <RPCO> 5.4.9 Test Horizon functionality


--------------------------------------------------------------------------------
 (5.5) Update Rackspace Support tools
--------------------------------------------------------------------------------

- <RPCO> 5.5.2 Reinstall support environment

   ( source /usr/local/bin/openstack-ansible.rc; \
    ansible neutron_agents_container:utility_container -m copy -a 'src=/root/.ssh/rpc_support dest=/root/.ssh/rpc_support mode=600' && \
    ansible neutron_agents_container:utility_container -m copy -a 'src=/root/.ssh/rpc_support.pub dest=/root/.ssh/rpc_support.pub mode=600' )

   ( source /usr/local/bin/openstack-ansible.rc; cd /opt/openstack-ops/playbooks; openstack-ansible main.yml )

--------------------------------------------------------------------------------
 (5.6) Update MAAS Monitoring
--------------------------------------------------------------------------------sd

</pre>
