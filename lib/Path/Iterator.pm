use v6;

unit class Path::Iterator;
has Sub:D @!rules;
our enum Prune is export(:prune) <PruneInclusive PruneExclusive>;

submethod BUILD(:@!rules) { }
method !rules() {
	return @!rules;
}

my multi rulify(Sub $rule) {
	return $rule;
}
my multi rulify(Path::Iterator:D $rule) {
	return $rule!rules;
}
proto method and(*@ --> Path::Iterator:D) { * }
multi method and(Path::Iterator:D $self: *@also --> Path::Iterator:D) {
	return self.bless(:rules(|@!rules, |@also.map(&rulify)));
}
multi method and(Path::Iterator:U: *@also --> Path::Iterator:D) {
	return self.bless(:rules(|@also.map(&rulify)));
}
multi method none(Path::Iterator:U: *@no --> Path::Iterator:D) {
	return self.or(|@no).not;
}
multi method none(Path::Iterator: Sub $rule --> Path::Iterator:D) {
	return self.and: sub ($item, *%options) { return negate($rule($item, |%options)) };
}

my multi negate(Bool $value) {
	return !$value;
}
my multi negate(Prune $value) {
	return Prune(+!$value)
}
method not(--> Path::Iterator:D) {
	my $obj = self;
	return self.bless(:rules[sub ($item, *%opts) {
		return negate($obj!test($item, |%opts))
	}]);
}
my multi unrulify(Sub $rule) {
	return Path::Iterator.and($rule);
}
my multi unrulify(Path::Iterator $iterator) {
	return $iterator;
}
proto method or(*@ --> Path::Iterator:D) { * }
multi method or(Path::Iterator:U: $rule --> Path::Iterator:D) {
	return unrulify($rule);
}
multi method or(Path::Iterator:U: *@also --> Path::Iterator:D) {
	my @iterators = |@also.map(&unrulify);
	my @rules = sub ($item, *%opts) {
		my $ret = False;
		for @iterators -> $iterator {
			given $iterator!test($item, |%opts) {
				when * === True {
					return True;
				}
				when PruneExclusive {
					$ret = $_;
				}
				when PruneInclusive {
					$ret = $_ if $ret === False;
				}
			}
		}
		return $ret;
	}
	return self.bless(:@rules);
}
method skip(*@garbage --> Path::Iterator:D) {
	my @iterators = |@garbage.map(&unrulify);
	self.and: sub ($item, *%opts) {
		for @iterators -> $iterator {
			if $iterator!test($item, |%opts) !== False {
				return PruneInclusive;
			}
		}
		return True;
	};
}

method !test(IO::Path $item, *%args) {
	my $ret = True;
	for @!rules -> &rule {
		my $value = rule($item, |%args);
		return $value unless $value;
		$ret = $value if $value === PruneExclusive;
	}
	return $ret;
}

my sub add-method(Str $name, Method $method) {
	$method.set_name($name);
	$?CLASS.^add_method($name, $method);
}
my sub add-matchable(Str $sub-name, &match-sub) {
	add-method($sub-name, method (Mu $matcher, *%opts --> Path::Iterator:D) {
		self.and: match-sub($matcher, |%opts);
	});
	add-method("not-$sub-name", method (Mu $matcher, *%opts --> Path::Iterator:D) {
		self.none: match-sub($matcher, |%opts);
	});
}

add-matchable('name', sub (Mu $name) { sub ($item, *%) { $item.basename ~~ $name } });
add-matchable('ext', sub (Mu $ext) { sub ($item, *%) { $item.extension ~~ $ext } });
add-matchable('path', sub (Mu $path) { sub ($item, *%) { $item ~~ $path } });

method dangling( --> Path::Iterator:D) {
	self.and: sub ($item, *%) { $item.l and not $item.e };
}
method not-dangling( --> Path::Iterator:D) {
	self.and: sub ($item, *%) { not $item.l or $item.e };
}

my %X-tests = %(
	:r('readable'),
	:w('writable'),
	:x('executable'),

	:rw('read-writable'),
	:rwx('read-write-executable')

	:e('exists'),
	:f('file'),
	:d('directory'),
	:l('symlink'),
	:z('empty'),
);
for %X-tests.kv -> $test, $method {
	add-method($method,       method ( --> Path::Iterator:D) { return self.and: sub ($item, *%) { ?$item."$test"() } });
	add-method("not-$method", method ( --> Path::Iterator:D) { return self.and: sub ($item, *%) { !$item."$test"() } });
}

{
	use nqp;
	my %stat-tests = %(
		inode  => nqp::const::STAT_PLATFORM_INODE,
		device => nqp::const::STAT_PLATFORM_DEV,
		mode   => nqp::const::STAT_PLATFORM_MODE,
		nlinks => nqp::const::STAT_PLATFORM_NLINKS,
		uid    => nqp::const::STAT_UID,
		gid    => nqp::const::STAT_GID,
	);
	for %stat-tests.kv -> $method, $constant {
		add-matchable($method, sub (Mu $matcher) { sub ($item, *%) { nqp::stat(nqp::unbox_s(~$item), $constant) ~~ $matcher } });
	}
}
for <accessed changed modified> -> $time-method {
	add-matchable($time-method, sub (Mu $matcher) { sub ($item, *%) { $item."$time-method"() ~~ $matcher } });
}

add-matchable('size', sub (Mu $size) { sub ($item, *%) { $item.f && $item.s ~~ $size }; });

