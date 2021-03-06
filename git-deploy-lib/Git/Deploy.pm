package Git::Deploy;

use strict;
use warnings;
use Exporter;

# generic utilities we use
use POSIX qw(strftime);
use Carp qw(confess);
use Sys::Hostname qw(hostname);
use Fcntl qw(:DEFAULT :flock);
use Cwd qw(cwd abs_path);
use File::Spec::Functions qw(catdir);
use Git::Deploy::Timing qw(push_timings);
use Git::Deploy::Say;

our $VERSION= "0.001";
our @ISA= qw(Exporter);

our @EXPORT= qw(
    $DEBUG
    $SKIP_HOOKS
    $VERBOSE
  
    check_if_working_dir_is_clean
    check_for_unpushed_commits
    clear_ref_info
    fetch
    fetch_tag_info
    fetch_tags
    filter_names_by_date
    filter_names_matching_head
    find_refs_matching_head
    find_tags_matching_head
    get_branches
    get_commit_for_name
    get_config
    get_config_int
    get_config_path
    get_config_bool
    get_config_as_hoh
    get_current_branch
    get_deploy_file_name
    get_ref_info
    get_sha1_for_name
    get_sorted_list_of_tags
    git_cmd
    git_errorcode
    git_result
    is_name_annotated_tag
    make_dated_tag
    make_tag
    parse_rollout_status
    print_refs
    pull
    push_all
    push_remote
    push_tag
    push_tags
    read_deploy_file
    read_rollout_status
    remote
    store_tag_info
    unlink_rollout_status_file
    what_branches_can_reach_head
    write_deploy_file
    write_rollout_status
    execute_deploy_hooks
    process_deploy_hooks
    execute_hook
    get_hook
    get_sync_hook

    _slurp
    init_gitdir

);

our $DEBUG = $ENV{GIT_DEPLOY_DEBUG} || 0;
our $SKIP_HOOKS;
our $VERBOSE;


my $gitdir;
sub init_gitdir {
    return $gitdir if $gitdir;
# test that we actually are in a git repository before we do anything non argument processing related
    $gitdir= git_result( 'git rev-parse --git-dir', 128 );
    _die "current working directory is not part of a git repository\n"
        if !$gitdir
            or $gitdir =~ /Not a git repository/;

    # XXX: Assume the root of the workdir is the parent of the gitdir
    # change directory to the root dir of the tree, so that we have a normalized
    # perspective of the repo (so .deploy and similar things end up in the expected
    # place regardless of where the tool was run from).
    chdir "$gitdir/.."
        or _die "Failed to chdir to root of git working tree:'$gitdir/..': $!";
    return $gitdir;
}


# execute a command and capture and return both its output result and its error code
sub git_cmd {
    my $cmd= shift;

    $cmd .= " 2>&1";
    my $res= `$cmd`;
    my $error_code= $?;
    if ( $error_code == -1 ) {
        _die "failed to execute '$cmd': $!\n";
    }
    elsif ( $error_code & 127 ) {
        _die sprintf "'$cmd' died with signal %d, %s coredump\n%s", ( $error_code & 127 ),
            ( $error_code & 128 ) ? 'with' : 'without', $res;
    }
    if ($DEBUG) {
        _info $cmd;
        _warn "got error code: $error_code"
            if $error_code;
        _info "result: $res";
    }
    chomp($res) if defined $res;
    return ( $res, $error_code >> 8 );
}

#execute a command and return what it output
sub git_result {
    my ( $cmd, @accept )= @_;
    my ( $res, $error_code )= git_cmd($cmd);
    if ( $error_code and !grep { $error_code == $_ } @accept ) {
        _die sprintf "'$cmd' resulted in an unexpected exit code: %d\n%s", $error_code, $res;
    }
    return $res;
}

BEGIN {
my $config_prefix= "deploy";
my %config;

my $config_file;

# _get_config($opts,$setting) # setting is mandatory!
# _get_config($opts,$setting,$default); # setting will default to $default
# $setting may either be a *fully* qualified setting name like "user.name" otherwise
# if $setting does not contain a period it will become "$config_prefix.$setting"
# if $setting _starts_ with a period it will become "$config_prefix.$setting" as well.
# $opts is any additional arguments to feed to git-config
# Note that if the setting "$config_prefix.config-file" is set then we will always
# check it first when looking up values that start with $config_prefix (others we wont bother).

sub _get_config {
    if (!defined $config_file) {
        # on first run we check to see if there is a deploy.config-file specified
        $config_file= ""; # prevent infinite loops
        $config_file= _get_config("--path","$config_prefix.config-file",""); # and now we read this from the normal configs
    }
    my $opts= shift;
    my $setting= shift;
    my $has_default= @_;
    my $default= shift;
    if ( $setting =~ m/^\./ ) {
        $setting= $config_prefix . $setting;
    } elsif ( $setting !~ m/\./ )  {
        $setting= "$config_prefix.$setting";
    }
    unless ( exists $config{$setting}{$opts} ) {
        # If we have a $config_file specified and we are looking for a $config_prefix 
        # config item we will want to look first in the config file, and only then look 
        # in the normal git config files if there is nothing specified in the $config_file. 
        
        CONF_SOURCE:
        foreach my $source (
            ($config_file && $setting=~/^\Q$config_prefix\E\./) 
                ? ("--file $config_file","") 
                : $setting=~/^user\./ 
                    ? ("--global") 
                    : ("") 
        ) {   
            my $cmd= "git config $source --get $opts $setting";
            my ($res,$error_code)= git_cmd($cmd);
        
            if ($error_code == 1) {
                if ($source=~/--file/) { # missing from our config file, but the rest? 
                    next CONF_SOURCE;
                } elsif ($has_default) {
                    $res= $default;
                } else {
                    _die "Missing mandatory config setting $setting";
                }
            } elsif ($error_code == 2) {
                _die "Bad config, multiple entries from $cmd: $res";
            } elsif ($error_code) {
                _die "Got unexpected error code $error_code from $cmd: $res";
            }
            $config{$setting}{$opts}= $res; 
            last;
        }
    }
    return $config{$setting}{$opts};
}

sub get_config_as_hoh {
    my ($file)= shift;
    if ($file) {
        $file= "--file $file" 
    } else {
        $file= "";
    }
    my ($res,$error_code)= git_cmd("git config $file --list -z");
    my %conf;
    foreach my $tuple (split /\0/,$res) {
        my ($option,$value)= split /\n/, $tuple, 2;
        my $node= \%conf;
        my @paths= split /\./, $option;
        my $leaf= pop @paths;
        foreach my $field (@paths) {
            $node->{$field}||={};
            $node= $node->{$field};
        }
        $node->{$leaf}= $value;
    }
    return \%conf;   
}

sub get_config { return _get_config("",@_) }
sub get_config_path { return _get_config("--path",@_) }
sub get_config_int  { return _get_config("--int",@_) }
sub get_config_bool { return 'true' eq _get_config("--bool",@_) } 

}



