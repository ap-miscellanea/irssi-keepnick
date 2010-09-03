# keepnick - irssi 0.7.98.CVS 
#
#    $Id: keepnick.pl,v 1.16 2002/10/27 14:55:25 peder Exp $
#
# Copyright (C) 2001, 2002 by Peder Stray <peder@ninja.no>
#

use strict;
use Irssi 20011118.1727;
use Irssi::Irc;

# ======[ Script Header ]===============================================

use vars qw{$VERSION %IRSSI};
($VERSION) = '$Revision: 1.16 $' =~ / (\d+\.\d+) /;
%IRSSI = (
          name        => 'keepnick',
          authors     => 'Peder Stray',
          contact     => 'peder@ninja.no',
          url         => 'http://ninja.no/irssi/keepnick.pl',
          license     => 'GPL',
          description => 'Try to get your nick back when it becomes available.',
         );

# ======[ Variables ]===================================================

my(%keepnick);		# nicks we want to keep
my(%nickserv);		# nickserv passwords
my(%nsreq,%nsok,%nsnick,%nshost,%nslast);	#nickserv information
my(%getnick);		# nicks we are currently waiting for
my(%inactive);		# inactive chatnets
my(%manual);		# manual nickchanges

# ======[ Helper functions ]============================================

# --------[ change_nick ]-----------------------------------------------

sub change_nick {
    my($server,$nick) = @_;
    $server->redirect_event('keepnick nick', 1, ":$nick", -1, undef,
			    {
			     "event nick" => "redir keepnick nick",
			     "" => "event empty",
			    });
    $server->send_raw("NICK :$nick");
}

sub event_notice {
    # $data = "nick/#channel :text"
    my ($server, $data, $nick, $host) = @_;
    my ($target, $text) = $data =~ /^(\S*)\s:(.*)/;
    my ($net);

    for my $check (keys %keepnick) {
	next if $inactive{$check};
	if (lc $server->{tag} eq lc $check){
		$net = $check;
	}
    }

    if ($net eq ""){
	server_printformat($server, MSGLEVEL_NICKS | MSGLEVEL_NO_ACT,
			   'keepnick_no_net', $net);
	return;
    }
    my $altnick = Irssi::settings_get_str("alternate_nick");
    return if ($text !~ /This nickname (is|has been) (owned|registered)/ &&
		$text !~ /Password accepted/ &&
		$text !~ /You have .*identified/);
    return if ($nick != $nsnick{$net});

    if ($host != $nshost{$net}) {
	server_printformat($server, MSGLEVEL_NICKS | MSGLEVEL_NO_ACT,
		'keepnick_hack_attempt', $nick, $host, $target, $text);
        return;
    }

    return if ($target !~ /$server->{nick}/);

    if ($text =~ /This nickname (is|has been) (owned|registered)/){
	if ($nickserv{$net} !~ /^$/){
		server_printformat($server, MSGLEVEL_NICKS | MSGLEVEL_NO_ACT,
			'keepnick_req_auth', $nick, $host);
		if ($nickserv{$net} =~ /^raw:/){
			my $pass = $nickserv{$net};
			$pass =~ s/^raw://;
			$server->send_raw("ns IDENTIFY $keepnick{$net} $pass");
		} else {
			$server->send_message("NickServ", "IDENTIFY $nickserv{$net}", 1);
		}
	} else {
		server_printformat($server, MSGLEVEL_NICKS | MSGLEVEL_NO_ACT,
			'keepnick_req_auth_fail', $nick, $host);
	}
    }
    elsif ($text =~ /You have already.*identified/){
	    return if (time() - $nslast{$net} < 25);
	    $nslast{$net} = time();
	    if ($server->{nick} eq $altnick){
		    if ($nickserv{$net} =~ /^raw:/){
			    my $pass = $nickserv{$net};
			    $pass =~ s/^raw://;
			    $server->send_raw("ns GHOST $keepnick{$net} $pass");
		    } else {
			    $server->send_message("NickServ",
				"GHOST $keepnick{$net} $nickserv{$net}", 1);
		    }
	    }
    }
    else {
	    server_printformat($server, MSGLEVEL_NICKS | MSGLEVEL_NO_ACT,
		    'keepnick_req_success', $nick, $host);
	    if ($nick == $altnick){
		    change_nick($server, $keepnick{$net});
	    } else {
		    $server->send_message("ChanServ", "INVITE #gametome.staff", 1);
	    }
    }
}

