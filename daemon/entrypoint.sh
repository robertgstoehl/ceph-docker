#!/bin/bash
set -e

: ${CLUSTER:=ceph}
: ${MON_NAME:=$(hostname -s)}
: ${OSD_WEIGHT:=1.0}
: ${MDS_NAME:=$(hostname -s)}
: ${CEPHFS_CREATE:=0}
: ${CEPHFS_NAME:=cephfs}
: ${CEPHFS_DATA_POOL:=${CEPHFS_NAME}_data}
: ${CEPHFS_DATA_POOL_PG:=8}
: ${CEPHFS_METADATA_POOL:=${CEPHFS_NAME}_metadata}
: ${CEPHFS_METADATA_POOL_PG:=8}
: ${RGW_NAME:=$(hostname -s)}
: ${RGW_CIVETWEB_PORT:=80}
: ${RGW_CIVETWEB_PORT:=80}
: ${RGW_REMOTE_CGI:=0}
: ${RGW_REMOTE_CGI_PORT:=9000}
: ${RGW_REMOTE_CGI_HOST:=0.0.0.0}
: ${CEPH_CLUSTER_NETWORK:=${CEPH_PUBLIC_NETWORK}}


if [ ! -n "$CEPH_DAEMON" ]; then
   echo "ERROR- CEPH_DAEMON must be defined as the name of the daemon you want to deploy"
   echo "Valid values for CEPH_DAEMON are MON, OSD, OSD_EXPERIMENTAL, MDS, RGW"
   exit 1
fi

function ceph_config_check {
if [[ ! -e /etc/ceph/ceph.conf ]]; then
  echo "ERROR- /etc/ceph/ceph.conf must exist; get it from your existing mon"
  exit 1
fi
}


#######
# MON #
#######

if [[ "$CEPH_DAEMON" = "MON" ]]; then

  if [ ! -n "$CEPH_PUBLIC_NETWORK" ]; then
    echo "ERROR- CEPH_PUBLIC_NETWORK must be defined as the name of the network for the OSDs"
    exit 1
  fi

  if [ ! -n "$MON_IP" ]; then
    echo "ERROR- MON_IP must be defined as the IP address of the monitor"
    exit 1
  fi

  # bootstrap MON
  if [ ! -e /etc/ceph/ceph.conf ]; then
    fsid=$(uuidgen)
    cat <<ENDHERE >/etc/ceph/ceph.conf
