#!/bin/bash

# Maintenance script for administration of the data repositories
#
# Functionality:
#
# - initializing hierarchy
# - clone main local source repository (with backup of older versions)
# - time based snapshot of clone
# - manipulation of test repository links
# - manipulation of production repository links

shopt -s extglob

# default system wide configuration lays beneath this
CONFDIR=/etc/kelda


# Exit codes
ENORMAL=0
ENODIR=1
EINVALCMD=2
ENOCONFIG=3
EUNKNOWN=6

usage()
{
    cat << EOF

$0 - Administrating Norcams Openstack local repository

Usage:

  $0 -h|[-e <environment>] <command> [...]

    -e : environment under $CONFDIR to use if no local configuration

  Commands:

    init        : initialize directory structure and initial retrieval of source
    clone       : clone main repo, keep backup of altered files
    snapshot    : create time stamped backups (hardlinked) of clone
    setup_test  : manipulate directory links in test repository
    setup_prod  : manipulate directory links in production repository

   NB: either an environment (under $CONFDIR) must be provided using the '-e' flag or there
       must exist local configuration ('config' and if necessary repofiles) in the current directory!

EOF

}



#
# Main part
#
# default location for configuration if no environment provided
environment=$PWD

while getopts ":he" opt; do
    case $opt in

        e)
            shift
            environment=$CONFDIR/$1
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


# Fill repositories according to configuration ('repofile')
sync()
{
    configdir=$1

    ./repo.pl -c $configdir sync
}

# create directory structures if missing
# populate main repository from external sources
initrepo()
{
    configdir=$1

    if( [ ! -d $ROOT ] ); then mkdir -p $ROOT || ( echo "Could not create top level directory, quitting"; exit $ENODIR; ) fi
    if( [ ! -d $REPODIR ] ); then mkdir $REPODIR || ( echo "Could not create main source directory, quitting"; exit $ENODIR; ) fi
    if( [ ! -d $CLONEDIR ] ); then mkdir $CLONEDIR || ( echo "Could not create clone directory, quitting"; exit $ENODIR; ) fi
    if( [ ! -d $SNAPSHOTSDIR ] ); then mkdir $SNAPSHOTSDIR || ( echo "Could not create snapshot directory, quitting"; exit $ENODIR; ) fi
    if( [ ! -d $TESTDIR ] ) ; then mkdir $TESTDIR || ( echo "Could not create test directory, quitting"; exit $ENODIR; ) fi
    if( [ ! -d $PRODDIR ] ); then mkdir $PRODDIR || ( echo "Could not create prod directory, quitting"; exit $ENODIR; ) fi

    # call external script to populate main local repository (using default repofile)
    sync $configdir
    # clone the repo to have a source with unaltering files
    clone
    # create initial backup (later snapshots refer to this)
    snapshot_init
}

# create an independent clone of the main repository
# This is to keep old versions of files which might change in the external source
# (file content in repo might change -> hard linked snapshot changes,
#  rsync'ed clone will create a new file -> hard linked snapshot does not change (link is broken instead)
clone()
{
#    rsync -Ha --links --backup --backup-dir=$CLONEDIR/revisions $REPODIR/ $CLONEDIR
    rsync -Ha --links $REPODIR/ $CLONEDIR
}

# Create the initial backup which the other snapshots are linked to
snapshot_init()
{
    datedir=`date +%Y-%m-%d-%H%M`
    rsync -a $CLONEDIR/ $SNAPSHOTSDIR/$datedir
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
    clone
    datedir=`date +%Y-%m-%d-%H%M`
    rsync -a --link-dest=$SNAPSHOTSDIR/current $CLONEDIR/ $SNAPSHOTSDIR/$datedir
    rm $SNAPSHOTSDIR/current
    ln -s $SNAPSHOTSDIR/$datedir $SNAPSHOTSDIR/current
}

# Set up test repository according to configuration ('repofile.test)
# Delegate to external repo script')
setup_test()
{
    configdir=$1
    ./repo.pl -c $configdir test
}

# Set up prod repository according to configuration ('repofile.prod)
# Delegate to external repo script')
setup_prod()
{
    configdir=$1
    ./repo.pl -c $configdir prod
}


#
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
ROOT=${rootdir#*( )repodir:*( )}
if [ -z "$ROOT" ]; then
    echo "Root repo directory not configured, please define \"repodir: <...>\" in 'config' file"'!'
    echo
    usage
    exit $ENOCONFIG
fi

REPODIR=$ROOT/repo
CLONEDIR=$ROOT/clone
SNAPSHOTSDIR=$ROOT/snapshots
TESTDIR=$ROOT/test
PRODDIR=$ROOT/prod

case $command in

    "init")
        initrepo $environment
        exit $ENORMAL
        ;;

    "sync")
        sync $environment
        exit $ENORMAL
        ;;

    "clone")
        clone
        exit $ENORMAL
        ;;

    "snapshot")
        snapshot
        exit $ENORMAL
        ;;

    "setup_test")
        setup_test $environment
        exit $ENORMAL
        ;;

    "setup_prod")
        setup_prod $environment
        exit $ENORMAL
        ;;

    *)
        echo "Unknown command!"
        usage
        exit $EINVALCMD
        ;;

esac
