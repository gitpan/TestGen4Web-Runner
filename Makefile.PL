use ExtUtils::MakeMaker;

WriteMakefile(
	NAME		=> 'TestGen4Web::Runner',
	VERSION_FROM	=> 'lib/TestGen4Web/Runner.pm',
	PREREQ_PM	=> {
		XML::Simple		=> 0,
		LWP::UserAgent		=> 0,
		HTTP::Cookies		=> 0,
		URI::Escape		=> 0,
		Term::ANSIColor		=> 0,
	},
	dist		=> { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
);
