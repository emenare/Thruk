package Thruk::Utils::Reports::Render;

=head1 NAME

Thruk::Utils::Render - Report Rendering Utilities Collection

=head1 DESCRIPTION

Report Rendering Utilities Collection. All subs will be available in report
templates. Templates are Template::Toolkit templates and are responsible for
the report layout, the mail content and the required parameters for a report.

=cut

use warnings;
use strict;
use Carp;
use Data::Dumper;
use File::Temp qw/tempfile/;
use File::Slurp;
use MIME::Base64;
use Encode qw/encode_utf8/;

$Thruk::Utils::Reports::Render::c      = undef;
$Thruk::Utils::Reports::Render::locale = {};

##########################################################

=head1 METHODS

=head2 sort_by_key

  sort_by_key()

return sorted list of hashes

=cut

sub sort_by_key {
    my($list, $sort_field) = @_;

    my @sorted = sort { $a->{$sort_field} <=> $b->{$sort_field} } @{$list};
    return \@sorted;
  }


##########################################################

=head2 current_page

  current_page()

return and increase page number

=cut
sub current_page {
    my $page = shift;
    our $current_page;
    $current_page = 0 unless defined $current_page;
    $current_page++;
    $current_page = $page if defined $page;
    return $current_page;
}

##########################################################

=head2 calculate_availability

  calculate_availability()

calculate availability from stash data

=cut
sub calculate_availability {
    my $c = $Thruk::Utils::Reports::Render::c or die("not initialized!");
    Thruk::Utils::Avail::calculate_availability($c);

    my $total_hosts    = 0;
    my $total_services = 0;
    if($c->stash->{'avail_data'}->{'hosts'}) {
        $total_hosts += scalar keys %{$c->stash->{'avail_data'}->{'hosts'}};
    }
    $c->stash->{'total_hosts'} = $total_hosts;

    if($c->stash->{'avail_data'}->{'services'}) {
        for my $hst (keys %{$c->stash->{'avail_data'}->{'services'}}) {
            $total_services += scalar keys %{$c->stash->{'avail_data'}->{'services'}->{$hst}};
        }
    }
    $c->stash->{'total_services'} = $total_services;
    return 1;
}

##########################################################

=head2 outages

  outages($logs, $start, $end, $x, $y, $step1, $step2, $max)

print outages from log entries

=cut
sub outages {
    my($logs, $start, $end) = @_;

    my $c                  = $Thruk::Utils::Reports::Render::c or die("not initialized!");
    my $u                  = $c->stash->{'unavailable_states'};
    my $host               = $c->{'request'}->{'parameters'}->{'host'};
    my $service            = $c->{'request'}->{'parameters'}->{'service'};
    my $only_host_services = $c->{'request'}->{'parameters'}->{'only_host_services'};

    # combine outages
    my @reduced_logs;
    my($combined, $last);
    my $downtime = 0;
    my $in_time  = 1;
    for my $l (@{$logs}) {
        next if $l->{'type'} eq 'TIMEPERIOD START' and $in_time == 1; # skip repeating timeperiod starts
        next if $l->{'type'} eq 'TIMEPERIOD STOP'  and $in_time == 0; # skip repeating timeperiod stops
        if($only_host_services) {
            next if  $l->{'host'} ne $host;
            next if !$l->{'service'};
        } else {
            if($service) {
                next if(defined $l->{'service'} and $l->{'service'} ne $service);
                next if(defined $l->{'host'}    and $l->{'host'}    ne $host);
            } else {
                next if(defined $l->{'host'}    and $l->{'host'}    ne $host);
            }
        }

        $l->{'class'} = lc $l->{'class'};
        $downtime = $l->{'in_downtime'} if defined $l->{'in_downtime'};
        if(!defined $combined) {
            $combined = $l;
        }
        # combine classes if report should contain downtimes too
        if($downtime) {
            if(   (defined $u->{$l->{'class'}}  and !defined $u->{$l->{'class'}.'_downtime'})
               or (!defined $u->{$l->{'class'}} and defined $u->{$l->{'class'}.'_downtime'})
            ) {
                $combined->{'class'} = $combined->{'class'}.'_downtime';
            }
        }
        if($combined->{'class'} ne $l->{'class'}) {
            $combined->{'real_end'} = $l->{'start'};
            push @reduced_logs, $combined if $in_time and $combined->{'class'} ne 'indeterminate';
            undef $combined;
            $combined = $l;
        }
        $in_time = 1 if $l->{'type'} eq 'TIMEPERIOD START';
        $in_time = 0 if $l->{'type'} eq 'TIMEPERIOD STOP';
        $last = $l;
    }
    if(defined $last) {
        $combined->{'real_end'} = $last->{'end'};
        $in_time = 1 if $last->{'type'} eq 'TIMEPERIOD STOP'; # if the last log entry is a stop, it must have been _in_ before
        push @reduced_logs, $combined if $in_time and $combined->{'class'} ne 'indeterminate';
    }

    my $outages = [];
    for my $l (reverse @reduced_logs) {
        next if $end   < $l->{'start'};
        next if $start > $l->{'real_end'};
        $l->{'start'}    = $start if $start > $l->{'start'};
        $l->{'real_end'} = $end   if $end   < $l->{'real_end'};
        $l->{'duration'} = $l->{'real_end'} - $l->{'start'};
        if(defined $u->{$l->{'class'}} and $l->{'duration'} > 0) {
            push @{$outages}, $l;
        }
    }

    return $outages;
}

