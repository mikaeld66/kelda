=====
Kelda
=====

**Scripts to maintain a local copy of a set of external repositories, and then present
a controlled test- and production-environment from timebased snapshots.**

The main hierarchy is controlled by a simple yaml-file, one set of options for each
external source. These sources might be of varying types, like YUM and GIT repositories,
simple file copying, controlled command execution etc. etc.

The main script 'repo.pl' handles most of this logic. There is also an additonal
wrapper script (written in Bash) which is supposed to be used as an administration and
cron frontend. The latter handles initializing and seeding, snapshoting and calls to the
main script with default arguments.

Which snapshot is presented to the "test" and "production" (prod) environment is configured by
separate and simple setup files, which mainly just lists the snapshot to present.

How "test" and "prod" is accessed is left to the user, but it seems natural to set up a web server
serving these directories to the consumer.

``kelda: old norse for "source" (norwegian: "kilde")``


Main script: repo.pl
====================

A Perl-script which handles the main parts of the setup. The supported commands are:

help
  short usage description

sync
  seeds or updates the local main repository hierarchy based on given configuration
  (default configuration file: "*repofile*")

test|prod
  set up links in the directory corrsponding to environment in argument, pointing to
  snapshots as configured (default configuration files: "*[test|prod].conf*")

init
  create the full environment, including necessary directories and perform the
  initial mirroring and initial snapshot

snapshot
  take an incremental snapshot (relating to previous snapshot), named after date
  and time


sync
----

This command syncronizes a set of local repos directly under the configured root directory from sources specified.
The methods for retrieval of these sources are specified in the configuration, the arguments and/or options varies
according to the method being used. They are described later in this document.

*Default configuration files*

:Repository file:
  repo.config

:Generic file:
  config

- required argument:

  **reporoot** *This is the top level directory under which all the repositories, snapshots and links are stored and created*


