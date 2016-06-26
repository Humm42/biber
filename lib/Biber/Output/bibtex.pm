package Biber::Output::bibtex;
use v5.16;
use strict;
use warnings;
use parent qw(Biber::Output::base);

use Biber::Annotation;
use Biber::Config;
use Biber::Constants;
use Biber::Utils;
use List::AllUtils qw( :all );
use Encode;
use IO::File;
use Log::Log4perl qw( :no_extra_logdie_message );
use Scalar::Util qw(looks_like_number);
use Text::Wrap;
$Text::Wrap::columns = 80;
use Unicode::Normalize;
my $logger = Log::Log4perl::get_logger('main');

=encoding utf-8

=head1 NAME

Biber::Output::bibtex - class for bibtex output

=cut


=head2 set_output_target_file

    Set the output target file of a Biber::Output::bibtex object
    A convenience around set_output_target so we can keep track of the
    filename

=cut

sub set_output_target_file {
  my $self = shift;
  my $outfile = shift;
  $self->{output_target_file} = $outfile;
  return undef;
}

=head2 set_output_comment

  Set the output for a comment

=cut

sub set_output_comment {
  my $self = shift;
  my $comment = shift;
  my $acc = '';

  # Make the right casing function
  my $casing;

  if (Biber::Config->getoption('output_fieldcase') eq 'upper') {
    $casing = sub {uc(shift)};
  }
  elsif (Biber::Config->getoption('output_fieldcase') eq 'lower') {
    $casing = sub {lc(shift)};
  }
  elsif (Biber::Config->getoption('output_fieldcase') eq 'title') {
    $casing = sub {ucfirst(shift)};
  }

  $acc .= '@';
  $acc .= $casing->('comment');
  $acc .= "{$comment}\n";

  push @{$self->{output_data}{COMMENTS}}, $acc;
  return;
}

=head2 set_output_entry

  Set the output for an entry

=cut

