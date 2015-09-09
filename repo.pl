#!/usr/bin/perl

use 5.010;                                      # to get 'given-when' functionality
use warnings;
use Carp;
use strict;
no strict 'refs';

use Readonly;                                   # for the "constants"
use Test::YAML::Valid;
use YAML::Tiny;
use Getopt::Long::Descriptive;
use File::Basename;
use Digest::MD5 qw(md5_hex);

Readonly my $FALSE => 0;
Readonly my $TRUE  => 1;

my $DEBUG        = $FALSE;
my $CONFIGDIR    = "/opt/scm/git/norcams/mikaeld66-repo/repo.conf.d";   # default configuration directory
my $CONFIG       = "$CONFIGDIR/repofile";                               # default main configuration file name
my $TESTCONFIG   = "$CONFIGDIR/repofile.test";                          # default test repo configuration
my $PRODCONFIG   = "$CONFIGDIR/repofile.prod";                          # default prod repo configuration
my $YUMCONFIG    = "$CONFIGDIR/yum.conf.d/yum.conf";                    # default yum configuration for external repositories
my $SNAPSHOTSDIR = "snapshots";
my $TESTDIR      = "test";
my $PRODDIR      = "prod";
my $yaml;                                       # content of main configuration file ('repofile')
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
    my $ret;
    my $cmdstring;

    # build command
    foreach ( @cmd )  {
        $cmdstring .= "$_ ";
    }
    if($DEBUG)  {
        $ret = print "system($cmdstring)\n";
    } else  {
        $ret = system($cmdstring);
    }
    return $ret;
}


