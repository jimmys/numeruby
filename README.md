# Ruby NumerousApp API

A ruby class implementing the [NumerousApp](http://www.numerousapp.com) [APIs](http://docs.numerous.apiary.io).

## Development Status

Packaged as a gem under the name "numerousapp" on rubygems.org

The source here on github is the current/newest; what you get on rubygems (gem install) is the stable "released" version and so tends to lag behind the github code. Choose accordingly.

### New in 1.2.5
* event() method now supports 'at' API (lookup via timestamps)

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

