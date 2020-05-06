use v5.20;
package Mergeotron::BuildStep;
use Moo;
use experimental qw(signatures postderef);

use Types::Standard qw(Str ConsumerOf Maybe ArrayRef InstanceOf);

has name => (
  is => 'ro',
  isa => Str,
  required => 1,
);

has remote => (
  is => 'ro',
  isa => ConsumerOf["Mergeotron::Remote"],
  required => 1,
  handles => {
    remote_name => 'name',
  },
);

has label => (
  is => 'ro',
  isa => Str,
  required => 1,
);

has tag_format => (
  is => 'ro',
  isa => Maybe[Str],
);

has merge_requests => (
  is => 'ro',
  init_arg => undef,
  isa => ArrayRef[InstanceOf["Mergeotron::MergeRequest"]],
  writer => 'set_merge_requests'
);

1;