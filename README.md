=====
Kelda
=====

**Scripts to maintain a local copy of a set of external repositories, and then present a controlled test- and production-environment from timebased snapshots.**

The main hierarchy is controlled by a simple yaml-file, one set of options for each
external source. These sources might be of varying types, like YUM and GIT repositories,
simple file copying, controlled command execution etc. etc.

The main script is 'repo.pl', this handles most of the logic. There is also an addional
wrapper script (written in Bash) which is supposed to be used as an administration and
cron frontend. The latter handles initializing and seeding, snapshoting and calling the
main script with default arguments.

Which snapshot is presented to the "test" and "production" (prod) environment is configured by
separate and simple setup files, which mainly just lists the snapshot to present.

How "test" and "prod" is accessed is left to the user, but it seems natural to set up a web server
serving these directories to the consumer.

``kelda: old norse for "source" (norwegian: "kilde")``


Main script: repo.pl
====================

A Perl-script which handles the main parts of the setup. The supported commands are:

how
  short usage description

sync
  seeds or updates the local main repository hierarchy based on given configuration 
  (default: "*repofile*")

test
  set up links in the test directory pointing to snapshots as configured 
  (default in "*repofile.test*")

prod
  set up links in the prod directory pointing to snapshots as configured
  (default in "*repofile.prod*")


sync
----

Default configuration file: *repofile*

This command syncronizes a set of local repos directly under the configured root directory from sources specified.
The methods for retrieval of these sources are specified in the configuration, the arguments and/or options varies
according to the method beeing used. They are described below.

- required argument:

    - **reporoot** *This is the top level directory under which all the repositories are stored*

Method expansion
''''''''''''''''

To expand the universe of methods for retrieving the sources, just add a subroutine to the script named exactly the same as the
name of the type which will be used in the configuration ("repofile"). Nothing else has to be altered in the script for this
new method to be available! The routine will be called with two arguments:

1. **id**: *the name of the repo and uniq identifier in the yaml file*
#. *a hash with all options provided for this section, no filtering*

Current methods supported
'''''''''''''''''''''''''

- GIT
    - type: *git*
    - required arguments:
        - **uri**

- YUM
    - type: *yum*
    - required arguments:
        **repoid**
    - optional arguments:
        **repofile** (default: *repo.conf.d/yum.conf.d/yum.conf*)

- FILE
    - type: *file*
    - required arguments:
        **uri**
    - optional arguments:
        **checksum**: *If not provided the file is ALLWAYS fetched, otherwise the checksum is first verified if file exists locally*

- RSYNC
    - type: *rsync*
    - required arguments:
        **uri**

- COMMAND
    - type: *exec*
    - required arguments:
        **exec**: *Command to be executed verbatim. It is assumed the script is never runned as a web service etc!*


test
----

*Default configruation files*


:Repository file:
  repofile.test

:Generic file:
  config

This command set up the test area. A directory is created as specified (if not already existing) and symbolic links is put in place as specified in
the configuration file. All links already in place are removed before the new ones are created! This way old links not listed in the configuration
any more is unpresented from the consumer.

- required arguments:
    **rootdir**: This is the directory under which the "top level" directory is created. If no directory named 'test' exists here, it is created. Beneath this there will be a link for every line specified in the configuration file.

- optional arguments:
    *For each repository which should be publized one line relative to the 'snapshot'-directory. That is; use the form "*<YYYY-MM-DD/[repo]>*".
    If the source directory does not exist the link will _not_ be created.*

prod
----

*Default configruation files*


:Repository files:
  repofile.prod
  repofile.test

:Generic file:
  config

.. NOTE::
   Test configuration is required!

This command behaves like the test command, but creates a subdirectory under the specified "rootdir" named 'prod'. An additional requirement for publication
of the production links, as opposed to the test procedure, is that every line in the configuration must also exist in the test configuration. The rationale
beeing that any source presented to the production environment must have been through testing. Removal of a reference to the relevant snapshot of a repository from
the test configuration will lead to the removal of any corresponding link in the production environment!


Perl modules
------------

The script require a number of modules, some of which might not be installed on the OS by default. Among these are:

- YAML::Tiny
- Getopt::Long::Descriptive
- Readonly
- Test::YAML::Valid

The latter is only for DEBUG mode.


Administration wrapper: repoadmin.sh
====================================

This Bash script is a convience wrapper around the main Perl script. It is ment for cron jobs or manual administration of routine tasks. The script has routines
for initializing the system and calling the main script with default values for all normal procedures.

Commands
--------

This commands are supported by the script:

init
  initialize directory structure and initial retrieval of source

clone
  clone main repo, keep backup of altered files

snapshot
  create time stamped backups (hardlinked) of clone

setup_test
  manipulate directory links in test repository

setup_prod
  manipulate directory links in production repository


The script assumes the top level directory is the same for all parts of the system, that is: the main repo hierarchy, the snapshots and the test- and production environment.


Installation procedure
======================

The recommended procedure for setting up the repository system:

1. Decide on the file area where all source and copies are to be stored. The size must be several times the sum of all external sources.
#. Write a *repofile* to configure the repository system, defining all external sources
#. Alter the *rootdir* definitions in the two scripts to reflect the storage area set up in 1)
#. Initialize and seed the repositories: **repoadmin.sh init**
#. Check that *repo*, *clone*, *snapshot*, *test* and *repo* directories exists, that the two first mentioned are full copies of each other and have all the expected sources and 
   that the *snapshot* directory contains a timestamped copy.
#. Set up the test configuration by creating a *repofile.test* (see example file for syntax) pointing to the snapshot repos
#. Set up the initial test environment: **repoadmin.sh setup_test**
#. The *test* directory should now contain symbolic links for each repo in the configuration
#. Set up the production configuration by creating a *repofile.prod* (see example file for syntax) pointing to the snapshot repos (remember the same lines must exist in the test configuration!)
#. Set up the initial production environment: **repoadmin.sh setup_prod**
#. The *prod* directory should now contain symbolic links for each repo in the configuration

After this one might run **repoadmin.sh snapshot** to create a new snapshot to get some more alternatives to experiment with. This will not consume much storage space as it will hardlink to previous snapshot. If there is a need to start from scratch just recursively delete the top level directory.

When everything is configured and tested, set up for instance cron jobs to run the *sync* and/or *snapshot* commands regurarly.

Lastly set up something to serve the test and prod areas, commonly this would be via a web service, which should be a simple task. But that is beyond this project and left for the user.