# --------[ check_nick ]------------------------------------------------

sub check_nick {
    my($server,$net,$nick);

    %getnick = ();	# clear out any old entries
    
    for $net (keys %keepnick) {
	next if $inactive{$net};
	$server = Irssi::server_find_chatnet($net);
	next unless $server;
	next if lc $server->{nick} eq lc $keepnick{$net};
	
	$getnick{$net} = $keepnick{$net};
    }
    
    for $net (keys %getnick) {
	$server = Irssi::server_find_chatnet($net);
	next unless $server;
	$nick = $getnick{$net};
	if (lc $server->{nick} eq lc $nick) {
	    delete $getnick{$net};
	    next;
	} elsif (lc $server->{nick} == Irssi::settings_get_str("alternate_nick")){
		Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'keepnick_alternate_auth');
		if ($nickserv{$net} =~ /^raw:/){
			my $pass = $nickserv{$net};
			$pass =~ s/^raw://;
			$server->send_raw("ns IDENTIFY $keepnick{$net} $pass");
		} else {
			$server->send_message("NickServ", "IDENTIFY $nickserv{$net}", 1);
		}
	} elsif($nickserv{$net} != "" &&
		lc $server->{nick} ne lc $keepnick{$net} ) {
	    server_printformat($server, MSGLEVEL_NICKS | MSGLEVEL_NO_ACT,
		'keepnick_ghost');
	    return if (time() - $nslast{$net} < 25);
	    $nslast{$net} = time();
	    if ($nickserv{$net} =~ /^raw:/){
		    my $pass = $nickserv{$net};
		    $pass =~ s/^raw://;
		    $server->send_raw("ns GHOST $keepnick{$net} $pass");
	    } else {
		    $server->send_message("NickServ",
			"GHOST $keepnick{$net} $nickserv{$net}", 1);
	    }
	}
	$server->redirect_event('keepnick ison', 1, '', -1, undef,
				{ "event 303" => "redir keepnick ison" });
	$server->send_raw("ISON :$nick");
    }
}

# --------[ load_nicks ]------------------------------------------------

sub load_nicks {
    my($file) = Irssi::get_irssi_dir."/keepnick";
    my($count) = 0;
    local(*CONF);
    
    %keepnick = ();
    open CONF, "< $file";
    while (<CONF>) {
	my($net,$nick,$nspass,$nshost,$nsnick) = split;
	if ($net && $nick) {
	    $keepnick{lc $net} = $nick;
	    $nickserv{lc $net} = $nspass;
	    $nshost{lc $net} = $nshost;
	    $nsnick{lc $net} = $nsnick;
	    $count++;
	}
    }
    close CONF;
    
    Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'keepnick_crap',
		       "Loaded $count nicks from $file");
}

# --------[ save_nicks ]------------------------------------------------

sub save_nicks {
    my($auto) = @_;
    my($file) = Irssi::get_irssi_dir."/keepnick";
    my($count) = 0;
    local(*CONF);
    
    return if $auto && !Irssi::settings_get_bool('keepnick_autosave');
    
    open CONF, "> $file";
    for my $net (sort keys %keepnick) {
	print CONF "$net\t$keepnick{$net}\t$nickserv{$net}\t$nshost{$net}\t$nsnick{$net}\n";
	$count++;
    }
    close CONF;
    
    Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'keepnick_crap',
		       "Saved $count nicks to $file")
	unless $auto;
}

# --------[ server_printformat ]----------------------------------------

sub server_printformat {
    my($server,$level,$format,@params) = @_;
    my($emitted) = 0;
    for my $win (Irssi::windows) {
	for my $item ($win->items) {
	    next unless ref $item;
	    if ($item->{server}{chatnet} eq $server->{chatnet}) {
		$item->printformat($level,$format,@params);
		$emitted++;
		last;
	    }
	}
    }
    $server->printformat(undef,$level,$format,@params)
	unless $emitted;
}