# tests for an empty directory
sub is_folder_empty {
    my $dirname = shift;
    opendir(my $dh, $dirname) or croak "Not a directory";
    return scalar( grep { $_ ne '.' && $_ ne '..' } readdir( $dh ) ) == 0;
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
# Non symlinks are preserved, this way exceptionally data might be publized
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
            if( $DEBUG )  {
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
        if( ! mkdir( $root ) )  {
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
    [ 'repofile|r=s',     "Main repofile (external sources etc)" ],
    [ 'testrepofile|t=s', "Repoconfiguration for local test repository" ],
    [ 'prodrepofile|p=s', "Repoconfiguration for local production repository" ],
    [ 'yumconf|y=s',      "Yum configuration (external repositories)" ],
    [ 'help|h',           "Usage help" ],
);

if($opt->help)  {
    usage();
    exit 0;
}
if( $opt->repofile     )  { $CONFIG     = $opt->repofile; }
if( $opt->testrepofile )  { $TESTCONFIG = $opt->testrepofile; }
if( $opt->prodrepofile )  { $PRODCONFIG = $opt->prodrepofile; }
if( $opt->yumconf      )  { $YUMCONFIG  = $opt->yumconf; }

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

	# read configuration ("profile")
	if($DEBUG)  {
	    yaml_file_ok("$CONFIG", "$CONFIG is a valid YAML file\n");
	}

	$yaml = YAML::Tiny->read( "$CONFIG" );

	# Ensure existence of root repositiory directory
	$rootdir = $yaml->[0]{'reporoot'};
	reporoot($rootdir);

	# For each id:
	#   - ensure repo subdirectory exists
	#   - call relevant handler
	#
    if( ! ( @ids ) )  { @ids = keys %{ $yaml->[0] }; }      # if no ids provided use all from configuration
	for my $id ( @ids )  {
	    my $type = $yaml->[0]{$id}{'type'};                 # for simplification of code

	    if($type)  {                                        # sanity check: all repo handlers must have type defined
	        my $repocreated = reporoot("$rootdir/$id");
	        if(defined &{$type})  {                         # check if appropriate handler routine is defined
	            $type->($id, $yaml->[0]{$id});
	        } else  {
	            error("Handler for type --> $type <-- does not exist. Skipping...");
	        }
	    }
	}
    return 0;
}


# command: test -- update pointers for test repository
sub test  {
    my $testcfgfile = $TESTCONFIG;
    my %oldrepo;
    my @config;
    my @links;
    my $root;

    if( ! -e $testcfgfile )  {
        error( "'test' command but no test configuration available." );
        usage();
        croak "Quitting!";
    }
    info( "Updating test...\n" );
    @config = readlines( $testcfgfile );
    ( $root ) = grep { /^\s*rootdir:/x } @config;
    ( $root ) = $root =~ /\s*rootdir:\s*(.*)/x;
    reporoot( "$root/$TESTDIR" );
    clean_symlinks( "$root/$TESTDIR" );

    @links = sort { $b cmp $a } @config;
    foreach my $link ( @links )  {
        chomp $link;
        if( $link =~ /^\s*rootdir:/x )  { next; }           # skip rootdir config line
        my ( $source, $repo ) = split( /\//x, $link );
        chomp $repo if $repo;
        if( $repo and $source and ( ! $oldrepo{"$repo"} ) )  {
            if($DEBUG)  {
                info( "Linking $root/$TESTDIR/$repo from $root/$SNAPSHOTSDIR/$source/$repo" );
            } else  {
                if( -d "$root/$SNAPSHOTSDIR/$source/$repo" )  {
                    symlink "$root/$SNAPSHOTSDIR/$source/$repo", "$root/$TESTDIR/$repo" || error("Could not make link for repo $repo");
                } else  {
                    error(" Source directory for $repo does not exist ($root/$SNAPSHOTSDIR/$source/$repo) - skipping");
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
    my $testcfgfile = $TESTCONFIG;
    my $prodcfgfile = $PRODCONFIG;
    my @prodconfig;
    my @testconfig;
    my %oldrepo;
    my @links;
    my $root;

    if( ! -e $testcfgfile )  {
        error( "'prod' command but no test configuration available!" );
        error( "Maybe provide one as an argument?" );
        usage();
        croak "Quitting!";
    }
    if( ! -e $prodcfgfile )  {
        error( "'prod' command but no production configuration available!" );
        error( "Maybe provide one as an argument?" );
        usage();
        croak "Quitting!";
    }
    info( "Updating prod...\n" );
    @prodconfig = readlines( $prodcfgfile );
    ( $root ) = grep { /^\s*rootdir:/x } @prodconfig;
    ( $root ) = $root =~ /\s*rootdir:\s*(.*)/x;
    reporoot( "$root/$PRODDIR" );
    clean_symlinks( "$root/$PRODDIR" );

    @testconfig = readlines( $testcfgfile );

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
                error( "$link is not allowed (not listed in test configuration: $testcfgfile)" );
                next;
            }
            if( $DEBUG )  {
                info( "Linking $root/$PRODDIR/$repo from $root/$SNAPSHOTSDIR/$source/$repo" );
            } else  {
                if( -d "$root/$SNAPSHOTSDIR/$source/$repo" )  {
                    symlink "$root/$SNAPSHOTSDIR/$source/$repo", "$root/$PRODDIR/$repo" || error( "Could not make link for repo $repo" );
                } else  {
                    error( "Source directory for $repo does not exist ($root/$SNAPSHOTSDIR/$source/$repo) - skipping" );
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
# - the 'id' (name of local repository as named in the repofile)
# - a hash of all values provided in the file for the named repository
#
# The local directory has the name "$rootdir/<id>" (where $rootdir is global) and
# can be assumed already exists.
#


# Mirroring YUM repositories
sub yum {
    my ($id, $repoinfo) = @_;
    my $repofile= $repoinfo->{'repofile'};
    my $repoid  = $repoinfo->{'repoid'};

    if( ! $repofile )  { $repofile = $YUMCONFIG; }
    if( $repoid )  {
        info( "Syncing YUM repository using $repofile as repofile (id: $id)..." );
        chdir( "$rootdir/$id" );
        run_systemcmd( 'reposync', "-qdc $repofile", '--delete', '--gpgcheck', '--norepopath', "-r $repoid", "-p $rootdir/$id" );
    } else  {
        error( "'repoid' must be specified! Skipping..." );
    }
    return 0;
}


# Mirroring Git repositories
sub git {
    my $id  = $_[0];
    my $uri = $_[1]->{'uri'};
    my $dir = "$rootdir/$id";
    my $new = is_folder_empty($dir);
    my $cmd;

    info("Getting GIT repository (id: $id) from $uri...");
    if($new)  {
        chdir("$rootdir");
        run_systemcmd('git', "clone", "$uri", "$dir");
    } else  {
        chdir("$dir");
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
    if( $chksum )  { return 1; }                            # no checksum provided, skip
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
    my $id      = $_[0];
    my $uri     = $_[1]->{'uri'};
    my $chksum  = $_[1]->{'checksum'};
    my $filename;

    if($uri)  {
        ($filename) = fileparse($uri);
        chdir("$rootdir/$id");
        info("Getting file $uri (id: $id)...");
        if( md5sum( $filename, $chksum ) )  {                   # checksum provided -> verify if file already in place
            info("No file with provided name and checksum exists, or no checksum provided -> fetching file...");
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
    my $id  = $_[0];
    my $uri = $_[1]->{'uri'};

    if($uri)  {
        info("Syncronizing from $uri (id: $id)...");
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
    my ($id, $cmd) = @_;
    $cmd = $cmd->{'exec'};

    if( $cmd )  {
        info("Executing command $cmd (id: $id)...");
        chdir( "$rootdir/$id" );
        run_systemcmd( "$cmd");
    } else  {
        info( "No command provided for id=$id, skipping...");
    }
    return 0;
}