#execute a command and return its error code
sub git_errcode {
    my ( $cmd, )= @_;
    my ( $res, $error_code )= git_cmd($cmd);
    return $error_code;
}


{    # lexical scope for the definition of locally static variables. Not just static in the sense
        # of C static vars, but also static in the sense the var is not modifiable once defined.
    my @gfer_names= (
        '%(*author)',           '%(*authordate:iso)', '%(*authoremail)',       '%(*authorname)',
        '%(*body)',             '%(*committer)',      '%(*committerdate:iso)', '%(*committeremail)',
        '%(*committername)',    '%(*contents)',       '%(*objectname)',        '%(*parent)',
        '%(*subject)',          '%(*tree)',           '%(author)',             '%(authordate:iso)',
        '%(authoremail)',       '%(authorname)',      '%(body)',               '%(committer)',
        '%(committerdate:iso)', '%(committeremail)',  '%(committername)',      '%(contents)',
        '%(objectname)',        '%(parent)',          '%(refname)',            '%(subject)',
        '%(tag)',               '%(tree)',
    );
    my %gfer_fields= map { $gfer_names[$_] => $_ } 0 .. $#gfer_names;
    my $gfer_format= join( "%01%01%01", @gfer_names ) . "%00%00%00";

    my $ref_info;
    my $ref_info_loaded;

    sub clear_ref_info {
        _info "Clearing ref info\n";
        undef $ref_info;
    }

    sub get_ref_info {

        #my $repo= shift;
        return $ref_info if $ref_info_loaded;
        undef $ref_info;
        _info "reading tag and branch info - this might take a second or two.\n"
            if $DEBUG;

        push_timings("gdt_internal__get_ref_info__git_for_each_ref__start");
        my $start_time= time;
        my $generated_code= `git for-each-ref --format '$gfer_format'`;
        push_timings("gdt_internal__get_ref_info__git_for_each_ref__end");

        my $elapsed= time - $start_time;
        _info "git for-each-ref took $elapsed seconds\n" if $DEBUG;

        #print "git for-each-ref --perl --format '$gfer_format'\n";
        if ( !$generated_code ) {
            _die "No refs were returned from git for-each-ref (which shouldn't be possible)\n";
        }

        _info "processing result\n" if $DEBUG;
        $start_time= time;
        push_timings("gdt_internal__get_ref_info__process_ref_info__start");

        my %ref;
        my %commit;

        # seems gfer adds a newline each record
        foreach my $chunk ( split /\x00\x00\x00\n?/, $generated_code ) {
            my %info;
            @info{@gfer_names}= split /\x01\x01\x01/, $chunk;

            local $_= $info{'%(refname)'};
            ( my $typename= $_ ) =~ s!^refs/!!;
            my %ref_data= (
                commit => $info{'%(*objectname)'} || $info{'%(objectname)'},
                refname  => $info{'%(refname)'},
                typename => $typename, (
                    s!^refs/(heads)/!!
                    ? (
                        refsdir  => $1,
                        category => "branch",
                        type     => "local",
                        barename => $_
                        )
                    : s!^refs/(remotes)/!! ? (
                        refsdir  => $1,
                        category => "branch",
                        type     => "remote",
                        barename => $_
                        )
                    : s!^refs/(tags)/!! ? (
                        refsdir  => $1,
                        category => "tag",
                        $info{'%(tag)'}
                        ? ( type => "object", barename => $info{'%(tag)'} )
                        : ( type => "symbolic", barename => $_ ) )
                    : s!^refs/(stash)!! ? (
                        refsdir  => $1,
                        category => "stash",
                        type     => "stash",
                        barename => $_
                        )
                    : s!^refs/(bisect)!! ? (
                        refsdir  => $1,
                        category => "bisect",
                        type     => "bisect",
                        barename => $_
                        )
                    : _die "Cant parse type from refname: ",
                    Dumper( \%info ) ) );
            my $commitname;
            if ( $ref_data{category} eq "tag" and $ref_data{type} eq "object" ) {
                $ref_data{sha1}= $info{'%(objectname)'};
                $ref_data{message}= {
                    body     => $info{'%(body)'},
                    subject  => $info{'%(subject)'},
                    contents => $info{'%(contents)'} };
                $commitname= $info{'%(*objectname)'};
                $commit{$commitname} ||= {
                    sha1   => $info{'%(*objectname)'},
                    author => {
                        author => $info{'%(*author)'},
                        date   => $info{'%(*authordate:iso)'},
                        email  => $info{'%(*authoremail)'},
                        name   => $info{'%(*authorname)'}
                    },
                    committer => {
                        committer => $info{'%(*committer)'},
                        date      => $info{'%(*committerdate:iso)'},
                        email     => $info{'%(*committeremail)'},
                        name      => $info{'%(*committername)'}
                    },
                    parent  => [ split /\s+/, $info{'%(*parent)'} ],
                    tree    => $info{'%(*tree)'},
                    message => {
                        body     => $info{'%(*body)'},
                        subject  => $info{'%(*subject)'},
                        contents => $info{'%(*contents)'}
                    },
                };
            }
            else {
                $commitname= $info{'%(objectname)'};
                $commit{$commitname} ||= {
                    sha1   => $info{'%(objectname)'},
                    author => {
                        author => $info{'%(author)'},
                        date   => $info{'%(authordate:iso)'},
                        email  => $info{'%(authoremail)'},
                        name   => $info{'%(authorname)'}
                    },
                    committer => {
                        committer => $info{'%(committer)'},
                        date      => $info{'%(committerdate:iso)'},
                        email     => $info{'%(committeremail)'},
                        name      => $info{'%(committername)'}
                    },
                    parent  => [ split /\s+/, $info{'%(parent)'} ],
                    tree    => $info{'%(tree)'},
                    message => {
                        body     => $info{'%(body)'},
                        subject  => $info{'%(subject)'},
                        contents => $info{'%(contents)'}
                    },
                };
            }
            $ref{all}{$typename}= \%ref_data;
            $ref{ $ref_data{category} }{ $ref_data{type} }{ $ref_data{barename} }= \%ref_data;
            push @{ $commit{$commitname}{refs} }, $typename;
        }
        push_timings("gdt_internal__get_ref_info__process_ref_info__end");

        $elapsed= time - $start_time;
        _info "processing ref data took $elapsed seconds\n", "returning from ref_info\n"
            if $DEBUG;
        $ref_info_loaded= 1;
        return $ref_info= { refs => \%ref, commit => \%commit };
    }



    sub _get_name_data {
        my ($name)= @_;
        return if $name eq 'HEAD';
        my $ri= get_ref_info();
        my $all= $ri->{refs}{all};
        return
               $all->{$name}
            || $all->{"tags/$name"}
            || $all->{"heads/$name"}
            || $all->{"remotes/$name"};
    }
}

