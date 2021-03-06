# -*- cperl -*-

use strict;
use warnings;
use utf8;

use 5.008_001;
use Config;
use Getopt::Long;
use ExtUtils::MakeMaker;
use Data::Dumper;
use Devel::CheckLib;
use File::Path;
use File::Copy;
use File::Basename;
use File::Spec;
require DBI;
require DBI::DBD;

my $TESTDB = "test";

our $opt = { "help" => \&Usage, };

{
local ($::test_host, $::test_port, $::test_user, $::test_socket, $::test_password, $::test_db, $::test_force_embedded, $::test_mysql_config, $::test_cflags, $::test_libs);
eval { require "./t/MariaDB.mtest" } || eval { require "../t/MariaDB.mtest" } and do {
$opt->{'testhost'} = $::test_host;
$opt->{'testport'} = $::test_port;
$opt->{'testuser'} = $::test_user;
$opt->{'testsocket'} = $::test_socket;
$opt->{'testpassword'} = $::test_password;
$opt->{'testdb'} = $::test_db;
$opt->{'force-embedded'} = $::test_force_embedded if $::test_force_embedded;
$opt->{'mysql_config'} = $::test_mysql_config;
$opt->{'cflags'} = $::test_cflags;
$opt->{'libs'} = $::test_libs;
}
}

Getopt::Long::GetOptions(
    $opt,
    "help",
    "testdb=s",
    "testhost=s",
    "testport=s",
    "testuser=s",
    "testpassword=s",
    "testsocket=s",
    "cflags=s",
    "libs=s",
    "embedded=s",
    "mysql_config=s",
    "mariadb_config=s",
    "force-embedded",
    ) || die Usage();

$opt->{mysql_config} = delete $opt->{mariadb_config} if exists $opt->{mariadb_config};

my $source = {};

  #Check for mysql_config first
  $source->{'mysql_config'} = "guessed";

  if ($opt->{'mysql_config'}) {
    $source->{'mysql_config'} = "User's choice";
  }
  if (!$opt->{'mysql_config'} && $ENV{DBD_MARIADB_CONFIG}) {
     $opt->{'mysql_config'} = $ENV{DBD_MARIADB_CONFIG};
     $source->{'mysql_config'} = 'environment';
  }
  if ($opt->{'mysql_config'})
  {
    if ($opt->{'mysql_config'} ne 'skip') {
    $opt->{'mysql_config'} = Win32::GetShortPathName($opt->{'mysql_config'})
        if $^O eq 'MSWin32';
    if (! defined `$opt->{'mysql_config'} 2>&1`)
    {
      die <<"MSG";

Specified mysql configuration script '$opt->{'mysql_config'}' doesn't exist.
Please check path/permissions.
MSG
    }
    }
  }
  else
  {
    if (defined `mariadb_config 2>&1`)
    {
      $opt->{'mysql_config'} = "mariadb_config";
    }
    elsif (defined `mysql_config 2>&1`)
    {
      $opt->{'mysql_config'} = "mysql_config";
    }
    else
    {
      print <<MSG;

Cannot find the file 'mariadb_config' nor 'mysql_config'! Your execution PATH doesn't seem
not contain the path to mariadb_config or mysql_config. Resorting to guessed values!
MSG
    }
  }

for my $key (qw/testdb testhost testuser testpassword testsocket testport
                    cflags embedded libs
                    force-embedded/)
{
  Configure($opt, $source, $key);
}

#if we have a testport but no host, assume localhost
if ( $opt->{testport} && !$opt->{testhost} ) {
  $opt->{testhost} = 'localhost';
  $source->{testhost} = 'guessed';
}

#We have to rename/move Makefile.PL in MariaDBEmb directory
#since MakeMaker will find it and will try to execute it.
if (-f "MariaDBEmb/Makefile.PL")
{
  move ("MariaDBEmb/Makefile.PL", "MariaDBEmb/Makefile.PL.old");
}

#Disable of building of DBD::MariaDBEmb driver by default
if (!$opt->{'force-embedded'})
{
  $opt->{'embedded'} = '';
  $source->{ldflags} = 'guessed';
}