##########################################################

=head2 set_unavailable_states

  set_unavailable_states($states)

set list of states which count as unavailable

=cut
sub set_unavailable_states {
    my($states) = @_;
    my $c = $Thruk::Utils::Reports::Render::c or die("not initialized!");
    $c->stash->{'unavailable_states'} = {};
    if(defined $states and $states ne '') {
        for my $s (@{$states}) {
            $c->stash->{'unavailable_states'}->{$s} = 1;
        }
    }
    return 1;
}

##########################################################

=head2 get_report_timeperiod

  get_report_timeperiod()

return report timeperiod in human readable form

=cut
sub get_report_timeperiod {
    my($start, $end, $format) = @_;
    return Thruk::Utils::format_date($start, $format).' - '.Thruk::Utils::format_date(($end - 1), $format);
}

##########################################################

=head2 get_events

  get_events()

set events by pattern from eventlog

=cut
sub get_events {
    my $c             = $Thruk::Utils::Reports::Render::c or die("not initialized!");
    my($start,$end)   = Thruk::Utils::get_start_end_for_timeperiod_from_param($c);
    my $pattern          = $c->{'request'}->{'parameters'}->{'pattern'};
    my $exclude_pattern  = $c->{'request'}->{'parameters'}->{'exclude_pattern'};
    die('no pattern') unless defined $pattern;

    my @filter;
    push @filter, { time => { '>=' => $start }};
    push @filter, { time => { '<=' => $end }};

    if($pattern !~ m/^\s*$/mx) {
        die("invalid pattern: ".$pattern) unless(Thruk::Utils::is_valid_regular_expression($c, $pattern));
        push @filter, { message => { '~~' => $pattern }};
    }
    if(defined $exclude_pattern and $exclude_pattern !~ m/^\s*$/mx) {
        die("invalid pattern: ".$exclude_pattern) unless Thruk::Utils::is_valid_regular_expression($c, $exclude_pattern);
        push @filter, { message => { '!~~' => $exclude_pattern }};
    }

    my $event_types = $c->{'request'}->{'parameters'}->{'event_types'};
    # event type filter set?
    if(defined $event_types and @{$event_types} > 0) {
        my @evt_filter;
        my $typeshash = Thruk::Utils::array2hash($event_types);
        my $hst_states = 'both';
        my $svc_states = 'both';
        for my $state (qw/hard soft both/) {
            for my $typ (qw/host service/) {
                if(defined $typeshash->{$typ.'_state_'.$state}) {
                    $hst_states = $state if $typ eq 'host';
                    $svc_states = $state if $typ eq 'service';
                    delete $typeshash->{$typ.'_state_'.$state};
                }
            }
        }

        # host states
        my $hst_softlogfilter;
        if($hst_states eq 'hard') {
            $hst_softlogfilter = { state_type => { '=' => 'HARD' }};
        } elsif($hst_states eq 'soft') {
            $hst_softlogfilter = { state_type => { '=' => 'SOFT' }};
        }
        for my $state (qw/up down unreachable/) {
            if(defined $typeshash->{'host_'.$state}) {
                my $stateid = 0;
                $stateid = 1 if $state eq 'down';
                $stateid = 2 if $state eq 'unreachable';
                push @evt_filter, { '-and' => [ { type => 'HOST ALERT' }, { state => $stateid }, $hst_softlogfilter ] };
                delete $typeshash->{'host_'.$state};
            }
        }

        # service states
        my $svc_softlogfilter;
        if($svc_states eq 'hard') {
            $svc_softlogfilter = { state_type => { '=' => 'HARD' }};
        } elsif($svc_states eq 'soft') {
            $svc_softlogfilter = { state_type => { '=' => 'SOFT' }};
        }
        for my $state (qw/ok warning unknown critical/) {
            if(defined $typeshash->{'service_'.$state}) {
                my $stateid = 0;
                $stateid = 1 if $state eq 'warning';
                $stateid = 2 if $state eq 'critical';
                $stateid = 3 if $state eq 'unknown';
                push @evt_filter, { '-and' => [ { type => 'SERVICE ALERT' }, { state => $stateid }, $svc_softlogfilter ]};
                delete $typeshash->{'service_'.$state};
            }
        }

        # host notifications
        if(defined $typeshash->{'notification_host'}) {
            push @evt_filter, { '-and' => [ { type => 'HOST NOTIFICATION' } ] };
            delete $typeshash->{'notification_host'};
        }

        # service notifications
        if(defined $typeshash->{'notification_service'}) {
            push @evt_filter, { '-and' => [ { type => 'SERVICE NOTIFICATION' } ] };
            delete $typeshash->{'notification_service'};
        }

        # combine filter
        my $or_filter = Thruk::Utils::combine_filter('-or', \@evt_filter);
        push @filter, $or_filter;

        # unknown filter left?
        if(scalar keys %{$typeshash} > 0) {
            die("filter left: ".Dumper($typeshash));
        }
    }

    my $total_filter = Thruk::Utils::combine_filter('-and', \@filter);
    $c->{'db'}->renew_logcache($c, 1);
    my $logs = $c->{'db'}->get_logs(filter => [$total_filter], sort => {'DESC' => 'time'});

    if($c->{'request'}->{'parameters'}->{'reverse'}) {
        @{$logs} = reverse @{$logs};
    }

    $c->stash->{'start'} = $start;
    $c->stash->{'end'}   = $end;
    $c->stash->{'logs'}  = $logs;

    return 1;
}