# $commit_sha1= get_commit_for_name($name)
# $sha1= get_sha1_for_name($name)
#
# These two routines are very similar, and in most cases return the exact same result.
# They differ for tags however. A lightweight tag will return the same commit id for both.
# An annotated tag will return the tag's id for get_sha1_for_name() and will return the
# commit id it points at from get_commit_for_name().  This is one way to distinguish the
# two types of tags (of course there are other ways).
#
#

BEGIN {
    my %name2commit;

    sub get_commit_for_name {
        my ($name)= @_;
        return '' if !$name;
        $name ne 'HEAD'
            and exists $name2commit{$name}
            and return $name2commit{$name};

        if ( my $name_data= _get_name_data($name) ) {
            return $name2commit{$name}= $name_data->{commit};
        }
        else {
            _info "$name not in cache!" if $DEBUG and $name ne 'HEAD';
            my $cmd= qq(git log -1 --pretty="format:%H" $name);
            my $sha1= `$cmd 2>/dev/null`;
            $sha1 ||= '';
            chomp($sha1);
            $name2commit{$name}= $sha1 if $sha1;
            return $sha1;
        }

    }

    my %name2sha1;

    sub get_sha1_for_name {
        my ($name)= @_;
        return '' if !$name;
        $name ne 'HEAD'
            and exists $name2sha1{$name}
            and return $name2sha1{$name};
        if ( my $name_data= _get_name_data($name) ) {
            return $name2commit{$name}= $name_data->{sha1};
        }
        else {
            my $sha1= `git rev-parse $name 2>/dev/null`;
            $sha1 ||= '';
            chomp($sha1);
            $name2sha1{$name}= $sha1 if $sha1;
            return $sha1;
        }
    }
}


# check if a name is an annotated tag.
sub is_name_annotated_tag {
    my ($name)= @_;
    my $name_data= _get_name_data($name);
    return
        unless $name_data->{category} eq 'tag'
            and $name_data->{type} eq 'object';
    return ( $name_data->{commit}, $name_data->{sha1} );
}

my %type;


# returns the tags sorted by their date stamp, with undated tags last alphabetically
# the idea is we want a list where we find a match for head ASAP
sub get_sorted_list_of_tags {
    my $ref_info= get_ref_info();
    my $all_refs= $ref_info->{refs}{all};
    my @tags= map { s!^tags/!!; $_ }
        grep { $all_refs->{$_}{category} eq 'tag' } keys %$all_refs;

    # ST: parse out datestamps first so we can use them as a key to sort by
    @tags= map { $_->[0] }
        sort { $b->[1] cmp $a->[1] || $a->[0] cmp $b->[0] }
        map {
        $type{$_}= 'tag';
        [ $_, m/\D(20\d{6})[_-]?(\d+)?/ ? $1 . ( $2 || '' ) : '' ]
        } @tags;

    return @tags;
}


# list filter to remove names that contain a date tag which is older than a specific date.
#
# my @filtered=filter_names_by_date($date,@list);

sub filter_names_by_date {
    my $ignore_older_than= shift;
    return grep {
        m/\D(20\d{6})[_-]?(\d+)?/    # does it have a date?
            ? ( $1 . ( $2 || '' ) ge $ignore_older_than )    # yes - compare
            : 1;                                             # no - keep
    } @_;
}

# get a list of branches includes remote tracking branches as well as local.

sub get_branches {
    return map {
        chomp;
        s/^\s*(?:\*\s*)?//;
        if ( $_ ne '(no branch)' ) {
            $type{$_}= "branch";
            $_;
        }
        else {
            ();
        }
    } `git branch -a`;
}

# find the current branch
# returns an empty list/undef if no branch found
# returns the empty string if the current branch is reported as '(no branch)'
sub get_current_branch {
    for (`git branch`) {
        chomp;
        if ( $_ =~ s/^\s*\*\s*// ) {
            return $_ ne '(no branch)' ? $_ : '';
        }
    }
    return undef;
}



