#!/bin/bash

set -u

ERROR_TAR_FAILED=5
ERROR_PROCFS_SAVE_FAILED=6
ERROR_INVALID_ARGUMENT=10

TAR=tar
MKDIR=mkdir
RM=rm
LN=ln
GZIP=gzip
CP=cp
MV=mv
GREP=grep
TOUCH=touch
V=
ALLOW_PROCESS_STOP=
NOOP=false
DO_COMPRESS=true
CMD_PREFIX=
SINCE_DATE="@0" # default is set to January 1, 1970 at 00:00:00 GMT
REFERENCE_FILE=/tmp/reference
TECHSUPPORT_TIME_INFO=`mktemp "/tmp/techsupport_time_info.XXXXXXXXXX"`
BASE=nokia_plaform_`hostname`_`date +%Y%m%d_%H%M%S`
DUMPDIR=/var/dump
TARDIR=$DUMPDIR/$BASE
TARFILE=$DUMPDIR/$BASE.tar
LOGDIR=$DUMPDIR/$BASE/dump
PLUGINS_DIR=/usr/local/bin/debug-dump
NUM_ASICS=1
HOME=${HOME:-/root}
USER=${USER:-root}
TIMEOUT_MIN="5"
SKIP_BCMCMD=0

IS_SUP=1
NOKIA_NDK_CLI=/opt/srlinux/bin/sr_platform_ndk_cli
NOKIA_DEVMGR=devmgr
NOKIA_QFPGA_GRPC_PORT=50067

handle_signal()
{
    echo "Generate Dump received interrupt" >&2
    $RM $V -rf $TARDIR
    exit 1
}
trap 'handle_signal' SIGINT

###############################################################################
# Terminates generate_dump early just in case we have issues.
# Globals:
#  None
# Arguments:
#  retcode: 0-255 return code to exit with. default is 1
#  msg: (OPTIONAL) msg to print to standard error
# Returns:
#  None
###############################################################################
abort() {
    local exitcode=${1:-1}
    local msg=${2:-Error. Terminating early for safety.}
    echo "$msg" >&2
    exit $exitcode
}

###############################################################################
# Runs a comamnd and saves its output to the incrementally built tar.
# Command gets timedout if it runs for more than TIMEOUT_MIN minutes.
# Globals:
#  LOGDIR
#  BASE
#  MKDIR
#  TAR
#  TARFILE
#  DUMPDIR
#  V
#  RM
#  NOOP
# Arguments:
#  cmd: The command to run. Make sure that arguments with spaces have quotes
#  filename: the filename to save the output as in $BASE/dump
#  do_gzip: (OPTIONAL) true or false. Should the output be gzipped
#  save_stderr: (OPTIONAL) true or false. Should the stderr output be saved
# Returns:
#  None
###############################################################################
save_cmd() {
    local start_t=$(date +%s%3N)
    local end_t=0
    local cmd="$1"
    local filename=$2
    local filepath="${LOGDIR}/$filename"
    local do_gzip=${3:-false}
    local save_stderr=${4:-true}
    local tarpath="${BASE}/dump/$filename"
    local timeout_cmd="timeout --foreground ${TIMEOUT_MIN}m"
    local redirect="&>>"
    [ ! -d $LOGDIR ] && $MKDIR $V -p $LOGDIR

    if ! $save_stderr
    then
        redirect=">>"
    fi

    # eval required here to re-evaluate the $cmd properly at runtime
    # This is required if $cmd has quoted strings that should be bunched
    # as one argument, e.g. vtysh -c "COMMAND HERE" needs to have
    # "COMMAND HERE" bunched together as 1 arg to vtysh -c
    if $do_gzip; then
        tarpath="${tarpath}.gz"
        filepath="${filepath}.gz"
        local cmds="$cmd 2>&1 | gzip -c > '${filepath}'"
        if $NOOP; then
            echo "${timeout_cmd} bash -c \"${cmds}\""
        else
            eval "${timeout_cmd} bash -c \"${cmds}\""
            if [ $? -ne 0 ]; then
                echo "Command: $cmds timedout after ${TIMEOUT_MIN} minutes."
            fi
        fi
    else
        if $NOOP; then
            echo "${timeout_cmd} $cmd $redirect '$filepath'"
        else
            eval "${timeout_cmd} $cmd" "$redirect" "$filepath"
            if [ $? -ne 0 ]; then
                echo "Command: $cmd timedout after ${TIMEOUT_MIN} minutes."
            fi
        fi
    fi
    ($TAR $V -rhf $TARFILE -C $DUMPDIR "$tarpath" \
        || abort "${ERROR_TAR_FAILED}" "tar append operation failed. Aborting to prevent data loss.") \
        && $RM $V -rf "$filepath"
    end_t=$(date +%s%3N)
    echo "[ save_cmd:$cmd ] : $(($end_t-$start_t)) msec" >> $TECHSUPPORT_TIME_INFO
}

