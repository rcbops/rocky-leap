# Upgrades Newton to Rocky JCB style

Upgrades to Rocky from Newton


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


////////////////////////////////////////////////////////////////////////////////
// Maintenance Template for upgrading to RPC 18 Rocky release
////////////////////////////////////////////////////////////////////////////////

////////////////////////////////////////////////////////////////////////////////
// MAINTENANCE PREP
////////////////////////////////////////////////////////////////////////////////

 (1) Maintenance objective:
    - Update Queens (RPC17) to Rocky (RPC18) version

 (1a) What should we check to confirm the solution is functioning as expected?
    - Environment is running a RPC18 version
    - Galera cluster is functioning
    - Rabbit cluster is functioning
    - OpenStack services are functioning
    - Instances are reachable

 (2) Departments involved:
    - RPCO
    - NetSec or the customer network engineering team
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

   tmux new -s rpc18-leap-upgrade

   # To enable screen logging press: Ctrl + b followed by H

   export PS1='${debian_chroot:+($debian_chroot)}\u@\h:\w $(date +'%s') \$ '

- <RPCO> 5.1.1 Create upgrade directory and set environment

   export BKUPDIR="/root/rpc18-jump-upgrade-$(date +%F)"; mkdir $BKUPDIR
   export BKUPREFIX="pre_rocky";
   export ANSIBLE_FORKS=50

- <RPCO> 5.1.2 Setup monitoring suppression

   https://rba.rackspace.com/suppression-manager/

- <RPCO> 5.1.3 Backup the existing playbooks

   tar czf $BKUPDIR/rpc-openstack-$(date +%F-%H%M%S).tar.gz /opt/rpc-openstack /opt/openstack-ansible 2>/dev/null

- <RPCO> 5.1.4 For environments with Swift: Connect to the proxy node and verify the swift cluster

   # Deployment Node:
   ssh $(grep swift_proxy_container /etc/openstack_deploy/openstack_hostnames_ips.yml |sort -u |head -n1 |awk -F\" '{print $2}')

     grep -q venvs /etc/init/swift-proxy-server.conf && source $( awk '/venvs.*activate/ { print $2 }' /etc/init/swift-proxy-server.conf )
     source /root/openrc
     swift-recon -arlud --md5 --human-readable
     exit

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

5.1.7
  Remove all rpco references in /etc/openstack_deploy/user_osa_variables_overrides.yml or convert to OSA equivalents
  
  add lvm_type to all cinder nodes in openstack_user_config.yml . Default (for thick-provisioning) or auto (for thin-provisioning) () 
  
  openstack_user_config.yml
*   XXXXXX-cinder01:
*     container_vars:
*       cinder_backends:
*         lvm:
*           volume_backend_name: LVM_iSCSI
*           volume_driver: cinder.volume.drivers.lvm.LVMVolumeDriver
*           volume_group: cinder-volumes
*           lvm_type: default     #This has to be set in order to get thick provisioning
*  
5.1.8 . Environment cleanup
*  
* Verify no instances outside of ACTIVE, RUNNING, STOPPED.  Clean up any error states or transient instance states
* # nova list --all-t | egrep -iv 'ACTIVE|RUNNING|STOPPED'
*  
* Verify all volumes in AVAILABLE or IN-USE state.  Clean up any volumes outside of these states
* # cinder list | egrep -iv 'AVAILABLE|IN-USE'
*  
* Verify apt sources, remove all references not Xenial
* Example sources:
* /etc/apt/sources.list
*  
* deb http://us.archive.ubuntu.com/ubuntu/ xenial main restricted
* deb http://us.archive.ubuntu.com/ubuntu/ xenial-updates main restricted
* deb http://us.archive.ubuntu.com/ubuntu/ xenial universe
* deb http://us.archive.ubuntu.com/ubuntu/ xenial-updates universe
* deb http://us.archive.ubuntu.com/ubuntu/ xenial multiverse
* deb http://us.archive.ubuntu.com/ubuntu/ xenial-updates multiverse
* deb http://us.archive.ubuntu.com/ubuntu/ xenial-backports main restricted universe multiverse
* deb http://security.ubuntu.com/ubuntu xenial-security main restricted
* deb http://security.ubuntu.com/ubuntu xenial-security universe
* deb http://security.ubuntu.com/ubuntu xenial-security multiverse
*  
*  
--------------------------------------------------------------------------------
 (5.2) Maintenance Prep (Steps to be completed during maintenance time):
--------------------------------------------------------------------------------

- <RPCO> 5.2.1 Download new code and upgrade

  # cd /root
  # git clone https://github.com/rcbops/rocky-leap /root/upgrades
  # cd /root/upgrades
  # ./jump.sh