sub what_branches_can_reach_head {
    my $head= get_commit_for_name("HEAD");
    my %special= (
        'trunk'         => 1,
        'master'        => 2,
        'origin/trunk'  => 3,
        'origin/master' => 4,
    );
    my @branch=
        sort { ( $special{$a} || 100 ) <=> ( $special{$b} || 100 ) || $a cmp $b }
        grep { $_ ne "(no branch)" } map {
        chomp;
        s/^\s*(?:\*\s*)?//;
        $_;
        } `git branch -a --contains HEAD`;
    return wantarray ? @branch : $branch[0];
}



# filter through a list of items finding either the first or all
# items, (as controlled via $find_all).
#
# my @match_head= filter_names_matching_head($find_all, @names);

sub filter_names_matching_head {
    my $find_all= shift;
    $find_all= "" if $find_all and $find_all eq 'first';

    # get the currently checked out commit sha1
    my $head_sha1= get_commit_for_name('HEAD');

    # now loop through the tags to find a match
    my @matched_names;
    foreach my $name (@_) {
        my $sha1= get_commit_for_name($name);

        # check if the sha1 is the same as HEAD
        next unless $sha1 eq $head_sha1;

        # either return a singleton,
        return $name unless $find_all;

        # or gether the results in a list for later return
        push @matched_names, $name;

    }

    return @matched_names;
}


# find tags that match head,
#
# my $tag= find_tags_matching_head();
# my @tags= find_tags_matching_head('list');

sub find_tags_matching_head {
    my ($list)= @_;

    # report on existing tags
    return filter_names_matching_head( $list, get_sorted_list_of_tags() );
}

# find refs that match head,
#
# my $ref= find_refs_matching_head();
# my @refs= find_refs_matching_head('list');
#
# note this prefers tags over branches in the scalar form.

sub find_refs_matching_head {
    my ($list)= @_;

    # report on existing tags
    return filter_names_matching_head( $list, get_sorted_list_of_tags(), get_branches, );
}



# verify that the working directory is clean. If it is not clean returns the status output.
# if it is clean returns nothing.
sub check_if_working_dir_is_clean {
    push_timings("gdt_internal__git_status__start");
    my $status= `git status`;
    push_timings("gdt_internal__git_status__end");
    return if $status =~ /\(working directory clean\)/;
    return $status;
}

# make_tag($name,@message);
#
# @message will be in place modified such that %TAG is replaced by the
# new tagname.
#
# returns the new tagname.
#
sub make_tag {
    my $tag_name= shift;

    #my @message= @_; # except that we actually modify @_ in place

    _die "\$tag_name not optional in 'make_tag'\n"
        if !$tag_name;
    _die "\$message not optional in 'make_tag'\n"
        if !@_;

    # It is possible that rollback and rollout tags collide,
    # at least while testing the script. So we play some suffix
    # games to make them unique. It's unlikely to ever happen in
    # practice as there is always a non trivial amount of time between
    # the two steps.
    if ( get_commit_for_name($tag_name) ) {
        my $suffix= "A";
        while ( get_commit_for_name( $tag_name . "_" . $suffix ) ) {
            $suffix++;
        }
        $tag_name .= "_$suffix";
    }

    # the space after the -m is *required* on cyan
    my $message_opt= join " ", map { s/%TAG/$tag_name/g; "-m '$_'" } @_;

    #my $cmd= "git tag $message_opt $tag_name";
    my $cmd= "git tag $message_opt $tag_name";
    my $error= `$cmd 2>&1`;
    _die "failed to create tag $tag_name\n$error"
        if $error;
    _info "created tag '$tag_name'\n" if $VERBOSE;
    clear_ref_info();    # spoil the tag info cache
    return $tag_name;
}


# make_dated_tag($prefix,$date_fmt,@message);
#
# @message will be in place modified such that %TAG is replaced by the
# new tagname.
#
# returns the new tagname.
#
sub make_dated_tag {
    my $prefix= shift;
    my $date_fmt= shift;

    #my @message= @_; # except that we actually modify @_ in place
    my $date= strftime $date_fmt, localtime;
    my $tag_name= "$prefix-$date";
    return make_tag( $tag_name, @_ );
}

# preform an action against a remote site.
sub remote {
    my ( $action, $remote_site, $remote_branch )= @_;
    push_timings("gdt_internal__remote__action_${action}__start");
    if ( !$remote_site ) {
        _info "Note: not performing $action, as it is disabled\n";
    }
    return if !$remote_site or $remote_site eq 'none';

    #$remote_branch ||= get_current_branch()
    #    or _die "Not on a branch currently!"
    #    if !$remote_branch and defined $remote_branch;
    $remote_branch ||= '';
    my $cmd= "git $action $remote_site $remote_branch";
    _info "$cmd", $action =~ /pull/ ? "" : "\n(not updating working directory)\n", "\n"
        if $VERBOSE;
    my ( $res, $error )= git_cmd($cmd);
    my $name= "$remote_site" . ( $remote_branch ? ":$remote_branch" : "" );

    # if there is nothing new to fetch then we get error code 1, which does not
    # really mean an error, so we will just pretend it is not.
    if ( $action =~ /fetch/ and $error == 1 ) {
        _info "got exit code 1 - nothing to fetch\n" if $VERBOSE;
        $error= 0;
    }

    _die "failed to git $action from '$name' errorcode: $error\n$cmd\n$res\n"
        if $error;
    _info "$res", "\n" if $VERBOSE and $res;
    push_timings("gdt_internal__remote__action_${action}__end");
}

# fetch tags from a remote site
sub fetch_tags {
    my ( $remote_site )= @_;
    remote( "fetch --tags", $remote_site, undef );
}


# push tags to a remote site
sub push_tags {
    my ( $remote_site )= @_;
    remote( "push --tags", $remote_site, undef );
}

