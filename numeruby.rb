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

class NumerousError < StandardError
    def initialize(msg, code, details)
        super(msg)
        @code = code
        @details = details
    end

    attr_accessor :code, :details
end

class NumerousAuthError < NumerousError
end

class NumerousMetricConflictError < NumerousError
end

#
# This class is not meant for public consumption but it subclassed
# into Numerous and NumerousMetric. It encapsultes all the details
# of talking to the numerous server, dealing with chunked APIs, etc.
#
class NumerousClientInternals
    def initialize(apiKey, server:'api.numerousapp.com')
        @serverName = server
        @auth = { user: apiKey, password: "" }
        u = URI.parse("https://"+server) 
        @http = Net::HTTP.new(server, u.port)
        @http.use_ssl = true    # always required by NumerousApp

        @agentString = "NW-Ruby-NumerousClass/" + VersionString +
                       " (Ruby #{RUBY_VERSION}) NumerousAPI/v2"

        @debugLevel = 0
    end

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

    protected

    VersionString = '20141216.x'    

    MethMap = {
        GET: Net::HTTP::Get,
        POST: Net::HTTP::Post,
        PUT: Net::HTTP::Put,
        DELETE: Net::HTTP::Delete
    }


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
        substitutions = {}
        (info[:defaults]||{}).each { |k, v| substitutions[k] = v }

        # copy any supplied non-nil kwargs (nil ones defer to defaults)
        kwargs.each { |k, v| if v then substitutions[k] = v end }

        # this is the stuff specific to the operation, e.g.,
        # the 'next' and 'list' fields in a chunked GET
        # There can also be additional path info.
        # process the paty appendage and copy everything else

        appendThis = ""
        path = info[:path]
# XXX come back and see if whichOp is ever really a string
        if info[whichOp.to_sym]
            opi = info[whichOp.to_sym]
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
        end

        if @debugLevel > 0
            puts "Path: #{path}\n"
            puts "Request headers:\n"
            rq.each do | k, v |
                puts "k: " + k + " :: " + v + "\n"
            end
        end

        resp = @http.request(rq)
       
        if @debugLevel > 0
            puts "Response headers:\n"
            resp.each do | k, v |
                puts "k: " + k + " :: " + v + "\n"
            end
            puts "Code: " + resp.code + "/" + resp.code.class.to_s + "/\n"
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

    # generic iterator for chunked APIs
    def chunkedIterator(info, subs={}, block)
        api = makeAPIcontext(info, :GET, subs)
        list = []
        nextURL = api[:basePath]

        while nextURL
            # get a chunk from the server
            # XXX in the python version we caught various exceptions and
            #     attempted to translate them into something meaningful
            #     (e.g., if a metric got deleted while you were iterating)
            #     But here we're just letting the whatever-exceptions filter up
            v = simpleAPI(api, url:nextURL)


            list = v[api[:list]]
            nextURL = v[api[:next]]

            # hand them out
            if list             # can be nil for a variety of reasons
                list.each { |i| block.call i }
            end
        end
    end

end


class Numerous  < NumerousClientInternals

    # path info for the server-level APIs: create a metric, get user info, etc

    APIInfo = {
      # POST to this to create a metric
      create: {
        path: '/v1/metrics',
        POST: {
          successCodes: [ 201 ]
        }
      },

      # GET a users metric collection
      metricsCollection: {
        path: '/v2/users/%{userId}/metrics',
        defaults: { 
            userId: 'me'            # default userId meaning "myself"
        },
        GET: {
            next: 'nextURL',
            list: 'metrics'
        }
      },

      # subscriptions at the user level
      subscriptions: {
        path: '/v2/users/%{userId}/subscriptions',
        defaults: { 
            userId: 'me'            # default userId meaning "myself"
        },
        GET: {
            next: 'nextURL',
            list: 'subscriptions'
        }
      },

      # user info
      user: {
        path: '/v1/users/%{userId}',
        defaults: { 
            userId: 'me'            # default userId meaning "myself"
        },
        photo: {
            appendPath: '/photo',
            httpMethod: :POST,
            successCodes: [ 201 ]
        }
      },

      # the most-popular metrics list
      popular: {
        path: '/v1/metrics/popular?count=%{count}',
        defaults: { 
            count: 10
        }
        # no entry needed for GET because no special codes etc
      }
    }

    # iterator for the entire metrics collection. 
    # By default gets your own metrics list but you can specify other users
    def metrics(userId:nil, &block)
        chunkedIterator(APIInfo[:metricsCollection], { userId: userId }, block)
    end

    # return User info (Default is yourself)
    def user(userId:nil)
        api = makeAPIcontext(APIInfo[:user], :GET, {userId: userId})
        return simpleAPI(api)
    end

    def userPhoto()
    end

    def subscriptions(userId:nil, &block)
        chunkedIterator(APIInfo[:subscriptions], { userId: userId }, block)
    end    

    def mostPopular(count:nil)
        api = makeAPIcontext(APIInfo[:popular], :GET, {count: count})
        return simpleAPI(api)
    end

    # test/verify connectivity to the server
    def ping
        ignored = user()
        return true      # errors throw exceptions
    end

    def createMetric(label, value:nil, attrs:{})
        api = makeAPIcontext(APIInfo[:create], :POST)
        puts api

        j = {}
        attrs.each { |k, v| j[k] = v }
        j['label'] = label
        if value
            j['value'] = value
        end
        v = simpleAPI(api, jdict:j)
        return metric(v['id'])
    end

    # instantiate a metric object to access a numerous metric
    #   -- this is NOT creating a metric on the server; this is how you
    #      access a metric that already exists
    def metric(id)
        return NumerousMetric.new(id, self)
    end

