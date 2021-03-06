package SPM::Policy;
#+############################################################################
#
# File: Policy.pm
#

=head1 NAME

SPM::Policy - Class for management of local package policies.

=head1 SYNOPSIS

    use SPM::Policy;
    ..
    # Constructors
    #
    # $allowuserpkgs and $priorityuserpkgs set to 1 or 0
    $pol = SPM::Policy->new($allowuserpkgs,$priorityuserpkgs);
    ..
    # Policy application
    #
    $opsref = $pol->apply( \@ops );
    ..

=head1 DESCRIPTION   

    Given a list of package operations the Policy class allows
    implementation of local package priorities.

    The input list consists of DELETE, INSTALL, REPLACE and NOTHING
    operations. Each one can involve multiple instances (on both
    source and target configuration sides) of a named package. The
    NOTHING operation is a special case of REPLACE where both source
    and target lists are identical. Attributes of the contained
    packages have not yet been processed and, particularly in the case
    of the ISUNWANTED attribute may affect the transformation by the
    policy.

=over

=cut

use strict;
use vars qw(@ISA $VERSION);

use File::stat;
use LC::Exception qw(SUCCESS throw_error);
use LC::File      qw(file_contents);
use LC::Sysinfo;

use CAF::Object;
use CAF::Reporter;

use SPM::Op qw(OP_DELETE OP_INSTALL OP_REPLACE OP_NOTHING);

$VERSION = 1.00;
@ISA = qw(CAF::Object CAF::Reporter);

#============================================================================#
# new
#----------------------------------------------------------------------------#

=item new( HASH )

    $pol = SPM::Policy->new($allowuserpkgs,$priorityuserpkgs,$protectkernel);

    Initialise a new Policy instance. "1" values enable the
    policy options.

=cut

#-----------------------------------------------------------------------------#

sub _initialize {
    my ($self,$aup,$pup,$protectkern) = @_;

    # initial settings
    $self->_aup($aup);
    $self->_pup($pup);
    $self->_protectkern($protectkern);

    # uname -r might be easier?
    # can cache, unlikely to change at runtime...
    my $uname_r = LC::Sysinfo::uname->release(); 
    my $kernel = $uname_r;
    my $flavour = '';
    # Be sure to use a non-greedy '.*'...
    # NEVER change this regexp without testing first with script kernel-variant-test.pl.
    if($kernel =~ m/^(.*?)((?:large)?smp|xen|xenU|PAE|hugemem)$/) { # add exotic stuff here
        $kernel = $1;
        $flavour = $2;
    }

    # next code line will, if necessary, remove the architecture from $kernel to make the future comparisons with the packages names possible
    # this happens because in version 6 of slc the command 'uname -a' returns the architecture attached to the version
    $kernel =~ s/(\.x86_64)$//;

    $self->{_kernelversion} = $kernel;
    $self->{_kernelflavour} = $flavour;
    $self->debug(2," currently running kernel '$kernel', flavour '$flavour'");
 
    return SUCCESS;
}


#============================================================================#
# apply
#----------------------------------------------------------------------------#

=item apply( LISTREF )

    $opsref = $pol->apply( \@ops );

    Apply this policy to the given set of operations.  Think of the
    operations at this stage as "Requests". We havent looked at the
    package flags (mandatory,unwanted) yet. Here we combine the flags
    with the policy and generate another set of operations.

=cut

#-----------------------------------------------------------------------------#
sub apply {
    my $self = shift;
    my $opsref = shift;

    unless (ref($opsref) eq "ARRAY") {
	throw_error("Policy application expects reference to list of operations.");
	return;
    }

    my @outops = ();
    my $ops;

    for my $op (@$opsref) {

	# Process MANDATORY and UNWANTED flags. $op may be modified.

	if ($op->get_operation() eq OP_NOTHING ||
	    $op->get_operation() eq OP_REPLACE) {

	    $op = $self->_apply_force($op, \@outops);

	}

	if ($op) {

	    if ($op->get_operation() eq OP_DELETE) {
		$ops = $self->_apply_to_delete($op);
	    } elsif ($op->get_operation() eq OP_INSTALL) {
		$ops = $self->_apply_to_install($op);
	    } elsif ($op->get_operation() eq OP_NOTHING ||
		     $op->get_operation() eq OP_REPLACE) {
		$ops = $self->_apply_to_lists($op);
	    } else {
		throw_error("Invalid package operation code:".$op->get_operation());
		return;
	    }
	    
	    return unless ($ops);         # Throw exceptions up.
	    
	    push(@outops, @$ops) if (@$ops);
	}
    }

    return \@outops;
}



