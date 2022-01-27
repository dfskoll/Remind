package Remind::PDF::Month;
use strict;
use warnings;

use Cairo;
use Pango;

use Remind::PDF::Entry;
use Encode;

use JSON::MaybeXS;

=head1 NAME

Remind::Month - hold one month's worth of calendar data

=cut

sub create_from_stream
{
        my ($class, $in, $specials_accepted) = @_;
        while (<$in>) {
                chomp;
                if ($_ eq '# rem2ps begin'  ||
                    $_ eq '# rem2ps2 begin') {
                        my $self = bless {}, $class;
                        return $self->read_one_month($in, $_, $specials_accepted);
                } elsif ($_ eq '[') {
                        return (undef, "Unsupported format: Use remind -pp, not remind -ppp");
                }
        }
        return (undef, "Could not find any remind -p output anywhere");
}

sub read_one_month
{
        my ($self, $in, $first_line, $specials_accepted) = @_;
        $self->{entries} = [];
        $self->{daynames} = [];
        $self->{monthname} = '';
        $self->{year} = '';
        $self->{daysinmonth} = 0;
        $self->{firstwkday} = 0;
        $self->{mondayfirst} = 0;
        $self->{prevmonthname} = '';
        $self->{nextmonthname} = '';
        $self->{daysinprevmonth} = 0;
        $self->{daysinnextmonth} = 0;
        $self->{prevmonthyear} = 0;
        $self->{nextmonthyear} = 0;

        for (my $i=0; $i<=31; $i++) {
                $self->{entries}->[$i] = [];
        }

        my $line = $in->getline();
        chomp($line);

        # Month Year Days FirstWkday MondayFirst
        if ($line =~ /^(\S+) (\d+) (\d+) (\d+) (\d+)/) {
                $self->{monthname} = $1;
                $self->{year} = $2;
                $self->{daysinmonth} = $3;
                $self->{firstwkday} = $4;
                $self->{mondayfirst} = $5;
        } else {
                return (undef, "Cannot interpret line: $line");
        }

        # Day names
        $line = $in->getline();
        chomp($line);
        if ($line =~ /^\S+ \S+ \S+ \S+ \S+ \S+ \S+$/) {
                @{$self->{daynames}} = split(/ /, $line);
        } else {
                return (undef, "Cannot interpret line: $line");
        }

        # Prev month, num days
        $line = $in->getline();
        chomp($line);
        if ($line =~ /^\S+ \d+$/) {
                ($self->{prevmonthname}, $self->{daysinprevmonth}) = split(/ /, $line);
        } else {
                return (undef, "Cannot interpret line: $line");
        }
        # Next month, num days
        $line = $in->getline();
        chomp($line);
        if ($line =~ /^\S+ \d+$/) {
                ($self->{nextmonthname}, $self->{daysinnextmonth}) = split(/ /, $line);
        } else {
                return (undef, "Cannot interpret line: $line");
        }

        if ($first_line eq '# rem2ps2 begin') {
                # remind -pp format
                return $self->read_one_month_pp($in, $specials_accepted);
        }

        # Old-style "remind -p"
        # TODO: Eventually support this?
        return (undef, "Format not supported: Use -pp or -ppp, not plain -p");
}

sub read_one_month_pp
{
        my ($self, $in, $specials_accepted) = @_;

        my $json = JSON::MaybeXS->new(utf8 => 1);
        my $line;
        while ($line = $in->getline()) {
                chomp($line);
                if ($line eq '# rem2ps2 end') {
                        return ($self, undef);
                }
                my $hash;
                eval {
                        $hash = $json->decode($line);
                };
                if (!$hash) {
                        return (undef, "Unable to decode JSON: $@");
                }

                my $day = $hash->{date};
                $day =~ s/^\d\d\d\d-\d\d-//;
                $day =~ s/^0//;
                if ($self->accept_special($hash, $specials_accepted)) {
                        push(@{$self->{entries}->[$day]}, Remind::PDF::Entry->new_from_hash($hash));
                }
        }
        return (undef, "Missing # rem2ps2 end marker");
}

