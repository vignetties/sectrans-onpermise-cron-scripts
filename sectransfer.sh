#!/bin/bash
export PATH=/sbin:/usr/sbin:/bin:/usr/bin:${PATH}

umask 0000
#DEBUG=1
test ${HOSTNAME:0:4} = YLPS && DEBUG=${DEBUG:-1} #force debug on workstation
test "$(basename $0)" != sectransfer.sh && DEBUG=${DEBUG:-1} #force debug when called as something else
[[ -n "$DEBUG" && $- =~ x ]] && OFD=/dev/null || OFD=/dev/stderr

LOGDIR="/var/opt/allianz/logs"
LOGF="sftp-transfer-$(date +%y%m%d).log"
test -n "$DEBUG" && LOGF="debug-$LOGF"
LOG="$LOGDIR/$LOGF"


function message
{
        #local - O=$- ; set +x #grr - funkt erst ab bash 4.3
        NOW=$(date +"%Y/%m/%d %H:%M:%S")
        LOGSTR="$NOW [$$] $@"
        [[ -t 1 && ! $O =~ x ]] && echo "$LOGSTR"
        echo "$LOGSTR" >>${LOG}
} 2>$OFD

message "########## Start Transfer Script ##########"
test -n "$DEBUG" && {
        message '#### INFO - DEBUG flag is set; reduced functionality! ####' ;
        test $DEBUG = GET && message '#### INFO - DEBUG - Disabling RSYNC dry run mode! ####' || RSYNCDEBUGFLAG="--dry-run";
}

SERVERCONF='/etc/opt/allianz/allianz.server.conf'
if [ ! -e "${SERVERCONF}" ]; then
        message "${SERVERCONF} does not exist ####"
        exit 1
else
        . ${SERVERCONF}
fi

if [[ "$STAGE" == "" ]]; then
    STAGE="${WEBSERVER_TYPE}"
fi

mand=${MANDANT%%-*} #strip after first -
mandant=${mand,,} #to lc
stage=${WEBSERVER_TYPE,,} #to lc

## DELETE Log Files sftp-transfer-*
test -z "$DEBUG" && find "$LOGDIR" -maxdepth 1 -name "*sftp-transfer-*.log" -type f -mtime +6 -delete

#uses value from SERVERCONF
#ESBDB2CLPREPROD='10.12.14.42'
#ESBDB2CLPROD='10.12.12.97'

## scriptpath for this script
SCRIPTPATH="$(dirname "$(readlink -e "$BASH_SOURCE")")" #'/opt/allianz/bin/sectransfer'

## SFTP Local Dest Dir
LOCALDIR='/var/opt/allianz/sftptransfer'
test -n "$DEBUG" && { LOCALDIR=$(dirname $LOCALDIR)/debug-$(basename $LOCALDIR) ; test -d "$LOCALDIR" || mkdir "$LOCALDIR" ; }

## define SFTP Server
case "$LOCATION" in
        AMOS-SE) #EUROPE
                case "$MANDANT" in
                        AGA-EU)
                                SECTRANSSERVER='sectrans.srv.allianz'
                                ;;
                        AGA-CH)
                                SECTRANSSERVER='azp-sftp.srv.allianz'
                                ;;
                        *)
                                SECTRANSSERVER='sectrans.srv.allianz'
                        ;;
                esac
                ;;
        ACAN) #CANADA
                if test "x$WEBSERVER_TYPE" = xPROD ; then
                        SECTRANSSERVER='adcvf-intsftp-p01.acan.local'
                else
                        SECTRANSSERVER='adcvf-intsftp-r01.acan.local'
                fi
                ;;
        AMOSA) #USA
                SECTRANSSERVER='sectrans-us.srv.allianz'
                ;;
        AP2) #AUSTRALIA
            SECTRANSSERVER='auawp0012.srv.allianz'
            ;;
        *)
                case "$HOSTNAME" in
                        LX-*) #Austria
                                SECTRANSSERVER='sectrans.srv.allianz'
                                ;;
                        *)
                                #echo "Unrecognised LOCATION '$LOCATION', cannot continue"
                                message "#### ERROR - Unrecognised LOCATION '$LOCATION', cannot continue ####"
                                exit 1
                                ;;
                esac
                ;;
esac

message "#### INFO - Using Sectransserver: $SECTRANSSERVER for LOCATION: $LOCATION ####"

SECTRANSUSER='atagaprodftp'
test -n "$SFTPUSER" && SECTRANSUSER="$SFTPUSER"
if test -f  "$SCRIPTPATH/id_$SECTRANSUSER@$SECTRANSSERVER" ; then
        PRIVATE_KEY="$SCRIPTPATH/id_$SECTRANSUSER@$SECTRANSSERVER"