##########################################################

=head2 get_url

  get_url()

save content from url

=cut
sub get_url {
    my $c = $Thruk::Utils::Reports::Render::c or die("not initialized!");

    my $url = $c->stash->{'param'}->{'url'};
    if($url =~ m|^\w+\.cgi|gmx) {
        $url = '/thruk/cgi-bin/'.$url;
    }
    if($url !~ m/^https?:/mx) {
        if(defined $c->stash->{'param'}->{'theme'}) {
            $url = $url.'&theme='.$c->stash->{'param'}->{'theme'};
        }
        if(defined $c->stash->{'param'}->{'minimal'} and lc($c->stash->{'param'}->{'minimal'}) eq 'yes') {
            $url = $url.'&minimal=1';
        }
        if(defined $c->stash->{'param'}->{'nav'} and lc($c->stash->{'param'}->{'nav'}) eq 'no') {
            $url = $url.'&nav=0';
        }
    }
    if($url !~ m/\?/mx) { $url =~ s/\&/?/mx; }

    my @res = Thruk::Utils::CLI::request_url($c, $url);
    my $result = $res[1];
    if(defined $result and defined $result->{'headers'}) {
        $Thruk::Utils::PDF::ctype = $result->{'headers'}->{'Content-Type'};
        $Thruk::Utils::PDF::ctype =~ s/;.*$//mx;
        if(defined $result->{'headers'}->{'Content-Disposition'}) {
            my $file = $result->{'headers'}->{'Content-Disposition'};
            if($file =~ m/filename="(.*)"/mx) {
                $Thruk::Utils::PDF::attachment = $1;
            }
        } else {
            my $ext = 'dat';
            if($Thruk::Utils::PDF::ctype eq 'text/html') {
                $ext = 'html';
            } elsif($Thruk::Utils::PDF::ctype =~ m|image/(.*)$|mx) {
                $ext = $1;
            }
            if($url =~ m|^/thruk/cgi\-bin/([^\.]+)\.cgi|mx) {
                $Thruk::Utils::PDF::attachment = $1.'.'.$ext;
            } else {
                $Thruk::Utils::PDF::attachment = 'url_report.'.$ext;
            }
        }
        if($Thruk::Utils::PDF::ctype eq 'text/html') {
            my $include_js = 1;
            if(!defined $c->stash->{'param'}->{'js'} or $c->stash->{'param'}->{'js'} eq 'no') {
                $include_js = 0;
            }
            $result->{'result'} = html_all_inclusive($c, $url, $result->{'result'}, $include_js);
        }
        my $attachment = $c->stash->{'attachment'};
        open(my $fh, '>', $attachment);
        binmode $fh, ":encoding(UTF-8)";
        print $fh $result->{'result'};
        Thruk::Utils::IO::close($fh, $attachment);
    }
    return $result->{'result'};
}

