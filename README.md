# Ruby NumerousApp API

A ruby class implementing the [NumerousApp](http://www.numerousapp.com) [APIs](http://docs.numerous.apiary.io).

## Development Status

Packaged as a gem under the name "numerousapp" on rubygems.org

The source here on github is the current/newest; what you get on rubygems (gem install) is the stable "released" version and so tends to lag behind the github code. Choose accordingly.


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

