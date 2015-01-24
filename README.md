# Ruby NumerousApp API

A ruby class implementing the [NumerousApp](http://www.numerousapp.com) [APIs](http://docs.numerous.apiary.io).

## Development Status

Works, passes all my tests. 

Packaged as a gem under the name "numerousapp" on rubygems.org

## Documentation
The YARD docs on rubygems aren't quite working right and I'm not yet sure why. The docs are there it's just that not all of the directives came through the way I want them to.

In the meantime you may find it helpful to also look at the python docs which are much more complete, and then look at the source here to see how those concepts translate. I tried to not just "write python in ruby", but it is true that I developed the class in python and then translated it over to ruby. So you'll see a lot of common concepts, interfaces, etc.

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

