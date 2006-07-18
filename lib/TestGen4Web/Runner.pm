#
# $Id: Runner.pm 52 2006-07-18 20:54:17Z mackers $

package TestGen4Web::Runner;

=head1 NAME

TestGen4Web::Runner - A PERL module to replay files recorded with TestGen4Web

=head1 SYNOPSIS

  require TestGen4Web::Runner;

  my $runner = new TestGen4Web::Runner;

  $runner->load('actions.xml');

  if (!$runner->run())
  {
    print $runner->error() . "\n";
  }

=head1 DESCRIPTION

L<TestGen4Web::Runner> is a PERL module to replay files recorded with
SpikeSource's TestGen4Web Recorder.

From http://developer.spikesource.com/projects/testgen4web :

"TestGen4Web is written to ease the pain of writing tests for web applications.
This is a 2 part tool. Firefox extension, which records user input to a xml
file. Translator script: to generate automated test scripts."

This module fits in neither the 'recorder' or 'translator' category, instead
directly replaying the XML files as generated by the TestGen4Web recorder.
This leaves the implementation of the tests to the PERL developer utilizing
this module.

This release of the module implements a B<subset> of TestGen4Web's features. The
entire feature set will be implemented in a future release.

Another use for this module is to interact and automate with web services only
available via HTTP and HTML (commonly called 'screen scraping'). The desired
action is recorded in the browser with the TestGen4Web recorder and the
resulting XML can be replayed by this module in order to duplicate that action
and, for example, retrieve some text.

A working example of this module can be found in the L<WWW::SMS::IE::iesms>
module.

The following methods are available:

=over 4

=cut

use strict;
use warnings;

use vars qw( $VERSION );
$VERSION = '0.08';

use XML::Simple qw(:strict);
use Data::Dumper;
use LWP::UserAgent;
use HTTP::Cookies;
use URI::Escape;
use URI 1.26;

1;

=item $runner = new TestGen4Web::Runner

This is the object constructor. It takes no arguments.

=cut

sub new
{
	my $class = shift;
	my $self = {};

	$self->{xs} = new XML::Simple();
	$self->{ua} = LWP::UserAgent->new(max_redirect => 0);
	$self->{cookie_jar} = HTTP::Cookies->new(ignore_discard => 1);

	$self->{ua}->agent("Mozilla/5.0 (Macintosh; U; PPC Mac OS X Mach-O; en-US; rv:1.8) Gecko/20051112 Firefox/1.5");
	$self->{ua}->env_proxy();

	$self->{verify_titles} = 1;
	$self->{debug} = 0;
	$self->{quiet} = 0;
	$self->{matches} = [];
	$self->{start_step} = -1;
	$self->{end_step} = 9999;
	$self->{replacements} = {};

	my $key; my $val;

	while (($key = shift) && ($val = shift))
	{
		$self->{$key} = $val;
	}

	bless ($self, $class);

	$self->_log_debug("TestGen4Web::Runner version $VERSION");
	
	return $self;
}

=item $runner->load($filename)

Load an action XML file.

Returns true on success, false on failure; errors are in C<error()>.

=cut

sub load
{
	my $self = shift;
	my $actor_xml_file = shift;

	$self->_log_debug("Loading actions from file '$actor_xml_file'");
	
	if (!($self->{actor} = $self->{xs}->XMLin($actor_xml_file, ForceArray => 0, KeyAttr => ['step'])))
	{
		$self->_log_error("Error loading XML file: $actor_xml_file");
		return 0;
	}

	if (!$self->{actor}->{actions} || !$self->{actor}->{actions}{action})
	{
		$self->_log_error("No actions found in XML file: $actor_xml_file");
		return 0;
	}

	return 1;
}

=item $carrier->run($start_step, $end_step)

Replays the action file that was loaded with C<load()>.

The optional C<$start_step> and C<$end_step> arguments determine what action
steps the Runner will start and end with respectively.