##########################################################

=head2 count_event_totals

  count_event_totals()

count host / service totals from events

=cut
sub count_event_totals {
    my($logs) = @_;
    my $totals = {
        'host' => {
            'up'            => 0,
            'down'          => 0,
            'unreachable'   => 0,
        },
        'service' => {
            'ok'            => 0,
            'warning'       => 0,
            'unknown'       => 0,
            'critical'      => 0,
        },
    };

    for my $l (@{$logs}) {
        next unless defined $l->{'state'};
        if($l->{'service_description'}) {
            $l->{'state'} == 0 && $totals->{'service'}->{'ok'}++;
            $l->{'state'} == 1 && $totals->{'service'}->{'warning'}++;
            $l->{'state'} == 2 && $totals->{'service'}->{'critical'}++;
            $l->{'state'} == 3 && $totals->{'service'}->{'unknown'}++;
        }
        elsif($l->{'host_name'}) {
            $l->{'state'} == 0 && $totals->{'host'}->{'up'}++;
            $l->{'state'} == 1 && $totals->{'host'}->{'down'}++;
            $l->{'state'} == 2 && $totals->{'host'}->{'unreachable'}++;
        }
    }

    return $totals;
}

##########################################################

=head2 get_availability_percents

  get_availability_percents()

return list of availability percent as json list

=cut
sub get_availability_percents {
    my $c = $Thruk::Utils::Reports::Render::c or die("not initialized!");

    my $host               = $c->{'request'}->{'parameters'}->{'host'};
    my $service            = $c->{'request'}->{'parameters'}->{'service'};
    my $avail_data         = $c->stash->{'avail_data'};
    my $unavailable_states = $c->stash->{'unavailable_states'};
    confess("No host in parameters:\n".    Dumper($c->{'request'}->{'parameters'})) unless defined $host;
    return(Thruk::Utils::Avail::get_availability_percents($avail_data, $unavailable_states, $host, $service));
}


##########################################################

=head2 get_month_name

  get_month_name(date, monthNamesList)

return human readable month name

=cut
sub get_month_name {
    my($date, $months) = @_;
    $date =~ m/\d+\-(\d+)/mx;
    my $nr = $1 - 1;
    if($nr > 11) { $nr = $nr - 12; }
    return($months->[$nr]);
}

##########################################################

=head2 get_week_name

  get_week_name(date)

return human readable week name

=cut
sub get_week_name {
    my($date, $abbr) = @_;
    $date =~ m/\d+\-WK(\d+)/mx;
    return($abbr.$1);
}

##########################################################

=head2 get_day_name

  get_day_name(date)