Method expansion
""""""""""""""""

To expand the universe of methods for retrieving the sources, just add a subroutine to the script named exactly the same as the
name of the type which will be used in the configuration (*repofile*). Nothing further has to be altered in the script for this
new method to be available. The routine will be called with two arguments:

1. **id**: *the name of the repo and uniq identifier in the yaml file*
#. *a hash with all options provided for this section, no filtering*


Current methods supported
"""""""""""""""""""""""""

All methods support the **dist** option. This decides which architecture the
repository is meant for, and thus the subdirectory to mirror under. Default is
``generic``.

Name of repository
^^^^^^^^^^^^^^^^^^

Repositories synced will be placed into a sub directory, which name is derived
from this rule set:

1. The argument **name** if this is supplied (supported by all methods)
2. If no *name* supplied use **repoid** where that is applicable.
3. Otherwise use the *key* name (*id*) from ``repo.config``


- GIT

  Checkout of a normal git repository. No facilitation for authentication is
  provided, but i.e. ssh key authentication might be configured outside of this.

    - type: *git*
    - required arguments:

      **uri**

- YUM

  Repository sync of a remote YUM repo. Metadata is produced after the sync.

    - type: *yum*
    - required arguments:

      **repoid**

    - optional arguments:

      **repofile** (default: *repo.conf.d/yum.conf.d/yum.conf*)

- FILE

  This method fetches a file using `wget`, and thus capable of retrieveing any
  file which can be fetched by a `wget` supported uri.
  Optionally an `md5sum` might be provided, which will be compared to the
  computed md5 of a previously retrieved file. If they do not match the file
  will be fetched anew, otherwise nothing is done.

    - type: *file*
    - required arguments:

      **uri**

    - optional arguments:

      **checksum**: *If not provided the file is ALLWAYS fetched, otherwise the checksum is first verified if file exists locally*

- RSYNC

  Standard `rsync`, nothing fancy.

    - type: *rsync*
    - required arguments:

      **uri**


test
----

This command set up the test area. A directory is created as specified (if not already existing) and symbolic links is put in place as specified in
the configuration file. All links already in place are removed before the new ones are created! This way old links not listed in the configuration
any more is unpresented from the consumer.


*Default configuration files*

:Repository file:
  [<dist>/]test.config

:Generic file:
  config

  Required arguments:
    **rootdir**
    This is the directory under which the "top level" directory is created. If no directory named 'test' exists here, it is created. Beneath this there will be a link for every line specified in the configuration file.

    - optional arguments:
      *For each repository which should be publized one line relative to the 'snapshot'-directory. That is; use the form "*<YYYY-MM-DD/[repo]>*".
      If the source directory does not exist the link will _not_ be created.*

prod
----

This command behaves like the test command, but creates a subdirectory under the specified "rootdir" named 'prod'. An additional requirement for publication
of the production links, as opposed to the test procedure, is that every line in the configuration must also exist in the test configuration. The rationale
being that any source presented to the production environment must have been through testing. Removal of a reference to the relevant snapshot of a repository from
the test configuration will lead to the removal of any corresponding link in the production environment!


*Default configruation files*


:Repository files:
  [<dist>/]prod.config
  [<dist>/]test.config

:Generic file:
  config

.. NOTE::
   Test configuration is required!


Perl modules
------------

The script require a number of modules, some of which might not be installed on the OS by default. Among these are:

- YAML::Tiny
- Getopt::Long::Descriptive
- Readonly
- Test::YAML::Valid

The latter is only for DEBUG mode.


Administration wrappers
=======================

repoadmin.sh
------------

This Bash script is a convenience wrapper around the main Perl script. It is ment for cron jobs or manual administration thee routine tasks. The script has routines
for initializing the system and calling the main script with default values for all normal procedures. If no `test` or `prod` configuration found in root configuration,
directory, all sub directories will be searched instead, and *repo.pl* run once
for each which contains valid configuration.

Commands
''''''''

These commands are supported by the script:

init
  initialize directory structure and initial seeding of source

snapshot
  create time stamped backups (hardlinked) of repositories

setup <environment>
  manipulate directory links in repository for <environment>

  'environment' is usually "test" or "prod"

The script assumes the top level directory is the same for all parts of the system, that is: the main repo hierarchy, the snapshots and the test- and production environment.


snapshot_cleanup.sh
-------------------

A utility script which is for purging unused snapshots and repositories. If
older snapshots are not required anymore, then they may be purged by executing
this script. Additionally it may be used to remove any traces of repositories
not used; that is both the mirror and all snapshots of it. In the latter case an
archive will be made of the last snapshot of this repository.

commands
''''''''

*/usr/local/sbin/snapshot_cleanup.sh [-uhd] [ [-t <timestamp>] | [-r <repository name>] ]*

 -t : Expunge all snapshots (of all mirrors) taken before this timestamp
      If no date provided then remove all snapshots older than oldest date used in `prod.config`

 -r : Purge named repository completely
      Removes mirror and every snapshot of this repository (only) which exists on server

 `-t` and `-r` are mutually exclusive!

  -d   : `dryrun` - just print what should otherwise be done
  -h|u : help

Installation procedure
======================

The recommended procedure for setting up the repository system:

1. Decide on the file area where all source and copies are to be stored. The size must be several times the sum of all external sources.
#. Write a *repofile* to configure the repository system, defining all external sources
#. Define *rootdir*  in the *config* file
#. Initialize and seed the repositories: **repoadmin.sh init**
#. Check that *repo*,  *snapshot*, *test* and *repo* directories exists and that the *snapshot* directory contains a timestamped copy.
#. Set up the test configuration by creating a *repofile.test* (see example file for syntax) pointing to the snapshot repos
#. Set up the initial test environment: **repoadmin.sh setup_test**
#. The *test* directory should now contain symbolic links for each repo in the configuration
#. Set up the production configuration by creating a *repofile.prod* (see example file for syntax) pointing to the snapshot repos (remember the same lines must exist in the test configuration!)
#. Set up the initial production environment: **repoadmin.sh setup_prod**
#. The *prod* directory should now contain symbolic links for each repo in the configuration

After this one might run **repoadmin.sh snapshot** to create a new snapshot to get some more alternatives to experiment with. This will not consume much storage space as it will hardlink to previous snapshot. If there is a need to start from scratch just recursively delete the top level directory.

When everything is configured and tested, set up cron jobs to run the *sync* and/or *snapshot* commands regurarly. One might also consider running the cleanup script every day/night to remove old and unused snapshots automatically.

Lastly set up something to serve the test and prod areas, typically this would be via a web service, which should be a simple task. But that is beyond this project and left for the user.