elif test -f  "$SCRIPTPATH/id_$SECTRANSSERVER" ; then
        PRIVATE_KEY="$SCRIPTPATH/id_$SECTRANSSERVER"
else
        PRIVATE_KEY="$SCRIPTPATH/id_rsa_production_sectrans_muc"
fi
message "#### INFO - Use Sectransuser: $SECTRANSUSER ####"
message "#### INFO - Use PRIVATE_KEY: $PRIVATE_KEY ####"
test -z "$DEBUG" && RMSOURCE='--remove-sent-files'

## define remote and local sync directory
RDIR="/${mand}${STAGE}"
LDIR="${mand}${STAGE}"
CLUSTER=false
if [[ $STAGE = TEST* ]];
then
        CLUSTER=true
        SHARE="$SFTPSHARE" #use from serverconf
elif [ "$STAGE" = "ABNAHME" ] || [ "$STAGE" = "PREPROD" ]; then
        stage='prep'
        RDIR='/AGAPREP'
        LDIR='AGAPREP'
        SHARE="$SFTPSHARE" #use from serverconf
        CLUSTER=true
elif [ "$STAGE" = "MNTN" ]; then
    RDIR='/AGAMNTN'
        LDIR='AGAMNTN'
    SHARE="$SFTPSHARE" #use from serverconf
        CLUSTER=true
elif [ "$STAGE" = "PROD" ]; then
        SHARE="$SFTPSHARE" #use from serverconf
        CLUSTER=true
fi

declare -a EXCLUDES
mk_remote_exclude_filters() {
        EXCLUDES_FILE="/etc/opt/allianz/sectransfer/excludes.$HOSTNAME.sh"
        EXCLUDES=()
        TMP=$(ssh -v -o StrictHostKeyChecking=no -i $PRIVATE_KEY $SECTRANSUSER@$SECTRANSSERVER '/bin/bash -O extglob -O nullglob -c "echo '$1'/!('$2')"' 2>>$LOG)
        RET=$?
        if test $RET -ne 0 ; then
                message "#### Woops - ssh excludes command returned $RET"
        fi
        for i in $TMP ; do #"ls -1d /AGATESTUS/!(atagaesb*)"
                EXCLUDES+=(--exclude="$i")
        done
        #EXCLUDES=()
        if test ${#EXCLUDES[@]} -eq 0 ; then
                if test -f $EXCLUDES_FILE ; then
                        . $EXCLUDES_FILE
                fi
                message "#### Woops - no remote excludes received from remote server; using cached values (MASK=$OLD_FILTERMASK): '${EXCLUDES[@]}' ####"
                #AU (sla20181) needs excludes:
                if test ${#EXCLUDES[@]} -eq 0 ; then
                        message "#### ABORTING: no excludes defined! ####"
                        exit 99
                fi
                #barf when EXCLUDES is empty?

        else
                echo -e "OLD_FILTERMASK='$2'\nEXCLUDES=(${EXCLUDES[@]})" >/etc/opt/allianz/sectransfer/excludes.$HOSTNAME.sh
        fi

}


#RQ-0003052, RQ-0003053, RQ-0003079, RQ-0003756
FILTERMASK=''
case $MANDANT in
        AGA-US) RDIR+=US ; LDIR+=US ; FILTERMASK="usagaesb*" ;;
        AGA-EU) RDIR+=EU ; LDIR+=EU ;;
        AGA-CA) RDIR+=CA ; LDIR+=CA ;;
        AGA-CH) RDIR+=CH ; LDIR+=CH ;;
        AGA-AU) RDIR+=AU ; LDIR+=AU ; FILTERMASK="auagaesb*" ;;
        *) : ;; #FILTER="$RDIR/*/*/TRANSFER" ; echo "FILTER FIXME: $FILTER" ; exit 99 ;;
esac


if [[ ($STAGE =~ "TEST" || $STAGE =~ "TEXT" || $STAGE =~ "DEV") && $MANDANT != "AGA-CA" && $MANDANT != "AGA-GRP" && $MANDANT != "AGA-EU" ]]; then
        FILTERMASK="atagaesb*"
#       FILTER="$RDIR/atagaesb*/TRANSFER/*"
#       echo FILTER2 $FILTER ${EXCLUDES[@]};exit
fi
if test -n "$FILTERMASK" ; then
        mk_remote_exclude_filters $RDIR "$FILTERMASK"
        message "#### Remote Exclude filter (MASK=$FILTERMASK): '${EXCLUDES[@]}' ####"
else
        message "#### Remote Exclude filter is not being used ####"
fi

