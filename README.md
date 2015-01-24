# Ruby NumerousApp API

A ruby class implementing the [NumerousApp](http://www.numerousapp.com) [APIs](http://docs.numerous.apiary.io).

## Development Status

Works, passes all my tests. 

Packaged as a gem under the name "numerousapp" on rubygems.org

## Documentation
Personally I find the automatically generated YARD docs on rubygems to be a bit "funky" to read, plus occasionally there are some glitches I haven't quite figured out yet. Nevertheless, they are over there on rubygems for your reference.

In addition I've been creating a [wiki](https://github.com/outofmbufs/numeruby/wiki) hosted here on github. 

It is not yet complete, but you can start there.

Until I complete the numeruby wiki you may find it helpful to also look at the python docs which are much more complete, and then look at the source here to see how those concepts translate. I tried to not just "write python in ruby", but it is true that I developed the class in python and then translated it over to ruby. So you'll see a lot of common concepts, interfaces, etc.

The [python class documentation](https://github.com/outofmbufs/Nappy/wiki) is on github.


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

m.events { |v| puts "Event: /#{v}/\n" }
m.stream { |v| puts "Stream: /#{v}/\n" }
m.interactions { |v| puts "Interactions: /#{v}/\n" }
m.subscriptions { |v| puts "Subscriptions: /#{v}/\n" }

```