Returns true on success, false on failure; errors are in C<error()>, 
matches are in C<matches()>.

=cut

sub run
{
	my $self = shift;

	my $start_step = (defined($_[0]) ? $_[0] : $self->{start_step});
	my $end_step = (defined($_[1]) ? $_[1] : $self->{end_step});

	$self->_log_debug("Running actions from step '$start_step' to '$end_step'");
	
	$self->{error} = "";
	$self->{result} = -1;

	if (!($self->{actor}))
	{
		$self->_log_error("Cannot run: nothing loaded yet");
		$self->{error} = "Cannot run: no script loaded";

		return ($self->{result} = 0);
	}

	if (defined($self->{cookie_jar_file}))
	{
		$self->{cookie_jar}->load($self->{cookie_jar_file});
	}

	my $step = 0;

	while ($self->{actor}->{actions}{action}{$step})
	{
		my $action = $self->{actor}->{actions}{action}{$step};

		if (($step >= $start_step) && ($step <= $end_step))
		{
			$self->_log_debug("STEP$step: start " . $action->{type});

			my $retval = $self->_action_sink(
					$step,
					$action->{type},
					$action->{xpath},
					$action->{value},
					$action->{refresh},
					$action->{frame});

			$self->_log_debug("STEP$step: end, result = " . ($retval?'SUCCESS':'FAILURE'));

			if ($retval == 0)
			{
				return ($self->{result} = 0);
			}
		}
		else
		{
			$self->_log_debug("STEP$step: skipping");
		}

		$step++;
	}

	$self->{error} = "";

	if (defined($self->{cookie_jar_file}))
	{
		$self->{cookie_jar}->save($self->{cookie_jar_file});
	}

	return ($self->{result} = 1);
}

=item $runner->result()

Set/retrieve the result of the previous C<run()> operation. True on success,
false on failure.

=cut

sub result
{
	return $_[0]->{result};
}

=item $runner->matches()

Retrieves the array of matches from the last assertion action during a C<run()>.

The value part of a C<assert-text-exists> action may be a regular expression.
Matches in parentheses are returned by this method.

=cut

sub matches
{
	return $_[0]->{matches};
}

=item $runner->error()

Retrieve the error message of a failed C<run()>.

=cut

sub error
{
	return $_[0]->{error};
}

=item $runner->set_replacement($key, $val)

Replace all instances of C<{$key}> with C<$val> when filling forms or (or
waiting) in the action file.

=cut

sub set_replacement
{
	if ($_[2])
	{
		$_[0]->{replacements}{$_[1]} = $_[2];
	}
	else
	{
		undef($_[0]->{replacements}{$_[1]});
	}
}

=item $runner->clear_replacements()

Clear all replacements.

=cut

sub clear_replacements
{
	$_[0]->{replacements} = {};
}

=item $runner->verify_titles()

Set/retrieve the C<verify_titles> setting. If true (the default), then all
C<verify-title> assertions will be checked, otherwise, these assertions will
be ignored.

=cut

sub verify_titles
{
	defined($_[1]) ? $_[0]->{verify_titles} = $_[1] : $_[0]->{verify_titles};
}

=item $runner->start_step()

Set/retrieve the first action step that will be executed by the C<run()> method.

=cut

sub start_step
{
	defined($_[1]) ? $_[0]->{start_step} = $_[1] : $_[0]->{start_step};
}

=item $runner->end_step()

Set/retrieve the final action step that will be executed by the C<run()> method.

=cut

sub end_step
{
	defined($_[1]) ? $_[0]->{end_step} = $_[1] : $_[0]->{end_step};
}

=item $runner->user_agent()

Retrieve the C<LWP::UserAgent> object used internally by the Runner.

=cut

sub user_agent
{
	return $_[0]->{ua};
}

=item $runner->cookie_jar_file()