add-matchable('depth', sub (Mu $depth) {
	multi depth(Range $depth-range) {
		sub ($item, :$depth, *%) {
			return do given $depth {
				when $depth-range.max {
					PruneExclusive;
				}
				when $depth-range {
					True;
				}
				when * < $depth-range.min {
					False;
				}
				default {
					PruneInclusive;
				}
			}
		};
	}
	multi depth(Int $depth) {
		return depth($depth..$depth);
	}
	multi depth(Mu $depth-match) {
		sub ($item, :$depth, *%) {
			return $depth ~~ $depth-match;
		}
	}
	return depth($depth);
});

method skip-dir(Mu $pattern --> Path::Iterator:D) {
	self.and: sub ($item, *%) {
		if $item.basename ~~ $pattern && $item.d {
			return PruneInclusive;
		}
		return True;
	}
}
method skip-subdir(Mu $pattern --> Path::Iterator:D) {
	self.and: sub ($item, :$depth, *%) {
		if $depth > 0 && $item.basename ~~ $pattern && $item.d {
			return PruneInclusive;
		}
		return True;
	}
}
method skip-hidden( --> Path::Iterator:D) {
	self.and: sub ($item, :$depth, *%) {
		if $depth > 0 && $item.basename ~~ rx/ ^ '.' / {
			return PruneInclusive;
		}
		return True;
	}
}
my $vcs-dirs = any(<.git .bzr .hg _darcs CVS RCS .svn>, |($*DISTRO.name eq 'mswin32' ?? '_svn' !! ()));
my $vcs-files = none(rx/ '.#' $ /, rx/ ',v' $ /);
method skip-vcs(--> Path::Iterator:D) {
	return self.skip-dir($vcs-dirs).name($vcs-files);
}

add-matchable('shebang', sub (Mu $pattern = rx/ ^ '#!' /, *%opts) {
	sub ($item, *%) {
		return False unless $item.f;
		return $item.lines(|%opts)[0] ~~ $pattern;
	}
});
add-matchable('contents', sub (Mu $pattern, *%opts) {
	sub ($item, *%) {
		return False unless $item.f;
		return $item.slurp(|%opts) ~~ $pattern;
	}
});
add-matchable('line', sub (Mu $pattern, *%opts) {
	sub ($item, *%) {
		return False unless $item.f;
		for $item.lines(|%opts) -> $line {
			return True if $line ~~ $pattern;
		}
		return False;
	}
});

$?CLASS.^compose;

my &is-unique = $*DISTRO.name ne any(<MSWin32 os2 dos NetWare symbian>)
	?? sub (Bool %seen, IO::Path $item) {
		use nqp;
		my $inode = nqp::stat(nqp::unbox_s(~$item), nqp::const::STAT_PLATFORM_INODE);
		my $device = nqp::stat(nqp::unbox_s(~$item), nqp::const::STAT_PLATFORM_DEV);
		my $key = "$inode\-$device";
		return False if %seen{$key};
		return %seen{$key} = True;
	}
	!! sub (Bool %seen, IO::Path $item) { return True };

enum Order is export(:DEFAULT :order) < BreadthFirst PreOrder PostOrder >;

my %as{Any:U} = ((Str) => { ~$_ }, (IO::Path) => Block);
method in(*@dirs,
	Bool:D :$follow-symlinks = True,
	Order:D :$order = BreadthFirst,
	Bool:D :$sorted = True,
	Bool:D :$loop-safe = True,
	Bool:D :$relative = False,
	Any:U :$as = IO::Path,
	:&map = %as{$as},
	:&visitor,
	--> Seq:D
) {
	my @queue = (@dirs || '.').map(*.IO).map: { ($^path, 0, $^path, Bool) };

	my Bool %seen;
	my $seq := gather while @queue {
		my ($item, $depth, $base, $result) = @( @queue.shift );

		without ($result) {
			$result = self!test($item, :$depth, :$base);

			visitor($item) if &visitor && $result;

			if $result !~~ Prune && $item.d && (!$loop-safe || is-unique(%seen, $item)) && ($follow-symlinks || !$item.l) {
				my @next = $item.dir.map: { ($^child, $depth + 1, $base, Bool) };
				@next .= sort if $sorted;
				given $order {
					when BreadthFirst {
						@queue.append: @next;
					}
					when PostOrder {
						@next.push: ($item, $depth, $base, $result);
						@queue.prepend: @next;
						next;
					}
					when PreOrder {
						@queue.prepend: @next;
					}
				}
			}
		}

		take $relative ?? $item.relative($base).IO !! $item if $result;
	}
	return &map ?? $seq.map(&map) !! $seq;
}

my %priority = (
	0 => <skip-hidden skip skip-dir skip-subdir skip-vcs>,
	1 => <depth>,
	2 => <name ext path>,
	4 => <content line shebang>,
	5 => <not>
).flatmap: { ($_ => $^pair.key for @($^pair.value)) };

our sub finder(Path::Iterator :$base = Path::Iterator, Any:U :$in, *%options --> Path::Iterator) is export(:find) {
	my @keys = %options.keys.sort: { %priority{$_} // 3 };
	return ($base, |@keys).reduce: -> $object, $name {
		my $method = $object.^lookup($name);
		die "Finder key $name invalid" if not $method.defined or $method.signature.returns !~~ Path::Iterator;
		my $signature = $method.signature;
		my $value = %options{$name};
		my $capture = $value ~~ Capture ?? $value !! do given $signature.count - 1 {
			when 0 {
				\();
			}
			when 1 {
				\($value);
			}
			when Inf {
				\(|@($value).map: -> $entry { $entry ~~ Hash|Pair ?? finder(|%($entry)) !! $entry });
			}
		}
		$object.$method(|$capture);
	}
}

our sub find(*@dirs, *%options --> Seq:D) is export(:DEFAULT :find) {
	my %in-options = %options<follow-symlinks order sorted loop-safe relative visitor as map>:delete:p;
	return finder(|%options).in(|@dirs, |%in-options);
}