## check mount point availability
if [ "$CLUSTER" = "true" -a "$SHARE" != "localhost" -a -z "$DEBUG" ];
then
        if [ -z "$SHARE" ] ; then
                message "#### Clustermode activated, but cluster IP not defined ####"
                exit 1
        fi
        mountpoint="$LOCALDIR"
        if cat /proc/mounts | grep -q $mountpoint; then
                timeout 1 touch $mountpoint/test >/dev/null
                if [ $? -eq 0 ]; then
                        rm -v $mountpoint/test
                fi
                timeout 1 stat -t "$mountpoint" >/dev/null
                if [ ! $? -eq 0 ]; then
                        message "#### INFO - NFS mount stale. Removing... ####"
                        umount -f -l "$mountpoint"
                        PID_RSYNC=`pgrep -f "$(which rsync) -rucv --progress -e ssh -o StrictHostKeyChecking=no -i /opt/allianz/bin/sectransfer"`
                        if [ "$PID_RSYNC" != "" ]; then
                                kill -9 $PID_RSYNC
                        fi
                        sleep 2
                        timeout 5 mount $LOCALDIR
                        if [ ! $? -eq 0 ]; then
                                message "#### ERROR - NFS mount not working... ####"
                                exit 1
                        fi
                fi
        else
                timeout 5 mount $LOCALDIR
                if [ ! $? -eq 0 ]; then
                        message "#### ERROR - NFS mount not working... ####"
                        PID_RSYNC=`pgrep -f "$(which rsync) -rucv --progress -e ssh -o StrictHostKeyChecking=no -i /opt/allianz/bin/sectransfer"`
                        if [ "$PID_RSYNC" != "" ]; then
                                kill -9 $PID_RSYNC
                        fi
                        exit 1
                fi
        fi
else
        message "SFTPSHARE is localhost. Not mounting anything"
fi
message "#### INFO - AFTER MOUNT CHECK ####"

if rpm -q allianz-magesb-v2 &>/dev/null ; then
        message "#### INFO - SOA installation detected, no further proceeding ... ####"
        exit 0
fi

#results file zipping functionality start
ZIPDIRS=''
if [ "${MANDANT}" == 'AGA-CH' ];then
       SECTRANSFER_ZIPDIRSFILE="${SECTRANSFER_ZIPDIRSFILE:-/etc/opt/allianz/sectransfer/zipdirs.$LOCATION.$stage.$MANDANT.conf}"
fi
SECTRANSFER_ZIPDIRSFILE="${SECTRANSFER_ZIPDIRSFILE:-/etc/opt/allianz/sectransfer/zipdirs.$LOCATION.$stage.conf}"
if test -f "$SECTRANSFER_ZIPDIRSFILE" -a -s "$SECTRANSFER_ZIPDIRSFILE" -a -r "$SECTRANSFER_ZIPDIRSFILE" ; then
        message "#### INFO - reading zipdirs from $SECTRANSFER_ZIPDIRSFILE ####"
        ZIPDIRS="$(sed -re '/^#/d' <$SECTRANSFER_ZIPDIRSFILE)"
        message "#### INFO - zipdirs: $ZIPDIRS ####"
fi

if [[ -n "$ZIPDIRS" ]] ; then
        message "#### INFO - START ZIPDIR PREPROCESSING ####"
        RESTORENULLGLOB=$(shopt -p nullglob)
        shopt -s nullglob
        for ziprpath in $ZIPDIRS ; do
                #zipdir=$LOCALDIR/$LDIR/$ziprpath/result #fullpath
                zipdir=$LOCALDIR/$LDIR/$ziprpath/result #fullpath
                message "#### INFO - ZIPPING xml in $zipdir ####"
                if ! test -d "$zipdir" ; then
                        message "#### Invalid zip directory specified, skipping: $zipdir ####"
                        continue
                fi
                if ! test -d "$zipdir/archive" ; then
                        mkdir "$zipdir/archive" || exit 99
                        chown --reference="$zipdir" "$zipdir/archive"
                        chmod --reference="$zipdir" "$zipdir/archive"
                fi
                cd "$zipdir"
                while true ; do
                        tmp="$(echo "$ziprpath"|sed -re  's@^[^/]+/@@;s@/.*@@;s/^ataga(..).*/\1/')"
                        fn="${ziprpath##*/}_${tmp}_$(date +%Y%m%d%H%M%S).zip"
                        test ! -f "$fn" && break
                        sleep 1
                done
                files="$(echo *.xml)" #required nullglob
                test -z "$files" && continue #skip this zipdir if there are not files to process
                message "#### ZIPPING IN $zipdir - cmd: zip '$fn' $files ####"
                if zip "$fn" $files ; then
                        mv $files "$zipdir/archive/"
                else
                        : #zipping failed - do nothing
                fi
                cd  - >/dev/null
        done
        $RESTORENULLGLOB
        message "#### INFO - END OF ZIPDIR PREPROCESSING ####"
else
        message "#### INFO - no zipdirs configured ; skipping zipdir preprocessing ####"
fi
#end of results file zipping functionality


#if test -n "$DEBUG" ; then
#       message "#### INFO - DEBUG MODE; EXITING ####"
#       exit 22
#fi