if ($opt->{'embedded'})
{
  if ($source->{'embedded'} eq 'mysql_config')
  {
    #We have to use libmygcc to resolve linking problem
    # this causes problems for cygwin
    #$opt->{'embedded'} .= " -lmygcc";
    # Under Cygwin (at least) we have to use libstdc++ to resolve linking
    # problem because libmysqld is built using g++ rather than gcc.
    $opt->{'embedded'} .= " -lstdc++";
  }

  my @files = ($^O =~ /mswin32/i) ? qw(mysqlclient.lib) :
               qw(libmysqld.a);

  my @dirs = $opt->{'embedded'} =~ /-L(.*?)(?:\s|$)/g;

  if( !(SearchFor('lib', @files)) && !(SearchFor2(\@files,\@dirs)) )
  {
     warn <<"MSG";

You intended to build DBD::MariaDBEmb driver by using option:
--embedded=$opt->{'embedded'}.
But we failed to determine directory of @files. Building of DBD::MariaDBEmb
driver was disabled.

Please use

  perl Makefile.PL --embedded="-L<dir> <flags>"

to set correct directory. For details see DBD::MariaDB::INSTALL,
section "Linker flags" or type

  perl Makefile.PL --help
MSG
     $source->{'embedded'} = "guessed";
     $opt->{'embedded'}="";
  }
}

# Separate libs and libdirs from ldflags
# When linking libdirs must be specified before libs due to runtime linking problems
my ($main_lib, @libs, @libdirs, @ldflags);
for (split ' ', ($opt->{'embedded'} ? $opt->{'embedded'} : $opt->{libs})) {
  if (not $main_lib and /^-l(.*mariadb.*|.*mysql.*)$/) {
    $main_lib = $1;
  } elsif (/^-l/) {
    push @libs, $_;
  } elsif (/^-L/) {
    push @libdirs, $_;
  } else {
    push @ldflags, $_;
  }
}
if (not $main_lib) {
  $main_lib = shift @libs;
  $main_lib =~ s/^-l//;
}

print <<"MSG";
I will use the following settings for compiling and testing:

MSG

delete $opt->{'help'};
my $keylen = 0;
for my $key (keys %$opt)
{
  $keylen = length($key) if length($key) > $keylen;
}
my $slen = 0;
for my $val (values %$source)
{
  $slen = length($val) if length($val) > $slen;
}

for my $key (sort { $a cmp $b} keys %$opt)
{
  printf("  %-" . $keylen . "s (%-" . $slen . "s) = %s\n",
	 $key, $source->{$key}, $opt->{$key})
}

print <<"MSG";

To change these settings, see 'perl Makefile.PL --help' and
'perldoc DBD::MariaDB::INSTALL'.

MSG

print "Checking if libs and header files are available for compiling...\n";

assert_lib(
  LIBS => (join ' ', @libdirs, "-l$main_lib", @libs),
  ccflags => $opt->{cflags},
  ldflags => (join ' ', @ldflags),
  header => 'mysql.h',
);

print "Checking if correct version of MariaDB or MySQL client is present...\n";

check_lib(
  lib => $main_lib,
  ccflags => $opt->{cflags},
  ldflags => (join ' ', @libdirs, @libs, @ldflags),
  header => 'mysql.h',
  function => "\n#ifndef MYSQL_VERSION_ID\n#include <mysql_version.h>\n#endif\nreturn (MYSQL_VERSION_ID >= 40103) ? 0 : 1;\n",
) or die <<"MSG";

ERROR: Wrong version or unable to check version of MariaDB/MySQL include files.
To build DBD::MariaDB it is needed MariaDB or MySQL client >= 4.1.3.

MSG

print "Looks good.\n\n";

my $fileName = File::Spec->catfile("t", "MariaDB.mtest");
(open(FILE, ">$fileName") &&
 (print FILE ("{ local " . Data::Dumper->Dump([$opt], ["opt"]) .
	      " local " . Data::Dumper->Dump([$source], ["source"]) .
	      "\$::test_host = \$opt->{'testhost'};\n" .
	      "\$::test_port = \$opt->{'testport'};\n" .
	      "\$::test_user = \$opt->{'testuser'};\n" .
              "\$::test_socket = \$opt->{'testsocket'};\n" .
	      "\$::test_password = \$opt->{'testpassword'};\n" .
	      "\$::test_db = \$opt->{'testdb'};\n" .
	      "\$::test_dsn = \"DBI:MariaDB:\$::test_db\";\n" .
	      "\$::test_dsn .= \";mariadb_socket=\$::test_socket\" if \$::test_socket;\n" .
              "\$::test_dsn .= \":\$::test_host\" if \$::test_host;\n" .
	      "\$::test_dsn .= \":\$::test_port\" if \$::test_port;\n".
	      "\$::test_force_embedded = \$opt->{'force-embedded'} if \$opt->{'force-embedded'};\n" .
	      "\$::test_mysql_config = \$opt->{'mysql_config'} if \$source->{'mysql_config'} eq 'User\\'s choice';\n" .
	      "\$::test_cflags = \$opt->{'cflags'} if \$source->{'cflags'} eq 'User\\'s choice';\n" .
	      "\$::test_libs = \$opt->{'libs'} if \$source->{'libs'} eq 'User\\'s choice';\n" .
	      "} 1;\n"))  &&
  close(FILE))  ||  die "Failed to create $fileName: $!";


