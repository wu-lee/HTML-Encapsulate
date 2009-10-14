package HTML::Encapsulate;
use warnings;
use strict;
use Carp;
use PerlIO;
use File::Path qw(mkpath);
use File::Spec;
use File::Spec::Unix;
use Carp qw(croak carp cluck confess);
use Exporter qw(import);
use LWP::UserAgent;
use HTML::TreeBuilder::XPath;
use Scalar::Util qw(blessed);
use URI;
use HTML::Entities qw(decode_entities encode_entities);
use HTML::Tidy;
use HTTP::Response::Encoding;

use version; our $VERSION = qv('0.1');


our @EXPORT_OK = qw(download);

our %TIDY_OPTIONS = (lower_literals => 1,
                     show_errors => 0,
                     show_warnings => 0,
                     tidy_mark => 0);


# url(blah) or url( 'blah' ) etc.
my $QUOTED_STR = qr/ " ([^"]*) " | ' ([^']*) ' /x;

my $URL_RE = qr/ url \s* \( 
                             \s* (?: $QUOTED_STR | (.*?) ) \s*
                         \) 
/ix; 

my $IMPORT_RE = qr/ 
  \@import (?:
              \s+ $URL_RE     | # @import url(blah) with optional quotes
              \s* $QUOTED_STR | # @import "blah" or @import 'blah'
              \s+ (\S+)         # @import  blah
           )
/xi;

sub _inner_html
{
    my $node = shift;
    join "", map { ref $_? $_->as_HTML : $_ } $node->content_list;
}

sub _slurp
{
    my $path = shift;
    my $encoding = defined $_[0]?
        "encoding($_[0])" : "";

    local $/;
    confess "failed to open file '$path': $!" 
        unless open my $fh, "<$encoding", $path;
    my $content = <$fh>;
    close $fh;
    return $content;
}

sub _spit
{
    my $path = shift;
    my $content = shift;
    confess "failed to open file '$path': $!" unless open my $fh, ">", $path;
    print $fh $content;
    close $fh;
}


# Constructor

sub new
{
    my $class = shift;
    croak "You must supply a matched set of key => value paramters"
        if @_ % 2;

    my %options = @_;

    unless (defined $options{ua}) 
    {
        # the default user agent should follow redirects
        my $ua = LWP::UserAgent->new(
            requests_redirectable => [qw(GET POST HEAD)]
        );
        $options{ua} = $ua;
    }

    my $self = bless \%options, $class;
    
    return $self;
}

sub ua { @_>1 ? shift->{ua} = shift : shift->{ua} }

my $DEFAULT_INSTANCE; # lazily assigned within download

