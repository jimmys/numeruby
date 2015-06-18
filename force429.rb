#!/usr/bin/env ruby
#
# This test program uses up "all" your numerous-app API rate-limiting
# allocation. It's useful to generate conditions that test the 429 
# throttling code
#

require 'optparse'
require 'numerousapp'

options = {}
OptionParser.new do |opts|

    opts.banner = "Usage: force429.rb [options]"

    opts.on("-c", "--credentials CREDS", "credential info") do |c|
        options[:creds] = c
    end

    # the default, if you don't give us a limit, is to use them "all"
    opts.on("-n", "--napi N", "use up this many API calls") do |n|
        options[:n] = n.to_i
    end

    opts.on("-h", "--help", "Display this screen") { puts opts; exit 0 }


end.parse!

k = Numerous.numerousKey(s:options[:creds]) 

# note we create a Numerous with throttling turned off
# and we'll just bail out if we get the exception
# because that means we succeeded in using up "enough" APIs

nr = Numerous.new(k, throttle: Proc.new { |nr,tp,td,up| false })

exitstatus = 0
if not options[:n]
    options[:n] = 100000  # assumes this is enough to use them all :)
end

begin
    options[:n].times { nr.user() }
rescue NumerousError => e
    if e.code != 429
        # got an error, but not the expected "too many requests" one
        puts("Got unexpected error: #{e.code} (#{e})")
        exitstatus = 1
    end
end

exit(exitstatus)

