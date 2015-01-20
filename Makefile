gem: numerous.rb gem/numerousapp.gemspec
	rm -rf gem/lib
	mkdir gem/lib
	cp numerous.rb gem/lib/numerousapp.rb
	(cd gem ; gem build numerousapp.gemspec)


test:
	RUBYLIB=. ./test.rb 