###############################################################################
# Runs a comamnd and saves its output to the incrementally built tar.
# Globals:
#  LOGDIR
#  BASE
#  MKDIR                                                                                       #  TAR
#  TARFILE
#  DUMPDIR
#  V
#  RM
#  NOOP
# Arguments:
#  filename: the full path of the file to save
#  base_dir: the directory in $TARDIR/ to stage the file
#  do_gzip: (OPTIONAL) true or false. Should the output be gzipped
# Returns:
#  None
###############################################################################
save_file() {
    echo $@
    local start_t=$(date +%s%3N)
    local end_t=0
    local orig_path=$1
    local supp_dir=$2
    local gz_path="$TARDIR/$supp_dir/$(basename $orig_path)"
    local tar_path="${BASE}/$supp_dir/$(basename $orig_path)"
    local do_gzip=${3:-true}
    local do_tar_append=${4:-true}
    [ ! -d "$TARDIR/$supp_dir" ] && $MKDIR $V -p "$TARDIR/$supp_dir"

    if $do_gzip; then
        gz_path="${gz_path}.gz"
        tar_path="${tar_path}.gz"
        if $NOOP; then
            echo "gzip -c $orig_path > $gz_path"
        else
            gzip -c $orig_path > $gz_path
        fi
    else
        if $NOOP; then
            echo "cp $orig_path $gz_path"
        else
            cp $orig_path $gz_path
        fi
    fi

    if $do_tar_append; then
        ($TAR $V -rhf $TARFILE -C $DUMPDIR "$tar_path" \
            || abort "${ERROR_PROCFS_SAVE_FAILED}" "tar append operation failed. Aborting to prevent data loss.") \
            && $RM $V -f "$gz_path"
    fi
    end_t=$(date +%s%3N)
    echo "[ save_file:$orig_path] : $(($end_t-$start_t)) msec"  >> $TECHSUPPORT_TIME_INFO
}

save_platform_info() {
    save_cmd "cat /host/machine.conf" "machine.conf"

    save_cmd "systemd-analyze blame" "systemd.analyze.blame"
    save_cmd "systemd-analyze dump" "systemd.analyze.dump"
    save_cmd "systemd-analyze plot" "systemd.analyze.plot.svg"

    save_cmd "lspci -vvv -xx" "lspci"
    save_cmd "lsusb -v" "lsusb"
    save_cmd "sysctl -a" "sysctl"
}

save_ndk_devicemgr_info() {
    echo "Capture ndk devicemgr info"
    # Admintech
    NDK_ADMINTECH=devmgr.admintech
    $NOKIA_NDK_CLI -c "AdminTech::Save /tmp/$NDK_ADMINTECH"
    save_file /tmp/$NDK_ADMINTECH* dump false true
}

save_ndk_qfpgamgr_info() {
    if [ $IS_SUP -eq 0 ]; then
        echo "Capture ndk qfpgamgr info"
        # Admintech
        NDK_ADMINTECH=qfpgamgr.admintech
        $NOKIA_NDK_CLI --port $NOKIA_QFPGA_GRPC_PORT -c "AdminTech::Save /tmp/$NDK_ADMINTECH"
        save_file /tmp/$NDK_ADMINTECH* dump false true
    fi
}

save_ndk_ethmgr_info() {
    if [ $IS_SUP -eq 1 ]; then
        echo "Capture ndk ethmgr info"
    fi
}

save_ndk_cores() {
    echo "Copy ndk coredump files"
    core_dir=core
    for core_file in /var/core/sr_device_mgr*.gz; do
        [ -f "$core_file" ] || continue
        save_file $core_file  $core_dir false true
    done
}

main() {
    local start_t=0
    local end_t=0
    if [ `whoami` != root ] && ! $NOOP;
    then
        echo "$0: must be run as root (or in sudo)" >&2
        exit 10
    fi
    ${CMD_PREFIX}renice +5 -p $$ >> /dev/null
    ${CMD_PREFIX}ionice -c 2 -n 5 -p $$ >> /dev/null

    $MKDIR $V -p $TARDIR
    $RM $V -f $TARDIR/sonic_dump

    # Start populating timing data
    echo $BASE > $TECHSUPPORT_TIME_INFO
    start_t=$(date +%s%3N)

    source /host/machine.conf
    if [ "${onie_platform}" == "x86_64-nokia_ixr7250_cpm-r0" ] || \
       [ "${onie_platform}" == "x86_64-nokia_ixr7250e_sup-r0" ] ; then
        IS_SUP=1
    else
        IS_SUP=0
    fi

    save_platform_info
    save_file /usr/share/sonic/device/${onie_platform}/platform_ndk.json dump false true
    save_ndk_devicemgr_info
    save_ndk_qfpgamgr_info
    save_ndk_ethmgr_info
    save_ndk_cores

    # clean up working tar dir before compressing
    $RM $V -rf $TARDIR

    if $DO_COMPRESS; then
        $GZIP $V $TARFILE
        if [ $? -eq 0 ]; then
            TARFILE="${TARFILE}.gz"
        else
            echo "WARNING: gzip operation appears to have failed." >&2
        fi
        mv ${TARFILE} /tmp/hw-mgmt-dump.tar.gz
        echo "platform specific dump is in /tmp/hw-mgmt-dump.tar.gz"
    else
        mv ${TARFILE} /tmp/hw-mgmt-dump.tar
        echo "platform specific dump is in /tmp/hw-mgmt-dump.tar"
    fi

}
main