sub download
{
    my $self = shift;

    # An URI or HTTP::Request for the page we want
    my $request = shift;

    # Where to save things. A directory - the main file will be called
    # 'index.html'
    my $content_dir = shift; 

    # A specialised UserAgent to use
    my $ua = shift;

    if (!blessed($self) 
        || !$self->isa(__PACKAGE__))
    { # we're a function, readjust the paramters accordingly
        ($self, $request, $content_dir, $ua) 
            = ( ($DEFAULT_INSTANCE ||= __PACKAGE__->new), $self, $request, $content_dir, shift);
    }

   
    # If no user agent supplied, use the instance's
    $ua ||= $self->{ua};

    croak "please supply an URL or HTTP::Request to download" 
        unless $request;

    $request = HTTP::Request->new(GET => $request)
        if (blessed $request && $request->isa('URI'))
        || ref \$request eq 'SCALAR';

    croak "first argument must be an URL or HTTP::Request instance" 
        unless blessed $request and $request->isa('HTTP::Request');

    croak "please supply a directory to copy into" 
        unless $content_dir;

    carp "warning, path '$content_dir' already exists, we may overwrite content" 
        if -e $content_dir;

    # All seems in order, now proceed....
    mkpath $content_dir;


    # First get the main document
    my $file = File::Spec->catdir($content_dir, "index.html");
    my $response = $ua->request($request, $file);

    unless ($response and $response->is_success) 
    {
        croak "HTTP request failed: ". $response->status_line;
    }
    
    # If it's not HTML, we can't understand it, so just leave it
    # unchanged.
    return unless $response->content_type =~ /html$/;


    # Otherwise, "localise" it....

    # This will parse the HTML so we can get the links
    my $parser = HTML::TreeBuilder::XPath->new;

    # HTML::Tidy does a better job of interpreting bad html than
    # HTML::TreeBuilder alone, so we pass it through that first.  If
    # we don't, the resulting HTML obtained after HTML::TreeBuilder
    # has parsed it can be broken.
    {
        my $tidy = HTML::Tidy->new(\%TIDY_OPTIONS);
        $tidy->ignore( text => qr/./ );        

        # Get the encoding, using the method suggested in HTTP::Response::Encoding's
        # docs (that allows HTTP::Response to see the document's <meta> tags).
        my $encoding = do
        {
            my $trunc_request = $request->clone;
            $trunc_request->headers->header(Range => "bytes=0-4095"); # Just get 4k
            my $trunc_response = $ua->request($trunc_request);
            $trunc_response->encoding;
        };
          
        my $content = _slurp($file, $encoding);

        {
            no warnings 'redefine';

            # HTML::Tidy insists on calling this function.... silence
            # it, locally
            local *Carp::carp = sub {}; 
            
            $content = $tidy->clean($content);
        }

        $parser->parse($content);
    }
    
    my %seen; # We store URLs we've already processed in here

    # This will both download an URL's target and rewrite the URL to
    # point to the downloaded copy - here we refer to that process as
    # "localising" an url.
    my $localise_url = sub
    {
        my $url = shift || croak "no url parameter supplied";
        $url = URI->new_abs(decode_entities($url), $response->base) 
            unless blessed $url;

        my $local_url = $seen{$url};

        unless ($local_url)
        {
            # FIXME check for inline URL images? (i.e. data:// urls)
            my ($ext) = $url->path =~ m![.]([^./]+)$!;
            my $index = keys(%seen)+1;
            my $filename = $index;
            $filename .= ".$ext" 
                if defined $ext;
            my $file = File::Spec->catfile($content_dir, $filename); 


            # clean up things like '/../foo' which will cause an error 
            # if passed to $ua->get
            my $url_path = File::Spec::Unix->canonpath($url->path);
            $url->path($url_path);

            $local_url = $seen{$url} = $filename;
            
#            print "downloading $url -> $file\n";  DEBUG
            my $response2 = $ua->get($url, ':content_file' => $file);

            carp "failed to download $url: ". $response2->status_line
                unless $response2->is_success 
                    && -f $file;
        }

        return $local_url;
        
    };

    # This will localise URLs in tag attributes
    my $process_attr = sub 
    {
        my ($attr) = @_;

        my $url = $attr->getValue;
        return unless $url ne "";

        my $local_url = $localise_url->($url);
#        warn "url $url -> $local_url"; # DEBUG
        # rewrite the attribute
        $attr->getParentNode->attr($attr->getName, $local_url);
    };

    # This will localise a stylesheet link
    my $localise_style_url = sub
    {
        # note, CSS defines URLs to be relative to the stylesheet.
        my $base = shift || croak "you must supply a base url";
        my $url = URI->new_abs(shift, $base);

        my $local_url = $localise_url->($url);

        $local_url = encode_entities($local_url);

#        warn "localising $url-> $local_url\n"; # DEBUG
        return "url($local_url)";
    };

    my $process_stylesheet; # defined later

    # This will localise a stylesheet @import link
    my $localise_import = sub
    {
        my $base = shift;
        my $url = shift;

        my $local_url = $localise_url->($url);
        my $stylesheet_file = File::Spec->catdir($content_dir, $local_url);

        my $content = _slurp $stylesheet_file;
        $process_stylesheet->($base, $content);
        _spit $stylesheet_file, $content;        

        # Note, we don't convert the url, since that will be done later
        return "\@import url($url)"; 
    };

    # This function will localise an entire stylesheet's links.  It
    # returns the number of things downloaded.
    $process_stylesheet = sub
    {
        my $base = shift || croak "you must supply a base url";

        # First, convert all '@import' statements to the '@import url()' form,
        # then localise all url() references. Return true if either has been applied.
        my @stylesheets = $_[0] =~ s/$IMPORT_RE/$localise_import->($base, $+)/ige;
        my @urls = $_[0] =~ s/$URL_RE/$localise_style_url->($base, $+)/ige;

        return @stylesheets + @urls;
    };

    # This localises a <style> element
    my $process_style_node = sub 
    {
        my $style = shift || croak "you must supply a node";
        my $content = _inner_html $style;
        return unless $process_stylesheet->($response->base, $content);

        $style->delete_content;
        $style->push_content($content);
    };


    # A look-up table defining how to localise different things
    my @targets = 
        (images => '//img/@src', $process_attr,
         inputs => '//input/@src', $process_attr,
         # the XPath1 tranlsate() function is necessary to make a case-insensitive match of 'stylesheet'
         stylesheets => '/html/head/link[translate(@rel, "STYLHE","stylhe")="stylesheet"]/@href', sub { 
             my $attr = shift;
#             warn "node has value ".$attr->getValue;

             my $url = URI->new_abs($attr->getValue, $response->base);
             my $local_url = $localise_url->($url);
             my $file = File::Spec->catdir($content_dir, $local_url);
#             warn "file is $file $local_url";

             my $content = _slurp $file;
             $process_stylesheet->($url, $content);
             _spit $file, $content;

             $process_attr->($attr);
         },
         scripts => '//script/@src', $process_attr,
         styles => '//style', $process_style_node,
        );



    # Now localise each type of thing in turn
    while (@targets)
    {
        my ($type, $xpath, $process) = splice @targets, 0, 3;

        # FIXME unescape urls

        my @nodes = $parser->findnodes($xpath);

        foreach my $node (@nodes) 
        {
            eval { $process->($node) };
            next unless $@;

            $node = $node->getParentNode 
                while $node->getParentNode && !$node->can('as_HTML');
            warn "Failed to process node matching $xpath:\n    ". 
                $node->as_HTML ."\n...because: $@\n";
        }

    }


    # Now write the localised result back into the final index.html
    confess "failed to write to $file: $!" 
        unless open my $fh, ">", $file;
    print $fh $parser->as_HTML;
    close $fh;

    $parser->delete;
    
}

