# Repo
#
# Scripts to maintain a local copy of a set of external repositories, and then present a controlled test- and production-environment from timebased snapshots.

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



## Main script: 'repo.pl'

A Perl-script which handles the main parts of the setup. The supported commands are:

- help: short usage description
- sync: seeds or updates the local main repository hierarchy based on given configuration (default: "repo.conf.d/repofile")
- test: set up links in the test directory pointing to snapshots as configured (default in "repo.conf.d/repofile.test")
- prod: set up links in the prod directory pointing to snapshots as configured (default in "repo.conf.d/repofile.prod")

### sync

Default configuration file: *repo.conf.d/repofile*

This command syncronizes a set of local repos directly under the configured root directory from sources specified.
The methods for retrieval of these sources are specified in the configuration, the arguments and/or options varies
according to the method beeing used. They are described below.

- required argument:

    - **reporoot** *This is the top level directory under which all the repositories are stored*

#### Method expansion

To expand the universe of methods for retrieving the sources, just add a subroutine to the script named exactly the same as the
name of the type which will be used in the configuration ("repofile"). Nothing else has to be altered in the script for this
new method to be available! The routine will be called with two arguments:

1. the 'id' (the name of the repo and uniq identifier in the yaml file)
2. a hash with all options provided for this section, no filtering

#### Current methods supported

- GIT
    - type: *git*
    - required arguments:
        - uri

- YUM
    - type: *yum*
    - required arguments:
        - **repoid**
    - optional arguments:
        - **repofile** (default: *repo.conf.d/yum.conf.d/yum.conf*)

- FILE
    - type: *file*
    - required arguments:
        - uri
    - optional arguments:
        - checksum: *If not provided the file is ALLWAYS fetched, otherwise the checksum is first verified if file exists locally*

- RSYNC
    - type: *rsync*
    - required arguments:
        - uri

- COMMAND
    - type: *exec*
    - required arguments:
        - exec: *Command to be executed verbatim. It is assumed the script is never runned as a web service etc!*


### test

Default configuration file: *repo.conf.d/repofile.test*

This command set up the test area. A directory is created as specified (if not already existing) and symbolic links is put in place as specified in
the configuration file. All links already in place are removed before the new ones are created! This way old links not listed in the configuration
any more is unpresented from the consumer.

- required arguments:
    - rootdir: *This is the directory under which the "top level" directory is created. If no directory named 'test' exists here, it is created. Beneath this 
               there will be a link for every line specified in the configuration file.*

- otional arguments:
    *For each repository which should be publized one line relative to the 'snapshot'-directory. That is; use the form "<YYYY-MM-DD/[repo]>".
    If the source directory does not exist the link will _not_ be created.*

### prod

Default configuration file: *repo.conf.d/repofile.prod*

Additionally the test configuration is required (se above).

This command behaves like the test command, but creates a subdirectory under the specified "rootdir" named 'prod'. An additional requirement for publication
of the production links, as opposed to the test procedure, is that every line in the configuration must also exist in the test configuration. The rationale
beeing that any source presented to the production environment must have been through testing. Removal of a reference to the relevant snapshot of a repository from
the test configuration will lead to the removal of any corresponding link in the production environment!



## Administration wrapper: 'repoadmin.sh'

---> FIXME <---
