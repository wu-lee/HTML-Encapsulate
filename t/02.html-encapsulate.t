#!/usr/bin/perl
use strict;
use warnings;
use HTTP::Request;
use Test::More;
use File::Path qw(rmtree mkpath);
use Exporter qw(import);
use LWP::UserAgent::Snapshot;

use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

eval "use Test::Files 0.14";
plan skip_all => "Test::Files 0.14 required" if $@;
plan tests => 2;


use_ok 'HTML::Encapsulate', 'download';


my $download_dir = "$Bin/temp/html-encapsulate";
my $reference_dir = "$Bin/data/html-encapsulate";

rmtree $download_dir if -e $download_dir;
mkpath $download_dir;


my $ua = LWP::UserAgent::Snapshot->new;

#my $full_ref_path = File::Spec->rel2abs($reference_dir);
$ua->mock_from("$reference_dir/mock_data");

#my $url = "file://$full_ref_path/88fc2536dcb9da1666de4e5507f4aae6-response-001.html";
my $url = "http://nowhere/";

my $request = HTTP::Request->new(GET => $url);

download($request, "$download_dir/nowhere", $ua);

# compare downloaded files with the reference
compare_dirs_ok("$reference_dir/reference/nowhere", 
                "$download_dir/nowhere", 
                "downloaded files match reference");


# TODO
# test that missing dependencies don't abort the whole download
# add frames support?
