#
# The MIT License (MIT)
#
# Copyright (c) 2014 Neil Webber
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
# #################
# Classes for the NumerousApp API
#   Numerous
#     -- server-level operations: get user parameters,  create metric, etc
#
#   NumerousMetric 
#     -- individual metrics: read/write/like/comment, etc
#
#   NumerousClientInternals
#     -- all the hairball stuff for interfacing with numerousApp server
#        not really meant to be used outside of Numerous/NumerousMetric
# #################

require 'json'
require 'net/http'
require 'uri'

#
# NumerousError exceptions indicate errors from the server
#
class NumerousError < StandardError
    #
    # @!attribute msg
    #      human-targeted error message as a string
    #
    # @!attribute code
    #      HTTP error code (e.g., 404)
    #
    # @!attribute details
    #      hash containing more ad-hoc information, most usefully :id which
    #      is the URL that was used in the request to the server
    #

    def initialize(msg, code, details)
        super(msg)
        @code = code
        @details = details
    end

    attr_accessor :code, :details
end

#
# A NumerousAuthError occurs when the server rejects your credentials,
# Usually means your apiKey is (or has become) bad.
#
class NumerousAuthError < NumerousError
end

#
# A NumerousMetricConflictError occurs when you write to a metric
# and specified "only if changed" and your value 
# was (already) the current value
# 
class NumerousMetricConflictError < NumerousError
end