rsync() {
        message EXEC: $FUNCNAME "$@"
        command $FUNCNAME "$@"
} 2>$OFD


message "#### INFO - sync only the Directory Structure ####"
### sync only the Directory Structure
$(which rsync) -ruv $RSYNCDEBUGFLAG --delete --chmod=Dug+rwx,o+rx,Fug+rw --progress -e "ssh -o StrictHostKeyChecking=no -i $PRIVATE_KEY" \
--log-file=${LOG} \
${EXCLUDES[@]} \
--exclude="$RDIR/TRANSFER" \
--exclude="$RDIR/BATCH" \
--exclude={bin,dev,etc,home,lib64,proc,srv,usr,var}/ \
--include=*/ \
--exclude=* \
$SECTRANSUSER@$SECTRANSSERVER:$RDIR $LOCALDIR/

#exit 0
#-f"- /*" \
## Description ###
#-f'+ */at${mandant}*${stage}*' -> include all Users with name ataga*${stage}* below the MANDANT directory
#-f'+ */TRANSFER' -> include only the TRANSFER directory per User
#-f'- *.*' -> exclude all Files with . in there name
#-f'- ${mand}/*/*' -> exclude all files and dirs beside the directory TRANSFER
#-f'- ${mand}/*' -> exclude all other user directorys
message "#### INFO - Transfer Files from SFTP to local via rsync ####"
###########################################
#### Transfer Files from SFTP to local ####
###########################################

$(which rsync) -ruv $RSYNCDEBUGFLAG $RMSOURCE --chmod=Dug+rwx,o+rx,Fug+rw,o-x --progress -e "ssh -o StrictHostKeyChecking=no -i $PRIVATE_KEY" \
--log-file=${LOG} \
${EXCLUDES[@]} \
--exclude="$RDIR/TRANSFER" \
--exclude="$RDIR/BATCH" \
--exclude={error,result,processed,storno,bin,dev,etc,home,lib64,proc,srv,usr,var}/ \
$SECTRANSUSER@$SECTRANSSERVER:$RDIR $LOCALDIR/

test -n "$DEBUG" && { message ABORTING DEBUG MODE BEFORE SENDING; exit ; }



#-f"+ $RDIR" \
## Description ###
#-f'+ */at${mandant}*${stage}*' -> include all Users with name ataga*${stage}* below the MANDANT directory
#-f'+ */TRANSFER' -> include only the TRANSFER directory per User
#-f'- */error/**' -> exclude all Files from the error directorys
#-f'- */result/**' -> exclude all Files from the result directorys
#-f'- */processed/**' -> exclude all Files from the processed directorys
#-f'- */storno/**' -> exclude all Files from the storno directorys
#-f'- *.WORK' -> exclude all *.WORK files
#-f'- ${mand}/*/*' -> exclude all files and dirs beside the directory TRANSFER
#-f'- ${mand}/*' -> exclude all other user directorys

##################################################
#### Transfer Report Files from local to SFTP ####
##################################################
message "#### INFO - Transfer Report Files from local to SFTP via rsync ####"
#rsync -rucvp --progress -e "ssh -o StrictHostKeyChecking=no -i $PRIVATE_KEY" \
#1.0.5 - 20150505 - move results files to sectrans
$(which rsync) -ruv $RSYNCDEBUGFLAG -e "ssh -o StrictHostKeyChecking=no -i $PRIVATE_KEY" \
--log-file=${LOG} \
--include=*/ \
--exclude=*.tmp \
--exclude=**/result/archive/ \
--include=**/{error,result,processed,storno}/* \
--exclude=* \
$LOCALDIR/$LDIR/ $SECTRANSUSER@$SECTRANSSERVER:$RDIR

## Description ###
#-f'+ */' \ -> include all
#-f'+ */at${mandant}*${stage}*' -> include all Users with name ataga*${stage}* below the MANDANT directory
#-f'+ */TRANSFER' -> include only the TRANSFER directory per User
#-f'+ */error/**' -> include all Files from the error directorys

#-f'+ */result/**' -> include all Files from the result directorys
#-f'+ */processed/**' -> include all Files from the processed directorys
#-f'+ */storno/**' -> include all Files from the storno directorys
#-f'- *.tmp' -> exclude all *.tmp files
#-f'- *' -> exclude all

#message "#### INFO - DELETE local Report Files ####"
# DELETE Report Files
#find /var/opt/allianz/sftptransfer/$LDIR ! -name "*.tmp" \( -path */error/* -o -path */processed/* -o -path */result/* -o -path */storno/* \) -name "*" -type f -mtime +1 -delete  >>${LOG}

message "########## END Transfer Script ##########"

if test "$LOCATION" = AMOS-SE ; then
        $SCRIPTPATH/sectransfer_old.sh
fi