Set/retrieve the full filename of the cookie jar as used internally by the
C<LWP::UserAgent> performing the actions.

=cut

sub cookie_jar_file
{
	defined($_[1]) ? $_[0]->{cookie_jar_file} = $_[1] : $_[0]->{cookie_jar_file};
}

=item $runner->cookie_jar()

Set/retrieve the C<HTTP::Cookies> cookie jar object used by the module.

=cut

sub cookie_jar
{
	defined($_[1]) ? $_[0]->{cookie_jar} = $_[1] : $_[0]->{cookie_jar};
}

=item $runner->action_state()

Retrieve the state of the Runner between C<run()> requests. The returned object
is of the type C<HTTP::Response>.

=cut

sub action_state
{
	defined($_[1]) ? $_[0]->{action_state} = $_[1] : $_[0]->{action_state};
}

=item $runner->quiet()

Set/retrieve the C<quiet()> setting. If this is disabled (the default), normal
output will be printed. If set to true, normal output will be suppressed.

=cut

sub quiet
{
	defined($_[1]) ? $_[0]->{quiet} = $_[1] : $_[0]->{quiet};
}

=item $runner->debug()

Set/retrieve the C<debug mode> setting. If this is set to a value greater than 0,
debug output will be printed during C<load()> and C<run()> operations. Greater
values mean more debug output. The default is 0.

=cut

sub debug
{
	defined($_[1]) ? $_[0]->{debug} = $_[1] : $_[0]->{debug};
}

=item $runner->version()

Retrieve the version of this module.

=cut

sub version
{
	return $VERSION;
}

# private methods