#============================================================================#
# _aup - private (Allow User Packages)
#----------------------------------------------------------------------------#
sub _aup {
    
    # Return and/or set ALLOWUSERPACKAGES attribute

    my $self = shift;
    my $val = shift;

    if (defined($val)) {
	$self->{_ALLOWUSERPACKAGES} = $val;
    }
    return $self->{_ALLOWUSERPACKAGES};
}
#============================================================================#
# _pup - private (Priority to User Packages)
#----------------------------------------------------------------------------#
sub _pup {
    
    # Return and/or set PRIORITYTOUSERPACKAGES attribute

    my $self = shift;
    my $val = shift;

    if (defined($val)) {
	$self->{_PRIORITYTOUSERPACKAGES} = $val;
    }
    return $self->{_PRIORITYTOUSERPACKAGES};
}
#============================================================================#
# _protectkern - private (Protect currently-running kernel packages?)
#----------------------------------------------------------------------------#
sub _protectkern {
    
    # Return and/or set PROTECTKERNEL attribute

    my $self = shift;
    my $val = shift;

    if (defined($val)) {
	$self->{_PROTECTKERNEL} = $val;
    }
    return $self->{_PROTECTKERNEL};
}
#============================================================================#
# _is_kernel_pkg - private (is the current package supposed to be
# protected)?  should match on the currently-running kernel flavour
# (but not other flavours or add-ons - up/smp, xen, -devel etc) and the
# respective modules. Could/should use real RPM depencies, uses a
# simple pattern instead.
#----------------------------------------------------------------------------#
sub _is_kernel_pkg {
    my $self = shift;
    my $pkg = shift;
    my $justkernel = shift;   # can turn on/off module protections
    my $ret = 0; # default:no

    my $name = $pkg->get_name();
    my $version_release = $pkg->get_version().'-'.$pkg->get_release();
    my $kversrel = $self->{_kernelversion};
    my $flavour = $self->{_kernelflavour};
    my $kernelname = 'kernel';
    if($flavour) {
	$kernelname .= '-'.$flavour;
    }
    if( $version_release eq $kversrel && 
	$name eq $kernelname) {
	# kernel proper
	$ret = 1;
	$self->verbose("keeping current kernel $name-$version_release");
    } elsif (! $justkernel && 
               $name =~ m/^(kernel-module|kmod).*?-$kversrel$flavour/) {
	# module. RPM name is hardcoded, assumed to contain exact kernelversion
	# but with the "flavour"/uname-r part at the end. yuck.
	$ret = 1;
	$self->verbose("keeping current module $name-$version_release");
    } else {
	$self->debug(5,"     is_kernel: no protection for $name-$version_release");
    }

    return $ret;
}

