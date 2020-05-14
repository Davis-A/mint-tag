use v5.20;
package Mergeotron::Artifact;
use Moo;
use experimental qw(postderef signatures);

use TOML::Parser;
use Try::Tiny;
use Types::Standard qw(InstanceOf Int Maybe Str);

use Mergeotron::Logger '$Logger';

has config => (
  is => 'ro',
  required => 1,
  isa => InstanceOf['Mergeotron::Config'],
);

has base => (
  is => 'ro',
  required => 1,
  isa => Str,
);

has tag_name => (
  is => 'ro',
  required => 1,
  isa => Str,
);

has annotation_version => (
  is => 'ro',
  required => 1,
  isa => Int,
);

# used when building from a mergeotron object, not when generating from tag
# message
has this_step => (
  is => 'ro',
  isa => Maybe[InstanceOf['Mergeotron::BuildStep']],
  predicate => 'has_this_step',
);

has step_data => (
  is => 'ro',
  lazy => 1,
  default => sub ($self) {
    my @steps;

    for my $step ($self->config->steps) {
      my $data = {
        name           => $step->name,
        remote         => $step->remote->clone_url,
        merge_requests => [],
      };

      for my $mr ($step->merge_requests) {
        push $data->{merge_requests}->@*, {
          number => $mr->number,
          sha    => $mr->sha,
          merge_base => $mr->merge_base,
        };
      }

      push @steps, $data;
      last if $self->has_this_step && $step eq $self->this_step;
    }

    return \@steps;
  },
);

# The TOML generation perl library kinda stinks, so I'ma construct it
# manually. It's fine. -- michael, 2020-05-13
sub as_toml ($self) {
  # This wants to be a template, BUT ALSO.
  my @lines = (
    '[meta]',
    sprintf('tag_name = "%s"', $self->tag_name),
    sprintf('annotation_version = %d', $self->annotation_version),
    sprintf('base = "%s"', $self->base),
    "",
  );

  for my $step ($self->step_data->@*) {
    push @lines, '[[build_steps]]';
    push @lines, sprintf('name = "%s"', $step->{name});
    push @lines, sprintf('remote = "%s"', $step->{remote});
    push @lines, 'merge_requests = [';

    for my $mr ($step->{merge_requests}->@*) {
      push @lines, sprintf(
        '  { number="%s", sha="%s", merge_base="%s" },',
        $mr->{number},
        $mr->{sha},
        $mr->{merge_base},
      );
    }

    push @lines, ']';
    push @lines, '';
  }

  return join "\n", @lines;
}

sub from_toml ($class, $config, $toml_str) {
  my $data = try {
    TOML::Parser->new->parse($toml_str);
  } catch {
    my $e = $_;
    $Logger->log("error reading artifact from TOML");
  };

  return unless $data;

  return $class->new({
    config => $config,
    base => $data->{meta}{base},
    tag_name => $data->{meta}{tag_name},
    annotation_version => $data->{meta}{annotation_version},
    step_data => $data->{build_steps},
  });
}

# This is step_data, but in a different shape. Keyed on $cloneurl!$number
has merge_requests => (
  is => 'ro',
  lazy => 1,
  default => sub ($self) {
    my %mrs;

    for my $step ($self->step_data->@*) {
      my $url = $step->{remote};
      for my $mr ($step->{merge_requests}->@*) {
        my $key = sprintf("%s!%d", $url, $mr->{number});

        # maybe: rethink if we want to include merge-base?
        $mrs{$key} = $mr->{sha};
      }
    }

    return \%mrs;
  },
);

sub _key_for_mr ($class, $mr) {
  return sprintf("%s!%d", $mr->remote->clone_url, $mr->number);
}

# $mr is a blessed merge request object
sub contains_mr ($self, $mr) {
  return !! $self->sha_for_mr($mr);
}

# return the data we have matching a blessed merge request object
sub sha_for_mr ($self, $mr) {
  return $self->merge_requests->{ $self->_key_for_mr($mr) };
}

1;