sub accept_special
{
        my ($self, $hash, $specials_accepted) = @_;
        return 1 unless exists($hash->{passthru});
        return 1 if $specials_accepted->{lc($hash->{passthru})};
        return 0;
}

sub find_last_special
{
        my ($self, $special, $entries) = @_;
        my $class = "Remind::PDF::Entry::$special";
        my $found = undef;
        foreach my $e (@$entries) {
                $found = $e if ($e->isa($class));
        }
        return $found;
}

sub render
{
        my ($self, $cr, $settings) = @_;

        $self->{horiz_lines} = [];
        $cr->set_line_cap('square');
        my $so_far = $self->draw_title($cr, $settings);

        # Top line
        push(@{$self->{horiz_lines}}, $so_far);

        my $top_line = $so_far;

        $so_far = $self->draw_daynames($cr, $settings, $so_far);

        # Line under the days
        push(@{$self->{horiz_lines}}, $so_far);

        # First column
        my $first_col = $self->{firstwkday};
        if ($self->{mondayfirst}) {
                $first_col--;
                if ($first_col < 0) {
                        $first_col = 6;
                }
        }

        # Last column
        my $last_col = ($first_col + $self->{daysinmonth} - 1) % 7;

        # Number of rows
        my $rows = 1;
        my $last_day_on_row = 7 - $first_col;
        while ($last_day_on_row < $self->{daysinmonth}) {
                print STDERR "$rows $last_day_on_row\n";
                $last_day_on_row += 7;
                $rows++;
        }

        # Add a row for small calendars if necessary
        if (($settings->{small_calendars} != 0) && ($first_col == 0) && ($last_col == 6)) {
                $rows++;
        }

        my ($start_col, $start_day);
        for (my $row = 0; $row < $rows; $row++) {
                if ($row == 0) {
                        $start_day = 1;
                        $start_col = $first_col;
                } else {
                        $start_col = 0;
                }
                print STDERR "Drawing row $row $start_day $start_col\n";
                $so_far = $self->draw_row($cr, $settings, $so_far, $row, $start_day, $start_col);
                $start_day += 7 - $start_col;
                push(@{$self->{horiz_lines}}, $so_far);
        }

        # The vertical lines
        my $cell = ($settings->{width} - $settings->{margin_left} - $settings->{margin_right}) / 7;
        for (my $i=0; $i<=7; $i++) {
                $cr->move_to($settings->{margin_left} + $i * $cell, $top_line);
                $cr->line_to($settings->{margin_left} + $i * $cell, $so_far);
                $cr->stroke();
        }

        # And the horizontal lines
        foreach my $y (@{$self->{horiz_lines}}) {
                $cr->move_to($settings->{margin_left}, $y);
                $cr->line_to($settings->{width} - $settings->{margin_right}, $y);
                $cr->stroke();
        }
}

sub draw_row
{
        my ($self, $cr, $settings, $so_far, $row, $start_day, $start_col) = @_;

        my $col = $start_col;
        my $day = $start_day;
        my $height = 0;

        # Preview them to figure out the row height...
        while ($col < 7) {
                my $h = $self->draw_day($cr, $settings, $so_far, $day, $col, 0);
                $height = $h if ($h > $height);
                $day++;
                $col++;
                last if ($day > $self->{daysinmonth});
        }

        # Now draw for real
        $col = $start_col;
        $day = $start_day;
        while ($col < 7) {
                $self->draw_day($cr, $settings, $so_far, $day, $col, $height);
                $day++;
                $col++;
                last if ($day > $self->{daysinmonth});
        }

        return $so_far + $height + $settings->{border_size};
}

sub col_box_coordinates
{
        my ($self, $so_far, $col, $height, $settings) = @_;
        my $cell = ($settings->{width} - $settings->{margin_left} - $settings->{margin_right}) / 7;

        return (
                $settings->{margin_left} + $cell * $col,
                $so_far,
                $settings->{margin_left} + $cell * ($col + 1),
                $so_far + $height + $settings->{border_size},
            );
}

