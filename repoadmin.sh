#!/bin/bash

# Maintenance script for administration of the data repositories
#
# Functionality:
#
# - initializing hierarchy
# - time based snapshot of local repositories
# - manipulation of test repository links
# - manipulation of production repository links

shopt -s extglob

# get location of script
BASEDIR=$(dirname $0)

# default system wide configuration lays beneath this
CONFDIR=/etc/kelda


# Exit codes
ENORMAL=0
ENODIR=1
EINVALCMD=2
ENOCONFIG=3
EUNKNOWN=6

debug=""            # default no debug output


usage()
{
    cat << EOF

$0 - Administrating Norcams Openstack local repository

Usage:

  $0 -h|[-e <environment>][-d] <command> [...]

    -e : environment under $CONFDIR to use if no local configuration
    -d : debug output

  Commands:

    init        : initialize directory structure and initial retrieval of source
    sync        : update/freshen repositories from the external sources
    snapshot    : create time stamped backups (hardlinked) of clone
    setup_test  : manipulate directory links in test repository
    setup_prod  : manipulate directory links in production repository
    setup_vgpu  : manipulate directory links in vgpu repository

   NB: either an environment (under $CONFDIR) must be provided using the '-e' flag or there
       must exist local configuration ('config' and if necessary repofiles) in the current directory!

EOF

}



# default location for configuration if no environment provided
environment=$PWD

while getopts ":he:d" opt; do
    case $opt in

        e)
            environment=$CONFDIR/$OPTARG
            ;;
        d)
            debug="-d"
            ;;
        h)
            usage
            exit $ENORMAL
            ;;

        \?)
            echo "Unknown parameter!"
            usage
            exit $EINVALOPT
            ;;

    esac
done

shift $((OPTIND-1))
command=$1;


# Fill repositories according to configuration ('repoconfig')
sync()
{
    configdir=$1

    $BASEDIR/repo.pl $debug -c $configdir sync
}

# create directory structures if missing
# populate main repository from external sources
initrepo()
{
    configdir=$1

    if( [ ! -d $ROOT ] ); then mkdir -p $ROOT || ( echo "Could not create top level directory, quitting"; exit $ENODIR; ) fi
    if( [ ! -d $REPODIR ] ); then mkdir $REPODIR || ( echo "Could not create main source directory, quitting"; exit $ENODIR; ) fi
    if( [ ! -d $SNAPSHOTSDIR ] ); then mkdir $SNAPSHOTSDIR || ( echo "Could not create snapshot directory, quitting"; exit $ENODIR; ) fi
    if( [ ! -d $TESTDIR ] ) ; then mkdir $TESTDIR || ( echo "Could not create test directory, quitting"; exit $ENODIR; ) fi
    if( [ ! -d $PRODDIR ] ); then mkdir $PRODDIR || ( echo "Could not create prod directory, quitting"; exit $ENODIR; ) fi
    if( [ ! -d $VGPUDIR ] ); then mkdir $VGPUDIR || ( echo "Could not create vgpu directory, quitting"; exit $ENODIR; ) fi

    # call external script to populate main local repository (using default repofile)
    sync $configdir
    # create initial backup (later snapshots refer to this)
    snapshot_init
}

# Create the initial backup which the other snapshots are linked to
snapshot_init()
{
    datedir=`date +%Y-%m-%d-%H%M`
    rsync -a $REPODIR/ $SNAPSHOTSDIR/$datedir
    if [ -L $SNAPSHOTSDIR/current ]; then       # if a symlink just remove it
        rm $SNAPSHOTSDIR/current;
    elif [ -e $SNAPSHOTSDIR/current ]; then     # otherwise let it be and leave decision to user
        echo "Could not initialize the 'current' pointer"'!'
        echo "Remove obstruction and manually create a link:"
        echo "ln -s $SNAPSHOTSDIR/$datedir $SNAPSHOTSDIR/current"
        exit 1
    fi
    ln -s $SNAPSHOTSDIR/$datedir $SNAPSHOTSDIR/current
}

# Create a time based snapshot of clone
# Always fetch a clone first (no point in snapshotting if no new clone yet)
# The snapshot is stamped by naming the directory using the current time
snapshot()
{
    datedir=`date +%Y-%m-%d-%H%M`
    rsync -a --link-dest=$SNAPSHOTSDIR/current/ $REPODIR/ $SNAPSHOTSDIR/$datedir
    rm $SNAPSHOTSDIR/current
    ln -s $SNAPSHOTSDIR/$datedir $SNAPSHOTSDIR/current
}

# Set up repository according to configuration
# Delegate to external repo script
setup()
{
    mode=$1
    shift
    if [ $# -gt 0 ]; then configopt="-c $1"; fi
    $BASEDIR/repo.pl $debug $configopt $mode
}


# Main part
#

if [ ! -f "$environment/config" ]; then
    echo "No configuration found: \"$environment/config\" does not exist"'!'
    echo
    usage
    exit $ENOCONFIG
fi

# get top level directory from file
rootdir=$(grep repodir $environment/config)
ROOT=${rootdir#*(  *)repodir: *( )}
if [ -z "$ROOT" ]; then
    echo "Root repo directory not configured, please define \"repodir: <...>\" in 'config' file"'!'
    echo
    usage
    exit $ENOCONFIG
fi

REPODIR=$ROOT/repo
SNAPSHOTSDIR=$ROOT/snapshots
TESTDIR=$ROOT/test
PRODDIR=$ROOT/prod
VGPUDIR=$ROOT/vgpu

case $command in

    "init")
        initrepo $environment
        exit $ENORMAL
        ;;

    "sync")
        sync $environment
        exit $ENORMAL
        ;;

    "snapshot")
        snapshot
        exit $ENORMAL
        ;;

    "setup_test")
        setup test $environment
        exit $ENORMAL
        ;;

    "setup_prod")
        setup prod $environment
        exit $ENORMAL
        ;;

    "setup_vgpu")
        setup vgpu $environment
        exit $ENORMAL
        ;;

    *)
        echo "Unknown command!"
        usage
        exit $EINVALCMD
        ;;

esac