sub push_tag {
    my ( $remote_site, $tag )= @_;
    remote( "push", $remote_site, $tag );
}

# push tags and all references to a remote site.
sub push_all {
    my ( $remote_site )= @_;
    remote( "push --tags --all", $remote_site, undef );
}

# fetch a branch from a remote site.
sub fetch {
    my ( $remote_site, $remote_branch )= @_;
    remote( "fetch", $remote_site, $remote_branch );
}

# pull a branch from a remote site.
sub pull {
    my ( $remote_site, $remote_branch )= @_;
    remote( "pull", $remote_site, $remote_branch );
}

# push a branch to a remote site.
sub push_remote {
    my ( $remote_site, $remote_branch )= @_;
    remote( "push", $remote_site, $remote_branch );
}


# take a list of references and print them out in a formatted way.
# Currently the list is
#
# SHA1 *TYPE: NAME #NAME
# where the * may be a star or space and indicates that the ref points at HEAD,
# and the #NAME is optional, and points at the most recent tag with the same SHA1

sub print_refs {
    my $opts= shift;
    my $array= shift;
    my $head= get_commit_for_name('HEAD')
        or _die "panic: no sha1 for HEAD?! wtf!";
    if ( !$opts->{list} ) {
        return if !@$array;
        print shift @$array;
        print "\n" if -t STDOUT;
        return;
    }
    my %seen_sha1;
    my $start= time;
    foreach my $name ( reverse @$array ) {
        if ( !ref $name ) {
            my $sha1= get_commit_for_name($name);
            push @{$seen_sha1{$sha1}}, $name
		if !$seen_sha1{$sha1} or (!$opts->{prefix} or $name=~/^$opts->{prefix}/);
        }
    }
    my $elapsed= time - $start;
    _info "First loop took $elapsed seconds\n" if $DEBUG;
    my $count= 0;
    my $filtered= 0;
    $start= time;

    _info "Filtering list by m/^$opts->{prefix}/"
        . (
        $opts->{prefix} eq '.'
        ? "\n"
        : " (use `git-deploy show .` to see all).\n"
        ) if $opts->{prefix} and !$opts->{tag_only};
    _info "SHA1........  tag: PREFIX-YYYYMMDD-HHMM == Original rollout of same sha1\n"
        if !$opts->{tag_only};
    _info "Tags against active commit are marked with a '"
          . color(COLOR_WARN) . "*" . color('reset') . color(COLOR_INFO)
          . "' and are "
          . color(COLOR_WARN) . "highlighted" . color('reset') . color(COLOR_INFO)
          . " differently\n"
        if !$opts->{tag_only};

    my @printed;

    my $last_sha1= "";
    foreach my $name_idx (0..$#$array) {
	my $name= $array->[$name_idx];
        next if ref $name;
        ++$filtered and next
            if $opts->{prefix} and $name !~ m/^$opts->{prefix}/;
        last if $opts->{count} and $opts->{count} < ++$count;

	my $next_name= $array->[ $name_idx + 1 ];
	my $next_sha1= $next_name ? get_commit_for_name($next_name) : "";
        my $sha1= get_commit_for_name($name);

        if ( $opts->{tag_only} ) {
            _print $name, ( $opts->{action} && $opts->{action} eq 'showtag' ) ? "" : "\n";
            push @printed, $name;
        }
        else {
            if ( $opts->{for_interactive} ) {
                # next if $sha1 eq $head;
                push @printed, $name;
            }
	    my $tags_for_commit= $seen_sha1{$sha1};
	    pop @$tags_for_commit;

            _printf "%s%s%s %1s%s: %-25s%s%s%s\n",
                @printed ? sprintf( "%4d.\t", 0 + @printed ) : "",
                color( $sha1 eq $head ? COLOR_WARN : COLOR_SAY ),
                $opts->{long_digest} ? $sha1 : substr( $sha1, 0, 12 ) . "..",
                $sha1 eq $head ? "*" : " ",
                $type{$name},
                $name,
                @$tags_for_commit ? " ==\t" . join("\t",reverse @$tags_for_commit) : '',
		#$last_sha1 eq $next_sha1 ? " ***PROBABLY BAD***" : # XXX this doesnt work so leave it disabled for now
		"",
                color('reset'),
                ;
	    $last_sha1= $sha1;
        }
    }
    if ( @$array and @$array > $count ) {
        my $filtered_str= $filtered ? " ($filtered filtered)" : "";
        my $showing_str=
            ( $opts->{count} && $opts->{count} < ( @$array - $filtered ) )
            ? "Showing first $opts->{count}, "
            : "";
        _info "$showing_str", @$array - $count, " of ", 0 + @$array,
            " not shown$filtered_str. Use --count=N or different filter to show more (N=0 shows all)\n"
            if !$opts->{tag_only};
    }
    $elapsed= time - $start;
    _info "Second loop took $elapsed seconds\n" if $DEBUG;
    _warn "No tags match HEAD\n" if !@$array and !$opts->{tag_only};
    return @printed;
}




sub get_deploy_file_name {
    my ($file)= @_;
    $file ||= get_config("deploy-file",".deploy");
    return $file;
}


# Write a deploy file about what has been deployed. 
# This should be available to be parsed by the code being deployed to know where it came from
#
sub write_deploy_file {
    my ( $tag, $message, $file )= @_;

    $file= get_deploy_file_name($file);

    my $sha1= get_commit_for_name($tag)
        or _die "panic: no sha1 for tag '$tag'!";
    open my $out, ">", $file
        or _die "Failed to open deploy file '$file' for write: $!";

    my $text= join "",
        "commit: $sha1\n",
        "tag: $tag\n",
        "deploy-date: " . strftime( "%Y-%m-%d %H:%M:%S", localtime ) . "\n",
        "deployed-from: " . hostname() . "\n",
        "deployed-by: " . $ENV{USER} . "\n",
        ( $message && @$message ) ? join( "\n", "", @$message, "", "" ) : "\n",
        ;

    print $out $text
        or _die "panic: failed to write to deploy file handle for '$file': $!";
    close $out
        or _die "panic: failed to close deploy file handle for '$file': $!";
    _info "wrote deploy file '$file'\n" if $VERBOSE;
    $text;
}

