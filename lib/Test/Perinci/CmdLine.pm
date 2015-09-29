package Test::Perinci::CmdLine;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;
use Devel::Confess;

use App::GenPericmdScript qw(gen_pericmd_script);
use Capture::Tiny qw(capture);
use Data::Dumper;
use File::Path qw(remove_tree);
use File::Slurper qw(read_text write_text);
use File::Temp qw(tempdir tempfile);
use IPC::System::Options qw(system);

use Test::More 0.98;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(pericmd_ok);

our %SPEC;

my %common_args = (
    class => {
        summary => 'Which Perinci::CmdLine class are we testing',
        schema => ['str*', in=>[
            'Perinci::CmdLine::Lite',
            'Perinci::CmdLine::Classic',
            'Perinci::CmdLine::Inline',
        ]],
        req => 1,
    },
    include_tags => {
        schema => ['array*', of=>'str*'],
    },
    exclude_tags => {
        schema => ['array*', of=>'str*'],
    },
);

sub _dump {
    local $Data::Dumper::Deparse = 1;
    local $Data::Dumper::Terse   = 1;
    local $Data::Dumper::Indent  = 0;
    Data::Dumper::Dumper($_[0]);
}

$SPEC{run_test_groups} = {
    v => 1.1,
    summary => 'Run groups of Perinci::CmdLine tests',
    args => {
        %common_args,
        tempdir => {
            schema => 'str*',
            description => <<'_',

If not specified, will create temporary directory with `tempdir()`.

_
        },
        groups => {
            schema => ['array*'],
            req => 1,
        },
    },
};
sub run_test_groups {
    my %args = @_;

    my $class   = $args{class};

    my $should_cleanup_tempdir = 0;
    my $tempdir = $args{tempdir} // do {
        $should_cleanup_tempdir++;
        tempdir();
    };

    my $include_tags = $args{include_tags} // do {
        if (defined $ENV{TEST_PERICMD_INCLUDE_TAGS}) {
            [split /,/, $ENV{TEST_PERICMD_INCLUDE_TAGS}];
        } else {
            undef;
        }
    };
    my $exclude_tags = $args{exclude_tags} // do {
        if (defined $ENV{TEST_PERICMD_EXCLUDE_TAGS}) {
            [split /,/, $ENV{TEST_PERICMD_EXCLUDE_TAGS}];
        } else {
            undef;
        }
    };

    # create a pericmd script, run it, test the result
    my $test_cli = sub {
        use experimental 'smartmatch';
        no strict 'refs';
        no warnings 'redefine';

        my %test_args = @_;

        my $name = $test_args{name} // join(" ", @{$test_args{argv} // []});

        subtest $name => sub {
            my $tags = $test_args{tags} // [];

            if ($include_tags) {
                my $found;
                for (@$tags) {
                    if ($_ ~~ @$include_tags) {
                        $found++; last;
                    }
                }
                unless ($found) {
                    plan skip_all => 'Does not have any of the '.
                        'include_tag(s): ['. join(", ", @$include_tags) . ']';
                    return;
                }
            }
            if ($exclude_tags) {
                for (@$tags) {
                    if ($_ ~~ @$exclude_tags) {
                        plan skip_all => "Has one of the exclude_tag: $_";
                        return;
                    }
                }
            }

            my %gen_args;

            $gen_args{cmdline} = $class;

            if ($test_args{gen_args}) {
                $gen_args{$_} = $test_args{gen_args}{$_}
                    for keys %{$test_args{gen_args}};
            }
            if ($class eq 'Perinci::CmdLine::Lite' &&
                    $test_args{lite_gen_args}) {
                $gen_args{$_} = $test_args{lite_gen_args}{$_}
                    for keys %{$test_args{lite_gen_args}};
            }
            if ($class eq 'Perinci::CmdLine::Classic' &&
                    $test_args{classic_gen_args}) {
                $gen_args{$_} = $test_args{classic_gen_args}{$_}
                    for keys %{$test_args{classic_gen_args}};
            }
            if ($class eq 'Perinci::CmdLine::Inline' &&
                    $test_args{inline_gen_args}) {
                $gen_args{$_} = $test_args{inline_gen_args}{$_}
                    for keys %{$test_args{inline_gen_args}};
            }

            $gen_args{read_config} //= 0;
            $gen_args{read_env} //= 0;

            my ($fh, $filename) = tempfile('cliXXXXXXXX', DIR=>$tempdir);
            $gen_args{output_file} = $filename;
            $gen_args{overwrite} = 1;
            my $gen_res = gen_pericmd_script(%gen_args);
            die "Can't generate CLI script at $filename: ".
                "$gen_res->[0] - $gen_res->[1]" unless $gen_res->[0] == 200;
            note "Generated CLI script at $filename";

            my $stdout;
            my $stderr;
            my $res;
            system(
                {shell=>0, die=>0, log=>1,
                 ((env=>$test_args{env}) x !!$test_args{env}),
                 capture_stdout=>\$stdout, capture_stderr=>\$stderr, lang=>'C'},
                $^X,
                # pericmd-inline script must work with only core modules
                ($class eq 'Perinci::CmdLine::Inline' ?
                     ("-Mlib::filter=allow_noncore,0".
                      ($test_args{inline_allow} ? ",allow=".
                       join(";",@{$test_args{inline_allow}}) : "")) : ()),
                $filename,
                @{ $test_args{argv} // []},
            );
            note "Script's stdout: <$stdout>";
            note "Script's stderr: <$stderr>";
            my $exit_code = $? >> 8;

            if (defined $test_args{exit_code}) {
                is($exit_code, $test_args{exit_code}, "exit_code") or do {
                    diag "Script's stdout: <$stdout>";
                    diag "Script's stderr: <$stderr>";
                };
            }
            if ($test_args{stdout_like}) {
                like($stdout, $test_args{stdout_like}, "stdout_like");
            }
            if ($test_args{stdout_unlike}) {
                unlike($stdout, $test_args{stdout_unlike}, "stdout_unlike");
            }
            if ($test_args{stderr_like}) {
                like($stderr, $test_args{stderr_like}, "stderr_like");
            }
            if ($test_args{stderr_unlike}) {
                unlike($stderr, $test_args{stderr_unlike}, "stderr_unlike");
            }
            if ($test_args{posttest}) {
                $test_args{posttest}->($exit_code, $stdout, $stderr);
            }
        }; # subtest
    }; # test_cli

    my $test_cli_completion = sub {
        my %test_args = @_;

        my $comp_line = delete($test_args{comp_line0});
        my $answer = delete($test_args{answer});

        my $comp_point;
        if (($comp_point = index($comp_line, '^')) >= 0) {
            $comp_line =~ s/\^//;
        } else {
            $comp_point = length($comp_line);
        }

        $test_cli->(
            %test_args,
            tags => [@{$test_args{tags} // []}, 'completion'],
            env => {
                COMP_LINE  => $comp_line,
                COMP_POINT => $comp_point,
            },
            posttest => sub {
                my ($exit_code, $stdout, $stderr) = @_;
                my @answer = split /^/m, $stdout;
                for (@answer) {
                    chomp;
                    s/\\(.)/$1/g;
                }
                if ($answer) {
                    is_deeply(\@answer, $answer, 'answer')
                        or diag explain \@answer;
                }
            },
        );
    };

    for my $group (@{ $args{groups} }) {
        subtest $group->{name} => sub {
            ok 1, "dummy"; # just to avoid no tests being run if all excluded by tags
            for my $test (@{ $group->{tests} // [] }) {
                $test_cli->(%$test);
            }
            for my $test (@{ $group->{completion_tests} // [] }) {
                $test_cli_completion->(%$test);
            }
        } # group subtest
    } # for group

    if ($should_cleanup_tempdir) {
        if (!Test::More->builder->is_passing) {
            diag "there are failing tests, not deleting tempdir $tempdir";
        } elsif ($ENV{DEBUG}) {
            diag "DEBUG is true, not deleting tempdir $tempdir";
        } else {
            note "all tests successful, deleting tempdir $tempdir";
            remove_tree($tempdir);
        }
    }
}

$SPEC{pericmd_ok} = {
    v => 1.1,
    summary => 'Common test suite for Perinci::CmdLine::{Lite,Classic,Inline}',
    args => {
        %common_args,
    },
};
sub pericmd_ok {
    my %suite_args = @_;

    my $code_embed = q!
our %SPEC;
$SPEC{square} = {v=>1.1, args=>{num=>{schema=>'num*', req=>1, pos=>0}}};
sub square { my %args=@_; [200, "OK", $args{num}**2] }
!;

    require Perinci::Examples::Tiny;

    run_test_groups(
        %suite_args,
        groups => [
            {
                name => 'help action',
                tests => [
                    {
                        gen_args    => {url => '/Perinci/Examples/Tiny/noop'},
                        inline_gen_args => {load_module=>['Perinci::Examples::Tiny']},
                        argv        => [qw/--help/],
                        exit_code   => 0,
                        stdout_like => qr/^Usage.+^([^\n]*)Options/ims,
                    },
                    {
                        name        => 'extra args is okay',
                        gen_args    => {url => '/Perinci/Examples/Tiny/noop'},
                        inline_gen_args => {load_module=>['Perinci::Examples::Tiny']},
                        argv        => [qw/--help 1 2 3/],
                        exit_code   => 0,
                        stdout_like => qr/^Usage.+^([^\n]*)Options/ims,
                    },
                    {
                        tags        => [qw/subcommand/],
                        name        => 'help for cli with subcommands',
                        gen_args    => {
                            url => '/Perinci/Examples/Tiny/',
                            subcommands => [
                                'sc1:/Perinci/Examples/Tiny/noop',
                            ],
                        },
                        inline_gen_args => {load_module=>['Perinci::Examples::Tiny']},
                        argv        => [qw/--help/],
                        exit_code   => 0,
                        stdout_like => qr/^Subcommands.+\bsc1\b/ms,
                    },
                    {
                        tags          => [qw/subcommand/],
                        name          => 'help on a subcommand',
                        gen_args      => {
                            url => '/Perinci/Examples/Tiny/',
                            subcommands => [
                                'sc1:/Perinci/Examples/Tiny/noop',
                            ],
                        },
                        inline_gen_args => {load_module=>['Perinci::Examples::Tiny']},
                        argv          => [qw/sc1 --help/],
                        exit_code     => 0,
                        stdout_like   => qr/Do nothing.+^Usage/ms,
                        stdout_unlike => qr/^Subcommands.+\bsc1\b/ms,
                    },
                ],
            }, # help action

            {
                name => 'version action',
                tests => [
                    {
                        gen_args    => {url => '/Perinci/Examples/Tiny/noop'},
                        inline_gen_args => {load_module=>['Perinci::Examples::Tiny']},
                        argv        => [qw/--version/],
                        exit_code   => 0,
                        stdout_like => qr/\Q$Perinci::Examples::Tiny::VERSION\E/,
                    },
                ],
            }, # version action

            {
                name => 'subcommands action',
                tests => [

                    # XXX test that if specified, subcommand spec's summary is used
                    # instead of subcommand url's Riap summary.

                    {
                        tags        => ['subcommand'],
                        gen_args    => {
                            url => '/Perinci/Examples/Tiny/',
                            subcommands => [
                                'noop:/Perinci/Examples/Tiny/noop',
                                'odd_even:/Perinci/Examples/Tiny/odd_even',
                            ],
                        },
                        inline_gen_args => {load_module=>['Perinci::Examples::Tiny']},
                        argv        => [qw/--subcommands/],
                        exit_code   => 0,
                        stdout_like => qr/noop.+odd_even/ms,
                    },
                    {
                        tags        => ['subcommand'],
                        name        => 'unknown subcommand = error',
                        gen_args    => {
                            url => '/Perinci/Examples/Tiny/',
                            subcommands => [
                                'noop:/Perinci/Examples/Tiny/noop',
                                'odd_even:/Perinci/Examples/Tiny/odd_even',
                            ],
                        },
                        inline_gen_args => {load_module=>['Perinci::Examples::Tiny']},
                        argv        => [qw/foo/],
                        exit_code   => 200,
                    },
                    {
                        tags        => ['subcommand'],
                        name        => 'default_subcommand',
                        gen_args    => {
                            url => '/Perinci/Examples/Tiny/',
                            subcommands => [
                                'noop:/Perinci/Examples/Tiny/noop',
                                'odd_even:/Perinci/Examples/Tiny/odd_even',
                            ],
                            default_subcommand=>'noop',
                        },
                        inline_gen_args => {load_module=>['Perinci::Examples::Tiny']},
                        argv        => [qw//],
                        exit_code   => 0,
                        stdout_like => qr/^$/, # no-op
                    },
                    {
                        tags        => ['subcommand'],
                        name        => 'default_subcommand 2',
                        gen_args    => {
                            url => '/Perinci/Examples/Tiny/',
                            subcommands => [
                                'noop:/Perinci/Examples/Tiny/noop',
                                'odd_even:/Perinci/Examples/Tiny/odd_even',
                            ],
                            default_subcommand=>'odd_even',
                        },
                        inline_gen_args => {load_module=>['Perinci::Examples::Tiny']},
                        argv        => [qw//],
                        exit_code   => 100, # missing required argument: number
                    },

                ],
            }, # subcommands action

            {
                name => 'call action',
                tests => [
                    {
                        tags           => ['embedded-meta'],
                        name           => 'embedded function+meta works',
                        gen_args       => {
                            url => '/main/square',
                            code_before_instantiate_cmdline => $code_embed,
                        },
                        argv           => [qw/12/],
                        exit_code      => 0,
                        stdout_like    => qr/^144$/,
                    },
                    {
                        name           => 'extra args not allowed',
                        gen_args       => {url => '/Perinci/Examples/Tiny/noop'},
                        inline_gen_args => {load_module=>['Perinci::Examples::Tiny']},
                        argv           => [qw/1/],
                        exit_code      => 200,
                    },
                    {
                        name           => 'common option: --json',
                        gen_args       => {url => '/Perinci/Examples/Tiny/Args/as_is'},
                        inline_gen_args => {load_module=>['Perinci::Examples::Tiny::Args']},
                        argv           => [qw/--arg abc --json/],
                        exit_code      => 0,
                        stdout_like    => qr/^\[\s*200,\s*"OK",\s*"abc",\s*\{\}\s*\]/s,
                    },
                    # pericmd-inline currently doesn't support/enable per-arg json?
                    #{
                    #    name           => 'common option: --json (2)',
                    #    gen_args       => {url => '/Perinci/Examples/Tiny/Args/as_is'},
                    #    inline_gen_args => {load_module=>['Perinci::Examples::Tiny::Args']},
                    #    argv           => [qw/--arg-json ["a","b"] --json/],
                    #    exit_code      => 0,
                    #    stdout_like    => qr/^\[\s*200,\s*"OK",\s*\[\s*"a",\s*"b"\s*\],\s*\{\}\s*\]/s,
                    #},
                ],
            }, # call action

            {
                name => 'completion',
                completion_tests => [
                    {
                        name           => 'self-completion works',
                        gen_args       => {url => '/Perinci/Examples/Tiny/odd_even'},
                        inline_gen_args => {load_module=>['Perinci::Examples::Tiny']},
                        argv           => [],
                        comp_line0     => 'cmd --nu^',
                        answer         => ['--number'],
                    },
                    {
                        tags           => ['subcommand'],
                        name           => 'completion of subcommand name',
                        gen_args    => {
                            url => '/Perinci/Examples/Tiny/',
                            subcommands => [
                                'sc1:/Perinci/Examples/Tiny/noop',
                                'sc2:/Perinci/Examples/Tiny/odd_even',
                            ],
                        },
                        inline_gen_args => {load_module=>['Perinci::Examples::Tiny']},
                        argv           => [],
                        comp_line0     => 'cmd sc^',
                        answer         => ['sc1', 'sc2'],
                    },
                    {
                        tags           => ['subcommand'],
                        name           => 'completion of subcommand option',
                        gen_args    => {
                            url => '/Perinci/Examples/Tiny/',
                            subcommands => [
                                'sc1:/Perinci/Examples/Tiny/noop',
                                'sc2:/Perinci/Examples/Tiny/odd_even',
                            ],
                        },
                        inline_gen_args => {load_module=>['Perinci::Examples::Tiny']},
                        argv           => [],
                        comp_line0     => 'cmd sc2 --nu^',
                        answer         => ['--number'],
                    },
                ],
            }, # completion
        ] # groups
    );
}

1;
# ABSTRACT:

=head1 SEE ALSO

Supported Perinci::CmdLine backends: L<Perinci::CmdLine::Inline>,
L<Perinci::CmdLine::Lite>, L<Perinci::CmdLine::Classic>.


=head1 ENVIRONMENT

=head2 DEBUG => bool

If set to 1, then temporary files (e.g. generated scripts for testing) will not
be cleaned up, so you can inspect them.

=head2 TEST_PERICMD_EXCLUDE_TAGS => str

To set default for C<pericmd_ok()>'s C<exclude_tags> argument.

=head2 TEST_PERICMD_INCLUDE_TAGS => str

To set default for C<pericmd_ok()>'s C<include_tags> argument.
