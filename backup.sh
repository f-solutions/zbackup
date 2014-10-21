#!/bin/bash
if [ $# != 3 ]; then
	echo "usage: $0 <target_hostname> <remote_ds> <local_ds_name>"
	exit 1
fi
MYPATH=`dirname $0`
TARGET=$1
REMOTE_DS=$2
LOCAL_DS_NAME=$3

. ${MYPATH}/config.vars

zfs list ${ROOT_DATASET}/${TARGET} 2>/dev/null >/dev/null || zfs create -o atime=off ${ROOT_DATASET}/${TARGET}
SNAPSHOTS=`zfs list -r -d1 -t snapshot -s creation -o name -H ${ROOT_DATASET}/${TARGET}/${LOCAL_DS_NAME} 2>/dev/null`
RES=$?
FULL_SYNC=0
LOCAL_RECENT_SNAP=""

ZBK="[${TARGET}/${LOCAL_DS_NAME}]"

if [ ${RES} != 0 ]; then
	echo "${ZBK} dataset ${ROOT_DATASET}/${TARGET} does not exist, will be created upon snapshot sync"
	FULL_SYNC=1
else
	LOCAL_RECENT_SNAP=`echo $SNAPSHOTS | head -n1 | awk -F@ '{print $NF}'`
fi

REMOTE_SNAPSHOTS=`ssh -i ${SSH_IDENTITY} -c arcfour ${TARGET} zfs list -r -d1 -t snapshot -s creation -o name -H ${REMOTE_DS} 2>/dev/null`
RES=$?
if [ ${RES} != 0 ]; then
	echo "${ZBK} remote dataset (${REMOTE_DS}) does not exist or is inaccessible"
	exit 2
fi

if [ "${REMOTE_SNAPSHOTS}" = "" ]; then
	echo "${ZBK} remote dataset does not have any snapshots, aborting"
	exit 3
fi

REMOTE_RECENT_SNAP=`echo $REMOTE_SNAPSHOTS | head -n1 | awk -F@ '{print $NF}'`


if [ ${FULL_SYNC} = 1 ]; then
	# hold remote snap
	echo "${ZBK} hold remote @${REMOTE_RECENT_SNAP}"
	ssh -i ${SSH_IDENTITY} -c arcfour ${TARGET} zfs hold zbackup ${REMOTE_DS}@${REMOTE_RECENT_SNAP}

	# xfer initial sync
	echo "${ZBK} full sync -> ${REMOTE_RECENT_SNAP}"
	ssh -i ${SSH_IDENTITY} -c arcfour ${TARGET} zfs send -p ${REMOTE_DS}@${REMOTE_RECENT_SNAP} | zfs recv -u ${ROOT_DATASET}/${TARGET}/${LOCAL_DS_NAME}

	# hold local snap
	echo "${ZBK} hold local @${REMOTE_RECENT_SNAP}"
	zfs hold zbackup ${ROOT_DATASET}/${TARGET}/${LOCAL_DS_NAME}@${REMOTE_RECENT_SNAP}
else
	if [ "${LOCAL_RECENT_SNAP}" = "${REMOTE_RECENT_SNAP}" ]; then
		echo "${ZBK} up to date @${LOCAL_RECENT_SNAP}"
		exit 0
	fi
	# hold remote snap
	echo "${ZBK} hold remote @${REMOTE_RECENT_SNAP}"
	ssh -i ${SSH_IDENTITY} -c arcfour ${TARGET} zfs hold zbackup ${REMOTE_DS}@${REMOTE_RECENT_SNAP}

	# xfer incremental
	echo "${ZBK} incremental sync ${LOCAL_RECENT_SNAP} -> ${REMOTE_RECENT_SNAP}"
	ssh -i ${SSH_IDENTITY} -c arcfour ${TARGET} zfs send -pI @${LOCAL_RECENT_SNAP} ${REMOTE_DS}@${REMOTE_RECENT_SNAP} | zfs recv -u ${ROOT_DATASET}/${TARGET}/${LOCAL_DS_NAME}
	RES=$?
	if [ ${RES} != 0 ]; then
		echo "${ZBK} incremental transfer failed"
		exit 4
	fi
	echo "${ZBK} hold local @${REMOTE_RECENT_SNAP}"
	zfs hold zbackup ${ROOT_DATASET}/${TARGET}/${LOCAL_DS_NAME}@${REMOTE_RECENT_SNAP}
	echo "${ZBK} release local @${LOCAL_RECENT_SNAP}"
	zfs release zbackup ${ROOT_DATASET}/${TARGET}/${LOCAL_DS_NAME}@${LOCAL_RECENT_SNAP}
	echo "${ZBK} release remote @${LOCAL_RECENT_SNAP}"
	ssh -i ${SSH_IDENTITY} -c arcfour ${TARGET} zfs release zbackup ${REMOTE_DS}@${LOCAL_RECENT_SNAP}
fi