# read the deploy file
# Unless $skip_check is true we will verify that the .deploy file corresponds to HEAD
# If things are good we return the files contents as a string.
# If there are any problems we return the empty string (not undef!)



sub read_deploy_file {
    my ( $file, $skip_check )= @_;
    $file= get_deploy_file_name($file);
    return "" unless $file and -e $file;

    my $deploy_file_text= _slurp($file);
    $deploy_file_text ||= "";

    my $sha1= $deploy_file_text =~ /^commit: ([a-f0-9]{40})\n/ ? $1 : undef;
    return ""
        if !$skip_check
            and ( !defined $sha1 or $sha1 ne get_commit_for_name('HEAD') );
    return $deploy_file_text;
}

sub _slurp {
    my ($file_like,$no_die)= @_;
    my $fh;
    if ( !ref $file_like ) {
        if (!open $fh, "<", $file_like) {
            if ($no_die) {
                return "";
            } else {
                _die "Failed to read '$file_like': $!";
            }
        }
    }
    else {
        $fh= $file_like;
    }
    if (wantarray) {
        my @lines= <$fh>;
        return @lines;
    }
    else {
        local $/;
        return <$fh>;
    }
}

BEGIN {

    # This block contains the logic necessary to manage an advisory locking scheme,
    # enforce a particular sequence of steps, as well as cross process storage of
    # necessary reference data like the rollout status.
    # One thing to keep in mind is that the tool is going to invoked multiple times
    # with differing steps in between.

    # The basic idea is we maintain a "lock" file whose presence tells others that
    # they cannot do a rollout, and whose contents can be used to ensure a specific
    # order of actions is followed, and which can be used as an advisory to others
    # about the status, who is performing it and etc.
    my $lockdirname= "deploy";
    my $lockfilename= "lock";

    # additonally we maintain a file per rollout and rollback tag
    # these files only existing during a rollout and are erased afterwards
    my @tag_file_names= qw(rollout rollback);

    # utility sub, returns the lock_directory and the lockfilename for other subs
    # with some standard checking.
    sub _rollout_lock_dir_and_file {
        _die "panic: directory '$gitdir' must exist for a rollout lock step to occur"
            if !-d $gitdir;
        my $lock_dir= "$gitdir/$lockdirname";
        return ( $lock_dir, "$lock_dir/$lockfilename" );
    }


    # write the details of a tag into a file so it can be accessed by a later
    # step of the process
    sub store_tag_info {
        my ( $type, $tag )= @_;

        _die "Bad type '$type'"
            unless grep { $type eq $_ } @tag_file_names;

        my ($lock_dir)= _rollout_lock_dir_and_file();
        open my $out_fh, ">", "$lock_dir/$type"
            or _die "Failed to open '$lock_dir/$type' for writing: $!";
        my $sha1= get_commit_for_name($tag)
            or _die "Invalid tag!";
        print $out_fh "$sha1 $tag";
        close $out_fh;
    }


    # fetch the details about a tag from the file
    sub fetch_tag_info {
        my ( $type )= @_;

        _die "Bad type '$type'"
            unless grep { $type eq $_ } @tag_file_names;

        my ($lock_dir)= _rollout_lock_dir_and_file();
        my $tag_info= _slurp("$lock_dir/$type","no-die");
        my ( $sha1, $tag )= split /\s+/, $tag_info;

        # validate tag is matches the sha1 as a crude sanity check
        return $tag if $tag and $sha1 and $sha1 eq get_commit_for_name($tag);
        return "";
    }




    # read the rollout status file takes the gitdir as an argument
    sub read_rollout_status {
        my ( $lock_dir, $lock_file )= _rollout_lock_dir_and_file();
        return "" if !-d $lock_dir;
        return "" if !-e $lock_file;
        unless (wantarray) {
            my $content= _slurp($lock_file);
            return $content;
        }
        else {
            my @content= _slurp($lock_file);
            return @content;
        }
    }

    # read the rollout status file and parses it into hashes.
    # in list context returns a list of hashes, in scalar context
    # returns an AoH.
    sub parse_rollout_status {
        my @lines= map {
            chomp;
            my %hash;
            @hash{qw(action time branch sha1 uid username)}= split /\t/, $_;
            $hash{branch}= "" if $hash{branch} eq '(no branch)';
            $hash{action} =~ s/:\z//;
            \%hash
        } read_rollout_status(@_);
        return wantarray ? @lines : \@lines;
    }



    # write_rollout_status($dir,$status,$force,$other_checks)
    #
    # $dir is the directory to write the file to, a string.
    # $status is the type of action we are performing, 'start','sync','finish','rollback'
    # $force is a flag that overrides the security checks
    # $other_checks is a code ref of other checks that should be performed prior to creating
    # the file, it should die if the step should not proceed.
    #
    # returns nothing, dies if the status file cannot be created or updated properly or if any
    # of the necessary preconditions are not satisfied.
    #
    # Note this is called before we create a tag.
    # so we do not know the tagname that will be used for the step at the time
    # we write the data out, and thus cant include it in the file.
    #
    sub write_rollout_status {
        my $status= shift;
        my $force= shift;
        my $other_checks= shift;

        my ( $lock_dir, $lock_file )= _rollout_lock_dir_and_file();

        my ( $opened_ok, $out_fh, @file );

        my $somethings_wrong=
            $force
            ? sub { 0 }
            : sub {
            my $first_line= shift || "It looks like somethings wrong:";
            my $last_line= shift;
            $first_line =~ s/\n+\z//;

            #$first_line .= ":" if $fl !~ /:\z/;

            _die join "\n", $first_line, @file ? "Log:\n\t" . join( "\t", @file ) : (), $last_line ? $last_line : (),
                "";
            };

        if ( $status eq 'start' ) {
            my $sysadmin_lock= get_config_path('block-file','');
            if ($sysadmin_lock and -e $sysadmin_lock) {
                my $msg= _slurp($sysadmin_lock);
                _die "Sysadmin rollout lockfile '$sysadmin_lock' is preventing this rollout\n"
                   . $msg;
            }
            mkdir $lock_dir
                or do {
                my $message= "You may not start a new rollout as it looks like one is already in progress!\n"
                    . "Failed to create lock dir '$lock_dir' because '$!'\n";
                @file= _slurp($lock_file);
                $somethings_wrong->($message) if @file;
                };
            $opened_ok= sysopen( $out_fh, $lock_file, O_WRONLY | O_EXCL | O_CREAT )
                or do {
                my $message= "Can't start a new rollout, one is already in progress\n"
                    . "Failed to create lock file '$lock_file' because '$!'\n";
                @file= _slurp($lock_file);
                $somethings_wrong->($message);
                };
        }
        elsif ( !-d $lock_dir ) {
            _die "It looks like you havent started yet!\n";
        }
        elsif ( $opened_ok= sysopen( $out_fh, $lock_file, O_RDWR ) ) {
            @file= _slurp($out_fh);
            if ( @file == 3 ) {
                $somethings_wrong->(
                    "It looks like someone is just finishing a rollout",
                    "Wait a minute or two and retry."
                );
            }
            if ( !@file ) {
                _die "It looks like you havent started yet!\n";
            }
            if ( !$file[0] or $file[0] !~ /^start:/ or @file > 2 ) {
                $somethings_wrong->();
            }
            if ( $status eq 'sync' and @file != 1 ) {
                $somethings_wrong->("It looks like maybe you already synced");
            }
            if ( $status eq 'finish' ) {
                if ( @file == 1 ) {
                    $somethings_wrong->("It looks like maybe you havent synced yet");
                }
                elsif ( @file == 2 and $file[1] !~ /^(sync|release|manual-sync):/ ) {
                    $somethings_wrong->("Can't $status in the current state:");
                }
            }
            if ( $status eq 'finnish' ) {
                $somethings_wrong->("git-deploy ole saatavilla suomeksi! (maybe you meant 'finish' instead?)");
            }
            if ( $status eq 'rollback' ) {
                if ( @file == 2 and $file[1] !~ /^(sync|release|manual-sync):/ ) {
                    $somethings_wrong->("Can't $status in the current state:");
                }
            }
            if ( $file[0] !~ /\t\Q$ENV{USER}\E$/ ) {
                $somethings_wrong->("Someone else is doing a rollout. You cannot proceed.");
            }
        }
        if ( !$opened_ok ) {
            _die "Failed to open lockfile '$lock_file': $!\n"
                . "There is a good chance this means someone is already rolling out.";
        }
        flock( $out_fh, LOCK_EX | LOCK_NB )
            or _die "Failed to lock file:$!\nSomebody already rolling out?\n";
        $other_checks->();
        my $status_line= join(
            "\t",
            "$status:",    # must be first
            strftime( "%Y-%m-%d %H:%M:%S", localtime() ),
            get_current_branch() || '(no branch)',
            get_commit_for_name('HEAD'),
            $<,
            $ENV{USER}     # must be last
            ).
            "\n";
        _log($status_line);
        print $out_fh $status_line
            or _die "panic: failed to print to deployment status lock file: $!";
        close $out_fh
            or _die "panic: failed to close deployment status lock file: $!";

    }


    sub unlink_rollout_status_file {
        my ( $lock_dir, $lock_file )= _rollout_lock_dir_and_file();

        for my $type (@tag_file_names) {
            if ( -e "$lock_dir/$type" ) {
                unlink "$lock_dir/$type"
                    or _die "Failed to delete '$lock_dir/$type':$!";
            }
        }
        unlink $lock_file
            or _die "Failed to delete '$lock_file':$!";
        if ( -e "$lock_file~" ) {
            unlink $lock_file
                or _die "Failed to delete '$lock_file~':$!";
        }
        rmdir $lock_dir
            or _die "Failed to rmdir '$lock_dir':$!";
        _info "Removed rollout status locks\n" if $VERBOSE > 1;
    }
}


