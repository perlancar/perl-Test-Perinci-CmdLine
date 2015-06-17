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
    },
};
sub pericmd_ok {
    my %suite_args = @_;

    my $class   = $suite_args{class};
    my $tempdir = tempdir();

    my $test_run = sub {
        no strict 'refs';
        no warnings 'redefine';

        my %test_args = @_;

        my $name = "run: " .
            ($test_args{name} // join(" ", @{$test_args{argv} // []}));

        my %cli_args = %{
            # use class-specific args if defined
            ($class eq 'Perinci::CmdLine::Inline' ? $test_args{args_inline} :
                 $class eq 'Perinci::CmdLine::Lite' ? $test_args{args_lite} :
                 $test_args{args_classic}
             )
            // $test_args{args} // {}
        };
        $cli_args{read_config} //= 0;

        # construct the cli script
        my @script;
        if ($class eq 'Perinci::CmdLine::Inline') {
            require Perinci::CmdLine::Inline;
            my $res = Perinci::CmdLine::Inline::gen_inline_pericmd_script(%cli_args);
            die "Can't generate Perinci::CmdLine::Inline script: $res->[0] - $res->[1]"
                unless $res->[0] == 200;
            @script = ($res->[2]);
        } else {
            push @script, "use 5.010; use strict; use warnings;\n";
            push @script, "use $class;\n";
            push @script, "my \$cli = $class->new(\@{", _dump([%cli_args]), '});', "\n";
            push @script, "\$cli->run;\n";
        }

        # write cli script to tempfile
        my ($fh, $filename) = tempfile('cliXXXXXXXX', DIR=>$tempdir);
        write_text($filename, join("", @script));
        note "Generated CLI script at $filename";

        my ($stdout, $stderr);
        my $res;
        ($stdout, $stderr) = capture {
            system(
                {shell=>0, die=>0, lang=>'C'},
                $^X,
                @{ $test_args{argv} // []},
            );
        };
        my $exit_code = $? >> 8;

        if (defined $test_args{exit_code}) {
            is($exit_code, $test_args{exit_code}, "exit_code");
        }
        if ($test_args{stdout_like}) {
            like($stdout, $test_args{stdout_like}, "stdout_like");
        }
        if ($test_args{stderr_like}) {
            like($stderr, $test_args{stderr_like}, "stderr_like");
        }
        if ($test_args{posttest}) {
            $test_args{posttest}->($exit_code, $stdout, $stderr);
        }
    };

    subtest 'pericmd_ok test suite' => sub {
        $test_run->(
            name      => 'help action',
            args      => {url=>'/Perinci/Examples/noop'},
            argv      => [qw/--help/],
            exit_code => 0,
            stdout_re => qr/- Do nothing.+^Other options:/ms,
        );
    };

    if (Test::More->builder->is_passing) {
        note "all tests successful, deleting tempdir $tempdir";
        remove_tree($tempdir);
    } else {
        diag "there are failing tests, not deleting tempdir $tempdir";
    }

}

1;
# ABSTRACT:

=head1 SEE ALSO

Supported Perinci::CmdLine backends: L<Perinci::CmdLine::Inline>,
L<Perinci::CmdLine::Lite>, L<Perinci::CmdLine::Classic>.