# ======[ Signal Hooks ]================================================

# --------[ sig_message_nick ]------------------------------------------

# if anyone changes their nick, check if we want their old one.
sub sig_message_nick {
    my($server,$newnick,$oldnick) = @_;
    my($chatnet) = lc $server->{chatnet};
    if (lc $oldnick eq lc $getnick{$chatnet}) {
	change_nick($server, $getnick{$chatnet});
    }
}

# --------[ sig_message_own_nick ]--------------------------------------

# if we change our nick, check it to see if we wanted it and if so
# remove it from the list.
sub sig_message_own_nick {
    my($server,$newnick,$oldnick) = @_;
    my($chatnet) = lc $server->{chatnet};
    if (lc $newnick eq lc $keepnick{$chatnet}) {
	delete $getnick{$chatnet};
	if ($inactive{$chatnet}) {
	    delete $inactive{$chatnet};
	    Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'keepnick_unhold', 
			       $newnick, $chatnet);
	}
    } elsif (lc $oldnick eq lc $keepnick{$chatnet} &&
	     lc $newnick eq lc $manual{$chatnet}) {
	$inactive{$chatnet} = 1;
	delete $getnick{$chatnet};
	Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'keepnick_hold',
			   $oldnick, $chatnet);
    }
}

# --------[ sig_message_own_nick_block ]--------------------------------

sub sig_message_own_nick_block {
    my($server,$new,$old,$addr) = @_;
    Irssi::signal_stop();
    if (Irssi::settings_get_bool('keepnick_quiet')) {
	Irssi::printformat(MSGLEVEL_NICKS | MSGLEVEL_NO_ACT,
			   'keepnick_got_nick', $new, $server->{chatnet});
    } else {
	server_printformat($server, MSGLEVEL_NICKS | MSGLEVEL_NO_ACT,
			   'keepnick_got_nick', $new, $server->{chatnet});
    }
}

# --------[ sig_message_quit ]------------------------------------------

# if anyone quits, check if we want their nick.
sub sig_message_quit {
    my($server,$nick) = @_;
    my($chatnet) = lc $server->{chatnet};
    if (lc $nick eq lc $getnick{$chatnet}) {
	change_nick($server, $getnick{$chatnet});
    }
}

# --------[ sig_redir_keepnick_ison ]-----------------------------------

sub sig_redir_keepnick_ison {
    my($server,$text) = @_;
    my $nick = $getnick{lc $server->{chatnet}};
    change_nick($server, $nick)
      unless $text =~ /:\Q$nick\E\s?$/i;
}

# --------[ sig_redir_keepnick_nick ]-----------------------------------

sub sig_redir_keepnick_nick {
    my($server,$args,$nick,$addr) = @_;
    Irssi::signal_add_first('message own_nick', 'sig_message_own_nick_block');
    Irssi::signal_emit('event nick', @_);
    Irssi::signal_remove('message own_nick', 'sig_message_own_nick_block');
}

# --------[ sig_setup_reread ]------------------------------------------

# main setup is reread, so let us do it too
sub sig_setup_reread {
    load_nicks;
}

# --------[ sig_setup_save ]--------------------------------------------

# main config is saved, and so we should save too
sub sig_setup_save {
    my($mainconf,$auto) = @_;
    save_nicks($auto);
}

# ======[ Commands ]====================================================

# --------[ KEEPNICK HELP ]---------------------------------------------

sub cmd_print_help {
  Irssi::print(<<EOF, MSGLEVEL_CRAP);
   /keepnick [-net <chatnet>] [-nickserv <NSNICK> <NSHOST> <password>] [<nick>]
   /unkeepnick
   /listnick
EOF
}
# --------[ KEEPNICK ]--------------------------------------------------