end


class NumerousMetric < NumerousClientInternals
    def initialize(id, nr)
        @id = id
        @nr = nr
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

      # you can GET, POST, or DELETE events
      events: {
        path: '/v1/metrics/%{metricId}/events',
        GET: {
            next: 'nextURL',
            list: 'events'
        },
        POST: {
            successCodes: [ 201 ]
        },
        DELETE: {
            appendPath: '/%{eventID}',
            successCodes: [ 204 ]     # No Content is the expected return
        }
      },

      # GET the stream collection
      stream: {
        path: '/v2/metrics/%{metricId}/stream',
        GET: {
            next: 'next',
            list: 'items'
        }
      },

      # GET or POST or DELETE interactions
      interactions: {
        path: '/v2/metrics/%{metricId}/interactions',
        GET: {
            next: 'nextURL',
            list: 'interactions'
        },
        POST: {
            successCodes: [ 201 ]
        },
        DELETE: {
            appendPath: '/%{item}',
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

    # small wrapper to always supply the metricId substitution
    def getAPI(a, mx, args={})
        return @nr.makeAPIcontext(APIInfo[a], mx, args.merge({ metricId: @id }))
    end
    private :getAPI


    def read(dictionary: false)
        api = getAPI(:metric, :GET)
        v = @nr.simpleAPI(api)
        return (if dictionary then v else v['value'] end)
    end

    # "Validate" a metric object.
    # There really is no way to do this in any way that carries much weight.
    # However, if a user gives you a metricId and you'd like to know if
    # that actually IS a metricId, this might be useful. Realize that
    # even a valid metric can be deleted out from under and become invalid.
    #
    # Reads the metric, catches the specific exceptions that occur for 
    # invalid metric IDs, and returns True/False. Other exceptions mean
    # something else went awry (server down, bad authentication, etc).
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


    # define the events, stream, interactions, and subscriptions methods
    # All have same pattern so we use some of Ruby's awesome meta hackery
    %w(events stream interactions subscriptions).each do |w|
        define_method(w) do | &block |
            @nr.chunkedIterator(APIInfo[w.to_sym], {metricId:@id}, block)
        end
    end

    # This is an individual subscription -- namely, yours.
    # normal users can never see anything other than their own
    # subscription so there is really no point in ever supplying
    # the userId parameter (the default is all you can ever use)
    def subscription(userId=nil)
        api = getAPI(:subscription, :GET, {userId: userId})
        return @nr.simpleAPI(api)
    end

    # Subscribe to a metric. See the API docs for what should be
    # in the dict. This function will fetch the current parameters
    # and update them with the ones you supply (because the server
    # does not like you supplying an incomplete dictionary here).
    # While in some cases this might be a bit of extra overhead
    # it doesn't really matter because how often do you do this...
    # You can, however, stop that with overwriteAll=True
    #
    # NOTE that you really can only subscribe yourself, so there
    #      really isn't much point in specifying a userId 
    def subscribe(dict, userId:nil, overwriteAll:False)
        if overwriteAll
            params = {}
        else
            params = subscription(userId)
        end

        dict.each { |k, v| params[k] = v }

        api = getAPI(:subscription, :PUT, { userId: userId })
        return @nr.simpleAPI(api, jdict:params)
    end

    # write a value to a metric.
    #
    #   onlyIf=true sends the "only if it changed" feature of the NumerousAPI.
    #      -- throws NumerousMetricConflictError if no change
    #   add=true sends the "action: ADD" (the value is added to the metric)
    #   dictionary=true returns the full dictionary results.
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
                raise NumerousMetricConflictError.new(e.details, 0, "No Change")
            else
                raise e        # never mind, plain NumerousError is fine
            end
        end

        return (if dictionary then v else v['value'] end)
    end

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
    def like
        # a like is written as an interaction
        return writeInteraction({ 'kind' => 'like' })
    end

    #
    # Write an error to a metric
    #
    def sendError(errText)
        # an error is written as an interaction thusly:
        # (commentBody is used for the error text)
        j = { 'kind' => 'error' , 'commentBody' => errText }
        return writeInteraction(j)
    end

    #
    # Simply comment on a metric
    #
    def comment(ctext)
        j = { 'kind' => 'comment' , 'commentBody' => ctext }
        return writeInteraction(j)
    end

    # various deletion methods.
    # NOTE: If you try to delete something that isn't there, you will
    #       see an exception but the "error" code will be 200/OK.
    # Semantically, the delete "works" in that case (i.e., the invariant
    # that the thing should be gone after this invocation is, in fact, true). 
    # Nevertheless, I let the exception come through to you in case you 
    # want to know if this happened. This note applies to all deletion methods.

    def photoDelete
        api = getAPI(:photo, :DELETE)
        v = @nr.simpleAPI(api)
        return nil
    end

    def eventDelete(evID)
        api = getAPI(:events, :DELETE, {eventID:evID})
        v = @nr.simpleAPI(api)
        return nil
    end

    def interactionDelete(interID)
        api = getAPI(:interactions, :DELETE, {item:interID})
        v = @nr.simpleAPI(api)
        return nil
    end

    # be 100% sure, because this cannot be undone. Deletes a metric
    def crushKillDestroy
        api = getAPI(:metric, :DELETE)
        v = @nr.simpleAPI(api)
        return nil
    end

end