sub check_for_unpushed_commits {
    my ( $remote_site, $remote_branch, $force )= @_;
    push_timings("gdt_internal__check_for_unpushed_commits__start");
    $remote_branch ||= get_current_branch();

    #print "git cherry $remote_site/$remote_branch\n";# if $DEBUG;
    my @cherry= grep { /[0-9a-f]/ } `git cherry $remote_site/$remote_branch`;
    if (@cherry) {
        _warn "It looks like there are unpushed commits.\n",
            "Most likely this is harmless and you should just\n",
            "\tgit push\n",
            "and then continue with the deployment but you should review the following...\n";
        foreach my $cherry (@cherry) {
            chomp $cherry;
            my ( $type, $sha1 )= split /\s/, $cherry;
            if ( $type eq '-' ) {
                _warn "This commit appears to already be applied upstream:\n";
            }
            else {
                _warn "Unpushed commit:\n";
            }
            print `git log -1 $sha1`;
        }
    }
    push_timings("gdt_internal__check_for_unpushed_commits__end");
    _die "Will not proceed.\n" if @cherry and !$force;
    return 0;
}


sub rollback_to_name {
    my ( $name, $prefix )= @_;
    my ($rbinfo)= parse_rollout_status();
    push_timings("gdt_internal__rollback_to_name__start");
    my @cmd;
    my $cur_branch= get_current_branch();
    if ( $rbinfo->{branch} ne $cur_branch ) {
        _say "Will switch branch back to '$rbinfo->{branch}' from the current branch '$cur_branch'\n";
        push @cmd, [ "git reset --hard", qr/^HEAD is now at /m ];
        push @cmd, [ "git checkout $rbinfo->{branch}", qr/^Switched to branch /m ];
    }
    push @cmd, [ "git reset --hard $name", qr/^HEAD is now at /m ];
    push @cmd, [ "git checkout -f", '' ]; # we do this to guarantee that we execute git-hooks
    foreach my $tuple (@cmd) {
        my ( $cmd, $expect )= @$tuple;
        _info "$cmd\n" if $VERBOSE and $VERBOSE > 1;
        my $result= `$cmd 2>&1`;
        _die "command '$cmd' failed to produce expected output: $result"
            if $expect and $result !~ m/$expect/;
        _info "$result\n" if $expect and $VERBOSE and $VERBOSE > 1;
    }
    _say "Rolled back to '$name' succesfully\n";

    execute_deploy_hooks(
        phase   => $_,
        prefix  => $prefix,

        # We don't want the rollback to fail just because the
        # webserver didn't restart or something. This will warn if
        # the hooks fail, but will continue.
        ignore_exit_code => 1,
    ) for qw(post-tree-update post-rollback);

    push_timings("gdt_internal__rollback_to_name__end");
    return;
}


