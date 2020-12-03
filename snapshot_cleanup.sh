#!/bin/bash

#
# This script removes all snapshots (directories) which are
# older than the oldest referenced pointer in any kelda config
# (that is /etc/kelda/prod/[test|prod].config
#
# Options:
#   -u      = usage
#   -d      = dry-run (just print what would otherwise be deleted)
#   -t <timestamp>  = remove snapshots older than this
#           Will never remove snapshots newer than the oldest
#           still in use
#      Timestamps in kelda format: YYYY-MM-DD-HHMM
#   -r <repository name> = purge this repository and all its snapshots
#


# Exit codes
readonly EXIT_TIMESTAMPTOONEW=1
readonly EXIT_USERREQUEST=2
readonly EXIT_TIMESTAMPERROR=3
readonly EXIT_INVALIDOPTION=4

BASEDIR=/var/www/html/uh-iaas
SNAPSHOTDIR=${BASEDIR}/snapshots
KELDACONFDIR=/etc/kelda/prod

# Counter
removed=0

# Simple usage text
usage()
{
    echo "Usage:"
    echo
    echo "$0 [-uhd] [ [-t <timestamp>] | [-r <repository name>] ]"
    echo
    echo "-h|-u: usage help (this text)"
    echo "   -d: dryrun - just print what would otherwise be deleted"
    echo "   -t: delete all snapshots older than timestamp provided"
    echo "       <timestamp> = YYYY-MM-DD-HHMM (kelda config format)"
    echo "   -r: remove named repository completely (incl. all snapshots taken"
    echo "       <repository name> = directory name under 'repo'"
    echo
    echo "NB: '-r' and '-t' are mutually exclusive"
    echo
    echo "If neither '-r' nor '-t' provided then purge all snapshots older than oldest still in use (prod or test)"
    echo
}

# Convert a "kelda" formatted date string to EPOCH seconds
# kelda: YYYY-MM-DD-HHMM
timestamp2seconds()
{
    local timestamp=$1

    # convert kelda timestamp to a format accepted by the `date`command (YYYY-MM-DD HH:MM)
    local datestamp="$(echo $timestamp | sed 's/\(20[0-9]\{2\}-[0-9]\{2\}-[0-9]\{2\}\)-\([0-9]\{2\}\)\([0-9]\{2\}\)/\1 \2:\3/')"
    # return EPOCH time
    date -d "$datestamp" +%s
}


#
# Main code
#

# User argument handling
# Kinda stupid ...
dryrun=''
userseconds=''
purge_repo=''
while getopts :uht:dr: option; do
    case "${option}" in
        h|u)
          usage
          exit
          ;;
        t)
          userseconds=${OPTARG}
          ;;
        r)
          purge_repo=${OPTARG}
          ;;
        d)
          dryrun='true'
          ;;
        :)
          echo "Option -$OPTARG requires an argument." >&2
          exit $EXIT_INVALIDOPTION
          ;;
        \?)
          echo "Invalid option -$OPTARG" >&2
          exit $EXIT_INVALIDOPTION
          ;;
    esac
done

# -r and -t can not be set at the same time
[ "${userseconds}x" != "x" ] && if [ "${purge_repo}y" != "y" ]; then
    echo "'-t' and '-r' are mutually exclusive!"
    echo "Please enter one of those only"
    exit $EXIT_INVALIDOPTION
fi


# if purging repo then do that now and then exit
if [ "${purge_repo}x" != "x" ]; then
    echo "Removing all traces of the $purge_repo repository ..."
    read -p "Proceed? " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Exiting due to user request" >&2
        exit $EXIT_USERREQUEST
    fi

    # Got 'go ahead'
    # 1. remove the mirror itself
    if [ -n "$dryrun" ]; then
        echo "Would run: rm -rf ${BASEDIR}/repo/${purge_repo}"
    else
        [ -d "${BASEDIR}/repo/${purge_repo}" ] && rm -rf ${BASEDIR}/repo/${purge_repo}
    fi
    # 2. find and remove all snapshots of it
    if [ -n "$dryrun" ]; then
        find ${SNAPSHOTDIR} -maxdepth 2 -type d -name ${purge_repo} -exec echo "Would run: rm -rf {}" \;
    else
        find ${SNAPSHOTDIR} -maxdepth 2 -type d -name ${purge_repo} -exec rm -rf {} \;
    fi
    # Finished; exit so we don't attempt snapshot cleaning as well
    exit
fi

# otherwise the order of the day is purging of old snapshots

# If any user provided timestamp convert it to EPOCH seconds
if [[ -n $userseconds ]]; then
    userseconds=$(timestamp2seconds $userseconds)
    if [ $? -ne 0 ]; then
        echo "Wrong timestamp format; please use 'YYYY-MM-DD-HHMM'" >&2
        echo
        exit $EXIT_TIMESTAMPERROR
    fi
fi

# Find oldest snapshot still in use
prodseconds=$(sort ${KELDACONFDIR}/prod.config | head -1 | cut -d/ -f1)
prodseconds=$(timestamp2seconds $prodseconds)
testseconds=$(sort ${KELDACONFDIR}/test.config | head -1 | cut -d/ -f1)
testseconds=$(timestamp2seconds $testseconds)

oldestseconds="$(( prodseconds <= testseconds ? prodseconds : testseconds ))"

# If any date provided by caller -> verify as old (or older) than oldest
# snapshot still in use
if [[ -n $userseconds ]]; then
    if [ $userseconds -gt $oldestseconds ]; then
        echo "ERROR: data stamp provided newer than oldest snapshot still in use!" >&2
        echo "Exiting" >&2
        echo
        exit $EXIT_TIMESTAMPTOONEW
    else
        oldestseconds=$userseconds
    fi
fi

# Get a listing of all snapshot directories ( = timestamps) and delete
# all which are older than $oldestseconds

echo "Now purging all snapshots older than $(date -d @$oldestseconds) ..."
read -p "Proceed? " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Exiting due to user request" >&2
    exit $EXIT_USERREQUEST
fi

# Got 'Go Ahead', proceed ...
cd $SNAPSHOTDIR
for dir in *; do

    # filter any non timestamped snapshots
    if [[ ! $dir =~ ^20[0-9][0-9]* ]]; then
        break;
    fi

    # convert dir to EPOCH seconds for comparison
        dirseconds=$(timestamp2seconds $dir)

    # if older then remove
    if [ $dirseconds -lt $oldestseconds ]; then
        let removed++
        if [ -n "$dryrun" ]; then
            echo "Would run: rm -rf ${SNAPSHOTDIR}/$dir"
        else
            echo "Removing ${SNAPSHOTDIR}/$dir"
            rm -rf ${SNAPSHOTDIR}/$dir
        fi
    fi
done

if [ $removed -eq 0 ]; then
    echo "No snapshots purged"
else
    echo "Purged $removed snapshots"
fi

