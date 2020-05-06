use v5.20;
package Mergeotron;
use Moo;
use experimental qw(postderef signatures);

use Mergeotron::Config;
use Mergeotron::Logger '$Logger';

use Data::Dumper::Concise;
use DateTime;
use IPC::Run3 qw(run3);
use Path::Tiny ();
use Process::Status;
use Try::Tiny;
use Types::Standard qw(Bool InstanceOf);

has config => (
  is => 'ro',
  isa => InstanceOf['Mergeotron::Config'],
  required => 1,
  handles => [qw(
    all_remotes
    remote_named
    target_branch_name
    upstream_base
    upstream_remote_name
  )]
);

sub from_config_file ($class, $config_file) {
  return $class->new({
    config => Mergeotron::Config->from_file($config_file),
  });
};

sub build ($self) {
  $self->prepare_local_directory;

  # Fetch
  for my $step ($self->config->steps) {
    my $mrs = $self->fetch_mrs_for($step);
    $step->set_merge_requests($mrs);
  }

  # Confirm

  # Act
  for my $step ($self->config->steps) {
    $self->merge_mrs($step->merge_requests);
    $self->maybe_tag_commit($step->tag_format);
  }

  $self->finalize;
}

sub run_git ($self, @cmd) {
  # A little silly, but hey.
  my $arg = {};
  $arg = pop @cmd if ref $cmd[-1] eq 'HASH';

  $Logger->log_debug([ "run: %s", join(q{ }, 'git', @cmd) ]);

  my $in = $arg->{stdin} // undef;
  my $out;

  unshift @cmd, 'git';
  run3(\@cmd, $in, \$out, \$out);
  my $ps = Process::Status->new;

  chomp $out;

  if ($Logger->get_debug) {
    local $Logger = $Logger->proxy({ proxy_prefix => '(git): ' });
    my @lines = split /\r?\n/, $out;
    $Logger->log_debug($_) for @lines;
  }

  $ps->assert_ok(join(q{ }, @cmd[0..1]));

  return $out;
}

# Change into our directory, check out the correct branch, and make sure we
# start from a clean slate.
sub prepare_local_directory ($self) {
  $self->ensure_initial_prep;

  my $target = $self->target_branch_name;

  $Logger->log("creating branch: $target");
  $self->run_git('reset', '--hard');
  # maybe: git clean -fdx
  $self->run_git('checkout', '--no-track', '-B', $target, $self->upstream_base);
  $self->run_git('submodule', 'update');
}

has have_set_up => (
  is => 'rw',
  isa => Bool,
  default => 0,
);

sub ensure_initial_prep ($self) {
  return if $self->have_set_up;

  my $dir = Path::Tiny::path($self->config->local_repo_dir);

  # If it doesn't exist, we either need to clone it or die.
  if (! $dir->is_dir) {
    die "local path $dir does not exist! (maybe you should set clone = true)\n"
      unless $self->config->should_clone;

    chdir $dir->parent;
    $Logger->log(["cloning into $dir from %s", $self->upstream_base]);

    my $remote = $self->remote_named($self->upstream_remote_name);

    $self->run_git(
      'clone',
      '--recursive',
      '-o' => $remote->name,
      $remote->clone_url,
      $dir->basename
    );
  }

  chdir $dir;

  $self->_ensure_remotes;
  $self->have_set_up(1);
}