#
# == NumerousClientInternals 
#
# Handles details of talking to the numerousapp.com server, including
# the (basic) authentication, handling chunked APIs, json vs multipart APIs,
# fixing up a few server response quirks, and so forth. It is not meant 
# for use outside of Numerous and NumerousMetric.
#
class NumerousClientInternals



    #
    # @param apiKey [String] API authentication key
    # @param server [String] Optional (keyword arg). Server name.
    # @param throttle [Proc] Optional throttle policy
    # @param throttleData [Any] Optional data for throttle
    #
    # @!attribute agentString 
    #    @return [String] User agent string sent to the server.
    #
    # @!attribute [r] serverName
    #    @return [String] FQDN of the target NumerousApp server.
    #
    # @!attribute [r] debugLevel
    #    @return [Fixnum] Current debugging level; use debug() method to change.
    #
    def initialize(apiKey, server:'api.numerousapp.com',
                           throttle:nil, throttleData:nil)

        if not apiKey
            apiKey = Numerous.numerousKey()
        end

        @serverName = server
        @auth = { user: apiKey, password: "" }
        u = URI.parse("https://"+server) 
        @http = Net::HTTP.new(server, u.port)
        @http.use_ssl = true    # always required by NumerousApp

        @agentString = "NW-Ruby-NumerousClass/" + VersionString +
                       " (Ruby #{RUBY_VERSION}) NumerousAPI/v2"

        @filterDuplicates = true     # see discussion elsewhere

        # throttling.
        # The arbitraryMaximum is just that: under no circumstances will we retry
        # any particular request more than that. Tough noogies.
        #
        # the throttlePolicy "tuple" is:
        #     [ 0 ] - Proc
        #     [ 1 ] - specific data for Proc
        #     [ 2 ] - "up" tuple for chained policy
        #
        # and the default policy uses the "data" (40) as the voluntary backoff point
        #
        @arbitraryMaximumTries = 10
        @throttlePolicy = [ThrottleDefault, 40, nil]
        if throttle
            @throttlePolicy = [throttle, throttleData, @throttlePolicy]
        end

        @statistics = Hash.new { |h, k| h[k] = 0 }  # just useful debug/testing info
        @debugLevel = 0

    end
    attr_accessor :agentString
    attr_reader :serverName, :debugLevel
    attr_reader :statistics

    # Set the debug level
    #
    # @param [Fixnum] lvl 
    #   The desired debugging level. Greater than zero turns on debugging.
    # @return [Fixnum] the previous debugging level.
    def debug(lvl=1)
        prev = @debugLevel
        @debugLevel = lvl
        if @debugLevel > 0
            @http.set_debug_output $stderr
        else
            @http.set_debug_output nil
        end
        return prev
    end

    # XXX This is primarily for testing; control filtering of bogus duplicates
    #     If you are calling this you are probably doing something wrong.
    def setBogusDupFilter(f)
        prev = @filterDuplicates
        @filterDuplicates = f
        return prev
    end

    protected

    VersionString = '20150123.1x'

    MethMap = {
        GET: Net::HTTP::Get,
        POST: Net::HTTP::Post,
        PUT: Net::HTTP::Put,
        DELETE: Net::HTTP::Delete
    }
    private_constant :MethMap

    #
    # This gathers all the relevant information for a given API
    # and fills in the variable fields in URLs. It returns an "api context"
    # containing all the API-specific details needed by simpleAPI.
    #

    def makeAPIcontext(info, whichOp, kwargs={})
        rslt = {}
        rslt[:httpMethod] = whichOp

        # Build the substitutions from the defaults (if any) and non-nil kwargs.
        # Note: we are carefully making copies of the underlying dictionaries
        #       so you get your own private context returned to you
        substitutions = (info[:defaults]||{}).clone

        # copy any supplied non-nil kwargs (nil ones defer to defaults)
        kwargs.each { |k, v| if v then substitutions[k] = v end }

        # this is the stuff specific to the operation, e.g.,
        # the 'next' and 'list' fields in a chunked GET
        # There can also be additional path info.
        # process the paty appendage and copy everything else

        appendThis = ""
        path = info[:path]
        if info[whichOp]
            opi = info[whichOp]
            opi.each do |k, v|
                if k == :appendPath
                    appendThis = v
                elsif k == :path
                    path = v           # entire path overridden on this one
                else
                    rslt[k] = v
                end
            end
        end
        rslt[:basePath] = (path + appendThis) % substitutions
        return rslt
    end

    # compute a multipart boundary string; excessively paranoid
    BChars = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ".b
    BCharsLen = BChars.length

    def makeboundary(s)
        # Just try something fixed, and if it is no good extend it with random
        b = "RoLlErCaSeDbOuNdArY8675309".b
        while s.include? b
            b += BChars[rand(BCharsLen)]
        end
        return b
    end
    private :makeboundary


    # ALL api exchanges with the Numerous server go through here except
    # for getRedirect() which is a special case (hack) for photo URLs 
    #
    # Any single request/response uses this; chunked APIs use
    # the iterator classes (which in turn come back and use this repeatedly)
    #
    # The api parameter dictionary specifies:
    #
    #      basePath - the url we use (without the https://server.com part)
    #      httpMethod' - GET vs POST vs PUT etc
    #      successCodes' - what "OK" responses are (default 200)
    #
    # The api parameter may also carry additional info used elsewhere.
    # See, for example, how the iterators work on collections.
    #
    # Sometimes you may have started with a basePath but then been given
    # a "next" URL to use for subsequent requests. In those cases pass
    # in a url and it will take precedence over the basePath if any is present
    #
    # You can pass in a dictionary jdict which will be json-ified
    # and sent as Content-Type: application/json. Or you can pass in 
    # a multipart dictionary ... this is used for posting photos
    # You should not specify both jdict and multipart
    #
    def simpleAPI(api, jdict:nil, multipart:nil, url:nil)

        @statistics[:simpleAPI] += 1

        # take the base url if you didn't give us an override
        url ||= api[:basePath]

        if url[0] == '/'                  # i.e. not "http..."
            path = url
        else
            # technically we should be able to reassign @http bcs it could
            # change if server redirected us. But don't want to if no change.
            # need to add logic. XXX TODO XXX
            path = URI.parse(url).request_uri
        end
                
        rq = MethMap[api[:httpMethod]].new(path)
        rq.basic_auth(@auth[:user], @auth[:password])
        rq['user-agent'] = @agentString
        if jdict
            rq['content-type'] = 'application/json'
            rq.body = JSON.generate(jdict)
        elsif multipart
            # the data in :f is either a raw string OR a readable file
            begin
                f = multipart[:f]
                img = f.read
            rescue NoMethodError
                img = f
            end
            boundary = makeboundary(img)

            rq["content-type"] = "multipart/form-data; boundary=#{boundary}"
            d = []
            d << "--#{boundary}\r\n"
            d << "Content-Disposition: form-data;"
            d << ' name="image";'
            d << ' filename="image.img";'
            d << "\r\n"
            d << "Content-Transfer-Encoding: binary\r\n"
            d << "Content-Type: #{multipart[:mimeType]}\r\n"
            d << "\r\n"
            d << img + "\r\n"
            d << "--#{boundary}--\r\n"
            rq.body = d.join
        end

        if @debugLevel > 0
            puts "Path: #{path}\n"
            puts "Request headers:\n"
            rq.each do | k, v |
                puts "k: " + k + " :: " + v + "\n"
            end
        end

        resp = nil   # ick, is there a better way to get this out of the block?
        @arbitraryMaximumTries.times do |attempt|

            @statistics[:serverRequests] += 1
            resp = @http.request(rq)

            if @debugLevel > 0
                puts "Response headers:\n"
                resp.each do | k, v |
                    puts "k: " + k + " :: " + v + "\n"
                end
                puts "Code: " + resp.code + "/" + resp.code.class.to_s + "/\n"
            end

            # invoke the rate-limiting policy
            rateRemain = resp['x-rate-limit-remaining'].to_i
            rateReset = resp['x-rate-limit-reset'].to_i
            @statistics[:rateRemaining] = rateRemain
            @statistics[:rateReset] = rateReset

            tp = { :debug=> @debug,
                   :attempt=> attempt,
                   :rateRemaining=> rateRemain,
                   :rateReset=> rateReset,
                   :resultCode=> resp.code.to_i,
                   :resp=> resp,
                   :statistics=> @statistics,
                   :request=> { :httpMethod => api[:httpMethod], :url => path } }

            td = @throttlePolicy[1]
            up = @throttlePolicy[2]
            if not @throttlePolicy[0].call(self, tp, td, up)
                break
            end
        end

        goodCodes = api[:successCodes] || [200]

        responseCode = resp.code.to_i

        if goodCodes.include? responseCode
            begin
                rj = JSON.parse(resp.body)
            rescue TypeError, JSON::ParserError => e
                # On some requests that return "nothing" the server
                # returns {} ... on others it literally returns nothing.
                if (not resp.body) or resp.body.length == 0
                    rj = {} 
                else
                    # this isn't supposed to happen... server bug?
                    raise e
                end
            end
        else
            rj = { errorType: "HTTPError" }
            rj[:code] = responseCode
            rj[:reason] = resp.message
            rj[:value] = "Server returned an HTTP error: #{resp.message}"
            rj[:id] = url
            if responseCode == 401     # XXX is there an HTTP constant for this?
                emeth = NumerousAuthError
            else
                emeth = NumerousError
            end

            raise emeth.new(rj[:value],responseCode, rj)

        end

        return rj
    end

    # This is a special case ... a bit of a hack ... to determine
    # the underlying (redirected-to) URL for metric photos. The issue
    # is that sometimes we want to get at the no-auth-required actual
    # image URL (vs the metric API endpoint for getting a photo)
    #
    # This does that by (unfortunately) getting the actual image and
    # then using the r.url feature of requests library to get at what
    # the final (actual/real) URL was.

    def getRedirect(url)
        rq = MethMap[:GET].new(url)
        rq.basic_auth(@auth[:user], @auth[:password])
        rq['user-agent'] = @agentString

        resp = @http.request(rq)
        return resp.header['Location']
    end


    # generic iterator for chunked APIs
    def chunkedIterator(info, subs={}, block)
        # if you didn't specify a block... there's no point in doing anything
        if not block; return nil; end

        api = makeAPIcontext(info, :GET, subs)
        list = []
        nextURL = api[:basePath]
        firstTime = true

        # see discussion about duplicate filtering below
        if @filterDuplicates and api[:dupFilter]
            filterInfo = { prev: {}, current: {} }
        else
            filterInfo = nil
        end

        while nextURL
            # get a chunk from the server

            # XXX in the python version we caught various exceptions and
            #     attempted to translate them into something meaningful
            #     (e.g., if a metric got deleted while you were iterating)
            #     But here we're just letting the whatever-exceptions filter up
            v = simpleAPI(api, url:nextURL)

            # statistics, helpful for testing/debugging. Algorithmically
            # we don't really care about first time or not, just for the stats
            if firstTime
                @statistics[:firstChunks] += 1
                firstTime = false
            else
                @statistics[:additionalChunks] += 1
            end

            if filterInfo
                filterInfo[:prev] = filterInfo[:current]
                filterInfo[:current] = {}
            end
            
            list = v[api[:list]]
            nextURL = v[api[:next]]

            # hand them out
            if list             # can be nil for a variety of reasons
                list.each do |i| 

                    # A note about duplicate filtering
                    #
		    # There is a bug in the NumerousApp server which can
		    # cause collections to show duplicates of certain events
		    # (or interactions/stream items). Explaining the bug in great
		    # detail is beyond the scope here; suffice to say it only
		    # happens for events that were recorded nearly-simultaneously
		    # and happen to be getting reported right at a chunking boundary.
                    #
                    # So we are filtering them out here. For a more involved
                    # discussion of this, see the python implementation. This
                    # filtering "works" because it knows pragmatically how/where
                    # the bug can show up
                    #
                    # Turning off duplicate filtering is really meant only for testing.
                    #
                    # Not all API's require dupfiltering, hence the APIInfo test
                    #
                    if (not filterInfo)    # the easy case, not filtering
                        block.call i
                    else
                        thisId = i[api[:dupFilter]]
                        if filterInfo[:prev].include? thisId
                            @statistics[:duplicatesFiltered] += 1
                        else
                            filterInfo[:current][thisId] = 1
                            block.call i
                        end
                    end
                end
            end
        end
        return nil     # the subclasses return (should return) their own self
    end

    #
    # The default throttle policy.
    # Invoked after the response has been received and we are supposed to
    # return true to force a retry or false to accept this response as-is.
    #
    # The policy this implements:
    #    if the server failed with too busy, do backoff based on attempt number
    #
    #    if we are "getting close" to our limit, arbitrarily delay ourselves
    #
    #    if we truly got spanked with "Too Many Requests"
    #    then delay the amount of time the server told us to delay.
    #
    # The arguments supplied to us are:
    #     nr is the Numerous (handled explicitly so you can write external funcs too)
    #     tparams is a Hash containing:
    #         :attempt         : the attempt number. Zero on the very first try
    #         :rateRemaining   : X-Rate-Limit-Remaining reported by the server
    #         :rateReset       : time (in seconds) until fresh rate granted
    #         :resultCode      : HTTP code from the server (e.g., 409, 200, etc)
    #         :resp            : the full-on response object if you must have it
    #         :request         : information about the original request
    #         :statistics      : place to record stats (purely informational stats)
    #         :debug           : current debug level
    #
    #     td is the data you supplied as "throttleData" to the Numerous() constructor
    #     up is a tuple useful for calling the original system throttle policy:
    #          up[0] is the function pointer
    #          up[1] is the td for *that* function
    #          up[2] is the "up" for calling *that* function
    #       ... so after you do your own thing if you then want to defer to the
    #           built-in throttle policy you can
    #                     return send(up[0], nr, tparams, up[1], up[2])
    #
    # It's really (really really) important to understand the return value and
    # the fact that we are invoked AFTER each request:
    #    false : simply means "don't do more retries". It does not imply anything
    #            about the success or failure of the request; it simply means that
    #            this most recent request (response) is the one to "take" as
    #            the final answer
    #
    #    true  : means that the response is, indeed, to be interpreted as some
    #            sort of rate-limit failure and should be discarded. The original
    #            request will be sent again. Obviously it's a very bad idea to
    #            return true in cases where the server might have done some
    #            anything non-idempotent. We assume that a 429 ("Too Many") or
    #            a 500 ("Too Busy") response from the server means the server didn't
    #            actually do anything (so a retry, timed appropriately, is ok)
    #
    # All of this seems overly general for what basically amounts to "sleep sometimes"
    #

    ThrottleDefault = Proc.new do |nr, tparams, td, up|
        rateleft = tparams[:rateRemaining]
        attempt = tparams[:attempt]    # note: is zero on very first try
        stats = tparams[:statistics]

        if attempt > 0
            stats[:throttleMultipleAttempts] += 1
        end

        backarray = [ 2, 5, 15, 30, 60 ]
        if attempt < backarray.length
            backoff = backarray[attempt]
        else
            stats[:throttleMaxed] += 1
            next false               # too many tries
        end

        # if the server actually has failed with too busy, sleep and try again
        if tparams[:resultCode] == 500
            stats[:throttle500] += 1
            sleep(backoff)
            next true
        end

        # if we weren't told to back off, no need to retry
        if tparams[:resultCode] != 429
            # but if we are closing in on the limit then slow ourselves down
            # note that some errors don't communicate rateleft so we have to
            # check for that as well (will be -1 here if wasn't sent to us)
            #
            # at constructor time our "throttle data" (td) was set up as the
            # voluntary arbitrary limit
            if rateleft >= 0 and rateleft < td
                stats[:throttleVoluntaryBackoff] += 1
                # arbitrary .. 1 second if more than half left, 3 seconds if less
                if (rateleft*2) > td
                    sleep(1)
                else
                    sleep(3)
                end
            end
            next false               # no retry
        end

        # decide how long to delay ... we just wait for as long as the
        # server told us to (plus "backoff" seconds slop to really be sure we
        # aren't back too soon)
        stats[:throttle429] += 1
        sleep(tparams[:rateReset] + backoff)
        next true
    end
    private_constant :ThrottleDefault