sub set_output_entry {
  my $self = shift;
  my $be = shift; # Biber::Entry object
  my $bee = $be->get_field('entrytype');
  my $section = shift; # Section object the entry occurs in
  my $dm = shift; # Data Model object
  my $dmh = $dm->{helpers};
  my $acc = '';
  my $secnum = $section->number;
  my $key = $be->get_field('citekey');

  # Make the right casing function
  my $casing;

  if (Biber::Config->getoption('output_fieldcase') eq 'upper') {
    $casing = sub {uc(shift)};
  }
  elsif (Biber::Config->getoption('output_fieldcase') eq 'lower') {
    $casing = sub {lc(shift)};
  }
  elsif (Biber::Config->getoption('output_fieldcase') eq 'title') {
    $casing = sub {ucfirst(shift)};
  }

  $acc .= '@';
  $acc .= $casing->($bee);
  $acc .=  "\{$key,\n";

  # hash accumulator so we can gather all the data before formatting so that things like
  # $max_field_len can be calculated
  my %acc;

  # Name fields
  my $tonamesub = 'name_to_bib';
  if (Biber::Config->getoption('output_xname')) {
    $tonamesub = 'name_to_xname';
  }

  foreach my $namefield (@{$dmh->{namelists}}) {
    if (my $names = $be->get_field($namefield)) {
      my $namesep = Biber::Config->getoption('output_namesep');
      my @namelist;

      # Namelist scope useprefix
      if (defined($names->get_useprefix)) {# could be 0
        push @namelist, 'useprefix=' . Biber::Utils::map_boolean($names->get_useprefix, 'tostring');
      }

      # Namelist scope sortnamekeyscheme
      if (my $snks = $names->get_sortnamekeyscheme) {
        push @namelist, "sortnamekeyscheme=$snks";
      }

      # Now add all names to accumulator
      foreach my $name (@{$names->names}) {
        push @namelist, $name->$tonamesub;
      }
      $acc{$casing->($namefield)} = join(" $namesep ", @namelist);

      # Deal with morenames
      if ($names->get_morenames) {
        $acc{$casing->($namefield)} .= " $namesep others";
      }
    }
  }

  # List fields and verbatim list fields
  foreach my $listfield (@{$dmh->{lists}}, @{$dmh->{vlists}}) {
    if (my $list = $be->get_field($listfield)) {
      my $listsep = Biber::Config->getoption('output_listsep');
      my @plainlist;
      foreach my $item (@$list) {
        push @plainlist, $item;
      }
      $acc{$casing->($listfield)} = join(" $listsep ", @plainlist);
    }
  }

  # Per-entry options
  my @entryoptions;
  foreach my $opt (Biber::Config->getblxentryoptions($key)) {
    push @entryoptions, $opt . '=' . Biber::Config->getblxoption($opt, undef, $key);
  }
  $acc{$casing->('options')} = join(',', @entryoptions) if @entryoptions;

  # Date fields
  foreach my $datefield (@{$dmh->{datefields}}) {
    my ($d) = $datefield =~ m/^(.*)date$/;
    next unless $be->get_field("${d}year");
    $acc{$casing->($datefield)} = construct_date($be, $d);
  }

  # YEAR and MONTH are legacy - convert these to DATE if possible
  if (my $val = $be->get_field('year')) {
    if (looks_like_number($val)) {
      $acc{$casing->('date')} = $val;
      $be->del_field('year');
    }
  }
  if (my $val = $be->get_field('month')) {
    if (looks_like_number($val)) {
      $acc{$casing->('date')} .= "-$val";
      $be->del_field('month');
    }
  }

  # If CROSSREF and XDATA have been resolved, don't output them
  if (Biber::Config->getoption('output_resolve')) {
    if ( my $cr = $be->get_field('crossref') ) {
      $be->del_field('crossref');
    }
    if ( my $xd = $be->get_field('xdata') ) {
      $be->del_field('xdata');
    }
  }

  # Standard fields
  foreach my $field (@{$dmh->{fields}}) {
    if (my $val = $be->get_field($field)) {
      $acc{$casing->($field)} = $val;
    }
  }

  # XSV fields
  foreach my $field (@{$dmh->{xsv}}) {
    if (my $f = $be->get_field($field)) {
      $acc{$casing->($field)} .= join(',', @$f);
    }
  }

  # Ranges
  foreach my $rfield (@{$dmh->{ranges}}) {
    if ( my $rf = $be->get_field($rfield) ) {
      $acc{$casing->($rfield)} .= construct_range($rf);
    }
  }

  # Verbatim fields
  foreach my $vfield (@{$dmh->{vfields}}) {
    if ( my $vf = $be->get_field($vfield) ) {
      $acc{$casing->($vfield)} = $vf;
    }
  }

  # Keywords
  if ( my $k = $be->get_field('keywords') ) {
    $acc{$casing->('keywords')} = join(',', @$k);
  }

  # Annotations
  foreach my $f (keys %acc) {
    if (Biber::Annotation->is_annotated_field($key, lc($f))) {
      $acc{$casing->($f) . Biber::Config->getoption('output_annotation_marker')} = construct_annotation($key, lc($f));
    }
  }

  # Determine maximum length of field names
  my $max_field_len;
  if (Biber::Config->getoption('output_align')) {
    $max_field_len = max map {Unicode::GCString->new($_)->length} keys %acc;
  }

  # Determine order of fields
  my %classmap = ('names'     => 'namelists',
                  'lists'     => 'lists',
                  'dates'     => 'datefields');

  foreach my $field (split(/\s*,\s*/, Biber::Config->getoption('output_field_order'))) {
    if ($field eq 'names' or
        $field eq 'lists' or
        $field eq 'dates') {
      my @donefields;
      foreach my $key (sort keys %acc) {
        if (first {fc($_) eq fc($key)} @{$dmh->{$classmap{$field}}}) {
          $acc .= bibfield($key, $acc{$key}, $max_field_len);
          push @donefields, $key;
          # Keep annotations with their fields
          my $ann = $key . Biber::Config->getoption('output_annotation_marker');
          if (my $value = $acc{$ann}) {
            $acc .= bibfield($ann, $value, $max_field_len);
            push @donefields, $ann;
          }
        }
      }
      delete @acc{@donefields};
    }
    elsif (my $value = delete $acc{$casing->($field)}) {
      $acc .= bibfield($casing->($field), $value, $max_field_len);
      # Keep annotations with their fields
      my $ann = $casing->($field) . Biber::Config->getoption('output_annotation_marker');
      if (my $value = delete $acc{$ann}) {
        $acc .= bibfield($ann, $value, $max_field_len);
      }
    }
  }

  # Now rest of fields not explicitly specified
  foreach my $field (sort keys %acc) {
    $acc .= bibfield($field, $acc{$field}, $max_field_len);
  }

  $acc .= "}\n\n";

  # If requested to convert UTF-8 to macros ...
  if (Biber::Config->getoption('output_safechars')) {
    $acc = latex_recode_output($acc);
  }
  else { # ... or, check for encoding problems and force macros
    my $outenc = Biber::Config->getoption('output_encoding');
    if ($outenc ne 'UTF-8') {
      # Can this entry be represented in the output encoding?
      if (encode($outenc, NFC($acc)) =~ /\?/) { # Malformed data encoding char
        # So convert to macro
        $acc = latex_recode_output($acc);
        biber_warn("The entry '$key' has characters which cannot be encoded in '$outenc'. Recoding problematic characters into macros.");
      }
    }
  }

  # Create an index by keyname for easy retrieval
  $self->{output_data}{ENTRIES}{$secnum}{index}{$key} = \$acc;

  return;
}


