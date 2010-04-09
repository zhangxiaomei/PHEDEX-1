package PHEDEX::Custom::Castor::Stager::Agent;
use strict;
use warnings;
use base 'PHEDEX::Core::Agent', 'PHEDEX::Core::Logging';
use PHEDEX::Core::Command;
use PHEDEX::Core::Timing;
use PHEDEX::Core::Catalogue;
use PHEDEX::Core::DB;

sub min { return (sort { $a <=> $b } @_)[0] }
sub max { return (sort { $b <=> $a } @_)[0] }

sub new
{
    my $proto = shift;
    my $class = ref($proto) || $proto;
    my $self = $class->SUPER::new(@_);
    my %params = (DBCONFIG => undef,		# Database configuration file
	  	  NODES => undef,		# Nodes this agent runs for
                  IGNORE_NODES => ['%_MSS'],    # TMDB nodes to ignore
                  ACCEPT_NODES => [],           # TMDB nodes to accept
	  	  STORAGEMAP => undef,		# Storage path mapping rules
	  	  PROTECT_CMD => undef,		# Command to check for overload
		  WAITTIME => 550 + rand(100),  # Agent cycle time
	  	  ME => "FileStager",	# Identity for activity logs
    	    	  MAXFILES => 100,		# Max number of files in one request
		  PFN_CACHE => {},		# LFN -> PFN cache
		  STAGE_CACHE => {},		# Stage status cache
		  DB_CACHE => {},		# Cache of DB state
		 );
    my %args = (@_);
    map { $$self{$_} = $args{$_} || $params{$_} } keys %params;
    bless $self, $class;
    return $self;
}

# Purge old entries from our caches.
sub purgeCache
{
    my ($cache, $lifetime) = @_;
    $lifetime ||= 86400;

    # Remove old positive matches after a day to avoid building up
    # a cache over a time.  Remove negative matches after an hour.
    my $now = time ();
    my $oldmatch = $now - $lifetime;
    my $oldnomatch = $now - 3600;

    # Remove entries that are too old
    foreach my $item (keys %$cache)
    {
	delete $$cache{$item}
	   if ($$cache{$item}{TIME} < $oldmatch
	       || (! $$cache{$item}{VALUE}
		   && $$cache{$item}{TIME} < $oldnomatch));
    }
}

# Get the list of files in transfer out of the node.
sub getNodeFiles
{
    my ($self, $dbh) = @_;
    my %files = ();

    # First fetch files coming out of our node from the database.  
    # If we come across something we haven't seen before, remember it
    # but don't look it up yet.  We get files exported from the node,
    # plus most recent time the file was in that state.
    my ($mynodes, %myargs) = $self->myNodeFilter ("xt.from_node");
    my ($dest, %dest_args) = $self->otherNodeFilter ("xt.to_node");
    my $stmt = &dbexec($dbh, qq{
	select f.logical_name from t_xfer_task xt
        join t_adm_link l on l.from_node = xt.from_node and l.to_node = xt.to_node
	join t_xfer_file f on f.id = xt.fileid
	where $mynodes $dest}, %myargs, %dest_args);
    $files{$_} = { LFN => $_, PFN => undef, TIME => 0 }
	while (($_) = $stmt->fetchrow());

    # Now, collect PFNs for cached files.
    foreach my $lfn (keys %files)
    {
	$files{$lfn}{PFN} = $$self{PFN_CACHE}{$lfn}{VALUE}
	    if exists $$self{PFN_CACHE}{$lfn};
    }

    # Finally PFNs for files not in cache.  We do this in single
    # efficient pull + cache results.
    if (my @lfns = grep(! $files{$_}{PFN}, keys %files))
    {
        my $now = time();
        my $pfns = &pfnLookup (\@lfns, "direct", "local", $$self{STORAGEMAP});
	while (my ($lfn, $pfn2) = each %$pfns)
        {
            my $pfn = $pfn2->[1];
            # HOW DO I PASS SPACE-TOKEN?
            my $space_token = $pfn2->[0];
	    $$self{PFN_CACHE}{$lfn} = { TIME => $now, VALUE => $pfn }; 
	    $files{$lfn}{PFN} = $pfn if defined $pfn;
        }
    }

    return \%files;
}

# Append into the file list the stager status information.
# It is not currently possible to get all files on stager.
#
# Returns undef if the stager can't be queried because of
# a transient error.  Otherwise returns the input hash.
sub getStagerFiles
{
    my ($self, $files) = @_;
    return undef if ! $files;

    # First check which files don't have a cached stager status.
    my @todo = ();
    my $now = time();
    foreach my $file (values %$files)
    {
	my $pfn = $$file{PFN};
	next if ! $pfn;
	my $c = $$self{STAGE_CACHE}{$pfn};
	do { push (@todo, $file); next }
	   if (($c && $$c{VALUE}) || '') ne 'STAGED';
	$$file{STATUS} = $$c{VALUE};
    }

    # Now, look up stager status for the files.  First mark the
    # pending files as negative match in the cache, then a bunch of
    # files at a time invoke stager_qry.  For the files this returns
    # status for, update the file status and the cache.
    #
    # Since stager_qry seems to hang every once in a while, blocking
    # the agent from making progress, run the command using a timeout.
    map { $$self{STAGE_CACHE}{$$_{PFN}} = {TIME=>$now, VALUE=>undef} } @todo;
    while (@todo)
    {
	my $pfx = $0;
	$pfx =~ s|/[^/]+$||;
	$pfx .= "/../../Utilities/RunWithTimeout 600";

	my @slice = splice(@todo, 0, $$self{MAXFILES});
	my %pfn2f = map { ($$_{PFN} => $_) } @slice;
	my @args = map { "-M $$_{PFN}" } @slice;
	open (QRY, "$pfx stager_qry @args |")
	    or do { $self->Alert ("stager_qry: cannot execute: $!"); return undef };
        while (<QRY>)
	{
	    chomp;
	    next if ! /^(\S+)\s+\d+\@\S+\s+(\S+)$/;
	    do { $self->Alert ("stager_qry output unrecognised file $1"); next }
	        if ! exists $pfn2f{$1};
	    my $status = $2;
	    if ($status && grep($status eq $_, qw(CANBEMIGR WAITINGMIGR BEINGMIGR)))
	    {
	        $status = "STAGED";
	    }
	    $pfn2f{$1}{STATUS} = $status;
	    $$self{STAGE_CACHE}{$1} = { TIME => time(), VALUE => $status };
	}
	close (QRY);
    }

    return $files;
}