#============================================================================#
# _apply_to_delete - private
#----------------------------------------------------------------------------#
sub _apply_to_delete {
    my $self = shift;

    # These are packages which are currently on the local list
    # but do not appear on the target list. NB. They may still
    # be locally "unwanted" => not currently installed.

    my $op   = shift;

    my @outops = ();

    foreach my $pkg ($op->get_packages()) {
	# If it's unwanted then do nothing on output 
	# because it's not installed anyway
	next if ($pkg->get_attrib()->{ISUNWANTED});

	# Now we know it's installed, but is it locally managed? if so, skip.
	next if ($self->_aup() && $pkg->get_attrib()->{ISLOCAL});

	# is the package somehow related to the current kernel (and do we care)? if so, skip.
	next if ($self->_protectkern() && $self->_is_kernel_pkg($pkg, 0));

	# if nothing else, we keep the operation
	push (@outops, SPM::Op->new(OP_DELETE, [$pkg]));
    }
    return \@outops;
}
#============================================================================#
# _apply_to_install - private
#----------------------------------------------------------------------------#
sub _apply_to_install {
    my $self = shift;

    # These are packages which only appear in the target (desired)
    # list and not on the currently installed list. 

    my $op   = shift;

    my @outops = ();

    foreach my $pkg ($op->get_packages()) {
	# If it's unwanted then do nothing on output 
	# because it's not installed anyway
	unless ($pkg->get_attrib()->{ISUNWANTED}) {
	    # We don't need to check the mandatory flag
	    push (@outops, SPM::Op->new(OP_INSTALL, [$pkg]));
	}
    }
    return \@outops;
}
#============================================================================#
# _apply_to_lists - private
#----------------------------------------------------------------------------#
sub _apply_to_lists {
    my $self = shift;

    # Mandatory and unwanted packages are already dealt with

    my $op   = shift;
    my $outops;

    my @tgts = $op->get_target_packages();
    my @srcs = $op->get_source_packages();
    
    if ( $op->get_operation() eq OP_NOTHING) {
	
	$outops = $self->_apply_to_nothing(\@srcs, \@tgts);
	
    } elsif ( $op->get_operation() eq OP_REPLACE) {
	
	$outops = $self->_apply_to_replace(\@srcs, \@tgts);
	
    } else {
	throw_error("Program logic error. Unexpected package operation : ".
		    $op->get_operation());
	return;
    }

    return $outops;
}
#============================================================================#
# _apply_to_nothing - private
#----------------------------------------------------------------------------#
sub _apply_to_nothing {
    my $self = shift;

    # Source and target lists match exactly. Mandatory and
    # unwanted targets are handled elsewhere.

    my $srcsref = shift;
    my $tgtsref = shift;

    my @outops = ();

    # No mandatory or unwanted targets so we have simple equal lists
    # >>> NO MANDATORY or UNWANTED packages in the target list <<<

    foreach my $tgt (@$tgtsref) {
	if ($tgt->get_attrib()->{ISUNWANTED} || 
	    $tgt->get_attrib()->{ISMANDATORY}) {
	    throw_error("Program logic error trap. ".
			"MANDATORY and UNWANTED packages in list supplied ".
			"to _apply_to_nothing policy method.");
	    return;
	}
	# Locate matching source package 
	my @src = grep { $tgt->is_equal($_) } @$srcsref;

	# Make sure there was only one of them
	unless (@src == 1) {
	    throw_error("Program logic error trap. ".
			"Unequal package lists being processed.");
	    return;
	}

	# Install it if we need to
	if ($src[0]->get_attrib()->{ISUNWANTED} && ! $self->_pup()) {
	    push (@outops,SPM::Op->new(OP_INSTALL,[$tgt]));
	}
    }

    return \@outops;
}
#============================================================================#
# _apply_to_replace - private
#----------------------------------------------------------------------------#
sub _apply_to_replace {
  my $self = shift;

  # Source and target lists do not match.

  my $srcsref = shift;
  my $tgtsref = shift;


  # Here, we receive a set of source and target packages with the same
  # name, but which potentially are of different architectures (for
  # multiarch platforms, e.g. x86_64, i386), or different versions ("multi" packages)
  #
  # The first step is to divide the $src and $tgt packages into
  # per-architecture sets, as each architecture needs to be handled
  # separatedly.

  my $pkg;
  my $lastpkg; #debug info

  my %archs; # what architectures do we have? Note: more than two is possible in theory...

  my %srcarchpkg; # this is a hash with key: architecture, value: ref(packages on that arch)
  foreach $pkg (@$srcsref) {
    unless (exists $srcarchpkg{$pkg->get_arch()}) {
      $srcarchpkg{$pkg->get_arch()} = [()];
      $archs{$pkg->get_arch()} = 1;
    }
    push(@{$srcarchpkg{$pkg->get_arch()}},$pkg);
    $lastpkg=$pkg;
  }
  my %tgtarchpkg; # this is a hash with key: architecture, value: ref(packages on that arch)
  foreach $pkg (@$tgtsref) {
    unless (exists $tgtarchpkg{$pkg->get_arch()}) {
      $tgtarchpkg{$pkg->get_arch()} = [()];
      $archs{$pkg->get_arch()} = 1;
    }
    push(@{$tgtarchpkg{$pkg->get_arch()}},$pkg);
    $lastpkg=$pkg;
  }


  my @total_ops =(); # total operations to be performed

  my $arch;
  foreach $arch (keys %archs) {

    # traverse each arch separately

    $self->debug(4,"checking replace ops for ".$lastpkg->get_name().", architecture: $arch");

    my $srcsref_arch=$srcarchpkg{$arch} || [()]; # set to empty if no package for a
    my $tgtsref_arch=$tgtarchpkg{$arch} || [()]; # given arch is found

    my @arch_ops = (); # per-arch operations to be performed

    my $is_something_to_protect = 0;  # inside this operation we touch a "protected" RPM; can't combine these..

    # No mandatory or unwanted targets so we have simple unequal lists
    # >>> NO MANDATORY or UNWANTED packages in the target list <<<

    # If we have any local packages (wanted or unwanted) and priority
    # to local packages is on, we do'nt do anything


    my @lclpkgs = grep { $_->get_attrib()->{ISLOCAL} } @$srcsref_arch;

    unless ($self->_pup() && @lclpkgs) {
      # Beyond here there are no local packages taking priority

      # Clean out packages not currently installed

      my @installed = grep { ! $_->get_attrib()->{ISUNWANTED} } @$srcsref_arch;
      foreach $pkg (@installed) {
	$self->debug(5,"  REPLACE: looking at installed ".$pkg->get_name().'-'.$pkg->get_version().'-'.$pkg->get_release());

	# Delete the installed sources
	my @sames = grep { $_->is_equal($pkg) } @$tgtsref_arch;
	if (@sames) {
	    $self->debug(4,"   REPLACE: nothing to do for old ".$pkg->get_name().'-'.$pkg->get_version().'-'.$pkg->get_release());
	} else {
	    # is the package somehow related to the current kernel (and do we care)? if so, skip even if not in target list
            # protection does not extend to kernel modules, these can be updated in place
	    if (! ($self->_protectkern() && $self->_is_kernel_pkg($pkg, 1))) {
		$self->debug(3,"   REPLACE: marking old ".$pkg->get_name().'-'.$pkg->get_version().'-'.$pkg->get_release().' for deletion');
		push(@arch_ops,SPM::Op->new(OP_DELETE,[$pkg]));
	    } else {
		$self->debug(3,"   REPLACE: protected old ".$pkg->get_name().'-'.$pkg->get_version().'-'.$pkg->get_release().' from deletion');
		$is_something_to_protect = 1;
	    }
        }
      }
      foreach $pkg (@$tgtsref_arch) {
	$self->debug(5,"  REPLACE: looking at target ".$pkg->get_name().'-'.$pkg->get_version().'-'.$pkg->get_release());
	my @sames = grep { $_->is_equal($pkg) } @$srcsref_arch;
	if (@sames) {
          $self->debug(4,"   REPLACE: nothing to do for target ".$pkg->get_name().'-'.$pkg->get_version().'-'.$pkg->get_release());
	} else {
          $self->debug(3,"   REPLACE: marking target ".$pkg->get_name().'-'.$pkg->get_version().'-'.$pkg->get_release().' for install');
	  push(@arch_ops,SPM::Op->new(OP_INSTALL,[$pkg]));
	}
      }
    }

    if (@$tgtsref_arch == 1 && 
	! $is_something_to_protect ) {
      # With only a single non-protected target we have the chance of converting (back) to
      # a replace operation
      unless ($self->_combine_ops(\@arch_ops)) {
	return;
      }
    }

    push(@total_ops,@arch_ops);

  }

  return \@total_ops;
}

