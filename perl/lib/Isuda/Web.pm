package Isuda::Web;
use 5.014;
use warnings;
use utf8;
use Kossy;
use DBIx::Sunny;
use Encode qw/encode_utf8 decode_utf8/;
use POSIX qw/ceil/;
use Furl;
use JSON::XS qw/decode_json/;
use String::Random qw/random_string/;
use Digest::SHA1 qw/sha1_hex/;
use URI::Escape qw/uri_escape_utf8/;
use Text::Xslate::Util qw/html_escape/;
use List::Util qw/min max/;
use Redis::Jet;
use DDP;

sub config {
    state $conf = {
        dsn           => $ENV{ISUDA_DSN}         // 'dbi:mysql:db=isuda',
        db_user       => $ENV{ISUDA_DB_USER}     // 'root',
        db_password   => $ENV{ISUDA_DB_PASSWORD} // '',
        isupam_origin => $ENV{ISUPAM_ORIGIN}     // 'http://localhost:5050',
    };
    my $key = shift;
    my $v = $conf->{$key};
    unless (defined $v) {
        die "config value of $key undefined";
    }
    return $v;
}

sub redis {
    my ($self) = @_;
    return $self->{redis} //= Redis::Jet->new(server => 'localhost:6379');
}

sub dbh {
    my ($self) = @_;
    return $self->{dbh} //= DBIx::Sunny->connect(config('dsn'), config('db_user'), config('db_password'), {
        Callbacks => {
            connected => sub {
                my $dbh = shift;
                $dbh->do(q[SET SESSION sql_mode='TRADITIONAL,NO_AUTO_VALUE_ON_ZERO,ONLY_FULL_GROUP_BY']);
                $dbh->do('SET NAMES utf8mb4');
                return;
            },
        },
    });
}

filter 'set_name' => sub {
    my $app = shift;
    sub {
        my ($self, $c) = @_;
        my $user_id = $c->env->{'psgix.session'}->{user_id};
        if ($user_id) {
            $c->stash->{user_id} = $user_id;
            $c->stash->{user_name} = $self->get_user_name($user_id);
            $c->halt(403) unless defined $c->stash->{user_name};
        }
        $app->($self,$c);
    };
};

filter 'authenticate' => sub {
    my $app = shift;
    sub {
        my ($self, $c) = @_;
        $c->halt(403) unless defined $c->stash->{user_id};
        $app->($self,$c);
    };
};

get '/initialize' => sub {
    my ($self, $c)  = @_;

    # isuda
    $self->dbh->query(q[
        DELETE FROM entry WHERE id > 7101
    ]);

    # redis
    $self->redis->command('flushall');

    # create cache
    $self->update_keywords();
    # user_id => name cache
    my $users = $self->dbh->select_all(qq[ SELECT id, name FROM user ]);
    for my $user (@$users) {
        $self->set_user_name($user->{id}, $user->{name});
        p $self->get_user_name($user->{id});
    }

    $c->render_json({
        result => 'ok',
    });
};

get '/' => [qw/set_name/] => sub {
    my ($self, $c)  = @_;

    my $PER_PAGE = 10;
    my $page = $c->req->parameters->{page} || 1;

    my $entries = $self->dbh->select_all(qq[
        SELECT * FROM entry
        ORDER BY updated_at DESC
        LIMIT $PER_PAGE
        OFFSET @{[ $PER_PAGE * ($page-1) ]}
    ]);

    my $re = $self->get_keyword_re();
    foreach my $entry (@$entries) {
        $entry->{html}  = $self->htmlify_with_re($c, $entry->{description}, $re);
        $entry->{stars} = $self->load_stars($entry->{keyword});
    }

    my $total_entries = $self->dbh->select_one(q[
        SELECT COUNT(*) FROM entry
    ]);
    my $last_page = ceil($total_entries / $PER_PAGE);
    my @pages = (max(1, $page-5)..min($last_page, $page+5));

    $c->render('index.tx', { entries => $entries, page => $page, last_page => $last_page, pages => \@pages });
};

get 'robots.txt' => sub {
    my ($self, $c)  = @_;
    $c->halt(404);
};

post '/keyword' => [qw/set_name authenticate/] => sub {
    my ($self, $c) = @_;
    my $keyword = $c->req->parameters->{keyword};
    unless (length $keyword) {
        $c->halt(400, q('keyword' required));
    }
    my $user_id = $c->stash->{user_id};
    my $description = $c->req->parameters->{description};

    if (is_spam_contents($description) || is_spam_contents($keyword)) {
        $c->halt(400, 'SPAM!');
    }
    $self->dbh->query(q[
        INSERT INTO entry (author_id, keyword, description, created_at, updated_at, keyword_length)
        VALUES (?, ?, ?, NOW(), NOW(), CHARACTER_LENGTH(?))
        ON DUPLICATE KEY UPDATE
        author_id = ?, keyword = ?, description = ?, updated_at = NOW()
    ], ($user_id, $keyword, $description, $keyword) x 2);

    $self->update_keywords();

    $c->redirect('/');
};

get '/register' => [qw/set_name/] => sub {
    my ($self, $c)  = @_;
    $c->render('authenticate.tx', {
        action => 'register',
    });
};

