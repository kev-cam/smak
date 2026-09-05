#!/usr/bin/perl
# Regression: SmakCMake (cmake-metadata mode) must synthesize CMake's special
# targets -- install, install/fast, install/local, install/strip, preinstall,
# clean -- from a build dir, not only the library/executable targets.
# Found on Trilinos for Xyce (2026-09-05): `smak install` was a silent no-op.
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/..";
use File::Temp qw(tempdir);
use SmakCMake;
my $bd = tempdir(CLEANUP => 1);
open(my $f, '>', "$bd/cmake_install.cmake") or die; print $f "# stub\n"; close $f;
my %info = (build_dir => $bd, cmake_command => '/opt/cmake/bin/cmake',
            targets => { foo => { dir => "$bd/CMakeFiles/foo.dir", flags => {}, sources => [],
                                  objects => ['CMakeFiles/foo.dir/a.o'], link_cmd => "/usr/bin/ar qc libfoo.a CMakeFiles/foo.dir/a.o" } },
            target_deps => {}, cxx_compiler => 'c++', c_compiler => 'cc');
my (%deps, %rule);
SmakCMake::generate_smak_rules(\%info, \%deps, \%rule, {}, 'CMakeLists.txt');
my $fail = 0;
for my $t (qw(install install/fast install/local install/strip preinstall clean all)) {
    if (exists $rule{"CMakeLists.txt\t$t"}) { print "PASS: target $t present\n" }
    else { print "FAIL: target $t missing\n"; $fail = 1 }
}
my $inst = $rule{"CMakeLists.txt\tinstall"} // '';
if ($inst =~ m{cd \Q$bd\E && /opt/cmake/bin/cmake -P cmake_install.cmake}) { print "PASS: install recipe\n" } else { print "FAIL: install recipe '$inst'\n"; $fail = 1 }
my @d = @{$deps{"CMakeLists.txt\tinstall"} // []};
if ("@d" eq 'all') { print "PASS: install depends on all\n" } else { print "FAIL: install deps '@d'\n"; $fail = 1 }
if (($rule{"CMakeLists.txt\tclean"} // '') =~ /rm -f .*a\.o .*libfoo\.a/) { print "PASS: clean recipe\n" } else { print "FAIL: clean recipe\n"; $fail = 1 }
exit $fail;