1;
__END__

=head1 NAME

HTML::Encapsulate - rewrites an HTML page as a self-contained set of files


=head1 VERSION

This document describes HTML::Encapsulate version 0.1


=head1 SYNOPSIS

    use HTML::Encapsulate qw(download);
    
    # This will download the page at the URL given in the first
    # argument into a folder named in the second, here called
    # C<bar.html>.  The folder will contain all the images and other
    # components required to view the page.  The page itself will be
    # saved as C<index.html>
    download "http://foo.com/bar" => "bar.html";

    # It also has an OO interface, allows various defaults to be
    # adjusted via the %options hash.
    my $he = HTML::Encapsulate->new(%options);
    $he->download("http://foo.com/bar" => "bar.html");


    # HTTP::Requests can also be passed.  This enables the result of
    # form posts to be captured.
    my $request = HTTP::Request->new(GET => 'http://somewhere.com/something.html');
    my $download_dir = 'some/directory/path';

    $he->download($request, $download_dir);
  

=head1 DESCRIPTION

The main motivation for this module is for archiving and printing web
pages: these typically come in various separate pieces and aren't
simple to download as one chunk.

However, it is possible to preserve the content of a web page, but to
rewrite the links to the embedded contend like images, stylesheets,
etc. so that the downloaded version can be viewed entirely offline.

Once web pages have been downloaded in an "encapsulated" form, they
can then be archived, and/or converted into other formats.

The C<wget> command line utility has an option for downloading web
pages with their images and stylesheets, rewriting the links to point
to the downloaded copies, like this:

    wget -kp http://foo.com/bar 

This command isn't always convenient, nor available, so it's a fairly
non-portable option.  This module aims to perform the same function in
a portable, pure-perl fashion.

See the documentation for the C<< ->download >> method for more details.


=head1 EXPORTABLE FUNCTIONS

=head2 C<< download($url_or_request, $download_dir) >>

=head2 C<< download($url_or_request, $download_dir, $user_agent) >>

Essentially constructs a default instance and delegates to its
C<< ->download >> method.  See the appropriate documentation for that
method.

Optionally, a LWP::UserAgent instance C<$user_agent> may be supplied
for use, e.g. if the download needs to be performed as part of an
ongoing session, or needs to have specific properties or behaviour.
By default, a new LWP::UserAgent instance will be created.



=head1 CLASS METHODS

=head2 C<< $obj = $class->new(%options)  >>

Constructs a new instance with tweaked properties.