[global]
fsid = $fsid
mon initial members = ${MON_NAME}
mon host = ${MON_IP}
auth cluster required = cephx
auth service required = cephx
auth client required = cephx
public network = ${CEPH_PUBLIC_NETWORK}
cluster network = ${CEPH_CLUSTER_NETWORK}
ENDHERE

    # Generate administrator key
    ceph-authtool /etc/ceph/ceph.client.admin.keyring --create-keyring --gen-key -n client.admin --set-uid=0 --cap mon 'allow *' --cap osd 'allow *' --cap mds 'allow'

    # Generate the mon. key
    ceph-authtool /etc/ceph/ceph.mon.keyring --create-keyring --gen-key -n mon. --cap mon 'allow *'

    # Create bootstrap key directories
    mkdir -p /var/lib/ceph/bootstrap-{osd,mds,rgw}

    # Generate the OSD bootstrap key
    ceph-authtool /var/lib/ceph/bootstrap-osd/ceph.keyring --create-keyring --gen-key -n client.bootstrap-osd --cap mon 'allow profile bootstrap-osd'

    # Generate the MDS bootstrap key
    ceph-authtool /var/lib/ceph/bootstrap-mds/ceph.keyring --create-keyring --gen-key -n client.bootstrap-mds --cap mon 'allow profile bootstrap-mds'

    # Generate the RGW bootstrap key
    ceph-authtool /var/lib/ceph/bootstrap-rgw/ceph.keyring --create-keyring --gen-key -n client.bootstrap-rgw --cap mon 'allow profile bootstrap-rgw'

    # Generate initial monitor map
    monmaptool --create --add ${MON_NAME} ${MON_IP} --fsid ${fsid} /etc/ceph/monmap
  fi

  # If we don't have a monitor keyring, this is a new monitor
  if [ ! -e /var/lib/ceph/mon/ceph-${MON_NAME}/keyring ]; then

    if [ ! -e /etc/ceph/ceph.mon.keyring ]; then
      echo "ERROR- /etc/ceph/ceph.mon.keyring must exist.  You can extract it from your current monitor by running 'ceph auth get mon. -o /etc/ceph/ceph.mon.keyring'"
      exit 3
    fi

    if [ ! -e /etc/ceph/monmap ]; then
       echo "ERROR- /etc/ceph/monmap must exist.  You can extract it from your current monitor by running 'ceph mon getmap -o /etc/ceph/monmap'"
       exit 4
    fi

    # Testing if it's not the first monitor, if one key doesn't exist we assume none of them exist
    ceph-authtool /tmp/ceph.mon.keyring --create-keyring --import-keyring /etc/ceph/ceph.client.admin.keyring
    ceph-authtool /tmp/ceph.mon.keyring --import-keyring /var/lib/ceph/bootstrap-osd/ceph.keyring
    ceph-authtool /tmp/ceph.mon.keyring --import-keyring /var/lib/ceph/bootstrap-mds/ceph.keyring
    ceph-authtool /tmp/ceph.mon.keyring --import-keyring /var/lib/ceph/bootstrap-rgw/ceph.keyring
    ceph-authtool /tmp/ceph.mon.keyring --import-keyring /etc/ceph/ceph.mon.keyring

    # Make the monitor directory
    mkdir -p /var/lib/ceph/mon/ceph-${MON_NAME}

    # Prepare the monitor daemon's directory with the map and keyring
    ceph-mon --mkfs -i ${MON_NAME} --monmap /etc/ceph/monmap --keyring /tmp/ceph.mon.keyring

    # Clean up the temporary key
    rm /tmp/ceph.mon.keyring
  fi

  # start MON
  exec /usr/bin/ceph-mon -d -i ${MON_NAME} --public-addr ${MON_IP}:6789
fi


#######
# OSD #
#######

if [[ "$CEPH_DAEMON" = "OSD" ]]; then

  ceph_config_check

  if [ -n "$(find /var/lib/ceph/osd -prune -empty)" ]; then
    echo "ERROR- could not find any OSD, did you bind mount the OSD data directory?"
    echo "ERROR- use -v <host_osd_data_dir>:<container_osd_data_dir>"
    exit 1
  fi

  for OSD_ID in $(ls /var/lib/ceph/osd |  awk 'BEGIN { FS = "-" } ; { print $2 }')
  do
    if [ -n "${JOURNAL_DIR}" ]; then
       OSD_J="${JOURNAL_DIR}/journal.${OSD_ID}"
    else
       if [ -n "${JOURNAL}" ]; then
          OSD_J=${JOURNAL}
       else
          OSD_J=/var/lib/ceph/osd/${CLUSTER}-${OSD_ID}/journal
       fi
    fi

    # Check to see if our OSD has been initialized
    if [ ! -e /var/lib/ceph/osd/${CLUSTER}-${OSD_ID}/keyring ]; then
      # Create OSD key and file structure
      ceph-osd -i $OSD_ID --mkfs --mkjournal --osd-journal ${OSD_J}

      if [ ! -e /var/lib/ceph/bootstrap-osd/ceph.keyring ]; then
        echo "ERROR- /var/lib/ceph/bootstrap-osd/ceph.keyring must exist. You can extract it from your current monitor by running 'ceph auth get client.bootstrap-osd -o /var/lib/ceph/bootstrap-osd/ceph.keyring'"
        exit 1
      fi

      timeout 10 --cluster ${CLUSTER} ceph --name client.bootstrap-osd --keyring /var/lib/ceph/bootstrap-osd/ceph.keyring health || exit 1

      # Generate the OSD key
      ceph --cluster ${CLUSTER} --name client.bootstrap-osd --keyring /var/lib/ceph/bootstrap-osd/ceph.keyring auth get-or-create osd.${OSD_ID} osd 'allow *' mon 'allow profile osd' -o /var/lib/ceph/osd/${CLUSTER}-${OSD_ID}/keyring

      # Add the OSD to the CRUSH map
      if [ ! -n "${HOSTNAME}" ]; then
        echo "HOSTNAME not set; cannot add OSD to CRUSH map"
        exit 1
      fi
      ceph --name=osd.${OSD_ID} --keyring=/var/lib/ceph/osd/${CLUSTER}-${OSD_ID}/keyring osd crush create-or-move -- ${OSD_ID} ${OSD_WEIGHT} root=default host=${HOSTNAME}
    fi

    mkdir -p /etc/service/ceph-${OSD_ID}
    cat >/etc/service/ceph-${OSD_ID}/run <<EOF