my $cflags = "-I\$(DBI_INSTARCH_DIR) $opt->{'cflags'}";
if ($^O eq 'VMS') {
  $cflags = "\$(DBI_INSTARCH_DIR),$opt->{'cflags'}";
}
$cflags .= " -DHAVE_DBI_1_634" if eval { DBI->VERSION(1.634) };
$cflags .= " -g ";
my %o = ( 'NAME' => 'DBD::MariaDB',
	  'INC' => $cflags,
	  'dist'         => { 'SUFFIX'       => ".gz",
			      'DIST_DEFAULT' => 'all tardist',
			      'COMPRESS'     => "gzip -9f" },
	  'clean' => { 'FILES' => '*.xsi' },
		'realclean' => { 'FILES' => 't/MariaDB.mtest' },
          'C' => ["dbdimp.c", "MariaDB.c", "socket.c"],
          'XS' => {'MariaDB.xs' => 'MariaDB.c'},
	  'OBJECT' => '$(O_FILES)',
	  'LIBS' => (join ' ', @libdirs, "-l$main_lib", @libs),
	  @ldflags ? (dynamic_lib => { OTHERLDFLAGS => (join ' ', @ldflags) }) : (),
	  'VERSION_FROM' => 'lib/DBD/MariaDB.pm'
	);

my %embedded_files=();

