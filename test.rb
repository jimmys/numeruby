#!/usr/bin/env ruby

require 'optparse'
require 'numerousapp'
require 'net/http'
require 'uri'

exitStatus = 0
$deleteTheseMetrics = []

def testingMsg(s)
    puts("TESTING::: #{s}")
end

def failedMsg(s)
    puts("FAILED:::: #{s}")
end

def resultsMsg(s)
    puts("RESULT:::: #{s}")
end

def infoMsg(s)
    puts("::INFO:::: #{s}")
end

def onlyIfTest(m, v, expectX:true)

    testingMsg("Writing #{v} with onlyIf and expectX:#{expectX}")
    gotX = false
    begin
        m.write(v, onlyIf:true)
    rescue NumerousMetricConflictError => e
        if not expectX
            failedMsg("got unexpected exception: #{e.inspect}")
        end
        gotX = true
    end

    if expectX and not gotX
        failedMsg("Did got get expected Exception")
    end

    return ((expectX and gotX) or ((not expectX) and (not gotX)))
end



# convenience function:
#   creates a PRIVATE metric
#   accepts additional attrs
#   automatically pushes the metric onto the given list
#   (used to push the metric onto the "delete These" list)
#
#   automatically prints an info message
def privateDeletableMetric(nr, label, pushTo, attrs:nil)
    if not attrs
        attrs = { 'private' => true }
    else
        attrs = attrs.clone
        attrs['private'] = true
    end
    infoMsg("Creating #{label} with attrs #{attrs}")
    m = nr.createMetric(label, attrs:attrs)
    pushTo.push m
    return m
end

