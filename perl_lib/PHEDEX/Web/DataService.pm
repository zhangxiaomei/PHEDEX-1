package PHEDEX::Web::DataService;

=head1 NAME

Service - Main program of the PhEDEx data service

=head1 DESCRIPTION

Checks configuration, parses URL path for parameters, makes API call

=cut

use warnings;
use strict;

use CGI qw(header path_info self_url param Vars);

use CMSWebTools::SecurityModule::Oracle;
use PHEDEX::Web::Config;
use PHEDEX::Web::Core;
use PHEDEX::Core::Timing;
use PHEDEX::Core::Loader;

our ($TESTING, $TESTING_MAIL);

sub new
{
  my $proto = shift;
  my $class = ref($proto) || $proto;
  my %h = @_;

  my $self;
  map { $self->{$_} = $h{$_}  if defined($h{$_}) } keys %h;

# Read PhEDEx web server configuration
  my $config_file = $self->{PHEDEX_SERVER_CONFIG} ||
		       $ENV{PHEDEX_SERVER_CONFIG} ||
    die "ERROR:  Web page config file not set (PHEDEX_SERVER_CONFIG)";

  my $dev_name = $self->{PHEDEX_DEV_NAME} || $ENV{PHEDEX_DEV_NAME};

  my $config = PHEDEX::Web::Config->read($config_file, $dev_name);
  $self->{CONFIG} = $config;
  $self->{CONFIG_FILE} = $config_file;
  eval "use CGI::Carp qw(fatalsToBrowser)"; # XXX turn off when in production!

# Set debug mode
  $TESTING = $$config{TESTING_MODE} ? 1 : 0;
  $TESTING_MAIL = $$config{TESTING_MAIL} || undef;

# Interpret the trailing path suffix: /FORMAT/DB/API?QUERY
  my $path = path_info() || "xml/prod";

  my ($format, $db, $call) = ("xml", "prod", undef);
  $format = $1 if ($path =~ m!\G/([^/]+)!g);
  $db =     $1 if ($path =~ m!\G/([^/]+)!g);
  $call =   $1 if ($path =~ m!\G/([^/]+)!g);

# Print documentation
  if ($format eq 'doc') {
      chdir '/tmp';
      print header();
      my ($module,$module_name,$loader,@lines,$line);
      $call = $db unless $call;
      $loader = PHEDEX::Core::Loader->new ( NAMESPACE => 'PHEDEX::Web::API' );
      $module_name = $loader->ModuleName($call);
      $module = $module_name || 'PHEDEX::Web::Core';

# This bit is ugly. I want to add a section for the commands known in this installation,
# but that can only be done dynamically. So I have to capture the output of the pod2html
# command and print it, but intercept it and add extra stuff at the appropriate point.
# I also need to check that I am setting the correct relative link for the modules.
      @lines = `perldoc -m $module |
                pod2html --header -css http://cern.ch/wildish/PHEDEX/phedex_pod.css`;

      my ($commands,$prefix,$count);
      $count = 0;
      foreach $line ( @lines )
      {
        if ( $line =~ m%^<table% )
        {
          $count++;
          if ( $count != 2 ) { print $line; next; }
          print "
<h1><a name='See Also'>See Also</a></h1>
Documentation for the commands known in this installation<br>
<br>
<table>
 <tr> <td> Command </td> <td> Module </td> </tr>
";
          $commands = $loader->Commands();
          $prefix = '';
          $prefix = 'doc/' unless $db;
          foreach ( sort keys %{$commands} )
          {
            $module = $loader->ModuleName($_);
            print "
<tr>
 <td><strong>$_</strong></td>
 <td><a href='$prefix$_'>$module</a></td>
</tr>
";
          }
          print "
</table>
<br>
and <a href='.'>PHEDEX::Web::Core</a> for the core module documentation<br>
<br>
";
        }
        print $line;
      }
      return;
  }

  my $core = new PHEDEX::Web::Core(VERSION => $config->{VERSION},
				   DBCONFIG => $config->{INSTANCES}->{$db}->{DBCONFIG},
				   INSTANCE => $db,
				   REQUEST_URL => self_url(),
				   DEBUG => $TESTING,
				   CACHE_CONFIG => $config->{CACHE_CONFIG} || {},
				   );

  my $type;
  if    ($format eq 'xml')  { $type = 'text/xml'; }
  elsif ($format eq 'json') { $type = 'text/javascript'; }
  elsif ($format eq 'perl') { $type = 'text/plain'; }
  else {
      print header(-type => 'text/xml');
      print "<error>Unsupported format '$format'</error>";
      return;
  }

  my $http_now = &formatTime(&mytimeofday(), 'http');

# Get the query string variables
  my %args = Vars();

# Reformat multiple value variables into name => [ values ]
  foreach my $key (keys %args) {
      my @vals = split("\0", $args{$key});
      $args{$key} = \@vals if ($#vals > 0);
  }

  $args{format} = $format;

  my %cache_headers;
  unless (param('nocache')) {
# getCacheDuration needs re-implementing.
      my $duration = $core->getCacheDuration($call) || 300;
      %cache_headers = (-Cache_Control => "max-age=$duration",
		        -Date => $http_now,
		        -Last_Modified => $http_now,
		        -Expires => "+${duration}s");
      warn "cache duration for '$call' is $duration seconds\n" if $TESTING;
  }
  print header(-type => $type, %cache_headers );

  $self->{CORE} = $core;
  $self->{CALL} = $call;
  $self->{ARGS} = \%args;
  bless $self, $class;
  return $self;
}

sub init_security
{
  my $self = shift;
# Access-control via the security module. Start by being fully paranoid,
# until we get a better idea how to do this stuff. So, require that the
# security module be configured wether used or not. For POSTs, exlicitly
# limit to Global Admins while working on the code. Later, relax to allow
# the roles in TMDB to limit access.
  my $core = $self->{CORE};

  my ($secmod,$secmod_config);
  $secmod_config = $self->{CONFIG}->{SECMOD_CONFIG};
  if (!$secmod_config) {
    $core->error("ERROR:  SecurityModule config file not set in $self->{CONFIG_FILE}");
    return;
  }
  $secmod = new CMSWebTools::SecurityModule::Oracle({CONFIG => $secmod_config});
  if ( ! $secmod->init() )
  {
    $core->error("Cannot initialise security module: " . $secmod->getErrMsg());
    return;
  }
  $core->{SECMOD} = $secmod;

  if ( $ENV{REQUEST_METHOD} eq 'POST' )
  {
    $secmod->reqAuthnCert();
    my $allowed = 0;
    my $roles = $secmod->getRoles();
    foreach( @{$roles->{'Global Admin'}} )
    { if ( m%^phedex$% ) { $allowed = 1; } }
    if ( !$allowed )
    {
      $core->error("You are not allowed to POST to this server.");
      return;
    }
  }
}

sub invoke
{
  my $self = shift;
  return $self->{CORE}->call($self->{CALL}, %{$self->{ARGS}});
}

1;
