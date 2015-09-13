package Test::Perinci::CmdLine;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;
use Devel::Confess;

use Capture::Tiny qw(capture);
use Data::Dumper;
use File::Path qw(remove_tree);
use File::Slurper qw(read_text write_text);
use File::Temp qw(tempdir tempfile);
use IPC::System::Options qw(system);

use Test::More 0.98;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(pericmd_ok);

our %SPEC;

sub _dump {
    local $Data::Dumper::Deparse = 1;
    local $Data::Dumper::Terse   = 1;
    local $Data::Dumper::Indent  = 0;
    Data::Dumper::Dumper($_[0]);
}

$SPEC{pericmd_ok} = {
    v => 1.1,
    summary => 'Common test suite for Perinci::CmdLine::{Lite,Classic,Inline}',
    args => {
        class => {
            summary => 'Which class are we testing',
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
    },
};
sub pericmd_ok {
    my %suite_args = @_;

    my $class   = $suite_args{class};
    my $tempdir = tempdir();

    my $include_tags = $suite_args{include_tags} // do {
        if (defined $ENV{TEST_PERICMD_INCLUDE_TAGS}) {
            [split /,/, $ENV{TEST_PERICMD_INCLUDE_TAGS}];
        } else {
            undef;
        }
    };
    my $exclude_tags = $suite_args{exclude_tags} // do {
        if (defined $ENV{TEST_PERICMD_EXCLUDE_TAGS}) {
            [split /,/, $ENV{TEST_PERICMD_EXCLUDE_TAGS}];
        } else {
            undef;
        }
    };

    my $test_run = sub {
        use experimental 'smartmatch';
        no strict 'refs';
        no warnings 'redefine';

        my %test_args = @_;

        my $name = "run: " .
            ($test_args{name} // join(" ", @{$test_args{argv} // []}));

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

            my %cli_args = %{
                # use class-specific args if defined
                ($class eq 'Perinci::CmdLine::Inline' ?
                     $test_args{args_inline} :
                     $class eq 'Perinci::CmdLine::Lite' ?
                     $test_args{args_lite} :
                     $test_args{args_classic}
                 )
                    // $test_args{args} // {}
                };
            $cli_args{read_config} //= 0;

            # construct the cli script
            my @script;
            if ($class eq 'Perinci::CmdLine::Inline') {
                require Perinci::CmdLine::Inline;
                $cli_args{include} = $test_args{inline_include}
                    if $test_args{inline_include};
                my $res = Perinci::CmdLine::Inline::gen_inline_pericmd_script(
                    %cli_args);
                die "Can't generate Perinci::CmdLine::Inline script: ".
                    "$res->[0] - $res->[1]" unless $res->[0] == 200;
                @script = ($res->[2]);
            } else {
                push @script, "use 5.010; use strict; use warnings;\n";
                push @script, "use $class;\n";
                push @script, "my \$cli = $class->new(\@{",
                    _dump([%cli_args]), '});', "\n";
                push @script, "\$cli->run;\n";
            }

            # write cli script to tempfile
            my ($fh, $filename) = tempfile('cliXXXXXXXX', DIR=>$tempdir);
            write_text($filename, join("", @script));
            note "Generated CLI script at $filename";

            my $stdout;
            my $stderr;
            my $res;
            system(
                {shell=>0, die=>0, log=>1,
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
    }; # test_run

    subtest 'pericmd_ok test suite' => sub {
        subtest 'help action' => sub {
            ok 1, "dummy"; # just to avoid no tests being run if all excluded by tags
            $test_run->(
                args        => {url => '/Perinci/Examples/Tiny/noop'},
                argv        => [qw/--help/],
                exit_code   => 0,
                stdout_like => qr/^Usage.+^([^\n]*)Options/ims,
                inline_include => [qw/Perinci::Examples::Tiny/],
            );
            $test_run->(
                name        => 'extra args is okay',
                args        => {url => '/Perinci/Examples/Tiny/noop'},
                argv        => [qw/--help 1 2 3/],
                exit_code   => 0,
                stdout_like => qr/^Usage.+^([^\n]*)Options/ims,
                inline_include => [qw/Perinci::Examples::Tiny/],
            );
            $test_run->(
                tags        => [qw/subcommand/],
                name        => 'help for cli with subcommands',
                args        => {
                    url => '/Perinci/Examples/Tiny/',
                    subcommands => {
                        sc1 => {url=>'/Perinci/Examples/Tiny/noop'},
                    },
                },
                argv        => [qw/--help/],
                exit_code   => 0,
                stdout_like => qr/^Subcommands.+\bsc1\b/ms,
                #inline_include => [qw/Perinci::Examples::Tiny/],
            );
            $test_run->(
                tags          => [qw/subcommand/],
                name          => 'help on a subcommand',
                args          => {
                    url => '/Perinci/Examples/Tiny/',
                    subcommands => {
                        sc1 => {url=>'/Perinci/Examples/Tiny/noop'},
                    },
                },
                argv          => [qw/sc1 --help/],
                exit_code     => 0,
                stdout_like   => qr/Do nothing.+^Usage/ms,
                stdout_unlike => qr/^Subcommands.+\bsc1\b/ms,
                #inline_include => [qw/Perinci::Examples::Tiny/],
            );
        };
        subtest 'run action' => sub {
            ok 1, "dummy"; # just to avoid no tests being run if all excluded by tags
            $test_run->(
                name           => 'extra args not allowed',
                args           => {url => '/Perinci/Examples/Tiny/noop'},
                inline_include => ['Perinci::Examples::Tiny'],
                argv           => [qw/1/],
                exit_code      => 200,
            );
        },
    };

    if (!Test::More->builder->is_passing) {
        diag "there are failing tests, not deleting tempdir $tempdir";
    } elsif ($ENV{DEBUG}) {
        diag "DEBUG is true, not deleting tempdir $tempdir";
    } else {
        note "all tests successful, deleting tempdir $tempdir";
        remove_tree($tempdir);
    }
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
