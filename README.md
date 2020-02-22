# Buildotron

This is a pretty generic way of building branches/tags from a config file. Its
main job is to fetch a series of merge/pull requests with some label and build
a branch from them. It's still a work in progress.

## Config

This is all driven by a config file. There's a sample in the config/
directory.

```toml
[meta]
remote_order = [ "upstream", "fastmail" ]     # meh

[local]
path = "/some/local/path"
target_branch = "deploy"
upstream_base = "upstream/master"

[remote.upstream]
interface_class = "Buildotron::Remote::Github"
api_url = "https://api.github.com"
api_key = "your-api-key"
repo = "cyrusimap/cyrus-imapd"
label = "include-in-deploy"
tag_format = "cyrus-%d.%s"

[remote.fastmail]
interface_class = "Buildotron::Remote::GitLab"
api_url = "https://gitlab.fm/api/v4"
api_key = "ENV:GITLAB_API_KEY"
repo = "fastmail/cyrus-imapd"
label = "include-in-deploy"
tag_format = "cyrus-%d.%s-fastmail"
```

`[local]` defines the local repository set up (i.e., on the machine this
program is running). We assume that there is already a clone in `path`. The
target branch is the name of the branch we will build, and the upsteam base is
where we'll reset before starting work.

You can have one or more remotes. Each remote must have an `interface_class`,
which tells the builder how to fetch the MRs. You also need to provide
instructions as to how to fetch the things it needs. You can provide your
`api_key` directly, but if it begins with the magic string `ENV:`, we'll fetch
it from the named environment variable instead. That means you can commit the
configs without worrying about leaking secrets.

You can provide a `tag_format`, but right now that's pretty janky. `%d` is
replaced with today's date (ymd, no-hyphens, in UTC), and `%s` with a serial
number, so if you build twice in the same day you'll get `cyrus-20200221.001`
and `cyrus-20200221.002`. This should probably be improved a lot.
(I wish you could customize `git describe` a little more, because it's
basically what I want.)

At build time, we go and fetch _all_ the appropriately labeled merge/pull
requests, then merge them all at once into a branch.   We do this
once per remote. Maybe we want to do this all at once (so you wind up with a
single merge), but for now this is ok, I think.

If the order matters, you can specify a `meta` block, with `remote_order`.
I am not thrilled about this, but it was expedient.

## Perly bits

The perl interface is meant to be dead simple:

```perl
my $bob = Buildotron->from_config_file('config/sample.toml`);
$bob->build();
```

The build routine itself does this:

```perl
sub build ($self) {
  $self->prepare_local_directory;

  for my $remote ($self->config->remotes) {
    my $mrs = $self->fetch_mrs_from($remote);
    $self->merge_mrs($mrs);
    $self->maybe_tag_commit($remote->tag_format);
  }

  $self->finalize;
}
```

Right now, `finalize` is a no-op, but eventually it will probably push tags
and whatnot to some remote.

If you want more control over the build process, you can just call those
methods yourself. YOu might do this if, say, you want a human to confirm that
those MRs are in fact the ones you want, and insert `$self->confirm_mrs($mrs)`
between the fetch and merge steps. Or, maybe you want to merge all the MRs at
once in a big octopus, in which case you could fetch all the MRs from every
remote, combine them, then call `->merge_mrs(\@all_mrs)`. You do you, buddy.

## Guts

When you call `->from_config_file`, we build a Buildotron::Config object.
That sets up objects for each remote based on their `interface_class`, either
Github or GitLab. Those each consume the Buildotron::Remote role, which I've
been meaning to write _forever_ and this finally gave me an excuse. That role
requires the method `get_mrs`, which returns a list of
Buildotron::MergeRequest objects. Those are very straightforward objects, but
it means that later you don't have to be concerned about the guts of the
Github/GitLab APIs and the different ways in which they are each terrible.

The merging process is straightforward:

1. fetch all the remotes
2. try to do an octopus merge
3. if that fails, try merging one-by-one to find the conflict

This is mostly stolen from the branch rebuilder we have in hm, but with better
diagnostics (I hope).

If you've defined a `tag_format` for a remote, we'll tag the resulting commit.
That's straightforward, if a little silly.

This uses only CPAN modules. If you have a normal rjbs-influenced environment,
you probably have these kicking around already.

- Data::Dumper::Concise;
- DateTime;
- Getopt::Long::Descriptive;
- IPC::Run3
- JSON::MaybeXS
- LWP::UserAgent;
- List::Util
- Log::Dispatchouli
- Moo::Role;
- Moo;
- Path::Tiny
- Process::Status;
- TOML::Parser;
- Try::Tiny;
- Types::Standard
- URI::Escape
- URI;