# Usage: /KEEPNICK [-net <chatnet>] [-nickserv <NSNICK> <NSHOST> <password>] [<nick>]
sub cmd_keepnick {
    my(@params) = split " ", shift;
    my($server) = @_;
    my($chatnet,$nick,@opts,$nsnick,$nshost,$nspass);

    # parse named parameters from the parameterlist
    while (@params) {
	my($param) = shift @params;
	if ($param =~ /^-(chat|irc)?net$/i) {
	    $chatnet = shift @params;
	} elsif ($param =~ /^-(nickserv|ns)$/i) {
	    $nsnick = shift @params;
	    $nshost = shift @params;
	    $nspass = shift @params;
	} elsif ($param =~ /^-/) {
	    Irssi::print("Unknown parameter $param");
	} else {
	    push @opts, $param;
	}
    }
    $nick = shift @opts;

    # check if the ircnet specified (if any) is valid, and if so get the
    # server for it
    if ($chatnet) {
	my($cn) = Irssi::chatnet_find($chatnet);
	unless ($cn) {
	    Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'keepnick_crap', 
			       "Unknown chat network: $chatnet");
	    return;
	}
	$chatnet = $cn->{name};
	$server = Irssi::server_find_chatnet($chatnet);
    }

    # if we need a server, check if the one we got is connected.
    unless ($server || ($nick && $chatnet)) {
	Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'keepnick_crap', 
			   "Not connected to server");
	return;
    }

    # lets get the chatnet, and the nick we want
    $chatnet ||= $server->{chatnet};
    $nick    ||= $server->{nick};

    if ($inactive{lc $chatnet}) {
	delete $inactive{lc $chatnet};
	Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'keepnick_unhold',
			   $nick, $chatnet);
    }

    Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'keepnick_add', $nick,
		       $chatnet);

    $keepnick{lc $chatnet} = $nick;
    $nickserv{lc $chatnet} = $nspass;
    $nshost{lc $chatnet} = $nshost;
    $nsnick{lc $chatnet} = $nsnick;

    save_nicks(1);
    check_nick();
}

# --------[ UNKEEPNICK ]------------------------------------------------

# Usage: /UNKEEPNICK [<chatnet>]
sub cmd_unkeepnick {
    my($chatnet,$server) = @_;
    
    # check if the ircnet specified (if any) is valid, and if so get the
    # server for it
    if ($chatnet) {
	my($cn) = Irssi::chatnet_find($chatnet);
	unless ($cn) {
	    Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'keepnick_crap', 
			       "Unknown chat network: $chatnet");
	    return;
	}
	$chatnet = $cn->{name};
    } else {
	$chatnet = $server->{chatnet};
    }

    Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'keepnick_remove',
		       $keepnick{lc $chatnet}, $chatnet);

    delete $keepnick{lc $chatnet};
    delete $getnick{lc $chatnet};

    save_nicks(1);
}

# --------[ LISTNICK ]--------------------------------------------------

# Usage: /LISTNICK
sub cmd_listnick {
    my(@nets) = sort keys %keepnick;
    my $net;
    if (@nets) {
	Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'keepnick_list_header');
	for (@nets) {
	    $net = Irssi::chatnet_find($_);
	    Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'keepnick_list_line',
			       $keepnick{$_},
			       $net ? $net->{name} : ">$_<",
			       $inactive{$_}?'inactive':'active',
			       $nickserv{$_},
			       $nsnick{$_},
			       $nshost{$_});
	}
	Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'keepnick_list_footer');
    } else {
	Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'keepnick_list_empty');
    }
	Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'keepnick_list_header');
}

# --------[ NICK ]------------------------------------------------------

sub cmd_nick {
    my($data,$server) = @_;
    my($nick) = split " ", $data;
    return unless $server;
    $manual{lc $server->{chatnet}} = $nick;
}

# ======[ Setup ]=======================================================

# --------[ Register settings ]-----------------------------------------

Irssi::settings_add_bool('keepnick', 'keepnick_autosave', 1);
Irssi::settings_add_bool('keepnick', 'keepnick_quiet', 0);

# --------[ Register formats ]------------------------------------------