#!/bin/bash
echo "store-daemon: starting daemon on ${HOSTNAME}..."
exec ceph-osd -f -d -i ${OSD_ID} --osd-journal ${OSD_J} -k /var/lib/ceph/osd/ceph-${OSD_ID}/keyring
EOF
    chmod +x /etc/service/ceph-${OSD_ID}/run
  done

read


####################
# OSD_EXPERIMENTAL #
####################

elif [[ "$CEPH_DAEMON" = "OSD_EXPERIMENTAL" ]]; then

  ceph_config_check

  if [[ -z "${OSD_DEVICE}" ]];then
    echo "ERROR- You must provide a device to build your OSD ie: /dev/sdb"
    exit 1
  fi

  if [ ! -e /var/lib/ceph/bootstrap-ods/ceph.keyring ]; then
    echo "ERROR- /var/lib/ceph/bootstrap-ods/ceph.keyring must exist. You can extract it from your current monitor by running 'ceph auth get client.bootstrap-ods -o /var/lib/ceph/bootstrap-ods/ceph.keyring'"
    exit 1
  fi

  mkdir -p /var/lib/ceph/osd

  # TODO:
  # -  add device format check (make sure only one device is passed
  # -  verify that the device is not an OSD already (force option)

  ceph-disk -v zap ${OSD_DEVICE}

  if [[ ! -z "${OSD_JOURNAL}" ]];then
    ceph-disk -v prepare ${OSD_DEVICE}:${OSD_JOURNAL}
  else
    ceph-disk -v prepare ${OSD_DEVICE}
  fi

  ceph-disk -v activate ${OSD_DEVICE}1
  OSD_ID=$(cat /var/lib/ceph/osd/$(ls -ltr /var/lib/ceph/osd/ | tail -n1 | awk -v pattern="$CLUSTER" '$0 ~ pattern {print $9}')/whoami)
  ceph --name=osd.${OSD_ID} --keyring=/var/lib/ceph/osd/${CLUSTER}-${OSD_ID}/keyring osd crush create-or-move -- ${OSD_ID} ${OSD_WEIGHT} root=default host=$(hostname)

  exec /usr/bin/ceph-osd -f -d -i ${OSD_ID}


#######
# MDS #
#######

