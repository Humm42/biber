# -*- cperl -*-
use strict;
use warnings;
use utf8;
no warnings 'utf8';

use Test::More tests => 5;

use Biber;
use Biber::Output::bbl;
use Log::Log4perl;
use Capture::Tiny qw(capture);

chdir("t/tdata") ;

# USING CAPTURE - DEBUGGING PRINTS, DUMPS WON'T BE VISIBLE UNLESS YOU PRINT $stderr
# AT THE END!

# Set up Biber object
my $biber = Biber->new(noconf => 1);

# Note stderr is output here so we can capture it and do a cyclic crossref test
my $LEVEL = 'ERROR';
my $l4pconf = qq|
    log4perl.category.main                             = $LEVEL, Screen
    log4perl.category.screen                           = $LEVEL, Screen
    log4perl.appender.Screen                           = Log::Log4perl::Appender::Screen
    log4perl.appender.Screen.utf8                      = 1
    log4perl.appender.Screen.Threshold                 = $LEVEL
    log4perl.appender.Screen.stderr                    = 1
    log4perl.appender.Screen.layout                    = Log::Log4perl::Layout::SimpleLayout
|;

Log::Log4perl->init(\$l4pconf);

$biber->parse_ctrlfile('xdata.bcf');
$biber->set_output_obj(Biber::Output::bbl->new());

# Options - we could set these in the control file but it's nice to see what we're
# relying on here for tests

# Biber options
Biber::Config->setoption('fastsort', 1);
Biber::Config->setoption('sortlocale', 'C');
Biber::Config->setoption('nodieonerror', 1); # because there is a cyclic xdata check

# Now generate the information
my ($stdout, $stderr) = capture { $biber->prepare };
my $section = $biber->sections->get_section(0);
my $main = $biber->sortlists->get_list(0, 'entry', 'nty');
my $out = $biber->get_output_obj;

my $xd1 = q|    \entry{xd1}{book}{}
      \name{form=original,lang=default}{labelname}{1}{}{%
        {{hash=51db4bfd331cba22959ce2d224c517cd}{Ellington}{E\bibinitperiod}{Edward}{E\bibinitperiod}{}{}{}{}}%
      }
      \name{form=original,lang=default}{author}{1}{}{%
        {{hash=51db4bfd331cba22959ce2d224c517cd}{Ellington}{E\bibinitperiod}{Edward}{E\bibinitperiod}{}{}{}{}}%
      }
      \list{form=original,lang=default}{location}{2}{%
        {New York}%
        {London}%
      }
      \list{form=original,lang=default}{publisher}{1}{%
        {Macmillan}%
      }
      \strng{namehash}{51db4bfd331cba22959ce2d224c517cd}
      \strng{fullhash}{51db4bfd331cba22959ce2d224c517cd}
      \field{form=original,lang=default}{sortinit}{E}
      \field{form=original,lang=default}{labelyear}{2007}
      \field{form=original,lang=default}{note}{A Note}
      \field{form=original,lang=default}{year}{2007}
    \endentry
|;

my $xd2 = q|    \entry{xd2}{book}{}
      \name{form=original,lang=default}{labelname}{1}{}{%
        {{hash=68539e0ce4922cc4957c6cabf35e6fc8}{Pillington}{P\bibinitperiod}{Peter}{P\bibinitperiod}{}{}{}{}}%
      }
      \name{form=original,lang=default}{author}{1}{}{%
        {{hash=68539e0ce4922cc4957c6cabf35e6fc8}{Pillington}{P\bibinitperiod}{Peter}{P\bibinitperiod}{}{}{}{}}%
      }
      \list{form=original,lang=default}{location}{2}{%
        {New York}%
        {London}%
      }
      \list{form=original,lang=default}{publisher}{1}{%
        {Routledge}%
      }
      \strng{namehash}{68539e0ce4922cc4957c6cabf35e6fc8}
      \strng{fullhash}{68539e0ce4922cc4957c6cabf35e6fc8}
      \field{form=original,lang=default}{sortinit}{P}
      \field{form=original,lang=default}{labelyear}{2003}
      \field{form=original,lang=default}{abstract}{An abstract}
      \field{form=original,lang=default}{addendum}{Москва}
      \field{form=original,lang=default}{note}{A Note}
      \field{form=original,lang=default}{year}{2003}
    \endentry
|;

is($out->get_output_entry($main,'xd1'), $xd1, 'xdata test - 1');
is($out->get_output_entry($main,'xd2'), $xd2, 'xdata test - 2');
# XDATA entries should not be output at all
is($out->get_output_entry($main,'macmillan'), undef, 'xdata test - 3');
is($out->get_output_entry($main,'macmillan:pub'), undef, 'xdata test - 4');
chomp $stderr;
is($stderr, "ERROR - Circular XDATA inheritance between 'loop'<->'loop:3'", 'Cyclic xdata error check');
#print $stdout;