FIXME elaborate.

Options can be:

=over 4 

=item

=back



=head1 OBJECT METHODS

=head2 C<< $obj->download($url_or_request, $download_dir) >>

This downloads the page obtained by the HTTP::Request C<$request>
(which could be a post, or any other request returning HTML) in the
directory C<$download_dir>, plus all images and other dependencies needed
to render it.

The main HTML document will be saved in C<$download_dir> as
'index.html'.  Other dependencies will be saved with filenames
composed of an index number (1 for the first item saved, 2 for the
second, etc.), plus an extension (taken from the source URL).

By design, this function will dowload but not attempt to process
non-html content (i.e. if the 'content-type' header does not end in
html).  Note also that I've been lazy, so it will still save the
content with as C<index.html> as for a HTML page.

The content of the HTML is re-written so that links to dependencies
refer to the downloaded files.  External dependencies (anything not
downloaded) are left as-is.

The following dependencies I<are> handled:

=over 4

=item *

C<< <img href="..."> >> linked images

=item *

C<< <style href="..."> >> stylesheet links

=item *

CSS C<@import url(...)> linked stylesheets

=item *

C<< <script src="..."> >> linked scripts.

=item *

C<< <input src="..."> >> linked images.

=item *

CSS C<url()> links. 

=back


B<TODO>

The following constructs are not handled, but ought to be:

=over 4

=item *

Frames and C<iframe> tags.

=item *

C<< <embed> >>, C<< C<object> >>

=back



B<Unsupported>

These are not handled, and may or may not get implemented:

=over 4

=item *

inline C<data://> urls

=item *

excessivly funky javascript which constructs content dynamically

=back


=head1 DEPENDENCIES

Dependencies are intentionally kept fairly minimal, but do exist. The
main non-core ones are HTML::Tidy, HTML::Entities and
HTML::TreeBuilder::XPath. See the C<META.yaml> included the
distribution for full details.


=head1 BUGS / CAVEATS

The internals are a bit of an ugly hack.  If I could find something
off the shelf which does the job equivalently, I'd have used that.
Since I couldn't find anything suitable I whipped this up in a jiffy,
and then warped it to support as much as I could.

See the description of C<< ->download >> for details of what is and
isn't implemented.

Please report any bugs or feature requests to
C<bug-HTML-Encapsulate@rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org>.


=head1 AUTHOR

Nick Woolley  C<< <npw@cpan.org> >>


=head1 LICENCE AND COPYRIGHT

Copyright (c) 2009, Nick Woolley C<< <npw@cpan.org> >>. All rights reserved.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself. See L<perlartistic>.


=head1 DISCLAIMER OF WARRANTY

BECAUSE THIS SOFTWARE IS LICENSED FREE OF CHARGE, THERE IS NO WARRANTY
FOR THE SOFTWARE, TO THE EXTENT PERMITTED BY APPLICABLE LAW. EXCEPT WHEN
OTHERWISE STATED IN WRITING THE COPYRIGHT HOLDERS AND/OR OTHER PARTIES
PROVIDE THE SOFTWARE "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER
EXPRESSED OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. THE
ENTIRE RISK AS TO THE QUALITY AND PERFORMANCE OF THE SOFTWARE IS WITH
YOU. SHOULD THE SOFTWARE PROVE DEFECTIVE, YOU ASSUME THE COST OF ALL
NECESSARY SERVICING, REPAIR, OR CORRECTION.

IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN WRITING
WILL ANY COPYRIGHT HOLDER, OR ANY OTHER PARTY WHO MAY MODIFY AND/OR
REDISTRIBUTE THE SOFTWARE AS PERMITTED BY THE ABOVE LICENCE, BE
LIABLE TO YOU FOR DAMAGES, INCLUDING ANY GENERAL, SPECIAL, INCIDENTAL,
OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OR INABILITY TO USE
THE SOFTWARE (INCLUDING BUT NOT LIMITED TO LOSS OF DATA OR DATA BEING
RENDERED INACCURATE OR LOSSES SUSTAINED BY YOU OR THIRD PARTIES OR A
FAILURE OF THE SOFTWARE TO OPERATE WITH ANY OTHER SOFTWARE), EVEN IF
SUCH HOLDER OR OTHER PARTY HAS BEEN ADVISED OF THE POSSIBILITY OF
SUCH DAMAGES.