=head2 output

    output method

=cut

sub output {
  my $self = shift;
  my $data = $self->{output_data};

  my $target_string = "Target"; # Default
  if ($self->{output_target_file}) {
    $target_string = $self->{output_target_file};
  }

  # Instantiate output file now that input is read in case we want to do in-place
  # output for tool mode
  my $enc_out;
  if (Biber::Config->getoption('output_encoding')) {
    $enc_out = ':encoding(' . Biber::Config->getoption('output_encoding') . ')';
  }
  my $target = IO::File->new($target_string, ">$enc_out");

  # for debugging mainly
  unless ($target) {
    $target = new IO::File '>-';
  }

  if ($logger->is_debug()) {# performance tune
    $logger->debug('Preparing final output using class ' . __PACKAGE__ . '...');
  }

  $logger->info("Writing '$target_string' with encoding '" . Biber::Config->getoption('output_encoding') . "'");
  $logger->info('Converting UTF-8 to TeX macros on output') if Biber::Config->getoption('output_safechars');

  out($target, $data->{HEAD});

  if ($logger->is_debug()) {# performance tune
    $logger->debug("Writing entries in bibtex format");
  }

  # Bibtex output uses just one special section, always sorted by global sorting spec
  foreach my $key ($Biber::MASTER->sortlists->get_list(99999, Biber::Config->getblxoption('sortscheme') . '/global/', 'entry', Biber::Config->getblxoption('sortscheme'), 'global', '')->get_keys) {
    out($target, ${$data->{ENTRIES}{99999}{index}{$key}});
  }

  # Output any comments when in tool mode
  if (Biber::Config->getoption('tool')) {
    foreach my $comment (@{$data->{COMMENTS}}) {
      out($target, $comment);
    }
  }

  out($target, $data->{TAIL});

  $logger->info("Output to $target_string");
  close $target;
  return;
}

=head2 create_output_section

    Create the output from the sections data and push it into the
    output object.

=cut

sub create_output_section {
  my $self = shift;
  my $secnum = $Biber::MASTER->get_current_section;
  my $section = $Biber::MASTER->sections->get_section($secnum);

  # We rely on the order of this array for the order of the .bib
  foreach my $k ($section->get_citekeys) {
    # Regular entry
    my $be = $section->bibentry($k) or biber_error("Cannot find entry with key '$k' to output");
    $self->set_output_entry($be, $section, Biber::Config->get_dm);
  }

  # Output all comments at the end
  foreach my $comment (@{$Biber::MASTER->{comments}}) {
    $self->set_output_comment($comment);
  }

  # Make sure the output object knows about the output section
  $self->set_output_section($secnum, $section);

  return;
}

=head2 bibfield

  Format a single field

=cut

sub bibfield {
  my ($field, $value, $max_field_len) = @_;
  my $acc;
  $acc .= ' ' x Biber::Config->getoption('output_indent');
  $acc .= $field;
  $acc .= ' ' x ($max_field_len - Unicode::GCString->new($field)->length) if $max_field_len;
  $acc .= ' = ';

  # Don't wrap fields which should be macros in braces
  my $mfs = Biber::Config->getoption('output_macro_fields');
  if (defined($mfs) and first {lc($field) eq $_} map {lc($_)} split(/\s*,\s*/, $mfs) ) {
    $acc .= "$value,\n";
  }
  else {
    $acc .= "\{$value\},\n";
  }
  return $acc;
}


=head2 construct_annotation

  Construct a field annotation

=cut

sub construct_annotation {
  my ($key, $field) = @_;
  my @annotations;

  if (my $fa = Biber::Annotation->get_field_annotation($key, $field)) {
    push @annotations, "=$fa";
  }

  foreach my $item (Biber::Annotation->get_annotated_items('item', $key, $field)) {
    push @annotations, "$item=" . Biber::Annotation->get_annotation('item', $key, $field, $item);
  }

  foreach my $item (Biber::Annotation->get_annotated_items('part', $key, $field)) {
    foreach my $part (Biber::Annotation->get_annotated_parts('part', $key, $field, $item)) {
      push @annotations, "$item:$part=" . Biber::Annotation->get_annotation('part', $key, $field, $item, $part);
    }
  }

  return join(';', @annotations);
}

