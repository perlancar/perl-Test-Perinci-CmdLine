package Test::Perinci::CmdLine;

# DATE
# VERSION

use 5.010;
use strict;
use warnings;

use Capture::Tiny qw(capture);
use Data::Dmp qw(dmp);
use File::Temp qw(tempdir tempfile);
use Test::More 0.98;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(
                       test_complete
                       test_pericmd
               );

our %SPEC;

sub _test_run {
    my %args = @_;

    my $name = "test_run: " . ($args{name} // join(" ", @{$args{argv} // []}));

    subtest $name => sub {
        no strict 'refs';
        no warnings 'redefine';

        my %cmdargs = %{$args{args}};
        $cmdargs{exit} = 0;
        $cmdargs{read_config} //= 0;

        my ($stdout, $stderr);
        my $res;
        eval {
            ($stdout, $stderr) = capture {
                if ($CLASS =~ /::(Lite|Classic)$/) {
                    local @ARGV = @{$args{argv} // []};
                    my $cmd = $CLASS->new(%cmdargs);
                    $res = $cmd->run;
                }
            };
        };
        my $eval_err = $@;
        my $exit_code = $res->[3]{'x.perinci.cmdline.base.exit_code'};

        if ($args{dies}) {
            ok($eval_err || ref($eval_err), "dies");
            return;
        } else {
            ok(!$eval_err, "doesn't die") or diag("dies: $eval_err");
        }

        if (defined $args{exit_code}) {
            is($exit_code, $args{exit_code}, "exit code");
        }

        if ($args{status}) {
            is($res->[0], $args{status}, "status")
                or diag explain $res;
        }

        if ($args{output_re}) {
            like($stdout // "", $args{output_re}, "output_re")
                or diag("output is <" . ($stdout // "") . ">");
        }

        if ($args{posttest}) {
            $args{posttest}->($stdout, $stderr, $res);
        }
    };
}

sub test_complete {
    my (%args) = @_;

    my $cmd = $CLASS->new(%{$args{args}}, exit=>0);

    local @ARGV = @{$args{argv} // []};

    # $args{comp_line0} contains comp_line with '^' indicating where comp_point
    # should be, the caret will be stripped. this is more convenient than
    # counting comp_point manually.
    my $comp_line  = $args{comp_line0};
    defined ($comp_line) or die "BUG: comp_line0 not defined";
    my $comp_point = index($comp_line, '^');
    $comp_point >= 0 or
        die "BUG: comp_line0 should contain ^ to indicate where comp_point is";
    $comp_line =~ s/\^//;

    local $ENV{COMP_LINE}  = $comp_line;
    local $ENV{COMP_POINT} = $comp_point;

    my ($stdout, $stderr);
    my $res;
    ($stdout, $stderr) = capture {
        $res = $cmd->run;
    };
    my $exit_code = $res->[3]{'x.perinci.cmdline.base.exit_code'};

    my $name = "test_complete: " . ($args{name} // $args{comp_line0});
    subtest $name => sub {
        is($exit_code, 0, "exit code = 0");
        is($stdout // "", join("", map {"$_\n"} @{$args{result}}), "result");
    };
}

$SPEC{test_pericmd} = {
    v => 1.1,
    summary => 'Common test suite for Perinci::CmdLine::{Lite,Classic,Inline}',
    args => {
        class => {
            summary => 'Which class are we testing',
            schema => ['str*', in=>[qw/Lite Classic Inline/]],
            req => 1,
        },
    },
};
sub test_pericmd {
    my %args = @_;

    my $cl = $args{class};
    $cl =~ /^Perinci::CmdLine:://;
    local $CLASS = "Perinci::CmdLine::$cl";

    local $TEMPDIR = tempdir(CLEANUP => 1);

    subtest 'help action' => sub {
        _test_run(
            args      => {url=>'/Perinci/Examples/noop'},
            argv      => [qw/--help/],
            exit_code => 0,
            output_re => qr/- Do nothing.+^Other options:/ms,
        );
    };
}

1;
# ABSTRACT: Test library for Perinci::CmdLine{::Classic,::Lite,::Inline}

=head1 FUNCTIONS

=head2 test_run(%args)

=head2 test_complete(%args)
