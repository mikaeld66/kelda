#!/usr/bin/perl
#
# Required packages for RedHat/Centos in additon to standard Perl setup :
#
# perl-Test-YAML-Valid (perl-YAML and perl-Yaml-Syck)
# perl-YAML-Tiny
# perl-Getopt-Long-Descriptive (bunch of dependencies)

use 5.010;                                      # to get 'given-when' functionality
use warnings;
use Carp;
use strict;
no strict 'refs';                               # to make indirect references to subroutines

use Readonly;                                   # for the "constants"
use Cwd 'abs_path';
use Test::YAML::Valid;
use YAML::Tiny;
use Getopt::Long::Descriptive;
use File::Basename;
use File::Temp qw(tempfile);
use Digest::MD5 qw(md5_hex);

Readonly my $FALSE => 0;
Readonly my $TRUE  => 1;

my $DEBUG        = $FALSE;
my $DEVDEBUG     = $FALSE;                      # development debug: set this to $TRUE to just write what should otherwise be done
my $CONFIGDIR    = "/etc/kelda";                # default top level system-wide configuration directory
my $REPODIR      = "repo";
my $SNAPSHOTSDIR = "snapshots";
my $TESTDIR      = "test";
my $PRODDIR      = "prod";
my $rootdir;                                    # top level local repository directory
my $command;                                    # command for script
my $opt;                                        # for argument and options handling
my $usage;


#
# Utility sub routines
#

# print informational messages
sub info  {
    my ($msg) = @_;

    print "INFO: $msg\n";
    return 0;
}

# print error mesasages
sub error  {
    my ($msg) = @_;

    print "ERROR: $msg\n";
    return 0;
}

# executes commands on the system proper
sub run_systemcmd  {
    my (@cmd) = @_;
    my $ret   = 0;
    my $cmdstring;

    # build command
    foreach ( @cmd )  {
        $cmdstring .= "$_ ";
    }
    if($DEVDEBUG)  {
        print "system($cmdstring)\n";
    } else  {
        $ret = system($cmdstring);
    }
    return $ret;
}


# tests for an empty directory
#
# Returns no of file entries excluding '.' and '..'.
# Returns -1 if not a directory
sub is_folder_empty {
    my $dirname = shift;
    my $dh;
    if( $DEBUG )  {
        info( "Will check $dirname for emptiness..." );
    }
    if( opendir($dh, $dirname) )  {
        return scalar( grep { $_ ne '.' && $_ ne '..' } readdir( $dh ) ) == 0;
    }
    info( "$dirname: Not a directory" ) if( $DEBUG );
    return -1;
}