sub draw_day
{
        my ($self, $cr, $settings, $so_far, $day, $col, $height) = @_;

        my ($x1, $y1, $x2, $y2) = $self->col_box_coordinates($so_far, $col, $height, $settings);

        # Do shading if we're in "for real" mode
        if ($height) {
                my $shade = $self->find_last_special('shade', $self->{entries}->[$day]);
                if ($shade) {
                        $cr->save;
                        $cr->set_source_rgb($shade->{r} / 255,
                                            $shade->{g} / 255,
                                            $shade->{b} / 255);
                        $cr->rectangle($x1, $y1, $x2 - $x1, $y2 - $y1);
                        $cr->fill();
                        $cr->restore;
                }
        }
        # Draw the day number
        my $layout = Pango::Cairo::create_layout($cr);
        $layout->set_text($day);
        my $desc = Pango::FontDescription->from_string($settings->{daynum_font} . ' ' . $settings->{daynum_size});

        $layout->set_font_description($desc);
        my ($wid, $h) = $layout->get_pixel_size();


        # Don't actually draw if we're just previewing to get the cell height
        if ($height) {
                $cr->save;
                if ($settings->{numbers_on_left}) {
                        $cr->move_to($x1 + $settings->{border_size}, $so_far + $settings->{border_size});
                } else {
                        $cr->move_to($x2 - $settings->{border_size} - $wid, $so_far + $settings->{border_size});
                }
                Pango::Cairo::show_layout($cr, $layout);
                $cr->restore();
        }

        $so_far += $h + 2 * $settings->{border_size};
        my $entry_height = 0;
        my $done = 0;
        foreach my $entry (@{$self->{entries}->[$day]}) {
                # Moon should not adjust height
                if ($entry->isa('Remind::PDF::Entry::moon')) {
                        $entry->render($self, $cr, $settings, $so_far, $day, $col, $height);
                        next;
                }
                if ($done) {
                        $so_far += $settings->{border_size};
                        $entry_height += $settings->{border_size};
                }
                $done = 1;
                my $h2 = $entry->render($self, $cr, $settings, $so_far, $day, $col, $height);
                $entry_height += $h2;
                $so_far += $h2;
        }
        return $h + $entry_height + 2 * $settings->{border_size};
}

sub draw_daynames
{
        my ($self, $cr, $settings, $so_far) = @_;

        my $w = $settings->{width} - $settings->{margin_left} - $settings->{margin_right};
        my $cell = $w/7;

        $so_far += $settings->{border_size};
        my $height = 0;
        for (my $i=0; $i<7; $i++) {
                my $j;
                if ($self->{mondayfirst}) {
                        $j = ($i + 1) % 7;
                } else {
                        $j = $i;
                }
                my $layout = Pango::Cairo::create_layout($cr);
                $layout->set_text(Encode::decode('UTF-8', $self->{daynames}->[$j]));
                my $desc = Pango::FontDescription->from_string($settings->{header_font} . ' ' . $settings->{header_size});

                $layout->set_font_description($desc);

                my ($wid, $h) = $layout->get_pixel_size();
                $cr->save;
                $cr->move_to($settings->{margin_left} + $i * $cell + $cell/2 - $wid/2, $so_far);
                Pango::Cairo::show_layout($cr, $layout);
                $cr->restore();
                if ($h > $height) {
                        $height = $h;
                }
        }
        return $so_far + $height + $settings->{border_size};
}

sub draw_title
{
        my ($self, $cr, $settings) = @_;
        my $title = $self->{monthname} . ' ' . $self->{year};

        my $layout = Pango::Cairo::create_layout($cr);
        $layout->set_text(Encode::decode('UTF-8', $title));
        my $desc = Pango::FontDescription->from_string($settings->{title_font} . ' ' . $settings->{title_size});

        $layout->set_font_description($desc);

        my ($w, $h) = $layout->get_pixel_size();
        $cr->save();
        $cr->move_to($settings->{width}/2 - $w/2, $settings->{margin_top});
        Pango::Cairo::show_layout($cr, $layout);
        $cr->restore();
        return $h + $settings->{margin_top} + $settings->{border_size};
}

1;