# Build status object from stager state and pending requests.
sub buildStatus
{
    my ($self, $files) = @_;
    return undef if ! $files;

    # Mark in unknown state all files without clear status.
    foreach my $file (values %$files)
    {
	do { $self->Warn ("unknown wanted file $$file{LFN}"); next }
	    if ! $$file{PFN};
	$$file{STATUS} ||= "UNKNOWN";
    }

    return $files;
}

# Called by agent main routine before sleeping.  Pick up stage-in
# assignments and map current stager state back to the database.
sub idle
{
    my ($self, @pending) = @_;

    my $dbh = undef;
    eval
    {
	my $rc;
	if ($$self{PROTECT_CMD} && ($rc = &runcmd(@{$$self{PROTECT_CMD}})))
	{
	  $self->Alert("storage system overloaded, backing off"
		 . " (exit code @{[&runerror($rc)]})");
	  return;
	}

	$dbh = $self->connectAgent();
	my @nodes = $self->expandNodes();
	my ($mynodes, %myargs) = $self->myNodeFilter ("node");

	# Clean up caches
	my %timing = (START => &mytimeofday());
	&purgeCache ($$self{PFN_CACHE});
	&purgeCache ($$self{STAGE_CACHE}, 3600);
	$timing{PURGE} = &mytimeofday();

	# Get pending and stager files
	my $files = $self->getNodeFiles ($dbh);
	return if ! $self->getStagerFiles ($files);
	return if ! $self->buildStatus ($files);
	$timing{STATUS} = &mytimeofday();

	# Update file status.  First mark everything not staged in,
	# then as staged-in the files currently in stager catalogue.
	# However, remember the status of the files we have updated
	# in the database in the last 4 hours, and only mark a delta.
	my $now = time();
	my $dbcache = $$self{DB_CACHE};
	if (($$dbcache{VALIDITY} || 0) < $now)
	{
	    $$dbcache{VALIDITY} = $now + 4*3600;
	    $$dbcache{FILES} = {};
	    &dbexec($dbh,qq{
	        update t_xfer_replica
	        set state = 0, time_state = :now
	        where $mynodes and state = 1},
	        ":now" => $now, %myargs);
	}

	my %oldcache = %{$$dbcache{FILES}};
	my $stmt = &dbprep($dbh, qq{
	    update t_xfer_replica set state = :state, time_state = :now
	    where fileid = (select id from t_xfer_file where logical_name = :lfn)
	      and $mynodes});
	foreach my $f (values %$files)
	{
	    next if ! defined $$f{LFN} || ! defined $$f{PFN};
	    my $isstaged = $$f{STATUS} eq 'STAGED' ? 1 : 0;
	    my $oldstaged = $$dbcache{FILES}{$$f{LFN}} ? 1 : 0;
	    $$dbcache{FILES}{$$f{LFN}} = $isstaged;
	    delete $oldcache{$$f{LFN}};
	    next if $isstaged == $oldstaged;

	    &dbbindexec ($stmt, ":now" => $now, %myargs,
			 ":lfn" => $$f{LFN}, ":state" => $isstaged);
	}
	foreach my $lfn (keys %oldcache)
	{
	    delete $$dbcache{FILES}{$lfn};
	    &dbbindexec ($stmt, ":now" => $now, %myargs,
			 ":lfn" => $lfn, ":state" => 0);
	}
	$dbh->commit();
	$timing{DATABASE} = &mytimeofday();

	# Issue stage-in requests for new files in batches.  Only consider
	# recent enough files in wanted state.
	my @requests = grep (defined $$_{PFN} && $$_{STATUS} eq 'UNKNOWN',
			     values %$files);
	my $nreq = scalar @requests;
	while (@requests)
	{
	    my @slice = splice (@requests, 0, $$self{MAXFILES});
	    my $rc = &runcmd ("stager_get", (map { ("-M", $$_{PFN}) } @slice));
	    $self->Alert ("stager_get failed: @{[&runerror($rc)]}") if ($rc);

	    # Mark these files as pending now
	    map { $$_{STATUS} = "STAGEIN" } @slice;
	}

	$timing{REQUESTS} = &mytimeofday();
	$self->Logmsg ("timing:"
		 . " nreq=$nreq"
		 . " purge=@{[sprintf '%.1f', $timing{PURGE} - $timing{START}]}"
		 . " status=@{[sprintf '%.1f', $timing{STATUS} - $timing{PURGE}]}"
		 . " database=@{[sprintf '%.1f', $timing{DATABASE} - $timing{STATUS}]}"
		 . " requests=@{[sprintf '%.1f', $timing{REQUESTS} - $timing{DATABASE}]}"
		 . " all=@{[sprintf '%.1f', $timing{REQUESTS} - $timing{START}]}");
    };
    do { chomp ($@); $self->Alert ("database error: $@");
	 eval { $dbh->rollback() } if $dbh; } if $@;

    # Disconnect from the database
    $self->disconnectAgent();
}

1;