if ($opt->{'embedded'})
{

 %embedded_files = ( 'MariaDB.xs' => { filename  => 'MariaDBEmb/MariaDBEmb.xs',
                                       replace   => { ':MariaDB'    => ':MariaDBEmb',
                                                      'MariaDB.xsi' => 'MariaDBEmb.xsi'},
                                       makedir => 'MariaDBEmb'
                                     },
                       'lib/DBD/MariaDB.pm' => { filename => 'MariaDBEmb/lib/DBD/MariaDBEmb.pm',
                                               replace  => { ':MariaDB'   => ':MariaDBEmb',
                                                    '=> \'MariaDB\'' => '=> \'MariaDBEmb\''},
                                               makedir => 'MariaDBEmb/lib/DBD'
                                             },
                       't/MariaDB.dbtest' => { filename => 'MariaDBEmb/t/MariaDBEmb.dbtest',
                                             makedir => 'MariaDBEmb/t'
                                           },
                       't/MariaDB.mtest' => { filename => 'MariaDBEmb/t/MariaDBEmb.mtest',
                                             makedir => 'MariaDBEmb/t',
                                             replace =>  { 'DBI:MariaDB'=> 'DBI:MariaDBEmb',
                                                            'test_db";' => 'test_db;mariadb_embedded_options=--datadir=./t,--skip-innodb";'
                                                         }
                                           },
                       't/lib.pl' => { filename => 'MariaDBEmb/t/lib.pl',
                                       replace =>  { '\$mdriver =.*' => "\$mdriver =\'MariaDBEmb\';"},
                                       makedir => 'MariaDBEmb/t'
                                    },
                       't/20createdrop.t' => { filename => 'MariaDBEmb/t/20createdrop.t',
                                               makedir => 'MariaDBEmb/t'
                                             },
                       't/30insertfetch.t' => { filename => 'MariaDBEmb/t/30insertfetch.t',
                                                makedir => 'MariaDBEmb/t'
                                              },
                       't/40bindparam.t' => { filename => 'MariaDBEmb/t/40bindparam.t',
                                              makedir => 'MariaDBEmb/t'
                                             },
                       't/40blobs.t' => { filename => 'MariaDBEmb/t/40blobs.t',
                                                                    makedir => 'MariaDBEmb/t'
                                                                  },
                       't/40listfields.t' => { filename => 'MariaDBEmb/t/40listfields.t',
                                                                    makedir => 'MariaDBEmb/t'
                                                                  },
                       't/40nulls.t' => { filename => 'MariaDBEmb/t/40nulls.t',
                                                                    makedir => 'MariaDBEmb/t'
                                                                  },
                       't/40numrows.t' => { filename => 'MariaDBEmb/t/40numrows.t',
                                                                    makedir => 'MariaDBEmb/t'
                                                                  },
                       't/50chopblanks.t' => { filename => 'MariaDBEmb/t/50chopblanks.t',
                                                                    makedir => 'MariaDBEmb/t'
                                                                  },
                       't/50commit.t' => { filename => 'MariaDBEmb/t/50commit.t',
                                                                    makedir => 'MariaDBEmb/t'
                                                                  },
                       't/60leaks.t' => { filename => 'MariaDBEmb/t/60leaks.t',
                                                                    makedir => 'MariaDBEmb/t'
                                                                  },
                       't/00base.t' => { filename => 'MariaDBEmb/t/00base.t',
                                                                    makedir => 'MariaDBEmb/t'
                                                                  },

                       'myld' => { filename => 'MariaDBEmb/myld',
                                   makedir => 'MariaDBEmb'
                                 },
                       'socket.c' => { filename => 'MariaDBEmb/socket.c',
                                   makedir => 'MariaDBEmb'
                                 },
                       'dbdimp.c' => { filename => 'MariaDBEmb/dbdimp.c',
                                   makedir => 'MariaDBEmb'
                                 },
                       'dbdimp.h' => { filename => 'MariaDBEmb/dbdimp.h',
                                   makedir => 'MariaDBEmb'
                                 },
                       'Makefile.PL.embedded' => { filename => 'MariaDBEmb/Makefile.PL',
                                   makedir => 'MariaDBEmb'
                                 },
            );


  #Create embedded files from original ones
  prepare_files(\%embedded_files);

  my %e=%o;

  $o{'clean'}->{'FILES'} .= " ./MariaDBEmb";
  $o{'DIR'}=['MariaDBEmb'];

  $e{'NAME'} = 'DBD::MariaDBEmb';
  $e{'C'} = ["dbdimp.c", "MariaDBEmb.c", "socket.c"];
  $e{'XS'} = {'MariaDBEmb.xs' => 'MariaDBEmb.c'};
  $e{'VERSION_FROM'} = 'lib/DBD/MariaDBEmb.pm';
  $e{'LIBS'} = $opt->{'embedded'};

  $e{'INC'} .= " -DDBD_MYSQL_EMBEDDED";

  print "Preparing embedded Makefile\n";

  #Create Makefile.conf for MariaDBEmb Makefile.PL
  create_makefile(Data::Dumper->Dump([\%e], ["o"]));

}