sub _ensure_remotes ($self) {
  my $remote_output = $self->run_git('remote', '-v');

  # name => url
  my %have_remotes = map  {; split /\t/       }
                     grep {; s/\s+\(fetch\)// }
                     split /\r?\n/, $remote_output;

  REMOTE: for my $remote ($self->all_remotes) {
    my $name = $remote->name;
    my $remote_url = $remote->clone_url;

    if (my $have = $have_remotes{$name}) {
      # nothing to do unless they're mismatched.
      if ($have ne $remote_url) {
        die "mismatched remote $name: have $have, want $remote_url";
      }

      next REMOTE;
    }

    $Logger->log("adding missing remote for $name at $remote_url");
    $self->run_git('remote', 'add', $name, $remote_url);
  }
}

sub fetch_mrs_for ($self, $step) {
  # get 'em
  $Logger->log([ "fetching MRs for step %s", $step->name ]);

  my @mrs = $step->remote->get_mrs_for_label($step->label);
  for my $mr (@mrs) {
    $Logger->log([ "will merge: %s",  $mr->oneline_desc ]);
    $self->run_git('fetch', $mr->as_fetch_args);
  }

  return \@mrs;
}

sub merge_mrs ($self, $mrs) {
  try {
    $self->_octopus_merge($mrs);
  } catch {
    my $err = $_;
    chomp $err;

    $Logger->log("octopus merge failed with error: $err");
    $Logger->log("will merge less octopodally for diagnostics");
    $self->_diagnostic_merge($mrs);
  };
}

sub maybe_tag_commit ($self, $tag_format) {
  return unless $tag_format;

  my $ymd = DateTime->now(time_zone => 'UTC')->ymd('');
  my $sha = $self->run_git('rev-parse', 'HEAD');

  my $tag;

  for (my $n = 1; $n < 1000; $n++) {
    my $candidate = sprintf '%03d', $n;
    $tag = $tag_format;
    $tag =~ s/%d/$ymd/;
    $tag =~ s/%s/$candidate/;

    # Do a prefix match, because we're going to add the sha at the end.
    my $found_tags = $self->run_git('tag', '-l', "$tag*");
    last unless $found_tags;
  }

  my $short = substr $sha, 0, 8;
  $tag .= "-g$short";

  $Logger->log("tagging $sha as $tag");
  $self->run_git('tag', $tag);
}

sub finalize ($self) {
  # I put this here, but I'm not sure right now that it will do anything.
}

sub _octopus_merge ($self, $mrs) {
  my @shas = map {; $_->sha } @$mrs;

  # Write our commit message into a file. This is potentially quite long, and
  # we don't really want it to show up in the debug logs for the commands.
  my $n = @$mrs;
  my $mrs_eng = "MR" . ($n > 1 ? 's' : '');

  my $msg = "Merge $n tagged $mrs_eng\n\n";
  $msg .= $_->oneline_desc . "\n" for @$mrs;

  my $path = Path::Tiny->tempfile();
  $path->spew_utf8($msg);

  $Logger->log("octopus merging $n $mrs_eng");

  $self->run_git('merge', '--no-ff', '-F' => $path->absolute, @shas);

  $Logger->log([ "merged $n $mrs_eng into %s", $self->target_branch_name ]);
}

sub _diagnostic_merge ($self, $mrs) {
  local $Logger = $Logger->proxy({ proxy_prefix => 'diagnostic merge: ' });

  $self->prepare_local_directory;

  for my $mr (@$mrs) {
    $Logger->log([ "merging %s", $mr->oneline_desc ]);

    try {
      $self->run_git('merge', '--no-ff', '-m' => $mr->as_commit_message, $mr->sha);
      $self->run_git('submodule', 'update');
    } catch {
      my $err = $_;
      chomp $err;

      # These errors are almost always useless, like 'git returned exit value 1'
      $Logger->log_debug("git error: $err");

      $Logger->log([
        "encountered error while merging %s; will attempt to find conflict",
        $mr->ident
      ]);
      $self->_find_conflict($mr, $mrs);
    };
  }

  # If we are in this sub at all, we expect that the above will fail. If it
  # doesn't, something very strange indeed has happened.
  $Logger->log('diagnostic merge succeeded somehow...this should not happen!');
}

sub _find_conflict ($self, $known_bad, $all_mrs) {
  # clean slate
  $self->prepare_local_directory;

  # First: does this conflict with the branch we're trying to deploy?
  try {
    $Logger->log([ "merging known-bad MR: %s", $known_bad->ident ]);

    my $msg = $known_bad->as_commit_message;
    $self->run_git('merge', '--no-ff', '-m' => $msg, $known_bad->sha);
    $self->run_git('submodule', 'update');
  } catch {
    my $err = $_;
    chomp $err;

    $Logger->log_fatal([ "%s conflicts with %s (%s)",
      $known_bad->ident,
      $self->target_branch_name,
      $err,
    ]);
  };

  # No? What *does* it conflict with, then?
  for my $mr (@$all_mrs) {
    next if $mr->ident eq $known_bad->ident;

    try {
      $Logger->log([ "merging %s to check for conflict", $mr->ident ]);

      # NB: this prefix nonsense is because I have diff.noprefix true in my
      # local gitconfig, which causes this command to fail cryptically.
      my $patch = $self->run_git(
        'format-patch', '--src-prefix=a/', '--dst-prefix=b/', '--stdout', $mr->sha
      );

      $self->run_git('apply', 'check', { stdin => \$patch });
    } catch {
      my $err = $_;
      chomp $err;

      $Logger->log_debug("git error: $err");

      $Logger->log_fatal([ "fatal conflict between %s and %s; giving up",
        $mr->ident,
        $known_bad->ident,
      ]);
    };
  }
}

1;