# read all lines in a file into an array
# optionally filter against a provided regexp
sub readlines  {
    my ($file, $filter) = @_;
    my $fh;
    my @array;

    if( ! open( $fh, '<', $file ) )  {
        error( "Could not open file $file!");
        return 1;
    }
    @array = <$fh>;
    close $fh;
    # filter line with just comments
    @array = grep { ! /^\s*#/ } @array;
    # if a filter is provided then run thorugh that
    if( $filter )  {
        @array = grep { /$filter/ } @array;
    }
    return @array;
}


# clean repository by removing all symbolic links
# Non symlinks are preserved, this way exceptional (non-repo) data might be publicized
sub clean_symlinks  {
    my ($dir) = @_;
    my @files;

    if( ! -d $dir )  {
        info( "$dir is not a directory, skip cleanup!");
        if( ! -e $dir ) { return 0; }                       # does not exist: no error
        return 1;                                           # exists but no directory -> something is wrong
    }
    @files = glob "$dir/*";
    foreach my $file ( @files )  {
        if ( -l "$file" ) {
            if( $DEVDEBUG )  {
                info( "Would unlink $file" );
            } else  {
                unlink "$file" or info( "Failed to remove the symbolic link $file" );
            }
        }
    }
    return 0;
}


# Ensure the repository directory is in place
sub reporoot  {
    my ($root)  = @_;
    my $created = $FALSE;

    if( ! -d $root )  {
#        if( ! run_systemcmd( "mkdir -p $root" ) )  {        # not using Perl 'mkdir' since it can not create '-p' style and also fails if dir already exists
        if( run_systemcmd( "mkdir -p $root" ) )  {          # not using Perl 'mkdir' since it can not create '-p' style and also fails if dir already exists
            croak "Can not create top level directory '$root', aborting\n";
        }
        $created = $TRUE;
    }
    return $created;
}


sub usage  {
    print "\n";
    print "Usage:\n\n";
    print $usage->text,"\n";
    print "Commands:\n\n";
    print "'sync' [repoid ...]:  Update local repositories from external sources (default if no command given)\n";
    print "                      The optional arguments 'repoid' refers to one or more ids in the configuration to fetch.\n";
    print "                      If none provided all external sources are retrieved.\n";
    print "'test'             :  Set up test repository (testrepofile required)\n";
    print "'prod'             :  Set up prod repository (test- _and_ prod-repofiles required)\n";
    print "\n";
    return 0;
}


#
# Main section starts here
#
if($DEBUG)  {
    print "repo.pl invoked like this:\n";
    print "$0 @ARGV\n";
}

( $opt, $usage ) = describe_options(
    'repo %o [command]',
    [ 'configdir|c=s',    "Configuration directory (if not provided expected locally)" ],
    [ 'testrepofile|t=s', "Repoconfiguration for local test repository" ],
    [ 'prodrepofile|p=s', "Repoconfiguration for local production repository" ],
    [ 'help|h',           "Usage help" ],
    [ 'debug|d',          "Debug mode (print more information)" ],
);

if($opt->help)  {
    usage();
    exit 0;
}

if($opt->debug)  {
    $DEBUG = $TRUE;
}

if( $opt->configdir    )  { $CONFIGDIR  = $opt->configdir; }

# we set these here in case the caller provided an alternative location
my $CONFIG       = "$CONFIGDIR/config";                     # generic configuration
my $REPOCONFIG   = "$CONFIGDIR/repo.config";                # default main repo configuration file name
my $TESTCONFIG   = "$CONFIGDIR/test.config";                # default test repo configuration
my $PRODCONFIG   = "$CONFIGDIR/prod.config";                # default prod repo configuration

if( $opt->testrepofile )  { $TESTCONFIG = $opt->testrepofile; }
if( $opt->prodrepofile )  { $PRODCONFIG = $opt->prodrepofile; }

# delegate work according to command
$command = $ARGV[0] ? $ARGV[0] : "sync";                    # let 'sync' be the default command
given( $command )  {
    when( 'sync' )  { shift; sync(@ARGV); }
    when( 'test' )  { test(); }
    when( 'prod' )  { prod(); }
    default         { print "\nUnknown command!\n"; usage(); }
};


# command: sync -- updates/initializes all repositories listed in 'repofile'
sub sync  {
    my @ids = defined $_[0] ? @_ : () ;                     # specific repo(s) to fetch or all?
    my $repoyaml;                                           # content of main repo configuration file ('repofile')
    my $cfgyaml;                                            # generic configuration

    # read configuration ("profile")
    if($DEVDEBUG)  {
        yaml_file_ok("$REPOCONFIG", "$REPOCONFIG is a valid YAML file\n");
    }

    $repoyaml = YAML::Tiny->read( "$REPOCONFIG" );
    $cfgyaml  = YAML::Tiny->read( "$CONFIG" );

    # Ensure existence of root repositiory directory
    $rootdir = abs_path( $cfgyaml->[0]{'repodir'} );
    reporoot("$rootdir/$REPODIR");

    # For each id:
    #   - ensure repo subdirectory exists
    #   - call relevant handler
    #
    if( ! ( @ids ) )  { @ids = keys %{ $repoyaml->[0] }; }  # if no ids provided use all from configuration
    for my $id ( @ids )  {
        my $type = $repoyaml->[0]{$id}{'type'};             # for simplification of code

        if($type)  {                                        # sanity check: all repo handlers must have type defined
            my $repocreated = reporoot( "$rootdir/$REPODIR/$id" );
            if(defined &{$type})  {                         # check if appropriate handler routine is defined
                $type->( "$rootdir/$REPODIR", $id, $repoyaml->[0]{$id} );
            } else  {
                error("Handler for type --> $type <-- does not exist. Skipping...");
            }
        }
    }
    return 0;
}


# command: test -- update pointers for test repository
sub test  {
    my %oldrepo;
    my @repoconfig;
    my $cfgyaml;
    my @links;
    my $rootdir;

    if( ! -e $TESTCONFIG )  {
        error( "'test' command but no test configuration available." );
        usage();
        croak "Quitting!";
    }
    info( "Updating test...\n" );
    @repoconfig = readlines( $TESTCONFIG );
    $cfgyaml = YAML::Tiny->read( "$CONFIG" );

    # Ensure existence of root repositiory directory
	$rootdir = $cfgyaml->[0]{'repodir'};
    if( ! $rootdir )  {
        error( "No root (top level) directory specified in configuration ($CONFIG)!\n" );
        croak "Cannot continue, quitting.";
    }
    reporoot( "$rootdir/$TESTDIR" );
    clean_symlinks( "$rootdir/$TESTDIR" );

    @links = sort { $b cmp $a } @repoconfig;
    foreach my $link ( @links )  {
        chomp $link;
        if( $link =~ /^\s*rootdir:/x )  { next; }           # skip rootdir config line
        my ( $source, $repo ) = split( /\//x, $link );
        chomp $repo if $repo;
        if( $repo and $source and ( ! $oldrepo{"$repo"} ) )  {
            if($DEVDEBUG)  {
                info( "Linking $rootdir/$TESTDIR/$repo from $rootdir/$SNAPSHOTSDIR/$source/$repo" );
            } else  {
                if( -d "$rootdir/$SNAPSHOTSDIR/$source/$repo" )  {
                    symlink "$rootdir/$SNAPSHOTSDIR/$source/$repo", "$rootdir/$TESTDIR/$repo" || error("Could not make link for repo $repo");
                } else  {
                    error(" Source directory for $repo does not exist ($rootdir/$SNAPSHOTSDIR/$source/$repo) - skipping");
                }
            }
            $oldrepo{"$repo"} = $TRUE;
        }
    }
    return 0;
}


# command: prod -- update pointers for production repository
# a requirement for production links is that the link is in the test config
# (assumed meaning the link has been tested)
sub prod  {
    my @prodconfig;                                         # test repo config
    my @testconfig;                                         # prod repo config
    my $cfgyaml;                                            # generic configuration
    my %oldrepo;
    my @links;
    my $rootdir;

    if( ! -e $TESTCONFIG )  {
        error( "'prod' command but no test configuration available!" );
        error( "Maybe provide one as an argument?" );
        usage();
        croak "Quitting!";
    }
    if( ! -e $PRODCONFIG )  {
        error( "'prod' command but no production configuration available!" );
        error( "Maybe provide one as an argument?" );
        usage();
        croak "Quitting!";
    }
    info( "Updating prod...\n" );
    @prodconfig = readlines( $PRODCONFIG );
    @testconfig = readlines( $TESTCONFIG );
    $cfgyaml    = YAML::Tiny->read( "$CONFIG" );

    # Ensure existence of root repositiory directory
	$rootdir = $cfgyaml->[0]{'repodir'};
    if( ! $rootdir )  {
        error( "No root (top level) directory specified in configuration ($CONFIG)!\n" );
        croak "Cannot continue, quitting.";
    }
    reporoot( "$rootdir/$PRODDIR" );
    clean_symlinks( "$rootdir/$PRODDIR" );


    @links = sort { $b cmp $a } @prodconfig;
    foreach my $link ( @links )  {
        chomp $link;
        if( $link =~ /^\s*rootdir:/x )  { next; }             # skip rootdir config line
        my ( $source, $repo ) = split( /\//x, $link );
        chomp $repo if $repo;
        if( $repo and $source and ( ! $oldrepo{"$repo"} ) )  {
            # don't allow links not also specified in test repo configuration
            if( ( ! grep { /$link/x } @testconfig) )  {
#my $a = any { /$link/x } ("a", "b");
#            if( none { /$link/x } @testconfig )  {
                error( "$link is not allowed (not listed in test configuration: $TESTCONFIG)" );
                next;
            }
            if( $DEVDEBUG )  {
                info( "Linking $rootdir/$PRODDIR/$repo from $rootdir/$SNAPSHOTSDIR/$source/$repo" );
            } else  {
                if( -d "$rootdir/$SNAPSHOTSDIR/$source/$repo" )  {
                    symlink "$rootdir/$SNAPSHOTSDIR/$source/$repo", "$rootdir/$PRODDIR/$repo" || error( "Could not make link for repo $repo" );
                } else  {
                    error( "Source directory for $repo does not exist ($rootdir/$SNAPSHOTSDIR/$source/$repo) - skipping" );
                }
            }
            $oldrepo{"$repo"} = $TRUE;
        }
    }
    return 0;
}


#
# Retrieval handlers
#
# There is one subroutine (handler) for each type in the configuratin yaml-file ('repofile').
# The routines must have the exact same name as the 'type' set in this file.
#
# Arguments provided:
# - the repo directory (where to the external sources should be retrieved)
#   (this directory can be assumed exists and be in absolute form)
# - the 'id' (name of local repository as named in the repofile)
# - a hash of all values provided in the file for the named repository
#
# The local directory has the name "$rootdir/<id>" (where $rootdir is global) and
# can be assumed already exists.
#

# Mirroring YUM repositories
sub yum {
    my ($rootdir, $id, $repoinfo) = @_;
    my $reposdir = $repoinfo->{'reposdir'};
    my $repoid   = $repoinfo->{'repoid'};
    my ( $fh, $yumtmp, @yumconf );

    my $yumconftmpl = << 'TMPL_END';
[main]
cachedir=/var/cache/yum/$basearch/$releasever
keepcache=0
debuglevel=0
logfile=/var/log/yum.log
exactarch=1
obsoletes=1
gpgcheck=0
plugins=1
installonly_limit=3
reposdir=[%REPOSDIR%]
TMPL_END

    if( ! $reposdir )  { $reposdir = "$CONFIGDIR/yum.repos.d"; }

    if( $repoid )  {
        # generate yum configurstion
        ($fh, $yumtmp) = tempfile( "yumXXXX", SUFFIX => '.conf', DIR => '/tmp' );
        @yumconf = $yumconftmpl =~ s/\[%REPOSDIR%\]/$reposdir/r;
        print( $fh @yumconf);
        close $fh;

        info( "Syncing YUM repository using $yumtmp as 'yum.conf' and $reposdir as repofiledirectory (id: $id)..." ) if( $DEBUG );
        chdir( "$rootdir/$id" );
        my $ret = run_systemcmd( 'reposync', "-qdc $yumtmp", '--delete', '--norepopath', '--download-metadata', '--downloadcomps', "-r $repoid", "-p $rootdir/$id" );
        if( $ret == 0 )  {
            run_systemcmd( 'createrepo', '-v', '--deltas', '--update', " $rootdir/$id/" );
        } else  {
            error( "Something happened during reposync, error#: $ret" );
        }
        unlink $yumtmp;
    } else  {
        error( "'repoid' must be specified! Skipping..." );
    }
    return 0;
}


# Mirroring Git repositories
sub git {
    my $rootdir = $_[0];
    my $id      = $_[1];
    my $uri     = $_[2]->{'uri'};
    my $new     = is_folder_empty( "$rootdir/$id" );
    my $cmd;

    info("Getting GIT repository (id: $id) from $uri...") if( $DEBUG );
    if($new)  {
        chdir("$rootdir");
        run_systemcmd('git', "clone", "$uri", "$id");
    } else  {
        chdir("$rootdir/$id");
        run_systemcmd('git', 'pull');
    }
    return 0;
}


# File retrieval (with optional checksum'ing)
# Supports HTTP, HTTPS and FTP

# Helper routine for checksum'ing
sub md5sum {
    my ($filename, $chksum) = @_;
    my $FILE;
    my $realchksum;

    if( ! -e $filename ) { return 1; }                      # file does not exist, skip
    if( ! $chksum )      { return 1; }                      # no checksum provided, skip
    if(! open( $FILE, '<', $filename ) )  {
        info( "Checksum provided and file exists, but can not open file. Skipping..." );
        return 1;
    }
    binmode( $FILE );
    $realchksum = Digest::MD5->new->addfile( $FILE )->hexdigest;
    close( $FILE );
    if( $DEBUG )  {
        print "Checksum provided: $chksum\n";
        print "Real checksum:     $realchksum\n";
    }
    if( $chksum eq $realchksum )  {
        return 0;
    } else  {
        return 1;
    }
}

sub file {
    my $rootdir = $_[0];
    my $id      = $_[1];
    my $uri     = $_[2]->{'uri'};
    my $chksum  = $_[2]->{'checksum'};
    my $filename;

    if($uri)  {
        ($filename) = fileparse($uri);
        chdir("$rootdir/$id");
        info("Getting file $uri (id: $id)...") if($DEBUG);
        if( md5sum( $filename, $chksum ) )  {                   # checksum provided -> verify if file already in place
            info("No file with provided name and checksum exists, or no checksum provided -> fetching file...") if( $DEBUG );
            run_systemcmd('wget', "-q", "-O $rootdir/$id/$filename", "$uri");
            if( ! md5sum($filename, $chksum ) )  {
                info("Retrieved file did not match provided checksum!");
            }
        }
    } else  {
        info( "No 'uri' provided for id=$id, skippping...");
    }
    return 0;
}


# Rsync based copying
sub rsync {
    my $rootdir = $_[0];
    my $id      = $_[1];
    my $uri     = $_[2]->{'uri'};

    if($uri)  {
        info("Syncronizing from $uri (id: $id)...") if( $DEBUG );
        chdir( "$rootdir/$id" );
        run_systemcmd('rsync', '-aq', "$uri", "$rootdir/$id");
    } else  {
        info("No URI given as rsync source, skipping!\n");
    }
    return 0;
}


# Retrieve data by running provided executable
# For now we assume this script is only run manually and thus everything it is
# tasked to do the "user" is also permitted to do him/herself
sub execute {
    my ($rootdir, $id, $cmd) = @_;
    $cmd = $cmd->{'exec'};

    if( $cmd )  {
        info("Executing command $cmd (id: $id)...") if( $DEBUG );
        chdir( "$rootdir/$id" );
        run_systemcmd( "$cmd");
    } else  {
        info( "No command provided for id=$id, skipping...");
    }
    return 0;
}