if (eval { ExtUtils::MakeMaker->VERSION(5.43) }) {
  $o{'CAPI'} = 'TRUE' if $Config::Config{'archname'} =~ /-object\b/i;
  $o{'AUTHOR'} = 'Patrick Galbraith <patg@patg.net>';
  $o{'ABSTRACT'} =
    'MariaDB and MySQL driver for the Perl5 Database Interface (DBI)';
  $o{'PREREQ_PM'} = { 'DBI' => 1.608 };
  %o=(%o,
    LICENSE => 'perl',
    MIN_PERL_VERSION => '5.008001',
    META_MERGE => {
      'meta-spec' => {
        version => 2,
      },
      dynamic_config => 0,
      resources => {
        repository  => {
          url  => 'git://github.com/gooddata/DBD-MariaDB.git',
          web  => 'https://github.com/gooddata/DBD-MariaDB',
          type => 'git',
        },
        bugtracker => {
          web  => 'https://github.com/gooddata/DBD-MariaDB/issues',
        },
        x_MailingList => 'mailto:dbi-dev@perl.org',
        license     => 'http://dev.perl.org/licenses/',
        homepage    => 'http://dbi.perl.org/',
        x_IRC       => 'irc://irc.perl.org/#dbi',
      },
      x_contributors => [
        # a list of our awesome contributors generated from git
        # using the command:
        # git shortlog -se | cut  -f2- | sed "s/^/        '/;s/$/',/"

        'Alexandr Ciornii <alexchorny@gmail.com>',
        'Alexey Molchanov <alexey.molchanov@portaone.com>',
        'Amiri Barksdale at Home <amiri@roosterpirates.com>',
        'Aran Deltac <bluefeet@gmail.com>',
        'Bernt M. Johnsen <bernt.johnsen@oracle.com>',
        'Chase Whitener <chase.whitener@infotechfl.com>',
        'Chip Salzenberg <chip@topsy.com>',
        'Chris Hammond <chrishammond@ymail.com>',
        'Chris Weyl <cweyl@alumni.drew.edu>',
        'Christian Walde <walde.christian@googlemail.com>',
        'Dagfinn Ilmari Mannsåker <ilmari@ilmari.org>',
        'Daisuke Murase <typester@cpan.org>',
        'Damyan Ivanov <dmn@debian.org>',
        'Daniël van Eeden <daniel.vaneeden@booking.com>',
        'Dave Lambley <davel@isosceles.(none)>',
        'David Farrell <davidnmfarrell@gmail.com>',
        'David Steinbrunner <dsteinbrunner@pobox.com>',
        'Giovanni Bechis <giovanni@bigio.snb.it>',
        'Graham Ollis <plicease@cpan.org>',
        'H.Merijn Brand - Tux <h.m.brand@xs4all.nl>',
        'Hanno <hanno@gentoo.org>',
        'James McCoy <jamessan@jamessan.com>',
        'Jim Winstead <jimw@trainedmonkey.com>',
        'Juergen Weigert <jw@suse.com>',
        'Kenny Gryp <kenny.gryp@percona.com>',
        'Lu Shengliang <lushl9301@gmail.com>',
        'Masahiro Chiba <chiba@everqueue.com>',
        'Matthew Horsfall (alh) <WolfSage@gmail.com>',
        'Michiel Beijen <michiel.beijen@gmail.com>',
        'Mike Pomraning <mjp@pilcrow.madison.wi.us>',
        'Pali <pali@cpan.org>',
        'Patrick Galbraith <patg@patg.net>',
        'Perlover <perlover@perlover.com>',
        'Petr Písař <ppisar@redhat.com>',
        'Reini Urban <rurban@cpanel.net>',
        'Rob Hoelz <rhoelz@inoc.com>',
        'Rob Van Dam <rvandam00@gmail.com>',
        'Rudy Lippan <rlippan@remotelinux.com>',
        'Scimon <simon.proctor@gmail.com>',
        'Sergey Zhuravlev <zhurs@ya.ru>',
        'Sergiy Borodych <Sergiy.Borodych@gmail.com>',
        'Sharif Nassar <mrwacky42+github@gmail.com>',
        'Steffen Mueller <smueller@cpan.org>',
        'Steven Hartland <steven.hartland@multiplay.co.uk>',
        'Taro Kobayashi <9re.3000@gmail.com>',
        'Tatsuhiko Miyagawa <miyagawa@bulknews.net>',
        'Tim Mullin <tim@cpanel.net>',
        'Vladimir Marek <vlmarek@volny.cz>',
        'katyavoid <katyavoid@gmail.com>',
        'kmx <kmx@cpan.org>',
        'tokuhirom <tokuhirom@gmail.com>',
        'zefram <zefram@fysh.org>',
        'zentooo <ankerasoy@gmail.com>',
      ],
      prereqs => {
        test => {
          recommends => {
            'TAP::Harness' => '3.31',
            'Proc::ProcessTable' => 0,
          },
          suggests => {
            'Test::Pod' => '1.41',
            'Test::DistManifest' => 0,
          },
        },
      },
    },
    TEST_REQUIRES => { 'bigint'       => 0,
                       'Test::More'   => '0.90',
                       'Test::Deep'   => 0,
                       'Time::HiRes'  => 0,
    },
    CONFIGURE_REQUIRES => { 'DBI' => '1.608',
                            'Data::Dumper' => 0,
                            'Devel::CheckLib' => '1.09',
                            'ExtUtils::MakeMaker' => 0,
    },
  );
}

WriteMakefile1(%o);
exit 0;


############################################################################
#
#   Name:    Usage
#
#   Purpose: Print Usage message and exit with error status.
#
############################################################################