end

#
# == Numerous
#
# Primary class for accessing the numerousapp server.
#
# === Constructor
#
#   You must supply an API key:
#      nr = Numerous.new('nmrs_3xblahblah')
#
#   You can optionally override the built-in server name
#      nr = Numerous.new('nmrs_3xblahblah', server:'test.server.com')
#
# === Server return values
#
# For most operations the NumerousApp server returns a JSON representation
# of the current or modified object state. This is converted to a ruby
# Hash of <string-key, value> pairs and returned from the appropriate methods.
#
# For some operations the server returns only a success/failure code.
# In those cases there is no useful return value from the method; the 
# method succeeds or else raises an exception (containing the failure code).
#
# For the collection operations the server returns a JSON array of dictionary
# representations, possibly "chunked" into multiple request/response operations.
# The enumerator methods (e.g., "metrics") implement lazy-fetch and hide 
# the details of the chunking from you. They simply yield each individual
# item (string-key Hash) to your block.
#
# === Exception handling
#
# Almost every API that interacts with the server will potentially 
# raise a {NumerousError} (or subclass thereof). This is not noted specifically
# in the doc for each method unless it might be considered a "surprise"
# (e.g., ping always returns true else raises an exception). Rescue as needed.
#

class Numerous  < NumerousClientInternals

    # path info for the server-level APIs: create a metric, get user info, etc
    APIInfo = {        
      # POST to this to create a metric
      create: { 
          path: '/v1/metrics',
          POST: { successCodes: [ 201 ] }
      },

      # GET a users metric collection
      metricsCollection: { 
          path: '/v2/users/%{userId}/metrics',
          defaults: { userId: 'me' },
          GET: { next: 'nextURL', list: 'metrics' }
      },

      # subscriptions at the user level
      subscriptions: {
          path: '/v2/users/%{userId}/subscriptions',
          defaults: { userId: 'me' },
          GET: { next: 'nextURL', list: 'subscriptions' }
      },

      # user info
      user: {
          path: '/v1/users/%{userId}',
          defaults: { userId: 'me' },
          photo: { appendPath: '/photo', httpMethod: :POST, successCodes: [201] }
      },

      # the most-popular metrics list
      popular: {
          path: '/v1/metrics/popular?count=%{count}',
          defaults: { count: 10 }
          # no entry needed for GET because no special codes etc
      }
    }
    private_constant :APIInfo

    #
    # Obtain user attributes
    #
    # @param [String] userId
    #    optional - numeric id (represented as a string) of user
    # @return [Hash] user representation (string-key hash)
    #
    def user(userId:nil)
        api = makeAPIcontext(APIInfo[:user], :GET, {userId: userId})
        return simpleAPI(api)
    end

    #
    # Set the user's photo
    #
    # @note the server enforces an undocumented maximum data size.
    #   Exceeding the limit will raise a NumerousError (HTTP 413 / Too Large)
    # @param [String,#read] imageDataOrReadable
    #   Either a binary-data string of the image data or an object
    #   with a "read" method. The entire data stream will be read.
    # @param [String] mimeType
    #   Optional(keyword arg). Mime type.
    # @return [Hash] updated user representation (string-key hash)
    #
    def userPhoto(imageDataOrReadable, mimeType:'image/jpeg')
        api = makeAPIcontext(APIInfo[:user], :photo)
        mpart = { :f => imageDataOrReadable, :mimeType => mimeType }
        return simpleAPI(api, multipart: mpart)
    end

    #
    # All metrics for the given user (default is your own)
    #
    # @param [String] userId 
    #    optional - numeric id (represented as a string) of user
    # @yield [m] metrics
    # @yieldparam m [Hash] String-key representation of one metric
    # @return self
    #
    def metrics(userId:nil, &block)
        chunkedIterator(APIInfo[:metricsCollection], { userId: userId }, block)
        return self
    end

    #
    # All subscriptions for the given user (default is your own)
    #
    # @param [String] userId 
    #    optional - numeric id (represented as a string) of user
    # @yield [s] subscriptions
    # @yieldparam s [Hash] String-key representation of one subscription
    # @return self
    #
    def subscriptions(userId:nil, &block)
        chunkedIterator(APIInfo[:subscriptions], { userId: userId }, block)
        return self
    end    


    #
    # Obtain array of the "most popular" metrics.
    #
    # @note this returns the array; it is not an Enumerator
    #
    # @param [Fixnum] count
    #    optional - number of metrics to return
    # @return [Array] Array of hashes (metric string dicts). Each element 
    #    represents a particular popular metric.
    #
    def mostPopular(count:nil)
        api = makeAPIcontext(APIInfo[:popular], :GET, {count: count})
        return simpleAPI(api)
    end

    #
    # Verify connectivity to the server
    #
    # @return [true] Always returns true connectivity if ok. 
    #     Raises an exception otherwise.
    # @raise [NumerousAuthError] Your credentials are no good.
    # @raise [NumerousError] Other server (or network) errors.
    #
    def ping
        ignored = user()
        return true      # errors raise exceptions
    end

    #
    # Create a brand new metric on the server.
    #
    # @param label [String] Required. Label for the metric.
    # @param value [Fixnum,Float] Optional (keyword arg). Initial value.
    # @param attrs [Hash] Optional (keyword arg). Initial attributes.
    # @return [NumerousMetric] 
    #
    # @example Create a metric with label 'bozo' and set value to 17
    #  nr = Numerous.new('nmrs_3vblahblah') 
    #  m = nr.createMetric('bozo')
    #  m.write(17)
    #
    # @example Same example using the value keyword argument.
    #  m = nr.createMetric('bozo', value:17)
    #
    # @example Same example but also setting the description attribute
    #  m = nr.createMetric('bozo', value:17, attrs:{"description" => "a clown"})
    #
    def createMetric(label, value:nil, attrs:{})

        api = makeAPIcontext(APIInfo[:create], :POST)

        j = attrs.clone
        j['label'] = label
        if value
            j['value'] = value
        end
        v = simpleAPI(api, jdict:j)
        return metric(v['id'])
    end

    #
    # Instantiate a metric object to access a metric from the server.
    # @return [NumerousMetric] metric object
    # @param id [String] 
    #     Required. Metric ID (something like '2319923751024'). NOTE: If id
    #     is bogus this will still "work" but (of course) errors will be
    #     raised when you do something with the metric.
    # @see #createMetric createMetric
    # @see NumerousMetric#validate validate
    #
    def metric(id)
        return NumerousMetric.new(id, self)
    end


    #
    # Version of metric() that accepts a name (label)
    # instead of an ID, and can even process it as a regexp.
    #
    # @param [String] labelspec The name (label) or regexp
    # @param [String] matchType 'FIRST' or 'BEST' or 'ONE' or 'STRING' (not regexp)
    # @param [Numerous] nr 
    #    The {Numerous} object that will be used to access this metric.
    def metricByLabel(labelspec, matchType:'FIRST')
        def raiseConflict(s1,s2)
            raise NumerousMetricConflictError.new("Multiple matches", 409, [s1, s2])
        end

        bestMatch = [ nil, 0 ]

        if not matchType
            matchType = 'FIRST'
        end
        if not ['FIRST', 'BEST', 'ONE', 'STRING'].include?(matchType)
            raise ArgumentError
        end

        self.metrics do |m|
            if matchType == 'STRING'        # exact full match required
                if m['label'] == labelspec
                    if bestMatch[0]
                        raiseConflict(bestMatch[0]['label'], m['label'])
                    end
                    bestMatch = [ m, 1 ]   # the length is irrelevant with STRING
                end
            else
                mm = labelspec.match(m['label'])
                if mm
                    if matchType == 'FIRST'
                        return self.metric(m['id'])
                    elsif (matchType == 'ONE') and (bestMatch[1] > 0)
                        raiseConflict(bestMatch[0]['label'], m['label'])
                    end
                    if mm[0].length > bestMatch[1]
                        bestMatch = [ m, mm[0].length ]
                    end
                end
            end
        end
        rv = nil
        if bestMatch[0]
            rv = self.metric(bestMatch[0]['id'])
        end
    end


    #
    # I found this a good way to handle supplying the API key so it's here
    # as a class method you may find useful. What this function does is
    # return you an API Key from a supplied string or "readable" object:
    #
    #          a "naked" API key (in which case this function is a no-op)
    #          @-        :: meaning "get it from stdin"
    #          @blah     :: meaning "get it from the file "blah"
    #          /blah     :: get it from file /blah
    #          .blah     :: get it from file .blah (could be ../ etc)
    #        /readable/  :: if it has a .read method, get it that way
    #          None      :: get it from environment variable NUMEROUSAPIKEY
    #
    # Where the "it" that is being gotten from any of those sources can be:
    #    a "naked" API key
    #    a JSON object, from which the credsAPIKey will be used to get the key
    #
    # Arguably this doesn't belong here, but it's helpful. Purists are free to
    # ignore it or delete from their own tree :)
    #

    def self.numerousKey(s:nil, credsAPIKey:'NumerousAPIKey')

    	if not s
    	    # try to get from environment
    	    s = ENV['NUMEROUSAPIKEY']
    	    if not s
    	        return nil
            end
        end

    	closeThis = nil

    	if s == "@-"             # creds coming from stdin
    	    s = STDIN

    	# see if they are in a file
    	else
    	    begin
    	        if s.length() > 0         # is it a string or a file object?
    	            # it's stringy - if it looks like a file open it or fail
    	            begin
    	        	if s.length() > 1 and s[0] == '@'
    	        	    s = open(s[1..-1])
    	        	    closeThis = s
    	        	elsif s[0] == '/' or s[0] == '.'
    	        	    s = open(s)
    	        	    closeThis = s
                        end
    	            rescue
    	        	return nil
                    end
                end
    	    rescue NoMethodError     # it wasn't stringy, presumably it's a "readable"
    	    end
        end

    	# well, see if whatever it is, is readable, and go with that if it is
    	begin
    	    v = s.read()
    	    if closeThis
    	        closeThis.close()
            end
    	    s = v
    	rescue NoMethodError
    	end

    	# at this point s is either a JSON or a naked cred (or bogus)
    	begin
    	    j = JSON.parse(s)
    	rescue TypeError, JSON::ParserError
    	    j = {}
        end


    	#
    	# This is kind of a hack and might hide some errors on your part
    	#
    	if not j.include? credsAPIKey  # this is how the naked case happens
    	    # replace() bcs there might be a trailing newline on naked creds
    	    # (usually happens with a file or stdin)
    	    j[credsAPIKey] = s.sub("\n",'')
        end 

    	return j[credsAPIKey]
    end

