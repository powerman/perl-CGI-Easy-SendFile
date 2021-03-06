package CGI::Easy::SendFile;
use 5.010001;
use warnings;
use strict;
use utf8;
use Carp;

our $VERSION = 'v2.0.1';

use Export::Attrs;
use List::Util qw( min );
use CGI::Easy::Util qw( date_http );

use constant STAT_MTIME => 9;
use constant BUF_SIZE   => 64*1024;


sub send_file :Export {
    my ($r, $h, $file, $opt) = @_;
    my %p = (
        type    => 'application/x-download',
        range   => !ref $file,
        cache   => 0,
        inline  => 0,
        %{$opt || {}},
    );

    if (!$p{cache}) {
        $h->{'Expires'} = 'Sat, 01 Jan 2000 00:00:00 GMT';
    }
    else {
        delete $h->{'Expires'};
        if (!ref $file) {
            my $lastmod = date_http((stat $file)[STAT_MTIME]);
            my $ifmod = $r->{ENV}{HTTP_IF_MODIFIED_SINCE};
            if ($ifmod && $ifmod eq $lastmod) {
                $h->{'Status'} = '304 Not Modified';
                return \q{};
            }
            else {
                $h->{'Last-Modified'} = $lastmod;
            }
        }
    }

    my $len = ref $file ? length ${$file} : -s $file;
    my ($start, $end) = _get_range($p{range}, $r, $len);
    my $size = $end-$start+1;

    $h->{'Accept-Ranges'}       = 'bytes';
    $h->{'Content-Length'}      = $size;
    $h->{'Content-Type'}        = $p{type};
    if (!$p{inline}) {
        $h->{'Content-Disposition'} = 'attachment';
    }
    if (!($start == 0 && $end == $len-1)) {
        $h->{Status}            = '206 Partial Content';
        $h->{'Content-Range'}   = "bytes $start-$end/$len";
    }

    return _read_block($file, $start, $size);
}

sub _get_range {
    my ($allow_range, $r, $len) = @_;
    my ($start, $end) = (0, $len-1);
    if ($allow_range && defined $r->{ENV}{HTTP_RANGE}) {
        if ($r->{ENV}{HTTP_RANGE} =~ /\Abytes=(\d*)-(\d*)\z/ixms) {
            my ($from, $to) = ($1, $2);
            if ($from ne q{} && $to ne q{} && $from <= $to && $to < $len) { # 0-0, 0-499, 500-999
                $start  = $from;
                $end    = $to;
            }
            elsif ($from ne q{} && $to eq q{} && $from < $len) {            # 0-, 500-, 999-
                $start  = $from;
            }
            elsif ($from eq q{} && $to ne q{} && 0 < $to && $to <= $len) {  # -1, -500, -1000
                $start  = $len - $to;
            }
        }
    }
    return ($start, $end);
}

sub _read_block {
    my ($file, $start, $size) = @_;
    my $data = q{};
    open my $fh, '<', $file or croak "open: $!";
    seek $fh, $start, 0;
    my ($n, $buf);
    while ($n = read $fh, $buf, min($size, BUF_SIZE)) {
        $size -= length $buf;
        $data .= $buf;
    }
    croak "read: $!" if !defined $n;
    close $fh or croak "close: $!";
    return \$data;
}


1; # Magic true value required at end of module
__END__

=encoding utf8

=head1 NAME

CGI::Easy::SendFile - send files from CGI to browser


=head1 VERSION

This document describes CGI::Easy::SendFile version v2.0.1


=head1 SYNOPSIS

    use CGI::Easy::SendFile qw( send_file );

    my $r = CGI::Easy::Request->new();
    my $h = CGI::Easy::Headers->new();

    my $data = send_file($r, $h, '/path/file.zip');
    print $h->compose();
    print ${$data};

    # -- send "file" generated in memory instead of real file
    my $dynamic_file = '…some binary data…';
    my $data = send_file($r, $h, \$dynamic_file);

    # -- simulate static image served by web server 
    #    (without "download file" dialog popup in browser)
    my $data = send_file($r, $h, 'avatar.png', {
            type    => 'image/png',
            cache   => 1,
            inline  => 1,
    });


=head1 DESCRIPTION

This module provide single function, which helps you prepare CGI reply for
sending file to browser.


=head1 EXPORTS

