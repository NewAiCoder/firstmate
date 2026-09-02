# firstmate on a host whose perl lacks JSON::PP (bare-Fedora-style install)

$ perl -MJSON::PP -e1   # the simulated host state
Can't locate JSON/PP.pm in @INC (you may need to install the JSON::PP module).
exit=2

## 1. Session-start bootstrap names the missing module and the per-platform package
$ fm-bootstrap.sh
MISSING_MANUAL: perl JSON::PP module (instructions: install the OS package - Fedora/RHEL: 'sudo dnf install perl-JSON-PP', Debian/Ubuntu: 'sudo apt install libjson-pp-perl', macOS/other: 'cpan JSON::PP'; required by bin/fm-captain-hold.sh, bin/fm-procevent-lavish.sh, and bin/fm-procevent-extension-capture.pl)
exit=0

## 2. Detect-only: rerunning installs nothing, the same diagnostic returns
$ fm-bootstrap.sh
MISSING_MANUAL: perl JSON::PP module (instructions: install the OS package - Fedora/RHEL: 'sudo dnf install perl-JSON-PP', Debian/Ubuntu: 'sudo apt install libjson-pp-perl', macOS/other: 'cpan JSON::PP'; required by bin/fm-captain-hold.sh, bin/fm-procevent-lavish.sh, and bin/fm-procevent-extension-capture.pl)
exit=0

## 3. Every JSON-decoding captain-hold subcommand stops with the install hint
$ fm-captain-hold.sh hold
fm-captain-hold: perl JSON::PP module is required to decode task fields; install the OS package - Fedora/RHEL: 'sudo dnf install perl-JSON-PP', Debian/Ubuntu: 'sudo apt install libjson-pp-perl', macOS/other: 'cpan JSON::PP'
exit=1
$ fm-captain-hold.sh answer
fm-captain-hold: perl JSON::PP module is required to decode task fields; install the OS package - Fedora/RHEL: 'sudo dnf install perl-JSON-PP', Debian/Ubuntu: 'sudo apt install libjson-pp-perl', macOS/other: 'cpan JSON::PP'
exit=1
$ fm-captain-hold.sh answers
fm-captain-hold: perl JSON::PP module is required to decode task fields; install the OS package - Fedora/RHEL: 'sudo dnf install perl-JSON-PP', Debian/Ubuntu: 'sudo apt install libjson-pp-perl', macOS/other: 'cpan JSON::PP'
exit=1
$ fm-captain-hold.sh complete
fm-captain-hold: perl JSON::PP module is required to decode task fields; install the OS package - Fedora/RHEL: 'sudo dnf install perl-JSON-PP', Debian/Ubuntu: 'sudo apt install libjson-pp-perl', macOS/other: 'cpan JSON::PP'
exit=1
$ fm-captain-hold.sh verify
fm-captain-hold: perl JSON::PP module is required to decode task fields; install the OS package - Fedora/RHEL: 'sudo dnf install perl-JSON-PP', Debian/Ubuntu: 'sudo apt install libjson-pp-perl', macOS/other: 'cpan JSON::PP'
exit=1
$ fm-captain-hold.sh diverged
fm-captain-hold: perl JSON::PP module is required to decode task fields; install the OS package - Fedora/RHEL: 'sudo dnf install perl-JSON-PP', Debian/Ubuntu: 'sudo apt install libjson-pp-perl', macOS/other: 'cpan JSON::PP'
exit=1

## 4. The binding subcommands decode nothing and stay usable (fm-bearings-board keeps serving)
$ fm-captain-hold.sh bind sample-board sample-origin
bound: sample-board -> sample-origin
exit=0
$ fm-captain-hold.sh binding sample-board
sample-origin
exit=0
$ fm-captain-hold.sh unbind sample-board
unbound: sample-board
exit=0

## 5. Control: same commands on this host's real perl (JSON::PP present) - no gate, no diagnostic
$ fm-bootstrap.sh
exit=0 (silent)
$ fm-captain-hold.sh diverged
exit=0 (silent - no diverged work)