return human readable day name

=cut
sub get_day_name {
    my($date, $months) = @_;
    $date =~ m/(\d+)\-(\d+)\-(\d+)/mx;
    return(get_month_name($1.'-'.$2, $months).' '.$3);
}


##########################################################

=head2 get_pnp_image

  get_pnp_image(hst, svc, start, end, width, height)

return base64 encoded pnp image if possible.
A string will be returned if no PNP graph can be exported.

=cut
sub get_pnp_image {
    my($hst, $svc, $start, $end, $width, $height, $source) = @_;
    my $c        = $Thruk::Utils::Reports::Render::c or die("not initialized!");
    my $exporter = $c->config->{'Thruk::Plugin::Reports2'}->{'pnp_export'} || $c->config->{plugin_path}.'/plugins-enabled/reports2/script/pnp_export.sh';
    my $pnpurl   = "";

    if($svc) {
        my $svcdata = $c->{'db'}->get_services(filter => [{ host_name => $hst, description => $svc }]);
        $pnpurl     = Thruk::Utils::get_pnp_url($c, $svcdata->[0], 1);
    } else {
        my $hstdata = $c->{'db'}->get_hosts(filter => [{ name => $hst }]);
        $pnpurl     = Thruk::Utils::get_pnp_url($c, $hstdata->[0], 1);
        $svc = '_HOST_';
    }

    my($fh, $filename) = tempfile();
    my $cmd = $exporter.' "'.$hst.'" "'.$svc.'" "'.$width.'" "'.$height.'" "'.$start.'" "'.$end.'" "'.$pnpurl.'" "'.$filename.'" "'.$source.'"';
    `$cmd`;
    if(-s $filename) {
        my $imgdata  = read_file($filename);
        my @lines = read_file($filename);
        unlink($filename);
        my $nb_lines = scalar @lines;
        return '' if substr($imgdata, 0, 10) !~ m/PNG/mx; # check if this is a real image
        return '' if $nb_lines < 5; # check if this is a real image
        return 'data:image/png;base64,'.encode_base64($imgdata, '');
    }
    unlink($filename);
    return "";
}


##########################################################

=head2 dump

  dump(...)

dump variables to stderr

=cut
sub dump {
    print STDERR  Dumper(@_);
    return "";
}

##########################################################

=head2 html_all_inclusive

  html_all_inclusive($c, $url, $page, [$include_js])

make html page include all remove css, js and images

=cut
sub html_all_inclusive {
    my($c, $url, $page, $include_js) = @_;
    $include_js = 0 unless defined $include_js;
    $c->stash->{'param'}->{'js'} = $include_js;
    my $report_base_url = $c->config->{'Thruk::Plugin::Reports2'}->{'report_base_url'} || $c->config->{'report_base_url'};
    $page = _replace_css_and_images($page, $url, $report_base_url);
    $page = _replace_links($page, $url, $report_base_url);

    if(!$include_js) {
        $page =~ s/<script[^>]*>.*?<\/script>//gsmxi;
    }
    return($page);
}

##########################################################

=head2 page_splice

  page_splice($data, $size_per_page, $max_pages)

cut data in chunks of $size_per_page size. $max_pages is the maximum number of
pages or -1 for all.

=cut
sub page_splice {
    my($data, $size_per_page, $max_pages) = @_;
    $max_pages  = 1 unless $max_pages =~ m/^\-?\d+$/mx;
    my $paged   = [];
    my $pages   = 0;
    my $page    = 0;
    my $entries = scalar @{$data};
    while($page < $max_pages || $max_pages == -1) {
        my $start = $page * $size_per_page;
        my $end   = $start + $size_per_page - 1;
        $end = $entries-1 if $end > $entries - 1;
        $paged->[$page] = [@{$data}[$start..$end]];
        $page++;
        last if $end >= $entries - 1;
    }
    return($paged);
}

