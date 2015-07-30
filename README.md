# Ruby NumerousApp API

A ruby class implementing the [NumerousApp](http://www.numerousapp.com) [APIs](http://docs.numerous.apiary.io).

## Development Status

Packaged as a gem under the name "numerousapp" on rubygems.org

The source here on github is the current/newest; what you get on rubygems (gem install) is the stable "released" version and so tends to lag behind the github code. Choose accordingly.

### New in 1.2.4
All server API endpoints converted to /v2 URLs. This is a minor update because there are no semantic changes. The few APIs that had real differences between /v1 and /v2 had been updated a long time ago, but the numerous server did not support /v2 endpoints for all APIs (i.e., the ones that had no reason to "go to" /v2 still had only /v1 endpoints). Numerous just activated their new server that now supports /v2 endpoints across the board; accordingly, 1.6.3 now uses the /v2 endpoints for everything. It's just a "spelling" change in the underlying endpoints.


### New in 1.2.3
* Voluntary throttling computes dynamic appropriate delay (vs hardcoded delay). If you are doing a gazillion API calls in a tight loop, this squeezes the maximum number of calls per minute out of the server (rate-limited by the server) while at the same time being "nice" to other apps using the same API key (i.e., same rate limit). The idea is that it is "smearing" the inevitable "out of API calls" delay over the tail end of your API allocation, the goal being to get the maximum number of APIs through per minute without actually hitting the hard rate limit. It works pretty well, getting about 299.7 API/minute (if no other apps are using your API key) vs a theoretical 300/minute, while respecting the API consumption of any other apps you are running and never actually hitting the hard rate limit from the server. It's pretty clear it's time to send the Engineer on vacation and lock development. (haha)
* Allow `updated` argument in metric writes to be a formattable time object as well as an already-formatted string.

### New in 1.2.2
* 1.2.2 fixes the debug method which got broken by the 1.2.1 keep-alive
* 1.2.1 included this (as does 1.2.2 of course): Performance fix: uses keep-alive so your second (and subsequent) API calls to the server will be MUCH faster. Depends on the particular API but the fastest ones will now be 60-70msec vs 300-ish msec without keep-alive. The first one will always be slow (300msec) though (TCP overhead, https negotiation, etc)

## Documentation Wiki

Primary documentation is here on github: [wiki](https://github.com/outofmbufs/numeruby/wiki).

## Getting started

Example code:

```
require 'numerousapp'    # if you installed it as the numerousapp gem
                         # if you hand-installed this file then 'numerous'

myApiKey = 'nmrs_28Cblahblah'
myMetric = '5476250826738809221'

nr = Numerous.new(myApiKey)
m = nr.metric(myMetric)

m.write(33)

# can also access fields this way:
puts(m['label'])

m.events { |v| puts "Event: /#{v}/\n" }
m.stream { |v| puts "Stream: /#{v}/\n" }
m.interactions { |v| puts "Interactions: /#{v}/\n" }
m.subscriptions { |v| puts "Subscriptions: /#{v}/\n" }

```