elif [[ "$CEPH_DAEMON" = "MDS" ]]; then

  ceph_config_check

  # Check to see if we are a new MDS
  if [ ! -e /var/lib/ceph/mds/ceph-${MDS_NAME}/keyring ]; then

     mkdir -p /var/lib/ceph/mds/ceph-${MDS_NAME}

    if [ ! -e /var/lib/ceph/bootstrap-mds/ceph.keyring ]; then
      echo "ERROR- /var/lib/ceph/bootstrap-mds/ceph.keyring must exist. You can extract it from your current monitor by running 'ceph auth get client.bootstrap-mds -o /var/lib/ceph/bootstrap-mds/ceph.keyring'"
      exit 1
    fi

    timeout 10 --cluster ${CLUSTER} ceph --name client.bootstrap-mds --keyring /var/lib/ceph/bootstrap-mds/ceph.keyring health || exit 1

    # Generate the MDS key
    ceph --cluster ${CLUSTER} --name client.bootstrap-mds --keyring /var/lib/ceph/bootstrap-mds/ceph.keyring auth get-or-create mds.$MDS_NAME osd 'allow rwx' mds 'allow' mon 'allow profile mds' > /var/lib/ceph/mds/ceph-${MDS_NAME}/keyring

  fi

  # NOTE (leseb): having the admin keyring is really a security issue
  # If we need to bootstrap a MDS we should probably create the following on the monitors
  # I understand that this handy to do this here
  # but having the admin key inside every container is a concern

  # Create the Ceph filesystem, if necessary
  if [ $CEPHFS_CREATE -eq 1 ]; then
    if [[ ! -e /etc/ceph/ceph.client.admin.keyring ]]; then
      echo "ERROR- /etc/ceph/ceph.client.admin.keyring must exist; get it from your existing mon"
      exit 1
    fi
    if [[ "$(ceph fs ls | grep -c name:.${CEPHFS_NAME},)" -eq "0" ]]; then
       # Make sure the specified data pool exists
       if ! ceph osd pool stats ${CEPHFS_DATA_POOL} > /dev/null 2>&1; then
          ceph osd pool create ${CEPHFS_DATA_POOL} ${CEPHFS_DATA_POOL_PG}
       fi

       # Make sure the specified metadata pool exists
       if ! ceph osd pool stats ${CEPHFS_METADATA_POOL} > /dev/null 2>&1; then
          ceph osd pool create ${CEPHFS_METADATA_POOL} ${CEPHFS_METADATA_POOL_PG}
       fi

       ceph fs new ${CEPHFS_NAME} ${CEPHFS_METADATA_POOL} ${CEPHFS_DATA_POOL}
    fi
  fi

  # NOTE: prefixing this with exec causes it to die (commit suicide)
  /usr/bin/ceph-mds -d -i ${MDS_NAME}


#######
# RGW #
#######

elif [[ "$CEPH_DAEMON" = "RGW" ]]; then

  ceph_config_check

  # Check to see if our RGW has been initialized
  if [ ! -e /var/lib/ceph/radosgw/${RGW_NAME}/keyring ]; then

    mkdir -p /var/lib/ceph/radosgw/${RGW_NAME}

    if [ ! -e /var/lib/ceph/bootstrap-rgw/ceph.keyring ]; then
      echo "ERROR- /var/lib/ceph/bootstrap-rgw/ceph.keyring must exist. You can extract it from your current monitor by running 'ceph auth get client.bootstrap-rgw -o /var/lib/ceph/bootstrap-rgw/ceph.keyring'"
      exit 1
    fi

    timeout 10 --cluster ${CLUSTER} ceph --name client.bootstrap-rgw --keyring /var/lib/ceph/bootstrap-rgw/ceph.keyring health || exit 1

    # Generate the RGW key
    ceph --cluster ${CLUSTER} --name client.bootstrap-rgw --keyring /var/lib/ceph/bootstrap-rgw/ceph.keyring auth get-or-create client.rgw.${RGW_NAME} osd 'allow rwx' mon 'allow rw' -o /var/lib/ceph/radosgw/${RGW_NAME}/keyring
  fi

  if [ "$RGW_REMOTE_CGI" -eq 1 ]; then
    /usr/bin/radosgw -d -c /etc/ceph/ceph.conf -n client.rgw.${RGW_NAME} -k /var/lib/ceph/radosgw/$RGW_NAME/keyring --rgw-socket-path="" --rgw-frontends="fastcgi socket_port=$RGW_REMOTE_CGI_PORT socket_host=$RGW_REMOTE_CGI_HOST"
  else
    /usr/bin/radosgw -d -c /etc/ceph/ceph.conf -n client.rgw.${RGW_NAME} -k /var/lib/ceph/radosgw/$RGW_NAME/keyring --rgw-socket-path="" --rgw-frontends="civetweb port=$RGW_CIVETWEB_PORT"
  fi


###########
# UNKNOWN #
###########

else

  echo "ERROR- Unrecognized daemon type."
  echo "Valid values for CEPH_DAEMON are MON, OSD, OSD_EXPERIMENTAL, MDS, RGW"
  exit 1
fi
