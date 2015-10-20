use strictures 2;

package Dancer2::Plugin::RRD;

# ABSTRACT: Interface to RRDtool for Dancer2

use Dancer2::Plugin;
use RRDTool::OO;
use Carp qw(croak);
use Scalar::Util qw(refaddr);
use Moo::Role 2;

# VERSION

=head1 SYNOPSIS

    use Dancer2::Plugin::RRD;

    set plugins => {
        RRD => {
            # define aliases
            my => 'my_round_robin_database.rrd'
        }
    };

    # update DS "views" in "my_round_robin_database.rrd"
    # with value of 10 at the current time
    rrd_update('my.views', 10);

=head1 DESCRIPTION

This module is a interface to L<RRDTool::OO>.

The RRD files are aliassed in the plugin configuration. For each file an instance of L<RRDTool::OO> is created on demand and cached.

=head2 Splitting the DS name

For L</rrd_update>, L</rrd_tune> and L</rrd_count> the first argument is splitted by the first dot (C<.>) into the rrd file alias and the DS name. If for those commands the DS name is not especially given, the default DS is assumed.

For all other command the first argument is just the RRD file alias.

=cut

has _cache => (
  is => 'ro',
  default => sub { {} },
);
has _rrds => (
  is => 'ro',
  default => sub { {} },
);
has _counter => (
  is => 'rwp',
  default => sub { {} },
);

sub _single {
    my $hash = shift;
    $hash->{''} if keys %$hash == 1 and exists $hash->{''};
}

sub _rrd {
  my $self = shift;
  my ($ds) = @_;
  my ($major, $minor) = split quotemeta('.'), $ds, 2;
  $minor //= '';
  my $file = plugin_setting->{$major} //
    croak "unknown section in plugin settings: $major";
  $self->_cache->{$file} //= RRDTool::OO->new(
    file => $file,
  ) // croak "cannot instanciate RRD: $!";
  my $rrd = $self->_cache->{$file};
  $self->_rrds->{refaddr($rrd)} = $rrd;
  return wantarray ? ($rrd, $minor) : $rrd;
}

sub _normalize_time {
    my $time = shift;
    my $now = shift // time;
    $time //= 0;
    if ($time < 0) {
        $time = time - $now;
    }
    if ($time < 2**24) {
        $time += $now;
    }
    return $time;
}

=func rrd_update

B<Invokation:> C<rrd_update( $rrd, $value = 0, $time = time )>

    # update DS "views" with value 2 at this moment
    rrd_update("$file.views", 2);

    # update DS "views" with default value 0 at this moment
    rrd_update("$file.views");

    # update DS "views" with value 10 and timestamp of 30 seconds ago
    rrd_update("$file.views", 10, -30);

    # update DS "views" with value 10 and timestamp of 1 hour in future
    rrd_update("$file.views", 10, 3600);

=cut

sub _update {
    my $self = shift;
    my ($ds, $value, $time) = @_;
    $value //= 0;
    $time = _normalize_time($time);
    my ($rrd, $key) = $self->_rrd($ds);
    if ($key) {
        return $rrd->update(time => $time, values => { $key, $value });
    } else {
        return $rrd->update(time => $time, value => $value);        
    }
}

=func rrd_last

Return the last RRD update time.

B<Invokation:> C<rrd_last( $rrd )>

    rrd_last("$file");

=cut

sub _last {
    my $self = shift;
    my ($ds) = @_;
    my $rrd = $self->_rrd($ds);
    return $rrd->last;
}

=func rrd_graph

Draw a nice RRD graph.

B<Invokation:> C<rrd_graph( $rrd )>

    rrd_graph("$file",
        image => $tempfile,
        vertical_label => "Page views",
        draw => {
            thickness => 2,
            color => 'ff0000',
            legend => 'views over time'
        }
    );

See L<RRDTool::OO> and L<rrdgraph(1)> for more information about drawing graphs.

=cut

sub _graph {
    my $self = shift;
    my ($ds, @opts) = @_;
    my $rrd = $self->_rrd($ds);
    return $rrd->graph(@opts);
}

=func rrd_info

Return metadata about the RRD.

B<Invokation:> C<rrd_info( $rrd )>

    my $meta = rrd_info("$file");

=cut

sub _info {
    my $self = shift;
    my ($ds) = @_;
    my $rrd = $self->_rrd($ds);
    return $rrd->info;
}

=func rrd_tune

Alter configuration values of a RRD.

B<Invokation:> C<rrd_tune( $rrd, %options )>

    # set heartbeat to 2min
    rrd_tune("$file", heartbeat => 120);
    # set type of DS "views" to "average"
    rrd_tune("$file.views", type => 'AVERAGE');

=cut

sub _tune {
    my $self = shift;
    my ($ds, %opts) = @_;
    my ($rrd, $key) = $self->_rrd($ds);
    if ($key) {
      return $rrd->tune(dsname => $key, %opts);
    } else {
      return $rrd->tune(%opts);
    }
}

=func rrd_count

Increases a counter for commiting the values later.

B<Invokation:> C<rrd_count( $rrd, $by = 1 )>

    rrd_count("$file.views"); # increase by one
    rrd_count("$file", 8); # increase the single DS in $file by 8

See L</rrd_commit> for committing the counted values.

=cut

sub _count {
    my $self = shift;
    my ($ds, $by) = @_;
    my ($rrd, $key) = $self->_rrd($ds);
    $by //= 1;
    return unless $by;
    $self->_counter->{refaddr($rrd)} //= {};
    $self->_counter->{refaddr($rrd)}->{$key} //= 0;
    return
    $self->_counter->{refaddr($rrd)}->{$key} += $by;
}

=func rrd_commit

Commit the counted values with L</rrd_count>.

B<Invokation:> C<rrd_commit( $time = time )>

    # increase counter by one
    rrd_count("$file.views");
    # commit the counter with timestamp two minutes ago
    rrd_commit(-180);

Hint: the time is normalized as documented in L</rrd_update>.

After that, all counter values are resetted to zero.

=cut

sub _commit {
    my $self = shift;
    my ($time) = @_;
    $time = _normalize_time($time);
    foreach my $refaddr (keys %{$self->_counter}) {
        my $vals = delete $self->_counter->{$refaddr};
        my $rrd = $self->_rrds->{$refaddr} // next;
        if (my $val = _single($vals)) {
            $rrd->update(time => $time, value => $val);
        } else {
            $rrd->update(time => $time, values => $vals);
        }
    }
}

register rrd_update => \&_update, { is_global => 1 };
register rrd_graph  => \&_graph , { is_global => 1 };
register rrd_info   => \&_info  , { is_global => 1 };
register rrd_tune   => \&_tune  , { is_global => 1 };
register rrd_last   => \&_last  , { is_global => 1 };
register rrd_count  => \&_count , { is_global => 1 };
register rrd_commit => \&_commit, { is_global => 1 };

register_plugin;

1;
