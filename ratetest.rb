#!/usr/bin/env ruby

require 'optparse'
require 'numerousapp'

#
# Test program whose primary goal is to test voluntary throttling.
#

#
# arguments:
#    -c credspec  : the usual
#    -m metric    : use metric as the test metric (see discussion below)
#    -n amt       : iterations of test (can be -1 for infinite)
#    -t limit     : limit on how many throttles (exit when reached)
#    -q           : quiet - no output unless you specifically rqst (e.g. stats)
#    -Y           : do NOT synchronize to top of API rate minute
#    -D           : debug flag
#    --capdelay   : force the volmaxdelay path (code coverage hack)
#    --statistics : display statistics when done
#
# With no arguments at all this loops over a default number of API calls
# and computes the effective API-per-minute rate.  Essentially it tests
# the voluntary throttling code. The rate should asymptomically approach
# the 300/minute theoretical max. 
#
# Note that you can get HIGHER rates than this if you don't sync to the top
# of the API rate minute (-Y) or if you run the test for too few iterations.
# For example, -n 20 will run very fast and not hit any limits and report
# an API/minute rate that you'd never get if you performed thousands of calls.
#
options = { :ncalls => 1500, :throttled => -1 }
OptionParser.new do |opts|

    opts.banner = "Usage: ratetest.rb [options]"

    opts.on("-c", "--credentials CREDS", "credential info") do |c|
        options[:creds] = c
    end

    opts.on("-q", "--quiet", "quiet mode") { options[:quiet] = true }
    opts.on("-D", "--debug", "debug") { options[:debug] = true }
    opts.on("-Y", "--nosync", "don't synchonize to API rate cycle") { 
        options[:nosync] = true 
    }

    opts.on("--capdelay", "force maximum voluntary delay cap") { 
        options[:capdelay] = true
    }

    opts.on("--statistics") { options[:statistics] = true }

    opts.on("-h", "--help", "Display this screen") { puts opts; exit 0 }

    opts.on("-m", "--metric mID", "test metric to use") do |m|
        options[:metric] = m
    end
    opts.on("-t", "--throttled N", OptionParser::DecimalInteger,
            "stop after this many throttlings") do |t|
        options[:throttled] = t
    end

    opts.on("-n", "--ncalls N", OptionParser::DecimalInteger,
            "stop after this many throttlings") do |n|
        options[:ncalls] = n
    end



end.parse!



#
# This sleeps until you have a fresh API allocation at the "top" of the minute
#

def sync_to_top_of_api_rate(nr)
    nr.ping()             # just anything to cause an API call
    if nr.statistics[:rateReset] > 0
        sleep(nr.statistics[:rateReset])
    end
end


nr = Numerous.new(apiKey=Numerous.numerousKey(s:options[:creds]))
if options[:statistics]
    nr.statistics[:serverResponseTimes] = [0]*5
end

if options[:debug]
    nr.debug(10)
end

testmetric = nil

if options[:metric]
    #  - attempt to use it as a metric ID. If that works, use that metric.
    #  - then attempt to look it up ByLabel 'STRING'
    #  - then attempt to look it up ByLabel 'ONE' (regexp processing will work)
    [ 'ID', 'STRING', 'ONE' ].each do |mt|
        begin
            testmetric = nr.metricByLabel(args.metric, matchType:mt)
            if testmetric
                break
            end
        rescue NumerousError   # can potentially get "conflict"
        end
    end
else
    options[:metric] = 'testrate-ruby-temp-metric'
end


# At this point either we found a metric (not None) or we have to create one.
# If we have to create it, use the args.metric as the label, if given.
deleteIt = false
if not testmetric
    attrs = { 'private' => true,
              'description' => 'used by throttle rate test. Ok to delete'
            }

    testmetric = nr.createMetric(options[:metric], value:0, attrs:attrs)
    deleteIt = true
end


if (not options[:quiet]) and (options[:ncalls] > 300) and (options[:throttled] == -1)
     puts("Performing #{options[:ncalls]} calls; expect this to take roughly #{sprintf('%.1f', (options[:ncalls]/300.0)+1)} minutes")
end

if (not options[:nosync]) or options[:capdelay]
    sync_to_top_of_api_rate(nr)
end



# To test the voluntary rate throttling, what we do is:
# Bang on a metric continuously writing something to it
# Stop as soon as we get voluntarily throttled N times
#

smallest_rate_remaining = 100000000

# if you wanted us to force the "maximum delay cap" branch of the code
# we need to use up as many APIs as quickly as possible and get down
# to a very small number left. To do that we actually have to turn off
# the voluntary throttling until we get the APIs remaining to a small number
if options[:capdelay]

    # as of 1.6.2 you can also easily turn off voluntary throttling this way
    k = Numerous.numerousKey(s:options[:credspec])
    nrX = Numerous.new(apiKey=k, throttleData:{voluntary: -1 })

    ignored = nrX.user()

    while nrX.statistics[:rateRemaining] > 3
        ignored = nrX.user()
    end
end


n_ops = 0
t0 = Time.now()
while true
    ignored = testmetric.read()
    n_ops += 1

    if nr.statistics[:rateRemaining] < smallest_rate_remaining
        smallest_rate_remaining = nr.statistics[:rateRemaining]
    end

    # if we were told to bomb out after a certain amount of throttles...
    s = nr.statistics
    if options[:throttled] > 0
        thd = s[:throttleVoluntaryBackoff] + s[:throttle429]
        if thd >= options[:throttled]
            break
        end
    end

    # if we were told to bomb out after n operations...
    if options[:ncalls] > 0 and n_ops >= options[:ncalls]
        break
    end
end

t1 = Time.now()

if not options[:quiet]
    puts("Smallest rate remaining was: #{smallest_rate_remaining}")
    puts("Performed #{sprintf('%.2f', (n_ops*60.0)/(t1-t0))} operations per minute")
end

if options[:statistics]
    puts(nr.statistics)
#    for k in nr.statistics:
#        print("{:>24s}: {}".format(k, nr.statistics[k]))
end     

if deleteIt
    testmetric.crushKillDestroy()
end