{
    my $root;

    sub get_hook_dir {
        my ( $prefix )= @_;
        return $root if defined $root;

        $root = get_config_path('hook-dir',undef);

        if ($SKIP_HOOKS) {
            $root= "";
            _warn "ALL HOOKS HAVE BEEN DISABLED.\n";
        }
        if ( not $root or not -e $root ) {
            $root= "";
            _info "Note: no deploy directory found. Directory '$root' does not exist\n"
                if $VERBOSE and $VERBOSE > 1;
            return;
        }
        else {
            _info "Note: Checking for hooks in '$root'\n"
                if $VERBOSE and $VERBOSE > 1;
        }
        return $root;
    }
}


sub get_hook {
    my ( $hook_name, $prefix )= @_;
    my $root= get_hook_dir( $prefix )
        or return;
    my $file= "$root/$hook_name/$prefix.$hook_name";
    return unless -e $file;
    if ( -x $file ) {
        return $file;
    }
    else {
        _warn "Found a $hook_name hook for '$prefix': '$file' however it is not executable! Ignoring!\n";
    }
    return;
}

sub get_sync_hook { return get_hook( "sync", @_ ) }


sub execute_hook {
    my ($cmd, $ignore_exit_code)= @_;

    my ($file)= $cmd =~ m/([^\/]+)$/;

    push_timings("gdt_internal__execute_hook__${file}__start");
    system("$cmd 2>&1");
    if ( $? == -1 ) {
        my $msg = "failed to execute '$cmd': $!\n";
        $ignore_exit_code ? _warn $msg : _die $msg;
    }
    elsif ( $? & 127 ) {
        my $msg = sprintf "'$cmd' _died with signal %d, %s coredump\n", ( $? & 127 ), ( $? & 128 ) ? 'with' : 'without';
        $ignore_exit_code ? _warn $msg : _die $msg;
    }
    elsif ( $? >> 8 ) {
        my $msg = sprintf "error: '$cmd' exited with value %d\n", $? >> 8;
        $ignore_exit_code ? _warn $msg : _die $msg;
    }
    push_timings("gdt_internal__execute_hook__${file}__end");
    return 1;
}

sub process_deploy_hooks {
    my ( $hook_dir, $appname, $phase, $ignore_exit_code )= @_;
    _info "Checking for '$phase' hooks for '$appname' ",
        $appname eq 'common' ? '(generic hooks)' : '(appliction specific)', "\n"
        if $VERBOSE > 1;

    my $appdir= "$hook_dir/apps/$appname";
    my @checks= sort glob "$appdir/$phase.*";
    if ( !@checks ) {
        _info "No '$phase' hooks found '$appdir' ", -e $appdir ? "is empty." : "does not exist.", "\n" if $DEBUG;
        return;
    }
    else {
        _info "Found ", 0 + @checks, " '$phase' hooks to execute in '$appdir'\n" if $DEBUG;
    }

    push_timings("gdt_internal__process_deploy_hooks__phase_${phase}__start");
    foreach my $spec (@checks) {
        my $cmd= "";
        unless ( -x $spec ) {
            _warn "Deploy hook '$spec' is not executable! IGNORING!\n";
            next;
        }
        $cmd= $spec;
        _info "Executing $phase hook: $cmd";
        execute_hook($cmd, $ignore_exit_code);
    }
    push_timings("gdt_internal__process_deploy_hooks__phase_${phase}__end");
    _info "All '$phase' checks for '$appname' were successful\n" if $DEBUG;
}

sub execute_deploy_hooks {
    my (%args) = @_;

    my $phase            = $args{phase}            || _die "Missing phase argument";
    my $prefix           = $args{prefix}           || _die "Missing prefix argument";
    my $ignore_exit_code = $args{ignore_exit_code} || 0;

    my $root= get_hook_dir( $prefix )
        or return;

    local $ENV{GIT_DEPLOYTOOL_PHASE}  = $phase;
    local $ENV{GIT_DEPLOY_PHASE}      = $phase;

    # the common 'app' is executed for everyone
    local $ENV{GIT_DEPLOYTOOL_HOOK_PREFIX} = 'common';
    local $ENV{GIT_DEPLOY_HOOK_PREFIX}     = 'common';
    process_deploy_hooks( $root, "common", $phase, $ignore_exit_code );

    # and then the 'app' specific stuff as determined by $prefix
    local $ENV{GIT_DEPLOYTOOL_HOOK_PREFIX} = $prefix;
    local $ENV{GIT_DEPLOY_HOOK_PREFIX}     = $prefix;
    process_deploy_hooks( $root, $prefix, $phase, $ignore_exit_code );
}

1;