sub Usage {
  print STDERR <<"USAGE";
Usage: perl $0 [options]

Possible options are:

  --cflags=<flags>       Use <flags> for running the C compiler; defaults
                         to the value of "mariadb_config --cflags" or a guessed
                         value
  --libs=<libs>          Use <libs> for running the linker; defaults
                         to the value of "mariadb_config --libs" or a guessed
                         value
  --force-embedded       Build version of driver supporting MariaDBEmb
  --embedded=<libs>      Use these libs when building the embedded version of
                         DBD (with --force-embedded). Defaults to the value of
                         "mariadb_config --embedded".
  --testdb=<db>          Use the database <db> for running the test suite;
                         defaults to $TESTDB
  --testuser=<user>      Use the username <user> for running the test suite;
                         defaults to no username
  --testpassword=<pwd>   Use the password <pwd> for running the test suite;
                         defaults to no password
  --testhost=<host>      Use <host> as a database server for running the
                         test suite; defaults to localhost.
  --testport=<port>      Use <port> as the port number of the database;
                         by default the port number is chosen from the
                         mariadb/mysqlclient library; ignored when --testhost
                         is set to "localhost"
  --testsocket=<socket>  Use <socket> as a unix socket for connecting to
                         the database server; by default unix socket is chosen
                         by mariadb/mysqlclient library; takes effect only
                         when --testhost is set to "localhost"
  --mariadb_config       Synonym for --mysql_config, override it
  --mysql_config=<path>  Specify <path> for mariadb_config or mysql_config script
  --help                 Print this message and exit

All options may be configured on the command line. If they are
not present on the command line, then mariadb_config is called (if
it can be found):

  mariadb_config --cflags
  mariadb_config --libs
  mariadb_config --embedded
  mariadb_config --testdb

and so on. See DBD::MariaDB::INSTALL for details.
USAGE
  exit 1;
}


############################################################################
#
#   Name:    Configure
#
#   Purpose: Automatic configuration
#
#   Inputs:  $param - Name of the parameter being configured
#
#   Returns: Generated value, never undef
#
############################################################################

sub Configure {
    my($opt, $source, $param) = @_;
    if (defined($opt->{$param}) and length($opt->{$param})) {
        $source->{$param} = "User's choice";
        return;
    }

    # First try to get options values from mysql_config
    my @mysql_config_options = qw(
      cflags include libs libs_r plugindir socket port version libmysqld-libs embedded
    );
    if ( grep {$_ eq $param} @mysql_config_options ) {
        if ($opt->{'mysql_config'} and $opt->{'mysql_config'} ne 'skip') {
        my $command = $opt->{'mysql_config'} . " --$param";
        if (open(PIPE, "$command |")) {
            my $str = "";
            while (defined(my $line = <PIPE>)) { $str .= $line; }

            if ($str ne ""  &&  $str !~ /Options:/) {
                $str =~ s/\s+$//s;
                $str =~ s/^\s+//s;

                # Unfortunately ExtUtils::MakeMaker doesn't deal very well
                # with -L'...'
                $str =~ s/\-L\'(.*?)\'/-L$1/sg;
                $str =~ s/\-L\"(.*?)\"/-L$1/sg;

                # Separate libs from ldflags
                if ($param eq 'libs') {
                    my (@libs, @ldflags);
                    for (split ' ', $str) {
                        if (/^-[Ll]/ || /^[^\-]/) { push @libs, $_ }
                        else          { push @ldflags, $_ }
                    }
                    $str = "@libs";
                    $opt->{ldflags} = "@ldflags";
                    $source->{ldflags} = "mysql_config";
                }

                $opt->{$param} = $str;
                $source->{$param} = "mysql_config";
                return;
            }
        }
        else {
            print "Can't find mysql_config. Use --mysql_config option to specify where mysql_config is located\n";
        }
        }
    }

    # Ok, mysql_config doesn't work. We need to do our best
    # First check environment variables
    my $normparam = uc($param);
    $normparam =~ tr/-/_/;
    if (defined($ENV{'DBD_MARIADB_'.$normparam})) {
        $opt->{$param} = $ENV{'DBD_MARIADB_'.$normparam};
        $source->{$param} = 'environment';
    }

    # Then try to guess
    unless ($opt->{$param}) {
      if ($param eq 'testuser') {
        my $user = $ENV{USER} || '';
        print "

PLEASE NOTE:

For 'make test' to run properly, you must ensure that the
database user '$user' can connect to your MariaDB or MySQL server
and has the proper privileges that these tests require such
as 'drop table', 'create table', 'drop procedure', 'create procedure'
as well as others.

mysql> grant all privileges on test.* to '$user'\@'localhost' identified by 's3kr1t';

You can also optionally set the user to run 'make test' with:

perl Makefile.PL --testuser=username

";
      $opt->{$param} = $user;
	  $source->{$param} = 'guessed';
    }
    elsif ($param eq "testdb") {
      $source->{$param} = "default";
      $opt->{$param} = $TESTDB;
    }
    elsif ($param eq "testhost" || $param eq "testport"  ||
        $param eq "testpassword" || $param eq "testsocket" ) {
      $source->{$param} = "default";
      $opt->{$param} = "";
    }
    elsif($param eq 'force-embedded') {
      $source->{$param} = $opt->{$param} ? "default" : 'not set';
    }
    elsif ($param eq "cflags") {
      $source->{$param} = "guessed";
      my $dir = SearchFor('include', 'mysql.h');
      if ($dir) {
        $opt->{$param} = "-I$dir";
        return;
      }
      die <<"MSG";
Failed to determine directory of mysql.h. Use

  perl Makefile.PL --cflags=-I<dir>

to set this directory. For details see DBD::MariaDB::INSTALL,
section "C Compiler flags" or type

  perl Makefile.PL --help
MSG
    }
    elsif ($param eq "libs" || $param eq "embedded") {
      $source->{$param} = "guessed";

      if ($param eq "embedded" && !$opt->{'embedded'}) {
        $opt->{$param}="";
        return;
      }

      my @files=();
      my $default_libs;
      if ($param eq "embedded") {
        $default_libs= "-lmysqld -lpthread -lz -lm -lcrypt -lnsl";
        @files = ($^O =~ /mswin32/i) ? qw(mysqlclient.lib) :
		  	qw(libmysqld.a);
      }
      else {
        $default_libs= "-lmysqlclient -lz -lm -lcrypt -lnsl";
        @files = ($^O =~ /mswin32/i) ? qw(mysqlclient.lib) :
	  		qw(libmysqlclient.a libmysqlclient.so);
      }

      my $dir = SearchFor('lib', @files);

      if ($dir) {
          $opt->{$param} = "-L$dir $default_libs";
        return;
      }
      my $f = join("|", @files);
      die <<"MSG";
Failed to determine directory of $f. Use

  perl Makefile.PL "--$param=-L<dir> $default_libs"

to set this directory. For details see the DBD::MariaDB::INSTALL,
section "Linker flags" or type

  perl Makefile.PL --help
MSG
    }
    else {
      die "Unknown configuration parameter: $param";
    }
  }
}