##########################################################
# INTERNAL SUBS
##########################################################
sub _replace_css_and_images {
    my($text, $url, $report_base_url) = @_;
    my $c = $Thruk::Utils::Reports::Render::c or die("not initialized!");
    # replace images for already existing css
    while(
    $text =~ s/(<style.*?)
              (url\()
              ([^:)]*)
              (\))
              (.*?<\/style>)
             /&_replace_css_img($url, $report_base_url, '',$2,$3,$4,$1,$5)/gemxis) {}
    $text =~ s/(<img[^>]*src=)
               ("|')
               ([^'"]*)
               ("|')
               ([^>]*>)
              /&_replace_img($url, $report_base_url, $1,$2,$3,$4,$5)/gemxi;
    $text =~ s/(<input[^>]*src=)
               ("|')
               ([^'"]*)
               ("|')
               ([^>]*>)
              /&_replace_img($url, $report_base_url, $1,$2,$3,$4,$5)/gemxi;
    $text =~ s/<link[^>]*href=("|')([^'"]*\.css[^"']*)("|')[^>]*>/&_replace_css($url, $report_base_url,$2)/gemxi;
    $text =~ s/<script[^>]*src=("|')([^'"]*\.js[^"']*)("|')[^>]*><\/script>/&_replace_js($url, $report_base_url, $2)/gemxi;
    return $text;
}

##########################################################
sub _replace_links {
    my($text, $url, $baseurl) = @_;
    return $text unless defined $baseurl;
    $baseurl =~ s|/thruk/.*||gmx;
    $baseurl =~ s|/$||gmx;
    $baseurl .= '/thruk/cgi-bin/';
    $text =~ s/(<a[^>]*href=)
               ("|')
               ([^'"]*)
               ("|')
               ([^>]*>)
              /&_replace_link($baseurl,$1,$2,$3,$4,$5)/gemxi;

    $text =~ s/(<form[^>]*action=)
               ("|')
               ([^'"]*)
               ("|')
               ([^>]*>)
              /&_replace_link($baseurl,$1,$2,$3,$4,$5)/gemxi;

    return $text;
}

##########################################################
sub _replace_link {
    my($baseurl,$a,$b,$url,$d,$e) = @_;
    if(    $url !~ m|^\w+://|mx
       and $url !~ m|^\#|mx
       and $url !~ m|^mailto:|mx
      ) {
        # absolute url
        if($url =~ m/^\//mx) {
            $baseurl =~ s|/thruk/cgi\-bin/$||mx;
            $url = $baseurl.$url;
        }
        # relative url
        else {
            $url = $baseurl.$url;
        }
    }
    return $a.$b.$url.$d.$e;
}

##########################################################
sub _replace_img {
    my($baseurl, $report_base_url, $a,$b,$url,$d,$e) = @_;
    return "" if $url eq '';
    # skip some images
    return "" if $url =~ m/waiting\.gif$/mx;

    our $image_cache;
    $image_cache = {} unless defined $image_cache;
    return $image_cache->{$url} if defined $image_cache->{$url};

    my $c = $Thruk::Utils::Reports::Render::c or die("not initialized!");

    # dynamic images
    if($url =~ m/^\w+\.cgi/mx) {
        if($url =~ m|^\w+\.cgi|gmx) {
            $url = '/thruk/cgi-bin/'.$url;
        }
        my @res = Thruk::Utils::CLI::request_url($c, $url);
        my $result = $res[1];
        my $text = "data:image/png;base64,".encode_base64($result->{'result'}, '');
        $image_cache->{$url} = $a.$b.$text.$d.$e;
        return $image_cache->{$url};
    }
    # static images
    elsif($url =~ m/\.(\w+)$/mx) {
        my $datatype = _get_datatype($1);
        my $data     = _read_static_content_file($baseurl, $report_base_url, $url);
        my $text;
        eval {
            $text = $datatype.";base64,".encode_base64($data, '');
        };
        if($@) {
            $text = $datatype.";base64,".encode_base64(encode_utf8($data), '');
        }
        $image_cache->{$url} = $a.$b.$text.$d.$e;
        return $image_cache->{$url};
    }
    elsif($url =~ m/^data:/mx) {
        $image_cache->{$url} = $a.$b.$url.$d.$e;
        return $image_cache->{$url};
    }

    #croak("unknown image url: ".$a.$b.$url.$d.$e);
    return "";
}

##########################################################
sub _replace_css {
    my($baseurl, $report_base_url, $url) = @_;
    my $css = _read_static_content_file($baseurl, $report_base_url, $url);
    $css =~ s/(url\()
              ([^)]*)
              (\))
             /&_replace_css_img($baseurl, $report_base_url, $url,$1,$2,$3)/gemx;
    my $text = "<style type='text/css'>\n<!--\n";
    $text .= $css;
    $text .= "\n-->\n</style>\n";
    return $text;
}

##########################################################
sub _replace_js {
    my($baseurl, $report_base_url, $url) = @_;
    my $c = $Thruk::Utils::Reports::Render::c or die("not initialized!");
    if(!defined $c->stash->{'param'}->{'js'} or $c->stash->{'param'}->{'js'} eq 'no') {
        return "";
    }
    if($url =~ m/excanvas\.js$/mx) {
        return "<script language='javascript' type='text/javascript' src='".$url."'></script>";
    }
    my $text = "<script type='text/javascript'>\n<!--\n";
    $text .= _read_static_content_file($baseurl, $report_base_url, $url);
    $text .= "\n-->\n</script>\n";
    return $text;
}

##############################################
sub _replace_css_img {
    my($baseurl, $report_base_url,$css, $a,$file,$b,$pre,$post) = @_;
    $pre  = '' unless defined $pre;
    $post = '' unless defined $post;
    # static images
    if($file =~ s/^('|")//gmx) {
        $pre  = $1;
    }
    if($file =~ s/('|")$//gmx) {
        $post = $1;
    }

    $file =~ s/\?.*$//gmx;
    $file =~ s/\#.*$//gmx;

    return($pre.$post) unless $css;

    if($file =~ m/\.(\w+)$/mx) {
        my $datatype = _get_datatype($1);
        my $data     = $datatype.";base64,";
        $css         = _get_url($baseurl, $css) ;
        my $content = _read_static_content_file($css, $report_base_url, $file);
        eval {
            $data .= encode_base64($content, '');
        };
        if($@) {
            $data .= encode_base64(encode_utf8($content), '');
        }

        return "$pre$a$data$b$post";
    }
    if($file =~ m|^data:|mx) {
        return($file);
    }
    croak("_replace_css_img($baseurl, ".($report_base_url||'').", $css) $file: unknown url format") if $ENV{'TEST_AUTHOR'};
    return($pre.$post);
}

##############################################
sub _read_static_content_file {
    my($baseurl, $report_base_url, $url) = @_;
    my $c = $Thruk::Utils::Reports::Render::c or die("not initialized!");
    my $product_prefix = $c->config->{'product_prefix'};
    if(!$baseurl && $url !~ m/^https?:/mx && $url !~ m/^\/\Q$product_prefix\E\//mx) {
        confess("no baseurl")
    }
    $url = _get_url($baseurl, $url) if $baseurl;

    our $image_cache;
    $image_cache = {} unless defined $image_cache;
    return $image_cache->{$url} if defined $image_cache->{$url};

    if($url =~ m/^https?:/mx) {
       my $content  = Thruk::Utils::CLI::request_url($c, $url);
       $image_cache->{$url} = $content;
       return($content);
    }
    $url =~ s|^.*/thruk/||gmx;
    while($url =~ m|[^/\.]+/\.\./|mx) {
        $url   =~ s|[^/\.]+/\.\./||mx;
    }
    my $file;

    my $logo_path_prefix = $c->config->{'logo_path_prefix'};
    my $logo_url         = $url;
    $logo_url            =~ s/^$logo_path_prefix//gmx;

    # image from theme
    my $default = $c->config->{'default_theme'};
    if($url =~ m|^themes/|mx) {
        $url =~ s|^themes/||gmx;
        my $themes_dir = $c->config->{'themes_path'} || $c->config->{'project_root'}.'/themes';
        $file = $themes_dir . '/themes-enabled/' . $url;
        if(!-e $file and defined $default) {
            $url =~ s|^Thruk/|$default/|gmx;
            # disabled theme? try available folder
            $file = $themes_dir . '/themes-available/' . $url;
        }
        # still no luck?
        if(!-e $file) {
            $file = $c->config->{'project_root'}.'/themes/themes-available/' . $url;
        }
    }

    # image from plugin
    elsif($url =~ m|^plugins/|mx) {
        $url =~ s|^plugins/([^/]+)/|$1/root/|gmx;
        my $plugins_dir = $c->config->{'plugin_path'} || $c->config->{'project_root'}."/plugins";
        $file = $plugins_dir . '/plugins-enabled/' . $url;
    }

    # icon image?
    elsif(defined $c->config->{'physical_logo_path'} and -e $c->config->{'physical_logo_path'}.'/'.$logo_url) {
        $file = $c->config->{'physical_logo_path'}.'/'.$logo_url;
    }

    else {
        $file = $c->config->{'project_root'}."/root/thruk/".$url;
    }

    return '' if $url eq '';
    if(-e $file) {
        return read_file($file);
    }

    croak("_read_static_content_file($baseurl, ".($report_base_url||'').", $url) $file: $!") if $ENV{'TEST_AUTHOR'};
    $c->log->debug("_read_static_content_file($baseurl, ".($report_base_url||'').", $url) $file: $!");
    return "";
}

##############################################

=head2 _get_url

  returns a absolute url

  expects
  $VAR1 = origin url
  $VAR2 = target link

=cut
sub _get_url {
    my($url, $link) = @_;

    confess("blah") if($url eq '' and $link eq '');

    # append trailing slash
    if($url =~ m/^https?:\/\/[^\/]+$/mx) {
        $url .= '/';
    }

    if($link !~ m/^https?:/mx) {
        my $newloc = $url;
        $newloc    =~ s/^(.*\/).*$/$1/gmxo;
        $newloc    .= $link;
        while($newloc =~ s|/[^\/]+/\.\./|/|gmxo) {}
        $link = $newloc;
    }

    return($link) if $url =~ m%/?thruk/(cgi\-bin|themes|plugins|javascript)/%mx;

    # split original url in host, path and file
    if($url =~ m/^(http|https):\/\/([^\/]*)(|\/|:\d+)(.*?)$/mx) {
        my $host     = $1."://".$2.$3;
        $host        =~ s/\/$//mx;      # remove last /
        my $fullpath = $4 || '';
        $fullpath    =~ s/\?.*$//mx;
        $fullpath    =~ s/^\///mx;
        my($path,$file) = ('', '');
        if($fullpath =~ m/^(.+)\/(.*)$/mx) {
            $path = $1;
            $file = $2;
        }
        else {
            $file = $fullpath;
        }
        $path =~ s/^\///mx; # remove first /

        if($link =~ m/^(http|https):\/\//mx) {
            return $link;
        }
        elsif($link =~ m/^\//mx) { # absolute link
            return $host.$link;
        }
        elsif($path eq '') {
            return $host."/".$link;
        } else {
            return $host."/".$path."/".$link;
        }
    }

    die("unknown url scheme in _get_url('".$url."', '".$link."')");
    return;
}

##############################################
sub _get_datatype {
    my($suffix) = @_;
    my $datatype = "data:image/".$suffix;
    if($suffix eq 'eot') {
        $datatype = "data:font/eot";
    }
    if($suffix eq 'woff') {
        $datatype = "data:font/woff";
    }
    if($suffix eq 'ttf') {
        $datatype = "data:font/ttf";
    }
    if($suffix eq 'svg') {
        $datatype = "data:font/svg";
    }
    return($datatype);
}

##############################################
sub _locale {
    my($fmt) = shift;
    my $tr  = $Thruk::Utils::Reports::Render::locale;
    $fmt = $tr->{$fmt} || $fmt;
    return sprintf($fmt, @_);
}

##############################################

=head1 EXAMPLES

See the shipped reports for some examples. Shipped reports are in the
'plugins/plugins-available/reports2/templates/reports' folder.

=head1 AUTHOR

Sven Nierlein, 2009-2014, <sven@nierlein.org>

=head1 LICENSE

This library is free software, you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

##############################################

1;