#============================================================================#
# _apply_force - private
#----------------------------------------------------------------------------#
sub _apply_force {
    my $self = shift;

    # Note in this world the ALLOWUSER and PRIORITYTOUSER have NO effect.

    my ($op, $outopsref) = @_;

    my @tgts = $op->get_target_packages();
    my @srcs = $op->get_source_packages();

    # Cull any sources which MUST be deleted.

    my ($srcsref1, $tgtsref1) = 
	$self->_apply_force_for_delete( \@srcs, \@tgts,	$outopsref );

    # Force through any installations that MUST be made.

    my ($srcsref, $tgtsref) = 
	$self->_apply_force_for_install( $srcsref1, $tgtsref1, $outopsref );

    if (@tgts == 1) {
	# With only a single target we have the chance of converting (back) to 
	# a replace operation
	unless ($self->_combine_ops($outopsref)) {
	    return;
	}
    }

    # Now we need to construct a new operation to carry any remaining
    # packages through to the rest of the policy apply

    my $newop;

    if (@$srcsref && @$tgtsref) {
	
	$newop = SPM::Op->new(OP_REPLACE, $srcsref, $tgtsref);

    } elsif (@$srcsref) {

	$newop = SPM::Op->new(OP_DELETE, $srcsref, undef);

    } elsif (@$tgtsref) {

	$newop = SPM::Op->new(OP_INSTALL, undef, $tgtsref);

    }

    return $newop;
}
#============================================================================#
# _apply_force_for_install - private
#----------------------------------------------------------------------------#
sub _apply_force_for_install {

    my $self = shift;

    my ($srcsref, $tgtsref, $outopsref) = @_;

    my @newtgts;
    my @newsrcs;

    # If package exists in the target
    # but not in the source (as wanted) we install it.

    foreach my $pt (@$tgtsref) {
	# If target is unwanted we should have already have handled DELETE
	if ($pt->get_attrib()->{ISMANDATORY}) {
	    # Find it in the source list
	    my $installed = 0;
	    for (my $i = 0; $i < @$srcsref; $i++) {
		my $ps = @$srcsref[$i];
		if ($ps && $ps->is_equal($pt)) {
		    # Have match. Flag as installed unless source says not
		    $installed = 1 unless $ps->get_attrib()->{ISUNWANTED};
		    # Need to remove from sources list whatever
		    @$srcsref[$i] = undef;
		}
	    }
	    unless ($installed) {
		push(@$outopsref, SPM::Op->new(OP_INSTALL,[$pt]));
	    }
	} else {
	    # Effectively cull all MANDATORY targets.
	    # (unwanted's should have been dealt with by ~_for_delete before)
	    push (@newtgts, $pt);
	}
    }
    # Gather up remaining source packages.
    foreach my $ps (@$srcsref) {
	push(@newsrcs, $ps) if $ps;
    }
    
    return (\@newsrcs, \@newtgts);
}
#============================================================================#
# _apply_force_for_delete - private
#----------------------------------------------------------------------------#
sub _apply_force_for_delete {

    my $self = shift;

    my ($srcsref, $tgtsref, $outopsref) = @_;

    # For installed packages, if it exists in the source but
    # not in the target (as wanted) then we need to delete it.

    my @newsrcs;
    my @newtgts;

    foreach my $ps (@$srcsref) {
	push(@newsrcs, $ps); # Save it by default in a new list
	my $removed = 0;
	my $unwanted = 0;
	foreach my $pt (@$tgtsref) {
	    if ($pt->get_attrib()->{ISUNWANTED} && $ps->is_equal($pt) ) {
		# Have a source and target match. Flag as wanted unless
		# the target says not.
		pop(@newsrcs) unless $removed++ ; # Pull it off the new list
		$unwanted = 1 unless $ps->get_attrib()->{ISUNWANTED};
	    }
	}
	if ($unwanted) {
	    push(@$outopsref, SPM::Op->new(OP_DELETE,[$ps]));
	}
    }
    
    # Now cull all UNWANTED targets since we have dealt with them

    foreach my $pt (@$tgtsref) {
	push (@newtgts, $pt) unless $pt->get_attrib()->{ISUNWANTED};
    }
		
    return (\@newsrcs, \@newtgts);
}
#============================================================================#
# _combine_ops - private
#----------------------------------------------------------------------------#
sub _combine_ops {
    my $self = shift;

    # Check if we can replace a DELETE-INSTALL sequence with a REPLACE

    # Sequence is relied on by some packages todecide whether they are being
    # updgraded or deleted ?? -
    # Upgrade:           new: preinstall,   postinstall    followed by -
    #                    old: preuninstall, postuninstall.
    # Deinstall-install: old: preuninstall, postuninstall  followed by -
    #                    new: preinstall,   postinstall.

    my $opslistref = shift;

    if (@$opslistref == 2 &&
	$$opslistref[0]->get_operation() eq OP_DELETE &&
	$$opslistref[1]->get_operation() eq OP_INSTALL &&
	$$opslistref[0]->get_packages() == 1 &&
	$$opslistref[1]->get_packages() == 1 && 
	(($$opslistref[0]->get_packages())[0]->get_name() eq
	 ($$opslistref[1]->get_packages())[0]->get_name())
	) {

	# We have a simple single package operation. Can
	# replace this with a single upgrade Op.

	my $srcpkg = (shift(@$opslistref)->get_packages())[0];
	my $tgtpkg = (shift(@$opslistref)->get_packages())[0];

	$self->debug(4,"combining: ".$srcpkg->get_name() . " and ".
		     $tgtpkg->get_name() );


# not neccessary since check is done above

#	if ($srcpkg->get_name() ne $tgtpkg->get_name()) {
#	    throw_error("Program error: Trying to combine operations on ".
#			"packages with different names:".
#			$srcpkg->get_name() . " and ".$tgtpkg->get_name() );
#	    return;
#	}

	push(@$opslistref,SPM::Op->new(OP_REPLACE, [$srcpkg], [$tgtpkg]) );
    }
    return SUCCESS;
}
#============================================================================#
# _count_forced - private (NOT USED ??)
#----------------------------------------------------------------------------#
sub _count_forced {
    my $self = shift;

    my $pkgsref = shift;

    unless (ref($pkgsref) eq "ARRAY") {
	throw_error("Expecting reference to list of packages.");
	return;
    }

    my $count = 0;

    foreach my $pkg (@$pkgsref) {
	$count++ if $pkg->get_attrib()->{ISMANDATORY};
	$count++ if $pkg->get_attrib()->{ISUNWANTED};
    }

    return $count;
	
}
#+#############################################################################
1;

=back

=head1 AUTHORS

Original Author: Ian Neilson <Ian.Neilson@cern.ch>
Modifications by German Cancio <German.Cancio@cern.ch>

=head1 VERSION

$Id: Policy.pm.cin,v 1.4 2007/12/06 17:20:40 poleggi Exp $

=cut
