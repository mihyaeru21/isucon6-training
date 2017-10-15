#!/usr/bin/env plackup
use 5.014;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";
use File::Spec;
use Plack::Builder;

use Isuda::Web;

my $root_dir = $FindBin::Bin;
my $app = Isuda::Web->psgi($root_dir);
#my $dir = sprintf('/tmp/profile-%s', time);
#mkdir $dir;
builder {
#  enable "Profiler::NYTProf",
#    env_nytprof          => 'start=no:addpid=0:slowops=0',
#    profiling_result_dir => sub { $dir },
#    enable_reporting     => 0,
#    enable_profile       => sub { $$ % 2 == 0 }
#    ;
    enable 'ReverseProxy';
    enable 'Static',
        path => qr!^/(?:(?:css|js|img)/|favicon\.ico$)!,
        root => File::Spec->catfile($root_dir, 'public');
    enable 'Session::Cookie',
        session_key => "isuda_session",
        secret      => 'tonymoris';
    $app;
};