post '/register' => sub {
    my ($self, $c) = @_;

    my $name = $c->req->parameters->{name};
    my $pw   = $c->req->parameters->{password};
    $c->halt(400) if $name eq '' || $pw eq '';

    my $user_id = $self->register($self->dbh, $name, $pw);

    $c->env->{'psgix.session'}->{user_id} = $user_id;
    $c->redirect('/');
};

sub register {
    my ($self, $dbh, $name, $pass) = @_;

    my $salt = random_string('....................');
    $dbh->query(q[
        INSERT INTO user (name, salt, password, created_at)
        VALUES (?, ?, ?, NOW())
    ], $name, $salt, sha1_hex($salt . $pass));

    my $id = $dbh->last_insert_id;
    $self->set_user_name($id, $name);

    return $id;
}

get '/login' => [qw/set_name/] => sub {
    my ($self, $c)  = @_;
    $c->render('authenticate.tx', {
        action => 'login',
    });
};

post '/login' => sub {
    my ($self, $c) = @_;

    my $name = $c->req->parameters->{name};
    my $row = $self->dbh->select_row(q[
        SELECT * FROM user
        WHERE name = ?
    ], $name);
    if (!$row || $row->{password} ne sha1_hex($row->{salt}.$c->req->parameters->{password})) {
        $c->halt(403)
    }

    $c->env->{'psgix.session'}->{user_id} = $row->{id};
    $c->redirect('/');
};

get '/logout' => sub {
    my ($self, $c)  = @_;
    $c->env->{'psgix.session'} = {};
    $c->redirect('/');
};

get '/keyword/:keyword' => [qw/set_name/] => sub {
    my ($self, $c) = @_;
    my $keyword = $c->args->{keyword} // $c->halt(400);

    my $entry = $self->dbh->select_row(qq[
        SELECT * FROM entry
        WHERE keyword = ?
    ], $keyword);
    $c->halt(404) unless $entry;
    $entry->{html} = $self->htmlify_with_re($c, $entry->{description}, $self->get_keyword_re());
    $entry->{stars} = $self->load_stars($entry->{keyword});

    $c->render('keyword.tx', { entry => $entry });
};

post '/keyword/:keyword' => [qw/set_name authenticate/] => sub {
    my ($self, $c) = @_;
    my $keyword = $c->args->{keyword} or $c->halt(400);
    $c->req->parameters->{delete} or $c->halt(400);

    $c->halt(404) unless $self->dbh->select_row(qq[
        SELECT * FROM entry
        WHERE keyword = ?
    ], $keyword);

    $self->dbh->query(qq[
        DELETE FROM entry
        WHERE keyword = ?
    ], $keyword);
    $c->redirect('/');
};

post '/stars' => sub {
    my ($self, $c) = @_;
    my $keyword = $c->req->parameters->{keyword};
    my $user    = $c->req->parameters->{user};

    # keyword check
    my $entry = $self->dbh->select_row(qq[SELECT 1 FROM entry WHERE keyword = ?], $keyword);
    $c->halt(404) unless $entry;

    $self->redis->command('lpush', encode_utf8($keyword), encode_utf8($user));

    $c->render_json({
        result => 'ok',
    });
};

sub get_keyword_re {
    my ($self) = @_;

    my $keywords = $self->keywords;
    my $re = join '|', map { quotemeta $_ } @$keywords;
    return $re;
}

sub htmlify_with_re {
    my ($self, $c, $content, $re) = @_;
    return '' unless defined $content;
    my %kw2sha;
    $content =~ s{($re)}{
        my $kw = $1;
        $kw2sha{$kw} = "isuda_" . sha1_hex(encode_utf8($kw));
    }eg;
    $content = html_escape($content);
    while (my ($kw, $hash) = each %kw2sha) {
        my $url = $c->req->uri_for('/keyword/' . uri_escape_utf8($kw));
        my $link = sprintf '<a href="%s">%s</a>', $url, html_escape($kw);
        $content =~ s/$hash/$link/g;
    }
    $content =~ s{\n}{<br \/>\n}gr;
}

sub load_stars {
    my ($self, $keyword) = @_;

    my $names = $self->redis->command('lrange', encode_utf8($keyword), 0, -1) // [];
    my $stars = [ map { { user_name => $_ } } @$names ];

    return $stars;
}

sub is_spam_contents {
    my $content = shift;
    my $ua = Furl->new;
    my $res = $ua->post(config('isupam_origin'), [], [
        content => encode_utf8($content),
    ]);
    my $data = decode_json $res->content;
    !$data->{valid};
}



sub update_keywords {
    my ($self) = @_;

    my $keywords = $self->dbh->select_all('SELECT keyword FROM entry ORDER BY keyword_length DESC') // [];
    my @keywords = map { $_->{keyword} } @$keywords;
    my $kw       = join "\t", @keywords;
    $self->redis->command(qw/set kw/, encode_utf8($kw));
}

sub keywords {
    my ($self) = @_;
    my $kw = $self->redis->command(qw/get kw/);
    return [split /\t/, decode_utf8($kw)];
}


sub set_user_name {
  my ($self, $id, $name) = @_;
  my $key = 'u:' . $id;
  $self->redis->command('set', $key, encode_utf8($name));
}

sub get_user_name {
  my ($self, $id) = @_;
  my $key = 'u:' . $id;
  return decode_utf8 $self->redis->command('get', $key);
}


1;
