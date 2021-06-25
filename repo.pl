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
use Cwd;
use Cwd 'abs_path';
use Test::YAML::Valid;
use YAML::Tiny;
use Getopt::Long::Descriptive;
use File::Basename;
use File::Temp qw(tempfile tempdir);
use File::Path qw(rmtree);
use Digest::MD5 qw(md5_hex);
use Data::Dumper;

Readonly my $FALSE => 0;
Readonly my $TRUE  => 1;

my $DEBUG        = $FALSE;
my $DEVDEBUG     = $FALSE;                      # development debug: set this to $TRUE to just write what should otherwise be done
my $CONFIGDIR    = "/etc/kelda/conf";           # default top level system-wide configuration directory
my $REPODIR      = "repo";
my $SNAPSHOTSDIR = "snapshots";
my $DIST         = '';                          # used if test/prod should be set up with distribution specific subdirectories
my $POSTCMD_DIR  = '/root/postcmd';             # location of post commands/scripts
my $rootdir;                                    # top level local repository directory
my $command;                                    # command for script
my $opt;                                        # for argument and options handling
my $usage;

# Main configuration matrix
my %modeconfig = (  'prod'  =>  {
                                    'name'      => 'production',
                                    'config'    => "prod.config",
                                    'dir'       => 'prod'
                                },
                    'test'  =>  {
                                    'name'      => 'testing',
                                    'config'    => "test.config",
                                    'dir'       => 'test',
                                },
                 );

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
( $opt, $usage ) = describe_options(
    'repo %o [command]',
    [ 'configdir|c=s',    "Configuration directory (if not provided expected locally)" ],
    [ 'testrepofile|t=s', "Repoconfiguration for local test repository" ],
    [ 'prodrepofile|p=s', "Repoconfiguration for local production repository" ],
    [ 'dist|D=s',         "distribution (used for dist specific subdirectories)" ],
    [ 'help|h',           "Usage help" ],
    [ 'debug|d',          "Debug mode (print more information)" ],
);

if($opt->debug)  {
    $DEBUG = $TRUE;
}

if($DEBUG)  {
    print "repo.pl invoked like this:\n";
    print "$0 @ARGV\n";
}

if($opt->help)  {
    usage();
    exit 0;
}

if( $opt->configdir    )  { $CONFIGDIR  = $opt->configdir . "/"; }

my $CONFIG       = "$CONFIGDIR/config";                     # generic configuration
my $REPOCONFIG   = "$CONFIGDIR/repo.config";                # default main repo configuration file name

$modeconfig{"test"}{"config"} = ( $opt->testrepofile ? $opt->testrepofile : $CONFIGDIR . $modeconfig{"test"}{"config"} );
$modeconfig{"prod"}{"config"} = ( $opt->prodrepofile ? $opt->prodrepofile : $CONFIGDIR . $modeconfig{"prod"}{"config"} );
if ( $opt->dist )  { $DIST = $opt->dist; }

# delegate work according to command
$command = $ARGV[0] ? $ARGV[0] : "sync";                    # let 'sync' be the default command
given( $command )  {
    when( 'sync' )  { shift; sync(@ARGV); }
    when( 'test' )  { test('test'); }
    when( 'prod' )  { prod(); }
    default         { print "\nUnknown command!\n"; usage(); }
};


