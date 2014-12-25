gem: numerous.rb gem/numerousapp.gemspec
	rm -f gem/numerousapp.rb 
	cp numerous.rb gem/lib/numerousapp.rb
	(cd gem ; gem build numerousapp.gemspec)
