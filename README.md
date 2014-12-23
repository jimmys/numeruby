# Ruby NumerousApp API

A ruby "translation" of the "Nappy" (numerous.py) python class implementing
the [NumerousApp](http://www.numerousapp.com) [APIs](http://docs.numerous.apiary.io).

## Development Status

I'm putting this up here "early" just to signal that it's in process. This version isn't complete yet though the basic functions work.

## Getting started

Example code:

```
require 'numerous'

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