# command: sync -- updates/initializes all repositories listed in 'repofile'
sub sync  {
    my @ids = defined $_[0] ? @_ : () ;                     # specific repo(s) to fetch or all?
    my $repoyaml;                                           # content of main repo configuration file ('repofile')
    my $cfgyaml;                                            # generic configuration
    my $postcmd;
    my $dist_support;                                       # distribution sub directories or not

    # read configuration ("profile")
    if($DEVDEBUG)  {
        yaml_file_ok("$REPOCONFIG", "$REPOCONFIG is a valid YAML file\n");
    }

    $repoyaml = YAML::Tiny->read( "$REPOCONFIG" );
    $cfgyaml  = YAML::Tiny->read( "$CONFIG" );

    # Ensure existence of root repositiory directory
    $rootdir = abs_path( $cfgyaml->[0]{'repodir'} );
    reporoot("$rootdir/$REPODIR");

    $dist_support = ( $cfgyaml->[0]{'dist_support'} ? $cfgyaml->[0]{'dist_support'} : 'true' );

    # For each id:
    #   - ensure repo subdirectory exists
    #   - call relevant handler
    #
    if( ! ( @ids ) )  { @ids = keys %{ $repoyaml->[0] }; }  # if no ids provided use all from configuration
    for my $id ( @ids )  {
        my $type = $repoyaml->[0]{$id}{'type'};             # for simplification of code
        my ( $dist, $repocreated, $reponame );

        if($type)  {                                        # sanity check: all repo handlers must have type defined
            # if distribution specific support enabled find current dist, otherwise set empty
            # to get the 'repo' sync'ed to reporoot
            if("$dist_support" eq "true")  {
                $dist = defined $repoyaml->[0]{$id}{'dist'} ? $repoyaml->[0]{$id}{'dist'} : 'generic';
            } else  { $dist = ''; }

            # if 'name' provided use that, otherwise use 'repoid' if that exists, otherwise use 'id' (always exists)
            $reponame = defined $repoyaml->[0]{$id}{'repoid'} ? $repoyaml->[0]{$id}{'repoid'} : $id;
            $reponame = defined $repoyaml->[0]{$id}{'name'} ? $repoyaml->[0]{$id}{'name'} : $reponame;
            $repocreated = reporoot( "$rootdir/$REPODIR/$dist/$reponame" );
            if(defined &{$type})  {                         # check if appropriate handler routine is defined
                $postcmd = $repoyaml->[0]{$id}{'postcmd'};  # post command to execute after sync is finished
                $type->( "$rootdir/$REPODIR/$dist", $id, $repoyaml->[0]{$id}, $reponame );
                # run post command if any defined
                if($postcmd)  {
                    # for safety reasons we only accept scripts or commands located into a predetermined location,
                    # which should be somewhere in root home directory
                    $postcmd = basename($postcmd);          # get filename of command/script
                    if ( -x "$POSTCMD_DIR/$postcmd" )  {    # make sure we only look into our pre defined directory
                                                            # and that it is marked executable
                        system("$POSTCMD_DIR/$postcmd");
                    } else  { info("postcmd does not exist, is not accessible or is not set executable : $POSTCMD_DIR/$postcmd\n"); }
                }
            } else  {
                error("Handler for type --> $type <-- does not exist. Skipping...");
            }
        } else  {
            error("No type specified for --> $id <-- - do not know which handler to call...");
        }
    }
    return 0;
}