=head2 construct_range

  Construct a range field from its components

  [m, n]      -> m-n
  [m, undef]  -> m
  [m, '']     -> m-
  ['', n]     -> -n
  ['', undef] -> ignore

=cut

sub construct_range {
  my $r = shift;
  my @ranges;
  foreach my $e (@$r) {
    my $rs = $e->[0];
    if (defined($e->[1])) {
      $rs .= '--' . $e->[1];
    }
    push @ranges, $rs;
  }
  return join(',', @ranges);
}

=head2 construct_date

  Construct a date from its components

=cut

sub construct_date {
  my ($be, $d) = @_;
  my $datestring = '';
  my $overridey;
  my $overridem;
  my $overrideem;
  my $overrided;

  my %seasons = ( 'spring' => 21,
                  'summer' => 22,
                  'autumn' => 23,
                  'winter' => 24 );

  # Did the date fields come from interpreting an EDTF 5.2.2 unspecified date?
  # If so, do the reverse of Biber::Utils::parse_date_edtf_unspecified()
  if (my $unspec = $be->get_field("${d}dateunspecified")) {

    # 1990/1999 -> 199u
    if ($unspec eq 'yearindecade') {
      my ($decade) = $be->get_field("${d}year") =~ m/^(\d+)\d$/;
      $overridey = "${decade}u";
      $be->del_field("${d}endyear");
    }
    # 1900/1999 -> 19uu
    elsif ($unspec eq 'yearincentury') {
      my ($century) = $be->get_field("${d}year") =~ m/^(\d+)\d\d$/;
      $overridey = "${century}uu";
      $be->del_field("${d}endyear");
    }
    # 1999-01/1999-12 => 1999-uu
    elsif ($unspec eq 'monthinyear') {
      $overridem = 'uu';
      $be->del_field("${d}endyear");
      $be->del_field("${d}endmonth");
    }
    # 1999-01-01/1999-01-31 -> 1999-01-uu
    elsif ($unspec eq 'dayinmonth') {
      $overrided = 'uu';
      $be->del_field("${d}endyear");
      $be->del_field("${d}endmonth");
      $be->del_field("${d}endday");
    }
    # 1999-01-01/1999-12-31 -> 1999-uu-uu
    elsif ($unspec eq 'dayinyear') {
      $overridem = 'uu';
      $overrided = 'uu';
      $be->del_field("${d}endyear");
      $be->del_field("${d}endmonth");
      $be->del_field("${d}endday");
    }
  }

  # Seasons derived from EDTF dates
  if (my $s = $be->get_field("${d}season")) {
    $overridem = $seasons{$s};
  }
  if (my $s = $be->get_field("${d}endseason")) {
    $overrideem = $seasons{$s};
  }

  # date exists if there is a start year
  if (my $sy = $overridey || $be->get_field("${d}year") ) {
    $datestring .= $sy;

    # Start month
    if (my $sm = $overridem || $be->get_field("${d}month")) {
      $datestring .= "-$sm";
    }

    # Start day
    if (my $sd = $overrided || $be->get_field("${d}day")) {
      $datestring .= "-$sd";
    }

    # Uncertain start date
    if ($be->get_field("${d}dateuncertain")) {
      $datestring .= '?';
    }

    # Circa start date
    if ($be->get_field("${d}datecirca")) {
      $datestring .= '~';
    }


    # End year, can be empty
    if ($be->field_exists("${d}endyear")) {
      $datestring .= '/';
    }

    # End year
    if (my $ey = $be->get_field("${d}endyear")) {
      $datestring .= $ey;

      # End month
      if (my $em = $overrideem || $be->get_field("${d}endmonth")) {
        $datestring .= "-$em";
      }

      # End day
      if (my $ed = $be->get_field("${d}endday")) {
        $datestring .= "-$ed";
      }

      # Uncertain start date
      if ($be->get_field("${d}enddateuncertain")) {
        $datestring .= '?';
      }

      # Circa start date
      if ($be->get_field("${d}enddatecirca")) {
        $datestring .= '~';
      }
    }
  }
  return $datestring;
}

1;

__END__

=head1 AUTHORS

François Charette, C<< <firmicus at ankabut.net> >>
Philip Kime C<< <philip at kime.org.uk> >>

=head1 BUGS

Please report any bugs or feature requests on our Github tracker at
L<https://github.com/plk/biber/issues>.

=head1 COPYRIGHT & LICENSE

Copyright 2009-2016 François Charette and Philip Kime, all rights reserved.

This module is free software.  You can redistribute it and/or
modify it under the terms of the Artistic License 2.0.

This program is distributed in the hope that it will be useful,
but without any warranty; without even the implied warranty of
merchantability or fitness for a particular purpose.

=cut