sub _action_sink
{
	my ($self, $step, $type, $xpath, $value, $refresh, $frame) = @_;

	if (!defined($refresh)) { $refresh = 'false'; }

	# work around for what looks like a bug in XML::Simple
	$value =~ s/>$//;

	$value =~ s/{(\w+?)}/$self->{replacements}{$1}/ge;

	if ($type eq 'goto')
	{
		return $self->_goto($step, $value);
	}
	elsif ($type eq 'fill')
	{
		# poor man's xpath
		if ($xpath =~ m/\*\/FORM\[(.*?)\]\/(\*\/)?(INPUT|TEXTAREA)\[(.*?)]/)
		{
			my $formxpath = $1;
			my $formnum = 0;
			my $inputxpath = $4;
			my $inputname = "";

			if ($formxpath =~ m/\@NAME="(.*?)"/)
			{
				$formnum = $self->_get_form_position($step, $1);

				if ($formnum == -1)
				{
					return 0;
				}
			}
			elsif ($formxpath =~ m/\d+/)
			{
				$formnum = $formxpath;
			}
			else
			{
				$self->{error} = "Could not parse xpath expression \"$xpath\", form \"$formxpath\"";
				$self->_log_error("STEP$step: " . $self->{error});
				return 0;
			}
			
			if ($inputxpath =~ m/\@(ID|NAME)="(.*?)"/)
			{
				$inputname = $2;
			}
			elsif ($inputxpath =~ m/\d+/)
			{
				if (!($inputname = $self->_get_input_name($step,
							$formnum, int($inputxpath)+1)))
				{
					return 0;
				}
			}
			else
			{
				$self->{error} = "Could not parse xpath expression \"$xpath\", input \"$inputxpath\"";
				$self->_log_error("STEP$step: " . $self->{error});
				return 0;
			}

			$self->{filldata}[$formnum]->{$inputname} = $value;

			return 1;
		}
		else
		{
			$self->{error} = "Could not parse xpath expression \"$xpath\"";
			$self->_log_error("STEP$step: " . $self->{error});

			return 0;
		}
	}
	elsif ($type eq 'wait')
	{
		if ($value > 0)
		{
			$self->_log_debug("STEP$step: sleeping for $value seconds...");
			sleep($value);

			return 1;
		}
		else
		{
			$self->{error} = "Could not parse wait value \"$value\"";
			$self->_log_error("STEP$step: " . $self->{error});

			return 0;
		}
	}
	elsif ($type eq 'click')
	{
		if (defined($frame) && ($self->{last_frame} ne $frame))
		{
			$self->_log_debug("STEP$step: going to search for frame \"$frame\"");

			if (!($self->_goto_frame($step, $frame)))
			{
				$self->{error} = "Frame not found \"frame\" in step $step";
				$self->_log_error("STEP$step: " . $self->{error});

				return 0;
			}
		}

		my $retval;

		# poor man's xpath
		if ($xpath =~ m/\*\/A\[\@CDATA="(.*?)"\]/)
		{
			$retval = $self->_goto_link($step, $1);
		}
		elsif ($xpath =~ m/\*\/A\[\@HREF="(.*?)"\]/)
		{
			$retval = $self->_goto_link($step, undef, $1);
		}
		elsif ($xpath =~ m/\*\/FORM\[(.*?)\]\//)
		{
			my $formname = $1;
			my $formnum = 0;

			if ($formname =~ m/\@NAME="(.*?)"/)
			{
				$formnum = $self->_get_form_position($step, $1);

				if ($formnum == -1)
				{
					return 0;
				}
			}
			elsif ($formname =~ m/\d+/)
			{
				$formnum = $formname;
			}

			$retval = $self->_submit_form($step, $formnum);
		}
		else
		{
			$self->{error} = "Could not parse xpath expression \"$xpath\"";
			$self->_log_error("STEP$step: " . $self->{error});

			return 0;
		}

		if (!$retval)
		{
			return 0;
		}
		elsif ($refresh eq "true")
		{
			return $self->_refresh($step);
		}
		else
		{
			return 1;
		}
	}
	elsif ($type eq 'verify-title')
	{
		$self->{matches} = [];

		if ($self->{verify_titles})
		{
			my $doctitle;

			if (!$self->{action_state})
			{
				$self->_log_warn("STEP$step: skipping $type action; no previous request");

				return 1;
			}

			if (($self->{action_state}->as_string() =~ m/<title>(.*?)<\/title>/ism) && (defined($1)))
			{
				$doctitle = $1;
			}
			else
			{
				$self->{error} = "Assertion failed in step $step ($type): document has no title";
				$self->_log_error("STEP$step: " . $self->{error});

				return 0;
			}

			$doctitle =~ s/\W//gsm;
			$value =~ s/\W//gsm;

			#if ($self->{action_state}->as_string() =~ m/<title>\s*$value\s*<\/title>/ism)
			if ($doctitle =~ m/$value/sm)
			{
				$self->_log_debug("title match for \"$value\" in last response");

				$self->{matches} = [$0, $1, $2, $3, $4, $5, $6, $7, $8, $9];
			}
			else
			{
				$self->_log_debug("no title match for \"$value\" in last response");
				$self->{error} = "Assertion failed in step $step ($type): no match for \"$value\""; 

				return 0;
			}
		}

		if ($refresh eq "true")
		{
			return $self->_refresh($step);
		}
		else
		{
			return 1;
		}
	}
	elsif ($type eq 'assert-text-exists')
	{
		$self->{matches} = [];

		if (!$self->{action_state})
		{
			$self->_log_warn("STEP$step: skipping $type action; no previous request");
			return 1;
		}

		if ($self->{action_state}->as_string() =~ m/$value/ism)
		{
			$self->_log_debug("text match for \"$value\" in last response");

			$self->{matches} = [$0, $1, $2, $3, $4, $5, $6, $7, $8, $9];

			return 1;
		}
		else
		{
			$self->_log_debug("no text match for \"$value\" in last response");
			$self->{error} = "Assertion failed in step $step ($type): no match for \"$value\""; 

			return 0;
		}
	}
	else
	{
		$self->{error} = "Unsupported action: $type";
		$self->_log_error("STEP$step: " . $self->{error});
		return 0;
	}

	return 0;
}

sub _refresh
{
	my ($self, $step) = @_;
	my $uri;

	if (!$self->{action_state})
	{
		$self->{error} = "Tried to refresh with no previous response";
		$self->_log_error("STEP$step: " . $self->{error});
		return 0;
	}

	# <meta http-equiv="refresh" content="0;URL=http://web.o2.ie/personal/">

	if ($self->{action_state}->header("Location"))
	{
		$uri = $self->{action_state}->header("Location");
		$self->_log_debug("found refresh in location header: $uri");
	}
	elsif ($self->{action_state}->header("Refresh") && ($self->{action_state}->header("Refresh") =~ m/\d+;URL=(.*)/i))
	{
		$uri = $1;
		$self->_log_debug("found refresh in refresh header: $uri");
	}
	elsif ($self->{action_state}->as_string() =~ m/<meta\s*http-equiv=["']?refresh["']?\s*content=["']?\d+;URL=(.*?)["']?>/)
	{
		$uri = $1;
		$self->_log_debug("found refresh in meta refresh tag: $uri");
	}
	else
	{
		#$self->{error} = "No refresh URL found";
		#$self->_log_error($self->{error});
		return 1;
	}

	$uri = $self->_make_absolute_url($uri);

	$self->_log_debug("redirecting to \"$uri\"");

	return $self->_goto($step, $uri);
}

sub _goto
{
	my ($self, $step, $uri) = @_;
	my $req = HTTP::Request->new();

	$req->uri($uri);
	$req->method("GET");
	$req->protocol("HTTP/1.0");
	$self->{cookie_jar}->add_cookie_header($req);

#$self->_log_debug("CJLOOKY: \n" . $self->{cookie_jar}->as_string());
#$self->_log_debug("REQLOOKY: \n" . $req->as_string());
	
	my $now = time();
	$self->_log_debug("about to fetch \"$uri\"");

	my $resp = $self->{ua}->request($req);

	$self->_log_debug("fetched url in " . (time() - $now) . " seconds with result \"" . $resp->status_line . "\"");

	if ($resp->is_error())
	{
		$self->{error} = "Action failed in step $step (subtype goto): " . $resp->status_line; 

		return 0;
	}

	$self->{cookie_jar}->extract_cookies($resp);
	$self->{action_state} = $resp;

	$self->_log_action_state();

#TODO fix this
	$self->_refresh($step);
	$self->_refresh($step);

	return 1;
}

sub _goto_link
{
	my ($self, $step, $linktext, $href) = @_;

	if (!defined($self->{action_state}))
	{
		$self->{error} = "No previous request";
		$self->_log_error("STEP$step: " . $self->{error});

		return 0;
	}
	
	# images in links seem to get the text 'null'
	defined($linktext) && ($linktext =~ s/null//g);

	my @links = ($self->{action_state}->as_string() =~ m/<a.*?>.*?<\/a>/gism);

	$self->_log_debug("STEP$step: document contains " . scalar(@links) . " links");

	foreach my $link (@links)
	{
		if (	(defined($linktext) && ($link =~ m/href=["'](.*?)["'>].*?$linktext/ism)) ||
			(defined($href) && ($link =~ m/href=["'](.*?$href.*?)["'>]/ism)))
		{
			my $link = $self->_make_absolute_url($1);
			$self->_log_debug("STEP$step: found link" . (defined($linktext)?" containing \"$linktext\"":"") . ": $link");

			$self->{last_frame} = "";

			return $self->_goto($step, $link);
		}
	}

	!defined($linktext) && ($linktext = "");

	$self->{error} = "No links found matching the text \"$linktext\"";
	$self->_log_error("STEP$step: " . $self->{error});

	return 0;
}

sub _goto_frame
{
	my ($self, $step, $framename) = @_;
	my @frames;

	if (!(@frames = ($self->{action_state}->as_string() =~ m/<i?frame.*?name=["']?$framename["' ].*?<\/i?frame>/gism)))
	{
		$self->{error} = "No frames found in document";
		$self->_log_error("STEP$step: " . $self->{error});

		return 0;
	}

	foreach my $frame (@frames)
	{
		if ($frame =~ m/src=["'](.*?)["' >]/ism)
		{
			$self->_log_debug("Found frame \"$framename\" with src = $1");
			$self->{last_frame} = $framename;

			return $self->_goto($step, $self->_make_absolute_url($1));
		}
	}

	$self->{error} = "Frame \"$framename\" not found in document";
	$self->_log_error("STEP$step: " . $self->{error});

	return 0;
}

sub _get_input_name
{
	my ($self, $step, $thisform, $inputnum) = @_;

	my @matches;

	if (!(@matches = ($self->{action_state}->as_string() =~ m/<form.*?>.*?<\/form>/gism)))
	{
		$self->{error} = "Unexpected failure in step $step (subtype fill_form); the document has no forms";
		$self->_log_error("STEP$step: " . $self->{error});

		return "";
	}

	if (!$matches[($thisform-1)])
	{
		$self->{error} = "Unexpected failure in step $step (subtype fill_form); form $thisform not found";
		$self->_log_error("STEP$step: " . $self->{error});

		return "";
	}
	
	my @inputs = ($matches[$thisform-1] =~ m/<(input|textarea).*?name=["']?(.*?)["'>\s]/gism);
	my $name = "";

	if (!($name = $inputs[($inputnum*2)-1]))
	{
		$self->{error} = "Unexpected failure in step $step (subtype fill_form); input $inputnum in form $thisform not found";
		$self->_log_error("STEP$step: " . $self->{error});
		
		return "";
	}

	return $name;
}

sub _get_form_position
{
	my ($self, $step, $formname) = @_;

	my @matches;

	if (!(@matches = ($self->{action_state}->as_string() =~ m/<form.*?>/gism)))
	{
		$self->{error} = "Unexpected failure in step $step (subtype submit_form); the document has no forms";
		$self->_log_error("STEP$step: " . $self->{error});

		return -1;
	}

	for (my $i=0; $i<scalar(@matches); $i++)
	{
		if ($matches[$i] =~ m/(name|id)=['"]?$formname/ism)
		{
			return $i + 1;
		}
	}

	$self->{error} = "Unexpected failure in step $step (subtype submit_form); can't find the form '$formname'";
	$self->_log_error("STEP$step: " . $self->{error});

	return -1;
}

sub _submit_form
{
	my ($self, $step, $thisform) = @_;
	my @matches;

	if ($thisform =~ m/\D/)
	{
		$thisform = $self->_get_form_position($step, $thisform);

		return 0 if ($thisform == -1);
	}

	my $html = $self->{action_state}->as_string();

	$html =~ s/<!--.*?-->//gsm;
	
	if (!(@matches = ($html =~ m/<form.*?>.*?<\/form>/gism)))
	{
		$self->{error} = "Refresh failed in step $step (subtype submit_form); the document has no forms";
		$self->_log_error("STEP$step: " . $self->{error});

		return 0;
	}

	if (!$matches[($thisform-1)])
	{
		$self->{error} = "Refresh failed in step $step (subtype submit_form); form $thisform not found";
		$self->_log_error("STEP$step: " . $self->{error});

		return 0;
	}
	
	if ($matches[$thisform-1] =~ m/(<form.*?>)(.*?)<\/form>/gism)
	{
		my $formtag = $1;
		my $formbody = $2;
		my $action = "";
		my $method = "";
		my $query_string = "";
		my $req = HTTP::Request->new();

		($formtag =~ m/action=["']?(.*?)["' >]/i) && ($action = $1);
		($formtag =~ m/method=["']?(get|post)["' ]?/i) && ($method = uc($1));

		$action = $self->_make_absolute_url($action);

#$self->_log_debug("11111111 $formbody 11111111");

		foreach my $input ($formbody =~ m/(<(input|textarea).*?>)/gism)
		{
			my $name = "";
			my $value = "";
			#my $type = "";

			($input =~ m/name=["']?(.*?)["' >]/i) && ($name = $1);
			($input =~ m/value=["']?(.*?)["' >]/i) && ($value = $1);
			#($input =~ m/type=["']?(.*?)["' >]/i) && ($type = $1);

#$self->_log_debug("Found input $name");

			if ($name eq "") # || $type eq "image" || $type eq "submit")
			{
				next;
			}

			if ($self->{filldata}[$thisform]->{$name})
			{
				$query_string .= "$name=" . uri_escape($self->{filldata}[$thisform]->{$name});
			}
			else
			{
				$query_string .= "$name=" . uri_escape($value);
			}

			$query_string .= '&';
		}

		$query_string .= "x=1&y=1";

		if ($method eq 'POST')
		{
			$req->push_header("Content-Type" => "application/x-www-form-urlencoded");
			$req->push_header("Content-Length" => length($query_string));
			$req->content($query_string);
		}
		elsif ($method eq 'GET')
		{
			$action .= '?' . $query_string;
		}
		else
		{
			$self->{error} = "Unsupported form method: '$method' in form tag '$formtag'"; 
			$self->_log_error("STEP$step: " . $self->{error});
			return 0;
		}

		$req->uri($action);
		$req->method($method);
		$req->protocol("HTTP/1.0");
		$self->{cookie_jar}->add_cookie_header($req);

		my $now = time();
		$self->_log_debug("about to $method \"$action\"");

		my $resp = $self->{ua}->request($req);

		$self->_log_debug("fetched url in " . (time() - $now) . " seconds with result \"" . $resp->status_line . "\"");

		$self->{cookie_jar}->extract_cookies($resp);
		$self->{action_state} = $resp;
		$self->{filldata} = [];
		$self->{last_frame} = "";
		$self->_log_action_state();

		if ($resp->is_error())
		{
			$self->{error} = "Action failed in step $step (subtype submit_form): " . $resp->status_line; 
			return 0;
		}

		return 1;
	}
}

sub _make_absolute_url
{
	my ($self, $url) = @_;

	my $u1 = URI->new_abs($url, $self->{action_state}->request()->uri);

	return $u1->as_string();
}

sub _log_debug
{
	my ($self, $msg) = @_;

	if ($self->{debug})
	{
		print "DEBUG: $msg\n";
	}
}

sub _log_action_state
{
	my $self = shift;

	return if ($self->{debug} < 2);

	my $out = Dumper($self->{action_state});

	eval 'use Term::ANSIColor';

	if (!$@)
	{
		$out 	= color('yellow') 
			. "********************************************************\n"
			. color('reset')
			. $out
			. color('yellow')
			. "********************************************************\n"
			. color('reset');
	}
	else
	{
		print $out;
	}

	print "DEBUG:\n $out";
}

sub _log_info
{
	my ($self, $msg) = @_;

	unless ($self->{quiet})
	{
		print "INFO: $msg\n";
	}
}

sub _log_error
{
	my ($self, $msg) = @_;

	unless ($self->{quiet})
	{
		print STDERR "ERROR: $msg\n";
	}
}

sub _log_warning
{
	my ($self, $msg) = @_;

	unless ($self->{quiet})
	{
		print STDERR "WARNING: $msg\n";
	}
}

=back

=head1 DISCLAIMER

The author accepts no responsibility nor liability for your use of this
software. 

=head1 SEE ALSO

L<WWW::SMS::IE::iesms>,

=head1 AUTHOR

David McNamara (me.at.mackers.dot.com)

=head1 COPYRIGHT

Copyright 2000-2006 David McNamara

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