# command: test -- update pointers for test repository
sub test  {
    my $mode = $_[0];
    my %oldrepo;
    my @repoconfig;
    my $cfgyaml;
    my @links;
    my ( $rootdir, $testdir, $snapshotdir );

    if( ! -e $modeconfig{"$mode"}{'config'} )  {
        error( "$modeconfig{\"$mode\"}{'name'} command but no appropriate configuration available." );
        error( "Expected config: $modeconfig{\"$mode\"}{'config'}" );
        usage();
        croak "Quitting!";
    }
    info( "Updating $modeconfig{\"$mode\"}{'name'}...\n" );
    @repoconfig = readlines( $modeconfig{"$mode"}{'config'} );
    $cfgyaml = YAML::Tiny->read( "$CONFIG" );

    # Ensure existence of root repositiory directory
	$rootdir = $cfgyaml->[0]{'repodir'};
    if( ! $rootdir )  {
        error( "No root (top level) directory specified in configuration ($CONFIG)!\n" );
        croak "Cannot continue, quitting.";
    }
    $testdir = "$rootdir/$modeconfig{\"$mode\"}{'dir'}";
    $snapshotdir = "$rootdir/$SNAPSHOTSDIR";
    reporoot( "$testdir" );
    if ( ! -d "$testdir/$DIST" )  {
        mkdir "$testdir/$DIST";
    } else  {
        clean_symlinks( "$testdir/$DIST" );
    }

    @links = sort { $b cmp $a } @repoconfig;
    foreach my $link ( @links )  {
        chomp $link;
        if( $link =~ /^\s*rootdir:/x )  { next; }           # skip rootdir config line
        my ( $source, $repo ) = split( /\//x, $link );
        chomp $repo if $repo;
        if( $repo and $source and ( ! $oldrepo{"$repo"} ) )  {
            if($DEVDEBUG)  {
                info( "Linking $testdir/$DIST/$repo from $snapshotdir/$source/$DIST/$repo" );
            } else  {
                if( -d "$snapshotdir/$source/$DIST/$repo" )  {
                    symlink "$snapshotdir/$source/$DIST/$repo", "$testdir/$DIST/$repo" || error("Could not make link for repo $repo");
                } else  {
                    error(" Source directory for $repo does not exist ($snapshotdir/$source/$DIST/$repo) - skipping");
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
    my ( $rootdir, $proddir, $snapshotdir );

    if( ! -e $modeconfig{'test'}{'config'} )  {
        error( "'prod' command but no test configuration available!" );
        error( "Maybe provide one as an argument?" );
        usage();
        croak "Quitting!";
    }
    if( ! -e $modeconfig{'prod'}{'config'} )  {
        error( "'prod' command but no production configuration available!" );
        error( "Maybe provide one as an argument?" );
        usage();
        croak "Quitting!";
    }
    info( "Updating prod...\n" );
    @prodconfig = readlines( $modeconfig{'prod'}{'config'}  );
    @testconfig = readlines( $modeconfig{'test'}{'config'}  );
    $cfgyaml    = YAML::Tiny->read( "$CONFIG" );

    # Ensure existence of root repositiory directory
	$rootdir = $cfgyaml->[0]{'repodir'};
    if( ! $rootdir )  {
        error( "No root (top level) directory specified in configuration ($CONFIG)!\n" );
        croak "Cannot continue, quitting.";
    }
    $proddir = "$rootdir/$modeconfig{'prod'}{'dir'}";
    $snapshotdir = "$rootdir/$SNAPSHOTSDIR";
    reporoot( "$proddir" );
    if ( ! -d "$proddir/$DIST" )  {
        mkdir "$proddir/$DIST";
    } else  {
        clean_symlinks( "$proddir/$DIST" );
    }

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
                error( "$link is not allowed (not listed in test configuration: $modeconfig{'test'}{'config'})" );
                next;
            }
            if( $DEVDEBUG )  {
                info( "Linking $proddir/$DIST/$repo from $snapshotdir/$source/$DIST/$repo" );
            } else  {
                if( -d "$snapshotdir/$source/$DIST/$repo" )  {
                    symlink "$snapshotdir/$source/$DIST/$repo", "$proddir/$DIST/$repo" || error( "Could not make link for repo $repo" );
                } else  {
                    error( "Source directory for $repo does not exist ($snapshotdir/$source/$DIST/$repo) - skipping" );
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
# - the name of the local repository
#
# The local directory has the name "$rootdir/<4th argument>" and can be assumed already exists.
#

# Mirroring YUM repositories
sub yum {
    my ($rootdir, $id, $repoinfo, $reponame) = @_;
    my $reposdir = $repoinfo->{'reposdir'};
    my $repoid   = $repoinfo->{'repoid'};
    my $gpgkey   = $repoinfo->{'gpgkey'};
    my $dist     = ( $repoinfo->{'dist'} ? $repoinfo->{'dist'} : "generic" );
    my $groupcmd = '';
    my ( $fh, $yumtmp, @yumconf, $yumcachetmp );
    my $ret;

    my $yumconftmpl = << 'TMPL_END';
[main]
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

    $reposdir = ( $reposdir ? "$CONFIGDIR/$reposdir" : "$CONFIGDIR/$dist/yum.repos.d" );

    if( $repoid )  {
        # generate yum configuration
        ($fh, $yumtmp) = tempfile( "yumXXXX", SUFFIX => '.conf', DIR => '/tmp' );
        @yumconf = $yumconftmpl =~ s/\[%REPOSDIR%\]/$reposdir/r;
        print( $fh @yumconf);
        close $fh;

        chdir( "$rootdir/$reponame" );
        $yumcachetmp = tempdir( "yumcacheXXXX" );
        if($DEBUG)  {
            info( "Syncing YUM repository using $yumtmp as 'yum.conf' and $reposdir as repofiledirectory (id: $id)..." );
            $ret = run_systemcmd( 'reposync', "-e $yumcachetmp", "-dc $yumtmp", '--norepopath', '--download-metadata', '--downloadcomps', "-r $repoid", "-p $rootdir/$reponame" );
        } else  {
            $ret = run_systemcmd( 'reposync', "-e $yumcachetmp", "-qdc $yumtmp", '--norepopath', '--download-metadata', '--downloadcomps', "-r $repoid", "-p $rootdir/$reponame" );
        }
        rmtree( $yumcachetmp, { safe => 1 }, );
        if( $ret == 0 )  {
            # test if any group definition file is present
            $groupcmd = "-g $rootdir/$reponame/comps.xml" if -e "$rootdir/$reponame/comps.xml";
            if($DEBUG)  {
                info("Running createrepo_c -v(q) $groupcmd $rootdir/$reponame/" );
                run_systemcmd( 'createrepo_c', '-v', $groupcmd, " $rootdir/$reponame/" );
            } else  {
                run_systemcmd( 'createrepo_c', '-q', $groupcmd, " $rootdir/$reponame/" );
            }
            if( $ret == 0 and $gpgkey )  {
                my $cwd = cwd();
                chdir("$rootdir/$reponame");
                my @gpgkeys = split '<', $gpgkey;
                foreach (@gpgkeys)  {
                    if( $DEBUG )  {
                        info("Retrieving gpg key from $_ using curl");
                        run_systemcmd('curl', "$_", "-vO");
                    } else  {
                        run_systemcmd('curl', "$_", "-sO");
                    }
                    info ("Importing gpg key $_ using 'rpm --import'") if ( $DEBUG );
                    run_systemcmd('rpm', '--import', "$_");
                    chdir($cwd);
                }
            }
        } else  {
            error( "Something happened during reposync, error#: $ret" );
        }
        unlink $yumtmp if ( ! $DEBUG );
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
    my $name    = $_[3];
    my $new     = is_folder_empty( "$rootdir/$name" );
    my $cmd;

    info("Getting GIT repository (id: $id) from $uri...") if( $DEBUG );
    if($new)  {
        chdir("$rootdir");
        run_systemcmd('git', "clone", "$uri", "$name");
    } else  {
        chdir("$rootdir/$name");
        run_systemcmd('git', 'pull');
    }
    return 0;
}


# File retrieval (with optional checksum'ing)
# Supports anonymous FTP

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
    my $name    = $_[3];
    my $filename;

    if($uri)  {
        ($filename) = fileparse($uri);
        chdir("$rootdir/$name");
        info("Getting file $uri (id: $id)...") if($DEBUG);
        if( md5sum( $filename, $chksum ) )  {                   # checksum provided -> verify if file already in place
            info("No file with provided name and checksum exists, or no checksum provided -> fetching file...") if( $DEBUG );
#            run_systemcmd('wget', "-q", "-O $rootdir/$id/$filename", "$uri");
            run_systemcmd('/usr/bin/ncftpget', '-TVR', "$uri", ">/dev/null", "2>&1");
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
    my $name    = $_[3];

    if($uri)  {
        info("Syncronizing from $uri (id: $id)...") if( $DEBUG );
        chdir( "$rootdir/$name" );
        run_systemcmd('rsync', '-aq', '--delete', "$uri", "$rootdir/$name");
    } else  {
        info("No URI given as rsync source, skipping!\n");
    }
    return 0;
}


# Retrieve data by running provided executable
# For now we assume this script is only run manually and thus everything it is
# tasked to do the "user" is also permitted to do him/herself
sub execute {
    my ($rootdir, $id, $cmd, $name) = @_;
    $cmd = $cmd->{'exec'};

    if( $cmd )  {
        info("Executing command $cmd (id: $id)...") if( $DEBUG );
        chdir( "$rootdir/$name" );
        run_systemcmd( "$cmd");
    } else  {
        info( "No command provided for id=$id, skipping...");
    }
    return 0;
}