end

#
# == NumerousMetric
#
# Class for individual Numerous metrics
#
# You instantiate these hanging off of a particular Numerous connection:
#    nr = Numerous.new('nmrs_3xblahblah')
#    m = nr.metric('754623094815712984')
#
# For most operations the NumerousApp server returns a JSON representation
# of the current or modified object state. This is converted to a ruby
# Hash of <string-key, value> pairs and returned from the appropriate methods.
# A few of the methods return only one item from the Hash (e.g., read
# will return just the naked number unless you ask it for the entire dictionary)
#
# For some operations the server returns only a success/failure code.
# In those cases there is no useful return value from the method; the 
# method succeeds or else raises an exception (containing the failure code).
#
# For the collection operations the server returns a JSON array of dictionary
# representations, possibly "chunked" into multiple request/response operations.
# The enumerator methods (e.g., "events") implement lazy-fetch and hide 
# the details of the chunking from you. They simply yield each individual
# item (string-key Hash) to your block.
#

class NumerousMetric < NumerousClientInternals
    #
    # @!attribute [r] id
    # @return [String] The metric ID string.
    #

    # Constructor for a NumerousMetric
    #
    # @param [String] id The metric ID string.
    # @param [Numerous] nr 
    #    The {Numerous} object that will be used to access this metric.
    #
    # "id" should normally be the naked metric id (as a string).
    #
    # It can also be a nmrs: URL, e.g.:
    #     nmrs://metric/2733614827342384
    #
    # Or a 'self' link from the API:
    #     https://api.numerousapp.com/metrics/2733614827342384
    #
    # in either case we get the ID in the obvious syntactic way.
    #
    # It can also be a metric's web link, e.g.:
    #     http://n.numerousapp.com/m/1x8ba7fjg72d
    #
    # in which case we "just know" that the tail is a base36
    # encoding of the ID.
    #
    # The decoding logic here makes the specific assumption that
    # the presence of a '/' indicates a non-naked metric ID. This
    # seems a reasonable assumption given that IDs have to go into URLs
    #

    def initialize(id, nr)
        begin
            if id.include? '/'
                fields = id.split('/')
                if fields[-2] == "m"
                    id = fields[-1].to_i(36)
                else
                    id = fields[-1]
                end
            end
        rescue NoMethodError
            id = id.to_s
        end

        @id = id
        @nr = nr
    end
    attr_reader :id


    #
    # Obtain the {Numerous} server object associated with a metric.
    # @return [Numerous]
    #
    def getServer()
        return @nr
    end

    APIInfo = {                             
      # read/update/delete a metric
      metric: {
        path: '/v1/metrics/%{metricId}' ,
        # no entries needed for GET/PUT because no special codes etc
        DELETE: {
            successCodes: [ 204 ]
        }
      },

      # you can GET or POST the events collection
      events: {
        path: '/v1/metrics/%{metricId}/events',
        GET: {
            next: 'nextURL',
            list: 'events',
            dupFilter: 'id'
        },
        POST: {
            successCodes: [ 201 ]
        }
      },
      # and you can GET or DELETE an individual event
      # (no entry made for GET because all standard parameters on that one)
      event: {
        path: '/v1/metrics/%{metricId}/events/%{eventID}',
        DELETE: {
            successCodes: [ 204 ]     # No Content is the expected return
        }
      },

      # GET the stream collection
      stream: {
        path: '/v2/metrics/%{metricId}/stream',
        GET: {
            next: 'next',
            list: 'items',
            dupFilter: 'id'
        }
      },

      # you can GET or POST the interactions collection
      interactions: {
        path: '/v2/metrics/%{metricId}/interactions',
        GET: {
            next: 'nextURL',
            list: 'interactions',
            dupFilter: 'id'
        },
        POST: {
            successCodes: [ 201 ]

        }
      },

      # and you can GET or DELETE an individual interaction
      interaction: {
        path: '/v2/metrics/%{metricId}/interactions/%{item}',
        DELETE: {
            successCodes: [ 204 ]     # No Content is the expected return
        }
      },

      # subscriptions collection on a metric
      subscriptions: {
        path: '/v2/metrics/%{metricId}/subscriptions',
        GET: {
            next: 'nextURL',
            list: 'subscriptions'
        }
      },

      # subscriptions on a particular metric
      subscription: {
        path: '/v1/metrics/%{metricId}/subscriptions/%{userId}',
        defaults: {
            userId: 'me'           # default userId for yourself ("me")
        },
        PUT: {
            successCodes: [ 200, 201 ]
        }
      },

      photo: {
        path: '/v1/metrics/%{metricId}/photo',
        POST: {
            successCodes: [ 201 ]
        },
        DELETE: {
            successCodes: [ 204 ]
        }
      }

    }
    private_constant :APIInfo

    # small wrapper to always supply the metricId substitution
    def getAPI(a, mx, args={})
        return @nr.makeAPIcontext(APIInfo[a], mx, args.merge({ metricId: @id }))
    end
    private :getAPI

    #
    # Read the current value of a metric
    # @param [Boolean] dictionary
    #    If true the entire metric will be returned as a string-key Hash;
    #    else (false/default) a bare number (Fixnum or Float) is returned.
    # @return [Fixnum|Float] if dictionary is false (or defaulted).
    # @return [Hash] if dictionary is true.
    #
    def read(dictionary: false)
        api = getAPI(:metric, :GET)
        v = @nr.simpleAPI(api)
        return (if dictionary then v else v['value'] end)
    end

    # "Validate" a metric object.
    # There really is no way to do this in any way that carries much weight.
    # However, if a user gives you a metricId and you'd like to know if
    # that actually IS a metricId, this might be useful. 
    #
    # @example
    #    someId = ... get a metric ID from someone ...
    #    m = nr.metric(someId)
    #    if not m.validate
    #        puts "#{someId} is not a valid metric"
    #    end
    #
    # Realize that even a valid metric can be deleted asynchronously
    # and thus become invalid after being validated by this method.
    #
    # Reads the metric, catches the specific exceptions that occur for 
    # invalid metric IDs, and returns True/False. Other exceptions mean
    # something else went awry (server down, bad authentication, etc).
    # @return [Boolean] validity of the metric
    def validate
        begin
            ignored = read()
            return true
        rescue NumerousError => e
            # bad request (400) is a completely bogus metric ID whereas 
            # not found (404) is a well-formed ID that simply does not exist
            if e.code == 400 or e.code == 404
                return false
            else        # anything else is a "real" error; figure out yourself
                raise e
            end
        end
        return false # this never happens
    end


    #
    # So I had a really nifty define_method hack here to generate
    # these methods that follow a simple pattern. Then trying to figure out
    # how to YARD document them was daunting. If it's easy someone needs to
    # show me (I get the impression it's possible with some run time magic
    # but it's just too hard to figure out for now). So, here we go instead...
    #

    # Enumerate the events of a metric. Events are value updates.
    #
    # @yield [e] events
    # @yieldparam e [Hash] String-key representation of one metric.
    # @return [NumerousMetric] self
    def events(&block)
        @nr.chunkedIterator(APIInfo[:events], {metricId:@id}, block)
        return self
    end

    # Enumerate the stream of a metric. The stream is events and
    # interactions merged together into a time-ordered stream.
    #
    # @yield [s] stream
    # @yieldparam s [Hash] String-key representation of one stream item.
    # @return [NumerousMetric] self
    def stream(&block)
        @nr.chunkedIterator(APIInfo[:stream], {metricId:@id}, block)
        return self
    end

    # Enumerate the interactions (like/comment/error) of a metric. 
    #
    # @yield [i] interactions
    # @yieldparam i [Hash] String-key representation of one interaction.
    # @return [NumerousMetric] self
    def interactions(&block)
        @nr.chunkedIterator(APIInfo[:interactions], {metricId:@id}, block)
        return self
    end

    # Enumerate the subscriptions of a metric.
    #
    # @yield [s] subscriptions
    # @yieldparam s [Hash] String-key representation of one subscription.
    # @return [NumerousMetric] self
    def subscriptions(&block)
        @nr.chunkedIterator(APIInfo[:subscriptions], {metricId:@id}, block)
        return self
    end


    # Obtain a specific metric event from the server
    #
    # @param [String] eId The specific event ID
    # @return [Hash] The string-key hash of the event
    # @raise [NumerousError] Not found (.code will be 404)
    #
    def event(eId)
        api = getAPI(:event, :GET, {eventID:eId})
        return @nr.simpleAPI(api)
    end

    # Obtain a specific metric interaction from the server
    #
    # @param [String] iId The specific interaction ID
    # @return [Hash] The string-key hash of the interaction
    # @raise [NumerousError] Not found (.code will be 404)
    #
    def interaction(iId)
        api = getAPI(:interaction, :GET, {item:iId})
        return @nr.simpleAPI(api)
    end

    # Obtain your subscription parameters on a given metric
    #
    # Note that normal users cannot see other user's subscriptions.
    # Thus the "userId" parameter is somewhat pointless; you can only 
    # ever see your own.
    # @param [String] userId
    # @return [Hash] your subscription attributes
    def subscription(userId=nil)
        api = getAPI(:subscription, :GET, {userId: userId})
        return @nr.simpleAPI(api)
    end

    # Subscribe to a metric. 
    #
    # See the NumerousApp API docs for what should be
    # in the dict. This function will fetch the current parameters
    # and update them with the ones you supply (because the server
    # does not like you supplying an incomplete dictionary here).
    # You can prevent the fetch/merge via overwriteAll:true
    #
    # Normal users cannot set other user's subscriptions.
    # @param [Hash] dict
    #   string-key hash of subscription parameters
    # @param [String] userId
    #   Optional (keyword arg). UserId to subscribe.
    # @param [Boolean] overwriteAll
    #   Optional (keyword arg). If true, dict is sent without reading
    #   the current parameters and merging them.
    def subscribe(dict, userId:nil, overwriteAll:false)
        if overwriteAll
            params = {}
        else
            params = subscription(userId)
        end

        dict.each { |k, v| params[k] = v }

        api = getAPI(:subscription, :PUT, { userId: userId })
        return @nr.simpleAPI(api, jdict:params)
    end

    # Write a value to a metric.
    #
    # @param [Fixnum|Float] newval Required. Value to be written.
    #
    # @param [Boolean] onlyIf 
    #   Optional (keyword arg). Only creates an event at the server
    #   if the newval is different from the current value. Raises
    #   NumerousMetricConflictError if there is no change in value.
    #
    # @param [Boolean] add
    #   Optional (keyword arg). Sends the "action: ADD"	attribute which
    #   causes the server to ADD newval to the current metric value.
    #   Note that this IS atomic at the server. Two clients doing
    #   simultaneous ADD operations will get the correct (serialized) result.
    # @param [Boolean] dictionary
    #   If true the entire metric will be returned as a string-key Hash;
    #   else (false/default) the bare number (Fixnum or Float) for the
    #   resulting new value is returned.
    # @return [Fixnum|Float] if dictionary is false (or defaulted). The new
    #   value of the metric is returned as a bare number.
    # @return [Hash] if dictionary is true the entire new metric is returned.
    #
    def write(newval, onlyIf:false, add:false, dictionary:false)
        j = { 'value' => newval }
        if onlyIf
            j['onlyIfChanged'] = true
        end
        if add
            j['action'] = 'ADD'
        end

        api = getAPI(:events, :POST)
        begin
            v = @nr.simpleAPI(api, jdict:j)

        rescue NumerousError => e
            # if onlyIf was specified and the error is "conflict"
            # (meaning: no change), raise ConflictError specifically
            if onlyIf and e.code == 409
                raise NumerousMetricConflictError.new("No Change", 0, e.details)
            else
                raise e        # never mind, plain NumerousError is fine
            end
        end

        return (if dictionary then v else v['value'] end)
    end

    # Update parameters of a metric (such as "description", "label", etc).
    # Not to be used (won't work) to update a metric's value.
    #
    # @param [Hash] dict
    #   string-key Hash of the parameters to be updated.
    # @param [Boolean] overwriteAll
    #   Optional (keyword arg). If false (default), this method will first
    #   read the current metric parameters from the server and merge them
    #   with your updates before writing them back. If true your supplied
    #   dictionary will become the entirety of the metric's parameters, and
    #   any parameters you did not include in your dictionary will revert to
    #   their default values. 
    # @return [Hash] string-key Hash of the new metric parameters.
    #
    def update(dict, overwriteAll:false)
        newParams = (if overwriteAll then {} else read(dictionary:true) end)
        dict.each { |k, v| newParams[k] = v }

        api = getAPI(:metric, :PUT)
        return @nr.simpleAPI(api, jdict:newParams)
    end

    # common code for writing interactions
    def writeInteraction(dict)
        api = getAPI(:interactions, :POST)
        v = @nr.simpleAPI(api, jdict:dict)
        return v['id']
    end
    private :writeInteraction

    #
    # "Like" a metric
    #
    # @return [String] The ID of the resulting interaction (the "like")
    #
    def like
        # a like is written as an interaction
        return writeInteraction({ 'kind' => 'like' })
    end

    #
    # Write an error to a metric
    #
    # @param [String] errText The error text to write.
    # @return [String] The ID of the resulting interaction (the "error")
    #
    def sendError(errText)
        # an error is written as an interaction thusly:
        # (commentBody is used for the error text)
        j = { 'kind' => 'error' , 'commentBody' => errText }
        return writeInteraction(j)
    end

    #
    # Comment on a metric
    #
    # @param [String] ctext The comment text to write.
    # @return [String] The ID of the resulting interaction (the "comment")
    #
    def comment(ctext)
        j = { 'kind' => 'comment' , 'commentBody' => ctext }
        return writeInteraction(j)
    end

    # set the background image for a metric
    # @note the server enforces an undocumented maximum data size.
    #   Exceeding the limit will raise a NumerousError (HTTP 413 / Too Large)
    # @param [String,#read] imageDataOrReadable
    #   Either a binary-data string of the image data or an object
    #   with a "read" method. The entire data stream will be read.
    # @param [String] mimeType
    #   Optional(keyword arg). Mime type.
    # @return [Hash] updated metric representation (string-key hash)
    #
    def photo(imageDataOrReadable, mimeType:'image/jpeg')
        api = getAPI(:photo, :POST)
        mpart = { :f => imageDataOrReadable, :mimeType => mimeType }
        return @nr.simpleAPI(api, multipart: mpart)
    end

    # Delete the metric's photo
    # @note Deleting a photo that isn't there will raise a NumerousError
    #   but the error code will be 200/OK.
    # @return [nil]
    def photoDelete
        api = getAPI(:photo, :DELETE)
        v = @nr.simpleAPI(api)
        return nil
    end

    # Delete an event (a value update)
    # @note Deleting an event that isn't there will raise a NumerousError
    #   but the error code will be 200/OK.
    # @param [String] evID ID (string) of the event to be deleted.
    # @return [nil]
    def eventDelete(evID)
        api = getAPI(:event, :DELETE, {eventID:evID})
        v = @nr.simpleAPI(api)
        return nil
    end

    # Delete an interaction (a like/comment/error)
    # @note Deleting an interaction that isn't there will raise a NumerousError
    #   but the error code will be 200/OK.
    # @param [String] interID ID (string) of the interaction to be deleted.
    # @return [nil]
    def interactionDelete(interID)
        api = getAPI(:interaction, :DELETE, {item:interID})
        v = @nr.simpleAPI(api)
        return nil
    end

    # Obtain the underlying photoURL for a metric.
    #
    # The photoURL is available in the metrics parameters so you could 
    # just read(dictionary:true) and obtain it that way. However this goes
    # one step further ... the URL in the metric itself still requires 
    # authentication to fetch (it then redirects to the "real" underlying
    # static photo URL). This function goes one level deeper and
    # returns you an actual, publicly-fetchable, photo URL.
    #
    # @note Fetches (and discards) the entire underlying photo,
    #   because that was the easiest way to find the target URL using net/http
    #
    # @return [String, nil] URL. If there is no photo returns nil.
    #
    def photoURL
        v = read(dictionary:true)
        begin
            phurl = v.fetch('photoURL')
            return @nr.getRedirect(phurl)
        rescue KeyError
            return nil
        end
        # never reached
        return nil
    end

    # some convenience functions ... but all these do is query the
    # server (read the metric) and return the given field... you could
    # do the very same yourself. So I only implemented a few useful ones.

    # Get the label of a metric.
    #
    # @return [String] The metric label.
    def label
        v = read(dictionary:true)
        return v['label']
    end

    # Get the URL for the metric's web representation
    #
    # @return [String] URL.
    def webURL
        v = read(dictionary:true)
        return v['links']['web']
    end

    # Delete a metric (permanently). Be 100% you want this, because there
    # is absolutely no undo.
    #
    # @return [nil]
    def crushKillDestroy
        api = getAPI(:metric, :DELETE)
        v = @nr.simpleAPI(api)
        return nil
    end

end