# Typically the PID is used but can be any integer that
# (ideally) isn't always the same
def numTests(nr, opts)
    testLabelPrefix = "TESTXXX-"

    testingMsg("Version under test: #{nr.agentString}")

    testVary = opts[:vary]

    if opts[:debug]
        nr.debug(1)
    else
        # we actually still want to test debug, for regression purposes
        # (i.e., I broke it once, don't want to do that again)
        # so ... cons up a temporary nr and try one thing with debug
        infoMsg("Testing debug ... one call to nr.ping with debug on")
        nr2  = Numerous.new(opts[:key])
        nr2.debug(1)
        nr2.ping()
    end

    # set it up to keep the last time server-response times (just for infotainment)
    nr.statistics[:serverResponseTimes] = [0]*10

    if opts[:perfonly]
        10.times { nr.user() }
        return true
    end

    begin
        testingMsg("nr.ping()")
        nr.ping()
    rescue NumerousAuthError
        failedMsg("NumerousAuthError exception.")
        infoMsg("Check setting of NUMEROUSAPIKEY environment or -c CREDSPEC")
        return false
    end

    mVal = 999
    mAttrs = {'private' => true, 'value' => mVal}
    testingMsg("nr.createMetric(#{mAttrs})")

    mName = "#{testLabelPrefix}NumerousAPI#{testVary}"
    m = privateDeletableMetric(nr, mName, $deleteTheseMetrics, attrs:mAttrs)

    resultsMsg("Created: #{m}")
    if m.read != mVal
        failedMsg("Wrong value read back #{m.read} should have been #{mVal}")
        return false
    end

    testingMsg("Looking up by label using STRING")
    m2 = nr.metricByLabel(mName, matchType:'STRING')
    if not m2 or m.read != mVal
        failedMsg("Didn't find it by label/STRING")
        return false
    end

    # test all the variations of ByLabel
    # make some similar names so we can test 'ONE' and 'BEST'

    middlePart = "XyzzY#{testVary}"
    endKey="7777"
    endPart=endKey
    xxx = []
    for i in 1..5
        endPart += "7"
        xxx[i-1] = endPart
    end

    # semi-random order on purpose
    for i in [3, 1, 4, 5, 2]
        mOneStr =  "#{testLabelPrefix}#{middlePart}-"+xxx[i-1]
        privateDeletableMetric(nr, mOneStr, $deleteTheseMetrics)
    end

    begin
        testingMsg("Looking up using matchType:FIRST")
        mx = nr.metricByLabel(/#{middlePart}/, matchType:'FIRST')
        if not mx
            failedMsg("Didn't get any match")
        else
            resultsMsg("Got #{mx.label}")
        end
        testingMsg("Looking up duplicate ByLabel with matchType:ONE")
        mx = nr.metricByLabel(/#{middlePart}/, matchType:'ONE')
        failedMsg("Failed ... didn't throw exception")
        return false
    rescue NumerousMetricConflictError => e
        resultsMsg("Correctly caught ConflictError, message: #{e.message}")
    end

    testingMsg("Looking up using BEST")
    rx = endKey + "\\d+$"
    mx = nr.metricByLabel(/#{rx}/,matchType:'BEST')
    resultsMsg("got BEST: #{mx.label}")

    testingMsg("Looking up ByLabel ID")

    # find any of the test metrics we've already made, doesn't really matter which
    # (implicitly also a regexp test)
    mx = nr.metricByLabel(/#{testLabelPrefix}.*#{testVary}/)

    # ok now see if we can find that one using the 'ID' feature of ByLabel
    mx2 = nr.metricByLabel(mx.id.to_s, matchType:'ID')

    # really the "or" part is redundant but it's just implicitly another test
    if (mx.id != mx2.id) or (mx['value'] != mx2['value'])
        failedMsg('Looking up by ByLabel/ID failed to get the correct metric')
        return false
    end

    # test the conflict part of 'STRING' ... make a second metric matching mx label
    privateDeletableMetric(nr, mx['label'], $deleteTheseMetrics)
    begin
        testingMsg("Looking up a duplicated label with matchType:STRING")
        ignored = nr.metricByLabel(mx['label'], matchType:'STRING')
        failedMsg("Failed ... didn't throw exception")
        return false
    rescue NumerousMetricConflictError => e
        resultsMsg("Correctly caught ConflictError, message: #{e.message}")
    end

    # write a value see if it gets there

    testingMsg("Write #{testVary}")
    m.write testVary
    if m.read != testVary
        failedMsg("Wrong value read back #{m.read} should have been #{testVary}")
        return false
    end

    # write the same value again with onlyIf; should throw conflict exception
    if not onlyIfTest(m, testVary, expectX:true)
        return false
    end


    testingMsg("writing a comment")

    cmt = "This be a righteously commentatious comment"
    cId = m.comment(cmt)
    m.interactions do |v|
        if v['commentBody'] == cmt
            break
        else
            # it's supposed to be the first one, so we know this is bad
            failedMsg("Got bad comment back: #{v}")
            return false
        end
    end

    testingMsg("m.interaction(#{cId}) to read the comment back")
    i = m.interaction(cId)
    if i['commentBody'] != cmt
        failedMsg("got #{i}")
        return false
    end

    # try onlyIf test again, comment should not have changed behavior
    if not onlyIfTest(m, testVary, expectX:true)
        return false
    end

    # write a different value, then delete that event, then try onlyIf AGAIN
    m.write testVary+1

    # the onlyIf should not see exception here
    if not onlyIfTest(m, testVary, expectX:false)
        return false
    end

    # ok, again, write the altered value
    m.write testVary+1

    id = m.events { |e| break e['id'] }    # haha/wow what a way to say this

    testingMsg("m.event(#{id}) to read back the value update")
    e = m.event(id)
    if e['value'] != testVary+1
        failedMsg("Got #{e}")
        return false
    end

    # delete that altered value write
    m.eventDelete(id)

    # and so now expect the onlyIf to fail
    if not onlyIfTest(m, testVary, expectX:true)
        return false
    end

    testingMsg("m.event(#{id}) after that id has been deleted")
    begin
        e = m.event(id)
        failedMsg("Got #{e}")
        return false
    rescue NumerousError => x
        if x.code != 404
            failedMsg("Got error but not the expected one. /#{x}/")
            return false
        end
    end

    testingMsg("Testing the [ ] operator")
    v = m.read
    if m['value'] != v
        failedMsg("Did not get same result from m['value'], got #{m['value']}")
        return false
    end

    # see if writing updates the cache correctly
    testingMsg("Testing the [ ] cache consistency")
    m.write v+1
    if m['value'] != v + 1
        failedMsg("Did not get updated result from m['value'], got #{m['value']}")
        return false
    end

    # see if caching works, by purposefully creating cache inconsistency
    testingMsg("More [ ] caching tests")
    m2 = nr.metric(m.id)
    v = m2['value']
    v = m['value']
    # both metrics should have caches now, so update m2 see if m stays stale
    m2.write v+1
    if m['value'] != v
        failedMsg("Caching didn't work as expected")
        return false
    end

    # test add
    testingMsg("ADD 1")
    m.write(17)
    m.write(1, add:true)
    if m.read != 18
        failedMsg("#{m.read(dictionary:true)}")
        return false
    end

    # test a bunch of ADDs
    testingMsg("MORE ADDs")
    m.write(17)
    m.write(3, add:true)
    m.write(-21, add:true)

    # should be -1 now
    if m.read != -1
        failedMsg("*** FAILED: #{m.read(dictionary:true)}")
        return false
    end

    infoMsg("server response time data: #{nr.statistics[:serverResponseTimes]}")

    # test error ... first turn off notifications (doh!)
    testingMsg("turning off error notifications")
    m.subscribe({ 'notifyOnError' => false })

    testingMsg("Setting an error")
    errText = "This is the error info"
    m.sendError(errText)

    e2 = m.interactions { |e| break e['commentBody'] }

    if errText != e2
        failedMsg("Got #{e2} instead of #{errText}")
        return false
    end

    # update the metric description
    testingMsg("Updating metric description and units")
    d = "This is the metric's porpoise in life"
    u = "blivets"

    m.update({ "description" => d, "units" => u})

    rd = m.read(dictionary:true)["description"]
    if rd != d
        failedMsg("Got #{rd} expected #{d}")
        return false
    end

    ru = m.read(dictionary:true)["units"]
    if ru != u
        failedMsg("Got #{ru} expected #{u}")
        return false
    end

    # now if we just update the description the units should be preserved
    # (because of the read/modify/write built into the method)
    m.update({"description" => "something else"})

    ru = m.read(dictionary:true)["units"]
    if ru != u
        failedMsg("Got #{ru} expected #{u}")
        return false
    end


    # test some of the /v2 parameters
    testingMsg("Updating metric graphing options to test /v2")
    g = { "defaultGraphType" => "bar" }
    m.update({ "graphingOptions" => g } )
    rg = m.read(dictionary:true)["graphingOptions"]
    if rg != g
        failedMsg("Got #{rg} expected #{g}")
        return false
    end

    # like a metric
    testingMsg("m.like")
    m.like

    # see if it is there at the top of the stream
    lk = m.stream { |s| break s }

    if lk['kind'] != 'like'
        failedMsg("got /#{lk}/")
        return false
    end


    testingMsg("event deletion... making events")
    # more testing of event deletion
    vals = [ 100, 101, 102, 103, 104]
    ids = []

    vals.each { |i| ids.push(m.write(i,dictionary:true)['id']) }

    # current value should be last one sent
    testingMsg("read back last value")
    if m.read != vals[-1]
        failedMsg("Value is #{m.read}")
        return false
    end

    testingMsg("deleting #{ids[1]}")
    # if we delete a middle value the value should not change
    m.eventDelete(ids[1])

    testingMsg("verifying no change in value")
    # current value should be last one sent
    if m.read != vals[-1]
        failedMsg("Value is #{m.read}")
        return false
    end

    testingMsg("deleting #{ids[1]} again (should fail)")
    gotExpected = false
    begin
        m.eventDelete(ids[1])
    rescue NumerousError => e
        gotExpected = (e.code == 404)
    end

    if not gotExpected
        failedMsg("did not get expected exception")
        return false
    end

    # now delete the top (last) event and the value SHOULD change
    testingMsg("deleting #{ids[-1]}")
    m.eventDelete(ids[-1])
    # current value should be last one sent
    testingMsg("appropriate change in value")
    if m.read != vals[-2]
        failedMsg("Value is #{m.read}")
        return false
    end


    # test comment deletion (interaction deletion)
    testingMsg("making a comment")

    cmt = "This is the magic comment string"
    cmtId = m.comment(cmt)

    # the comment should be there ... verify
    testingMsg("verifying it is there")
    found = false
    m.stream { |s| if s['commentBody'] == cmt; found = true; break; end }

    if not found
        # this would be odd, but it's not there
        failedMsg("could not find comment we just wrote")
        return false
    end

    # now delete the comment
    testingMsg("deleting the comment (#{cmtId})")
    m.interactionDelete(cmtId)

    # and the comment should NOT be there ... verify
    testingMsg("Verifying that it is gone")
    found = false
    m.stream { |s| if s['commentBody'] == cmt; found = true; break; end }

    if found
        failedMsg("the comment is still there!")
        return false
    end

    infoMsg("Testing fine-grained permissions")
    myUser = nr.user()
    infoMsg("My user ID is #{myUser['id']} (#{myUser['userName']})")
    if opts[:altcreds]
        nr2 = Numerous.new(Numerous.numerousKey(s:opts[:altcreds]))
        altUser = nr2.user()
        infoMsg("Alternate user ID is #{altUser['id']} (#{altUser['userName']})")
    else
        nr2 = nil
    end

    testingMsg("Setting metric to private visibility")
    m.update({'visibility' => 'private'})

    # there shouldn't be any perms now
    n = 0; m.permissions { n +=1 }
    if n != 1
        failedMsg("wrong number of permissions, expected one")
        return false
    end

    if not nr2
        infoMsg("skipping detailed perms tests because no second creds given")
    else
        m2 = nr2.metric(m['id'])

        # try to read it with the secondary creds; should fail
        knownval = 988
        m.write(knownval)
        testingMsg("Attempting to read via secondary creds")
        begin
            m2.read
            failedMsg("Was able to read via secondary creds without perms")
            return false
        rescue NumerousError => e
            if e.code != 403
                failedMsg("Did not get proper exception")
                return false
            end
        end

        # give that user permission
        testingMsg("Giving the alternate user read permission")
        m.set_permission({'readMetric' => true }, altUser['id'])

        # now this read should succeed
        testingMsg("Trying read again")
        if m2.read() != knownval
            failedMsg("Didn't get proper readback")
            return false
        end

        # then delete the perms and it should fail again
        testingMsg("Deleting those perms")
        m.delete_permission(altUser['id'])

        testingMsg("reading again, now without perms")
        begin
            m2.read
            failedMsg("Was able to read via secondary creds after perms deleted")
            return false
        rescue NumerousError => e
            if e.code != 403
                failedMsg("Did not get proper exception from deleted perms")
                return false
            end
        end
    end
    infoMsg("cursory perms tests complete; full test was in python")

    # write a (one pixel) photo to the metric

    # this 35 byte GIF file is "debateably legal" and does not come
    # back from the numerous server unchanged.
    # img = "\x47\x49\x46\x38\x39\x61\x01\x00\x01\x00\x80\x00\x00\xff\xff\xff\x00\x00\x00\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x44\x01\x00\x3b".b
    #
    # whereas this 43 byte GIF file survives the round trip
    #
    img = "\x47\x49\x46\x38\x39\x61\x01\x00\x01\x00\xf0\x00\x00\xff\xff\xff\x00\x00\x00\x21\xf9\x04\x00\x00\x00\x00\x00\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x44\x01\x00\x3b".b


    testingMsg("setting photo")
    r = m.photo(img)

    # now get the photo URL back
    phurl = m.photoURL
    if not phurl
        failedMsg("could not read back photo URL")
        return false
    end

    # and read the photo and compare it
    u = URI.parse(phurl)
    h = Net::HTTP.new(u.host, u.port)
    h.use_ssl = (u.scheme == "https")
    rq = Net::HTTP::Get.new(phurl)
    resp = h.request(rq)

    if img != resp.body
        failedMsg("did not get back same image")
        failedMsg(" ... Image: Length #{img.length} /#{img}/")
        failedMsg(" ... Reslt: Length #{resp.body.length} /#{resp.body}/")
        return false
    end

    # timer testing

    mAttrs = {'private' => true, 'kind' => 'timer'}
    testingMsg("nr.createMetric(#{mAttrs})")

    name = "#{testLabelPrefix}TMR-NmAPI#{testVary}"
    mtmr = privateDeletableMetric(nr, name, $deleteTheseMetrics, attrs:mAttrs)
    resultsMsg("created #{mtmr}")


    # just try writing to it, we don't really test that it displays correct
    testingMsg("writing to timer")
    mtmr.write(123456)

    # create a virgin metric to bang on
    name = "#{testLabelPrefix}V-NumerousAPI#{testVary}"
    mvir = privateDeletableMetric(nr, name, $deleteTheseMetrics)
    resultsMsg("Created: #{mvir}")

    # verify that the collection flavors all work correctly on virgin metric
    gotAny = false

    mvir.events { |x| puts x ; gotAny = true }
    mvir.interactions { |x| puts x ; gotAny = true }
    mvir.stream { |x| puts x ; gotAny = true }

    if gotAny
        failedMsg("GOT SOMETHING!")
        return false
    end


    # now to test the chunking functions
    # we need to create a LOT of metrics so that the server
    # will divide our metric listing up into multiple GETs under the covers

    # number determined empirically to cause chunking
    # of course this could change if server implementation changes.
    nMetrics = 40
    if opts[:quick]
        nMetrics = 4      # but this doesn't really test what is intended
    end

    testingMsg("making #{nMetrics} metrics")
    oneName = 'XXX-DELETEME-XXX'   # we can make them all with the same name
    lotsaMetrics = []
    nMetrics.times do |i|
        mAttrs = {'value' => i }
        x = privateDeletableMetric(nr, oneName, $deleteTheseMetrics, attrs:mAttrs)
        lotsaMetrics.push x
    end

    if lotsaMetrics.length != nMetrics
        failedMsg("they didn't all get made")
        return false
    end

    # see if we got them all there.
    verified=[]
    n = 0
    nr.metrics do |mh|
        if mh['label'] == oneName
            whichV = mh['value']
            # the slot should not already be occupied
            if not verified[whichV]
                verified[whichV] = mh['id']
                n += 1
            end
        end
    end

    if n != nMetrics or verified.length != nMetrics
        failedMsg("metrics not as expected")
        puts "   - here's the ID array -"
        puts verified
        puts "   - - - - - - -"
        return false
    end

    # do the same thing for events and interactions, but less rigorously

    m = privateDeletableMetric(nr, oneName, $deleteTheseMetrics)

    nTimes = 300
    if opts[:quick]
        nTimes = 5      # but this doesn't really test anything much
    end

    testingMsg("writing #{nTimes} comments and events")
    nTimes.times do |i|
        if i % 25 == 0
            infoMsg(" ... progress: #{i}")
        end
        m.write(i)
        m.comment('this is a comment')
    end

    testingMsg("verifying comment and event count")

    n = 0
    testingMsg("... events")
    m.events { n += 1 }

    if n != nTimes
        failedMsg("only got #{n} events")
        return false
    end

    n = 0
    testingMsg("... interactions")
    m.interactions { n += 1 }
    if n != nTimes
        failedMsg("only got #{n} interactions")
        return false
    end

    # should be 2x in the stream
    n = 0
    testingMsg("... stream")
    m.stream { n += 1 }
    if n != nTimes*2
        failedMsg("only got #{n} stream items")
        return false
    end

    infoMsg("server response time data: #{nr.statistics[:serverResponseTimes]}")

    return true

end




options = {}
OptionParser.new do |opts|

    opts.banner = "Usage: test.rb [options]"

    opts.on("-c", "--credentials CREDS", "credential info") do |c|
        options[:creds] = c
    end

    opts.on("-A", "--altcredentials CREDS", "secondary credential info") do |c|
        options[:altcreds] = c
    end

    opts.on("-Q", "--quick", "quick mode") { options[:quick] = true }

    opts.on("-P", "--performance", "performance test") {
       options[:perfonly] = true
    }
    opts.on("-D", "--debug", "debug") { options[:debug] = true }
    opts.on("-V", "--varyValue VAL", "variable value") do |v|
        options[:vary] = v
    end

    opts.on("-h", "--help", "Display this screen") { puts opts; exit 0 }


end.parse!

k = Numerous.numerousKey(s:options[:creds])

options[:key] = k


nr = Numerous.new(k)


if not options[:vary]
    options[:vary] = $$     # ideally some value that is different each time
end

begin
  if not numTests(nr, options); exitStatus = 1 end
rescue NumerousError => e
  puts "Test failed/exception:: #{e.inspect}"
  exitStatus = 1
rescue NoMethodError => e
  puts "something went really wrong got NoMethodError #{e.inspect}"
  exitStatus = 1
end

$deleteTheseMetrics.each { |m| m.crushKillDestroy }
infoMsg("statistics: #{nr.statistics}")
exit(exitStatus)