my $fineDir;
sub SearchFor {
  my($subdir, @files) = @_;

  my @dirs = ($^O eq 'MSWin32') ? qw(C:) : qw(/usr/local /usr /opt);
  unshift(@dirs, $fineDir) if defined($fineDir);

  for my $f (@files) {
    for my $dir (@dirs) {
      my $try1 = File::Spec->catdir($dir, $subdir);
      my $try2 = File::Spec->catdir($dir, "mysql");
      my $try3 = File::Spec->catdir($try1, "mysql");
      my $try4 = File::Spec->catdir($try2, $subdir);
      for my $path ($try3, $try4, $try2, $try1, $dir) {
	my $file = File::Spec->catfile($path, $f);
	if (-f $file) {
	  $fineDir = $dir;
	  return $path;
	}
      }
    }
  }
}

sub SearchFor2 {
  my($files, $dirs) = @_;

  for my $f (@{$files})
  {
    for my $dir (@{$dirs})
    {
      if (-f File::Spec->catfile($dir, $f))
      {
        $fineDir = $dir;
        return $dir;
      }
    }
  }
}

sub replace
{
  my ($str, $ref)=@_;

  for my $find (keys %{$ref})
  {
    $str =~ s/$find/$ref->{$find}/g;
  }
  $str;
}

sub prepare_files
{
  my ($files)= @_;
  my $line;
  my @lib;

  for my $file (keys %{$files})
  {

    if ($files->{$file}->{makedir})
    {
      mkpath $files->{$file}->{makedir} or die "Can't create dir $files->{$file}->{makedir}"
      unless (-e $files->{$file}->{makedir} && -d $files->{$file}->{makedir});
    }

    my $replace=$files->{$file}->{replace};

    if ($replace)
    {
       open(FILE, $file) or die "Can't open file $file";
       @lib= map { $replace ? replace($_, $replace) : $_; }  <FILE>;
       close(FILE);

       open(FILE, ">".$files->{$file}->{filename}) or die "Can't open file $files->{$file}->{filename}";
       print FILE @lib;
       close(FILE);
    }
    else
    {
       if(!copy($file, $files->{$file}->{filename}))
       {
         die "Unable to copy $file to $files->{$file}->{filename}\n";
       }
    }
  }
}

