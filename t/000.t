#!perl

use t::ests;

my $foo_rrd = tmpcopyfile('foo.rrd');

{

    package Webservice;
    use Dancer2;
    use Dancer2::Plugin::RRD;

    set plugins => {
        RRD => {
            FOO => $foo_rrd,
        },
    };

    get '/update' => sub {
        rrd_update(FOO => 10);
    };

    get '/count' => sub {
        rrd_count('FOO');
    };

    get '/commit' => sub {
        rrd_commit;
    };

    get '/info' => sub {
        use Data::Dumper;
        local $Data::Dumper::Purity = 1;
        local $Data::Dumper::Terse = 1;
        Dumper(rrd_info('FOO'));
    };

}

my $PT = init('Webservice');

#plan tests => 3;

my ($before, $after);

subtest 'info FOO before' => sub {
    plan tests => 3;
    my $R = $PT->request( GET('/info') );
    ok $R->is_success;
    $before = eval $R->content;
    is $before->{ds}{foo}{last_ds} => 'U';    
    is $before->{ds}{foo}{value}   => 0;
};

subtest 'update FOO' => sub {
    plan tests => 1;
    my $R = $PT->request( GET('/update') );
    ok $R->is_success;
};

subtest 'info FOO after' => sub {
    plan tests => 3;
    my $R = $PT->request( GET('/info') );
    ok $R->is_success;
    $after = eval $R->content;
    is $after->{ds}{foo}{last_ds} => 10;
    is $after->{ds}{foo}{value}   => undef;
};

done_testing;