Nothing by default, but all documented functions can be explicitly imported.


=head1 INTERFACE 

=head2 send_file

    $data = send_file( $r, $h, '/path/file.zip' );
    $data = send_file( $r, $h, '/path/file.zip', \%opt );
    $data = send_file( $r, $h, \$dynamic_file );
    $data = send_file( $r, $h, \$dynamic_file, \%opt );

Prepare HTTP headers and content for CGI reply to send file.

    $r      CGI::Easy::Request object
    $h      CGI::Easy::Headers object
    $file   STRING (file name) or SCALARREF (file contents)
    %opt
      {type}    STRING (default "application/x-download")
      {range}   BOOL (default TRUE if $file is STRING,
                              FALSE if $file is SCALARREF)
      {cache}   BOOL (default FALSE)
      {inline}  BOOL (default FALSE)

=over

=item {type}

Custom value for 'Content-Type' header. These are equivalents:

    $data = send_file($r, $h, $file, {type=>'image/png'});

    $data = send_file($r, $h, $file);
    $h->{'Content-Type'} = 'image/png';

=item {range}

Enable/disable support for sending partial file contents, if requested
(this is usually used by file downloader applications to fetch files
faster using several simultaneous connections to download different file
parts). You shouldn't enable this option for dynamic files generated by
your CGI if contents of these files may differ for different CGI requests
sent by same user to same url.

If your web server configured to gzip CGI replies, it will disable this
feature. To make this feature working disable gzip in web server (usually
by adding C< SetEnv no-gzip > in C< .htaccess > file).

When enabled and user requested partial contents will change 'Status' to
'206 Partial Content'.

=item {cache}

Enable/disable caching file contents.

HTTP header 'Expires' will be removed if {cache} is TRUE, or set to 
'Sat, 01 Jan 2000 00:00:00 GMT' if {cache} is FALSE.

If {cache} is TRUE and $file is STRING will set 'Last-Modified' header;
when browser use 'If-Modified-Since' and file doesn't changed will set
'Status' to '304 Not Modified' and return REF to empty string to avoid
sending any needless data to browser.

You may want to add custom 'ETag' caching manually:

    $h->{ETag} = calc_my_ETag($file);
    if ($r->{ENV}{IF_NONE_MATCH} eq $h->{ETag}) {
        $h->{Status} = '304 Not Modified';
        $data = \q{};
    } else {
        $data = send_file($r, $h, $file, {cache=>1});
    }
    print $h->compose(), ${$data};

=item {inline}

Try to control how browser should handle sent file (this have sense only
for file types which browser can just show instead of asking user where to
save downloaded file on disk - like images).

If FALSE will set 'Content-Disposition' to 'attachment', this should force
browser to save downloaded file instead of just showing it.

=back

Return SCALARREF with (full/partial/empty) file contents which should be
send as body of CGI reply.


=head1 LIMITATIONS

Sending large files will use a lot of memory - this module doesn't use
temporary files and keep everything in memory.


=head1 SUPPORT

=head2 Bugs / Feature Requests

Please report any bugs or feature requests through the issue tracker
at L<https://github.com/powerman/perl-CGI-Easy-SendFile/issues>.
You will be notified automatically of any progress on your issue.

=head2 Source Code

This is open source software. The code repository is available for
public review and contribution under the terms of the license.
Feel free to fork the repository and submit pull requests.

L<https://github.com/powerman/perl-CGI-Easy-SendFile>

    git clone https://github.com/powerman/perl-CGI-Easy-SendFile.git

=head2 Resources

=over

=item * MetaCPAN Search

L<https://metacpan.org/search?q=CGI-Easy-SendFile>

=item * CPAN Ratings

L<http://cpanratings.perl.org/dist/CGI-Easy-SendFile>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/CGI-Easy-SendFile>

=item * CPAN Testers Matrix

L<http://matrix.cpantesters.org/?dist=CGI-Easy-SendFile>

=item * CPANTS: A CPAN Testing Service (Kwalitee)

L<http://cpants.cpanauthors.org/dist/CGI-Easy-SendFile>

=back


=head1 AUTHOR

Alex Efros E<lt>powerman@cpan.orgE<gt>


=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2009- by Alex Efros E<lt>powerman@cpan.orgE<gt>.

This is free software, licensed under:

  The MIT (X11) License


=cut