sub create_makefile
{
  my ($cnf)=@_;

  open(LOG, ">MariaDBEmb/Makefile.conf") or die "Can't write to file MariaDBEmb/Makefile.conf";
  print LOG $cnf;
  close(LOG);
}

package MY;
sub postamble { return DBI::DBD::dbd_postamble(@_); }

package main;

sub WriteMakefile1 {  #Written by Alexandr Ciornii, version 0.21. Added by eumm-upgrade.
  my %params=@_;
  my $eumm_version=$ExtUtils::MakeMaker::VERSION;
  $eumm_version=eval $eumm_version;
  die "EXTRA_META is deprecated" if exists $params{EXTRA_META};
  die "License not specified" if not exists $params{LICENSE};
  if ($params{META_MERGE} and $params{META_MERGE}->{'meta-spec'}->{version} >= 2 and $eumm_version < 6.68) {
    #EUMM 6.68 has problems with meta-spec 2
    delete $params{META_MERGE}->{'meta-spec'};
    if ($params{META_MERGE}->{resources}) {
      foreach (values %{$params{META_MERGE}->{resources}}) {
        $_ = $_->{url} || $_->{web} if ref $_ eq 'HASH';
      }
    }
    if ($params{META_MERGE}->{prereqs}) {
      $params{CONFIGURE_REQUIRES} = { %{$params{CONFIGURE_REQUIRES} || {'ExtUtils::MakeMaker' => 0}}, %{$params{META_MERGE}->{prereqs}->{configure}->{requires} || {}} };
      $params{BUILD_REQUIRES} = { %{$params{BUILD_REQUIRES} || {'ExtUtils::MakeMaker' => 0}}, %{$params{META_MERGE}->{prereqs}->{build}->{requires} || {}} };
      $params{TEST_REQUIRES} = { %{$params{TEST_REQUIRES} || {}}, %{$params{META_MERGE}->{prereqs}->{test}->{requires} || {}} };
      $params{PREREQ_PM} = { %{$params{PREREQ_PM} || {}}, %{$params{META_MERGE}->{prereqs}->{runtime}->{requires} || {}} };
      my @recommends = (
        %{$params{META_MERGE}->{prereqs}->{configure}->{recommends} || {}},
        %{$params{META_MERGE}->{prereqs}->{configure}->{suggests} || {}},
        %{$params{META_MERGE}->{prereqs}->{build}->{recommends} || {}},
        %{$params{META_MERGE}->{prereqs}->{build}->{suggests} || {}},
        %{$params{META_MERGE}->{prereqs}->{test}->{recommends} || {}},
        %{$params{META_MERGE}->{prereqs}->{test}->{suggests} || {}},
        %{$params{META_MERGE}->{prereqs}->{runtime}->{recommends} || {}},
        %{$params{META_MERGE}->{prereqs}->{runtime}->{suggests} || {}},
      );
      $params{META_MERGE}->{recommends} = { %{$params{META_MERGE}->{recommends} || {}}, @recommends } if @recommends;
      delete $params{META_MERGE}->{prereqs};
    }
  }
  if ($params{BUILD_REQUIRES} and $eumm_version < 6.5503) {
    #EUMM 6.5502 has problems with BUILD_REQUIRES
    $params{PREREQ_PM}={ %{$params{PREREQ_PM} || {}} , %{$params{BUILD_REQUIRES}} };
    delete $params{BUILD_REQUIRES};
  }
  if ($params{TEST_REQUIRES} and $eumm_version < 6.64) {
    #EUMM 6.64 has problems with TEST_REQUIRES
    $params{PREREQ_PM}={ %{$params{PREREQ_PM} || {}} , %{$params{TEST_REQUIRES}} };
    delete $params{TEST_REQUIRES};
  }
  delete $params{CONFIGURE_REQUIRES} if $eumm_version < 6.52;
  delete $params{MIN_PERL_VERSION} if $eumm_version < 6.48;
  delete $params{META_MERGE} if $eumm_version < 6.46;
  delete $params{META_ADD} if $eumm_version < 6.46;
  delete $params{LICENSE} if $eumm_version < 6.31;
  delete $params{AUTHOR} if $] < 5.005;
  delete $params{ABSTRACT_FROM} if $] < 5.005;
  delete $params{BINARY_LOCATION} if $] < 5.005;

  ExtUtils::MakeMaker::WriteMakefile(%params);
}