Irssi::theme_register(
[
 'keepnick_ghost',
 '{hilight Keepnick:} Nick is already in use, sending GHOST',

 'keepnick_req_success',
 '{hilight Keepnick:} $0!$1 has accepted authentication!',


 'keepnick_req_auth_fail',
 '{hilight Keepnick:} $0!$1 requested athentication but I don\'t know what to say!',

 'keepnick_req_auth',
 '{hilight Keepnick:} $0!$1 requested authentication. sending...',

 'keepnick_alternate_auth',
 '{hilight Keepnick:} We have our alternate_nick, trying to auth anyway...',

 'keepnick_hack_attempt',
 '{hilight Keepnick:} !!! \'$0\' host is bad, hack attempt? !!!
{hilight Keepnick:} !!!
{hilight Keepnick:} !!! sender: \'$0!$1\'
{hilight Keepnick:} !!! target: \'$2\'
{hilight Keepnick:} !!! text  : \'$3\'
{hilight Keepnick:} !!!
{hilight Keepnick:} !!! \'$0\' host is bad, hack attempt? !!!',

 'keepnick_no_net',
 '{hilight Keepnick:} Couldn\'t determine chatnet (now $0)',

 'keepnick_crap', 
 '{line_start}{hilight Keepnick:} $0',

 'keepnick_add', 
 '{line_start}{hilight Keepnick:} Now keeping {nick $0} on [$1]',

 'keepnick_remove',
 '{line_start}{hilight Keepnick:} Stopped trying to keep {nick $0} on [$1]',

 'keepnick_hold',
 '{line_start}{hilight Keepnick:} Nickkeeping deactivated on [$1]',

 'keepnick_unhold',
 '{line_start}{hilight Keepnick:} Nickkeeping reactivated on [$1]',

 'keepnick_list_empty', 
 '{line_start}{hilight Keepnick:} No nicks in keep list',

 'keepnick_list_header', 
 '',

 'keepnick_list_line', 
 '{line_start}{hilight Keepnick:} Keeping {nick $0} in [$1] ($2):
{line_start}{hilight Keepnick:}        Nickserv Pass "$3"
{line_start}{hilight Keepnick:}        NickServ Name "$4"
{line_start}{hilight Keepnick:}        NickServ Host "$5"',

 'keepnick_list_footer', 
 '',

 'keepnick_got_nick',
 '{hilight Keepnick:} Nickstealer left [$1], got {nick $0} back',
 
]);

# --------[ Register signals ]------------------------------------------

Irssi::signal_add('message quit', 'sig_message_quit');
Irssi::signal_add('message nick', 'sig_message_nick');
Irssi::signal_add('message own_nick', 'sig_message_own_nick');

Irssi::signal_add('redir keepnick ison', 'sig_redir_keepnick_ison');
Irssi::signal_add('redir keepnick nick', 'sig_redir_keepnick_nick');

Irssi::signal_add('setup saved', 'sig_setup_save');
Irssi::signal_add('setup reread', 'sig_setup_reread');

Irssi::signal_add("event notice", "event_notice");

# --------[ Register commands ]-----------------------------------------

Irssi::command_bind("help_keepnick", 'cmd_print_help');
Irssi::command_bind("keepnick_help", 'cmd_print_help');
Irssi::command_bind("keepnick", "cmd_keepnick");
Irssi::command_bind("unkeepnick", "cmd_unkeepnick");
Irssi::command_bind("listnick", "cmd_listnick");
Irssi::command_bind("nick", "cmd_nick");

# --------[ Register timers ]-------------------------------------------

Irssi::timeout_add(12000, 'check_nick', '');

# --------[ Register redirects ]----------------------------------------

Irssi::Irc::Server::redirect_register('keepnick ison', 0, 0,
			 undef,
			 {
			  "event 303" => -1,
			 },
			 undef );

Irssi::Irc::Server::redirect_register('keepnick nick', 0, 0,
			 undef,
			 {
			  "event nick" => 0,
			  "event 432" => -1,	# ERR_ERRONEUSNICKNAME
			  "event 433" => -1,	# ERR_NICKNAMEINUSE
			  "event 437" => -1,	# ERR_UNAVAILRESOURCE
			  "event 484" => -1,	# ERR_RESTRICTED
			 },
			 undef );

# --------[ Load config ]-----------------------------------------------

load_nicks;

# ======[ END ]=========================================================

# Local Variables:
# header-initial-hide: t
# mode: header-minor
# end:
