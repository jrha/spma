package SPM::RPMPkgr;
#+############################################################################
#
# File: RPMPkgr.pm
#

=head1 NAME

SPM::RPMPkgr - Packager class implementation for RPM Packager

=head1 SYNOPSIS

    use SPM::RPMPkgr;
    ..
    $pkgr = SPM::RPMPkgr->new( );
    ..
    @pkgs = $pkgr->get_installed_list();
    ..
    $status = $pkgr->execute_ops( \@ops );
    ..
    # The following methods are implemented by the Packager base class
    ..
    @ops = $pkgr->get_diff_ops( \@srcpkgs, \@tgtpkgs );
    ..
    @ops = $pkgr->get_all_ops( \@srcpkgs, \@tgtpkgs );
    ..
    $status = $pkgr->execute( \@currentList, \@targetList );


=head1 DESCRIPTION   

    This class implements the SPM Packager interface for the RPM
    packager. It uses rpmt(8) to apply operations.

=over

=cut

use strict;
use vars qw(@ISA $this_app $EC);

use LC::Exception qw(SUCCESS throw_error);
$EC=LC::Exception::Context->new->will_store_all;

use LC::File qw(file_contents remove);
use LC::Process ();

use SPM::Packager;

use SPM::Op qw(OP_INSTALL OP_DELETE OP_REPLACE);

*this_app = \$main::this_app;

@ISA = qw(SPM::Packager);

use constant RPM_EXECUTABLE => "/bin/rpm";

use constant QUERY_COMMAND => (RPM_EXECUTABLE, qw(-qa --queryformat),
			       "- %{NAME} %{VERSION} %{RELEASE} %{ARCH} %{PUBKEYS}\n");
use constant DEFAULT_DB => "/var/lib/rpm";
use constant LSOF_BIN => "/usr/sbin/lsof";


my @RPMT_STDERR_FAIL_STR=(
   '^'.quotemeta('rpmt: rpmio_internal.h:').'.+'.quotemeta(': c2f: Assertion `fd && fd->magic ==').'.+\ failed\.',
   quotemeta('rpmio.c:').'.+'.quotemeta(': Fdopen: Assertion `fd && fd->magic ==').'.+\ failed\.',
   '^'.quotemeta('error: db4 error').'.+'.quotemeta('DB_VERIFY_BAD:Database verification failed'),
   '^'.quotemeta('error: ').'.+'.quotemeta('cpio: ')
			 );

# what RPM names indicate this is not a real RPM but a public key:
my @RPM_PUBKEY_NAMES=('gpg-pubkey');
# note: The above is evidently a hack. But there doesn't seem to be a way
# to clearly distinguish 'real' RPMs from public keys.


#============================================================================#
# new
#----------------------------------------------------------------------------#

=item new( )

    $pkgr = SPM::RPMPkgr->new( )
  
    Initialize an RPM Packager object.

=cut

#-----------------------------------------------------------------------------#
sub _initialize {
    my ($self,$cachepath,$proxytype,$proxyhost,$proxyport,$dbpath,$test) = @_;

    $self->_set_dbpath($dbpath);
    $self->_set_testing($test);
    return undef unless $self->_rpm_set_options();

    return $self->SUPER::_initialize($cachepath,$proxytype,$proxyhost,$proxyport);
}



#============================================================================#
# get_installed_list
#----------------------------------------------------------------------------#

=item get_installed_list(  ):LIST

    @pkgs = $pkgr->get_installed_list();
  
    Return a list of all installed packages.

=cut

#-----------------------------------------------------------------------------#
sub get_installed_list {
    my $self = shift;

    my ($qryout, $err);

    my @pkgs;

    my @cmd = (QUERY_COMMAND, "--dbpath", $self->_get_dbpath());
    push(@cmd, "--root", $this_app->option('root'))
	if ($this_app->option('root'));

    $self->debug(1,'getting locally installed packages with '.join(" ", @cmd));
    unless ($self->_free_rpmdb_access()) {
      $self->error("Cannot free RPMdb access");
      return undef;
    }

    my $execute_status = LC::Process::execute(\@cmd,
					      timeout => 20*60,
					      stdout => \$qryout,
					      stderr => \$err
					      );
    if (!defined $execute_status) {
      if ($EC->error) {
	$self->error($EC->error->format_short);
        $EC->ignore_error();
      }
      $self->error($err) if ($err);
      throw_error("Failed to run rpm to retrieve installed packages, aborting...");
      return undef;
    }	
    $self->warn("RPM query STDERR output: ".$err) if ($err);

    foreach my $p (split(/\n/,$qryout)) {
      if ($p =~ m%^-\s(\S+)\s(\S+)\s(\S+)\s(\S+)\s(.+)$%) {
	my ($n,$v,$r,$a,$sig)=($1,$2,$3,$4,$5);
	# ignore signature "packages"!
	unless ($sig ne '(none)' && $sig ne '(NONE)' &&
		grep {$_ eq $n} @RPM_PUBKEY_NAMES) {
	  my $pkg = SPM::Package->new(undef,$n,$v,$r,$a,undef);
	  if ($pkg) {
	    push(@pkgs,$pkg);
	    $self->debug(4," added package: n:$n v:$v r:$r a:$a");
	  } else {
	    return;
	  }
	} else {
	  $self->debug(3," skipping public key: $n $v");
	}
      } else {
	$self->debug(4," skipping garbage line: $p");
      }
    }
    $self->debug(1,scalar(@pkgs).' packages found installed.');
    return  \@pkgs;
}

#============================================================================#
# execute_ops
#----------------------------------------------------------------------------#

=item execute_ops( OPSLISTREF )

    $status = $pkgr->execute_ops( \@ops );
  
    Apply the given operations.

=cut

sub execute_ops {
    my $self = shift;

    my $ops = shift;

    my ($rpmtout, $err);

    # Put the rpmt operations file into /var/tmp instead of /tmp.
    # If the root is specified, put this under the root. 
    my $rpmtops = "/var/tmp/spma_ops.".$$;   # File to store rpmt instructions
    if ($this_app->option('root')) {
	$rpmtops = $this_app->option('root') . '/' . $rpmtops;
    }

    unless (ref($ops) eq 'ARRAY') {
	throw_error("Program error. RPM packager execute_ops method called ".
		    "with invalid or missing aoperations list.");
    }

    unless ($self->_write_ops($ops,$rpmtops)) {
	throw_error("Failed to write instructions for rpmt to $rpmtops.");
	return
    }


    my $dbpath=$self->_get_dbpath();
    my $rpmtpath;
    my $rpmtexec;
    my $path_exec=undef;
    my $execname=undef;
    foreach $rpmtpath (split(/,/,$this_app->option('rpmtpath'))) {
      foreach $rpmtexec (split(/,/,$this_app->option('rpmtexec'))) {
	$path_exec=$rpmtpath.'/'.$rpmtexec;
	if (-x $path_exec) {
	  $execname=$rpmtexec;
	  last;
	}
      }
      last if (-x $path_exec);
    }
    unless (defined $path_exec) {
      $self->error("cannot find rpmt in ".$this_app->option('rpmtpath'));
      return (-1);
    }
    my @cmd=($path_exec);
    if ($execname ne 'rpmt-py') {
      # 'old' rpmt
      push(@cmd, "--oldpackage", "--dbpath", $dbpath);
    } else {
      # 'new' rpmt-py
      push(@cmd, "--nosignature") unless ($this_app->option('checksig'));
    }

    if ($self->_get_testing()) {
      push(@cmd,"--test");
    } else {
      # not testing, but real run: ignore SIGs in order to avoid RPMDB
      # corruption due do a well-known RPM bug!
      $SIG{$_}='IGNORE' foreach qw(HUP PIPE INT QUIT);
    }
    push(@cmd, "--verbose") if ($this_app->option('verbose')
			     || $this_app->option('debug'));
#    $cmd .= " --percent" if ($this_app->option('debug'));
    push(@cmd, "--root=".$this_app->option('root'))
	if ($this_app->option('root'));

    if (defined $self->{'FWDPROXY'}) {
      push(@cmd, "--httpproxy=".$self->{'FWDPROXY'},
	   "--ftpproxy=".$self->{'FWDPROXY'});
      if (defined $self->{'FWDPROXYPORT'}) {
	push(@cmd, "--httpport=".$self->{'FWDPROXYPORT'},
	     "--ftpport=".$self->{'FWDPROXYPORT'});
      }
    }
    if ($execname eq 'rpmt-py') {
      push(@cmd, '--in');
    }


    $self->verbose ("command to be executed: ", join(" ",@cmd, "$rpmtops"));
    $self->verbose ("rpmt operations in $rpmtops :\n",
		    file_contents($rpmtops));

    unless ($self->_free_rpmdb_access()) {
      $self->error("cannot free RPM DB access");
      return (-1);
    }
    my $execute_status = LC::Process::execute([@cmd, $rpmtops],
					      timeout => 86400,
					      stdout => \$rpmtout,
					      stderr => \$err
					      );

    my $rpmt_status = $?;
    remove($rpmtops);

    if ($rpmtout) {
      $self->info("rpmt output produced:");
      $self->report($rpmtout);
    }

    if ($err) {
      $self->warn("rpmt STDERR output produced:");
      $self->warn($err);
      my $line;
      my @res;
      my @erray=split("\n",$err);
      foreach $line (@RPMT_STDERR_FAIL_STR){
	if (scalar (@res=grep (/$line/,@erray))) {
	  $self->error("rpmt failure detected: >> ".join(" >> ",@res));
	  return (-1);
	}
      }
    }

    $self->verbose ("rpmt execution finished with return status: ".
		    $rpmt_status);

    # If we managed to execute the transaction we'll return the command
    # exit status (should be 0-success, 1-error)
    # otherwise return -1 (error)

   if (defined $execute_status && $execute_status) {
      unless ($rpmt_status) {
	return 0; # rpmt OK
      } else {
	$self->error("rpmt failed to run, exit status: ".$rpmt_status);
	return 1; # rpmt failed
      }
   } else {
     # Otherwise we failed to execute command
     if ($EC->error) {
       $self->error($EC->error->format_short);
       $EC->ignore_error();
     }
     $self->error('error trying to run rpmt');
     return -1;
   }
}


#============================================================================#
# _write_ops - private
#----------------------------------------------------------------------------#
sub _write_ops {
    my $self = shift;

    my $ops = shift;
    my $file = shift;

    my $ops_list = '';

    foreach my $op (@$ops) {
	my $txt = $self->_print_op($op);
	$ops_list = join("\n",$ops_list,$txt);
    }

    return file_contents($file,$ops_list);
}
#============================================================================#
# _print_op - private
#----------------------------------------------------------------------------#
sub _print_op {
    my $self = shift;
    
    my $op = shift;   

    my $str;
    my $code = $op->get_operation();

    my @pkgs = $op->get_packages();

    if ($code eq OP_DELETE) {

      $str="-e ".$self->_print_package($pkgs[0]).'-'.$pkgs[0]->get_release();
      $str .= '.'.$pkgs[0]->get_arch() if ($self->{_OPTS}->{SETARCHINTRANS});
      return $str;

    } elsif ($code eq OP_INSTALL) {

      return "-i ".$self->_print_package_cache_path($pkgs[0]);

    } elsif ($code eq OP_REPLACE) {
	my @tgts = $op->get_target_packages();

	return "-u ".$self->_print_package_cache_path($tgts[0]);

    } else {
	throw_error("Packager does not support \"$code\" operation.");
	return;
    }
}

#============================================================================#
# _print_package_filename - private
#----------------------------------------------------------------------------#
sub _print_package_filename {
  my ($self,$pkg)=@_;

  return $self->_print_package($pkg)."-".
    $pkg->get_release().".".$pkg->get_arch.".rpm";
}


#============================================================================#
# _print_package - private
#----------------------------------------------------------------------------#
sub _print_package {
    my $self = shift;
    my $pkg = shift;

    return $pkg->get_name()."-".$pkg->get_version();
}

#============================================================================#
# _free_rpmdb_access - private
#----------------------------------------------------------------------------#

sub _free_rpmdb_access {
  my $self=shift;
   if (! $self->_get_testing() &&  $self->{_OPTS}->{RPMEXCLUSIVE}) {
      #
      # eliminate eventually existing reader applications
      #
      my $tries=10;
      my ($stdout,$stderr);
      my $dbpath=$self->_get_dbpath();
      while ($tries--) {
        $self->verbose ("checking for other applications accessing $dbpath/Packages");
	my $execute_status = LC::Process::execute([ LSOF_BIN, "-t", "$dbpath/Packages" ],
                                              timeout => 10*60,
                                              stdout => \$stdout,
                                              stderr => \$stderr
                                              );

        unless (defined $execute_status) {
	  if ($EC->error) {
	    $self->warn($EC->error->text);
	    $EC->ignore_error();
	  }
	  $self->warn("cannot run ", LSOF_BIN, " - continuing anyway...");
	  return SUCCESS;
	}
        my @procs=split("\n",$stdout);
        if (scalar @procs) {
          if ($tries==1) {
            $self->error ('other processes blocking SPMA to access the RPM database,\
 and not listening to SIGTERM (pid: ', join(' ', @procs), ': SPMA giving up.');
            return undef;
          }
          $self->info("found pids ", join(" ", @procs), " blocking RPMdb, TERMinating them...");
	  $self->verbose("tries to go: $tries");
          kill('TERM', @procs);
          sleep(5);
          kill('KILL', @procs);
        } else {
          last;
        }
      }
    }
  return SUCCESS;
}

#============================================================================#
# private methods
#----------------------------------------------------------------------------#
sub _get_dbpath {
    my $self = shift;
    return $self->{_OPTS}->{DBPATH};
}
sub _set_dbpath {
    my $self = shift;
    $self->{_OPTS}->{DBPATH} = shift;
}
sub _get_testing {
    my $self = shift;
    return $self->{_OPTS}->{TESTING};
}
sub _set_testing {
    my $self = shift;
    $self->{_OPTS}->{TESTING} = shift;
}

sub _rpm_set_options {
  my $self = shift;

  # set defaults
  $self->{_OPTS}->{RPMEXCLUSIVE}=0;
  $self->{_OPTS}->{SETARCHINTRANS}=1;

  LC::Process::execute([RPM_EXECUTABLE, '--version'],
		       stdout => \my $rpm_version,
		       stderr => \my $rpm_version_err);
  $self->warn(RPM_EXECUTABLE, "--version produced STDERR output:",
	      $rpm_version_err);
  # should be in the form 'RPM version X.Y.Z'
  if ($?) {
    $self->error ("cannot run ", join(" ", RPM_EXECUTABLE, '--version'),
		  ", aborting");
    return undef;
  }
  if ($rpm_version !~ /(\d+\.\d+\.\d+)/) {
    $self->warn ("cannot determine RPM version, default RPM flags apply");
    return SUCCESS;
  }
  my $ver=$1;
  $self->verbose ("RPM version $ver detected");
  if ($ver =~ m%^(4\.0|4\.1)\..+%) {
    $self->{_OPTS}->{SETARCHINTRANS}=0;
    $self->{_OPTS}->{RPMEXCLUSIVE}=1;
    $self->debug(3,"Setting SETARCHINTRANS=0 and RPMEXCLUSIVE=1");
  }
  return SUCCESS;
}




#+#############################################################################
1;

=back

=head1 AUTHOR

Ian Neilson, modifications by German Cancio

=head1 VERSION

$Id: RPMPkgr.pm.cin,v 1.27 2008/07/17 13:51:55 gcancio Exp $

=cut
